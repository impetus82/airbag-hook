# Build log

Running notes kept during the UHI10 Hookathon window (17 Aug – 3 Sep 2026). Written as the work
happens, not reconstructed afterwards. Feeds the progress updates and the final submission's
Problem / Impact / Challenges write-ups.

---

## Day 1 — 17 Aug

**Goal: prove the plumbing before writing any displacement math.** The cheapest day to discover
that the v4 wiring is wrong is the first one.

### Built

- `AirbagHookBase` implementing `IHooks` directly, plus `AirbagHook` with `beforeSwap`,
  `afterSwap`, `afterSwapReturnDelta`.
- `beforeSwap` snapshots the pool tick into transient storage; `afterSwap` reads it back and
  reports the tick span the swap swept.
- 3 passing tests: mined address encodes the intended permission bits, pool initializes with the
  hook attached, a real swap round-trips through both callbacks with the pre-tick matching.

### Decisions

**Implement `IHooks` directly instead of inheriting a periphery `BaseHook`.** The current
v4-periphery `main` has moved `BaseHook` out of `src`. Rather than pin an older tag, the base is
written here: one fewer moving dependency, and the entire permission surface is visible in a
single file.

**Assert the permissions we do *not* hold.** A stray flag bit in the mined address would enable a
callback that reverts `HookNotImplemented` — which would brick every pool using the hook. The
test asserts those bits are zero, not just that the wanted ones are set.

**Threshold is not a tuned constant.** It is the pool's own fee. Below it the maker has already
been compensated by the fee earned on their own fill, so the hook must stay silent; above it they
are genuinely out of pocket. This falls out of the measurement, not from taste.

### Challenges

1. **`BaseHook` vanished from v4-periphery's `src`.** Discovered only after installing. Turned
   into an advantage — see above.
2. **Inline assembly cannot reference a `keccak256` constant.** The transient slot had to become
   a hard-coded literal. Mitigated with a test that pins the literal to
   `keccak256("airbag.preTick")`, so the two cannot silently diverge.
3. **Duplicate type identities from import paths.** Importing `Deployers` as
   `v4-core/../test/utils/Deployers.sol` produces an un-normalized path, and solc then treats the
   `IPoolManager` reached through it as a *different type* from the one imported directly —
   `Invalid implicit conversion from contract IPoolManager to contract IPoolManager`. Fixed by
   routing every v4-core import through one canonical prefix.
4. **Submodules vs a clean clone.** `v4-periphery` is a submodule, so a plain `git clone` leaves
   it empty and `forge build` fails. Since "judges can build it" is a pass/fail gate, the README
   now documents the recursive clone.

   Verifying that took two attempts, and the first failure was instructive: `forge test` run
   immediately after `git clone --recurse-submodules` failed on a missing `solmate/MockERC20`,
   because the nested submodules two levels down (`v4-periphery → v4-core → solmate`) were still
   being fetched. Re-run against the settled clone: builds clean, 3/3 pass. Worth knowing that
   the dependency tree is deep enough for this to be a real race on a slow network.

---

## Day 2 — 17 Aug (same session as day 1)

**Goal: an order is a position, not a promise.**

### Built

`AirbagOrders`: a limit order is one tick-spacing of liquidity sitting entirely on one side of
the market, owned as an ERC-721. `createOrder` / `cancelOrder` go through `unlock` →
`unlockCallback` → `modifyLiquidity`, settling the maker's side directly.

6 new tests (9 total, all green): correct side inferred above and below the market, only the
funding token is pulled, straddling and unaligned ticks rejected, cancel refunds and burns,
cancel is owner-only.

### Decisions

**Concentrated liquidity does the filling.** When the market crosses the range, the position
converts on its own from the deposited token into the requested one. So "executing" an order is
bookkeeping rather than a second swap: no counterparty inventory, no routing back through the
pool, and — the part that matters here — nothing that perturbs the very price we are about to
measure displacement against.

**The side is derived, never trusted.** A caller does not declare `zeroForOne`; it follows from
where the tick sits relative to the market. A range above the market can only be funded with
`currency0`, one below only with `currency1`. A range straddling the market would be born
partially filled, which makes both the side and the later displacement measurement ambiguous —
so it is rejected at creation rather than handled downstream.

**Ownership is an NFT because the rebate has a recipient.** This is the whole differentiator:
every comparable design pays the pool at large, Airbag pays the specific maker who was run over.
That requires per-order identity from day one, not bolted on later.

### Challenges

5. **Colliding error declarations across inheritance branches.** Both the hook base and the order
   book independently declared `error NotPoolManager()`, which is an "Identifier already declared"
   at the point they meet. Fixed by hoisting it to file scope and sharing one definition — the
   same guard genuinely means the same thing in both places.

---

## Day 3 — 19 Aug

**Goal: notice which orders the market filled — cheaply, and without lying.**

### Built

Fill detection. Each pool keeps its own tick bitmap of ticks that host waiting orders, so
`afterSwap` walks only ticks that actually contain something, using v4-core's `TickBitmap`.
Orders fully crossed by the swap are marked filled and removed from their tick's waiting list;
the bitmap bit clears when the last order at a tick leaves.

6 new tests (15 total, all green): fills on a rising cross, fills on a falling cross, an
untouched order stays waiting, five orders fill in a single swap, a cancelled order leaves
nothing behind to fill — and the negative case below.

### Decisions

**Only fully crossed orders count.** If the price stops *inside* a maker's range the position is
only partly converted: they have not received their limit price, and there is no displacement
past their tick to compensate. Marking that filled would be a lie the rest of the design would
then be built on, so there is an explicit test for it.

**The scan budget is spent only inside the region the swap crossed.** The walk is anchored at
the market and returns the moment it leaves the fillable region; because the bitmap is ordered,
orders resting far away are never visited and so cannot be used to exhaust the budget. This is a
direct lesson from auditing my own previous hook, where a scan anchored at a sentinel could be
starved with ~100 dust orders. Cheap to mount, and I do not intend to ship it twice.

### Challenges

6. **`vm.prank` eaten by a helper.** A test helper that resolved an aligned tick called
   `manager.getSlot0()` internally — an external call, which consumed the prank, so `createOrder`
   arrived from the test contract rather than the maker. The maker had approved the hook; the
   test contract had not, and solmate's `transferFrom` decrements the allowance unchecked, so the
   failure surfaced as `panic: arithmetic underflow` from deep inside the unlock callback rather
   than as anything resembling "wrong caller". Resolve values before pranking.

---

## Day 4 — 20 Aug

**Goal: the charge rule — how far past a maker the market went, and what that is worth.**

### Built

`AirbagMath`, deliberately a standalone library so the arithmetic can be reasoned about and
cross-checked without instantiating a pool. 13 tests, property-first (28 total, all green).

### Decisions

**Displacement is measured from the edge where the fill completed, not from the maker's near
tick.** Traversing the maker's own range *is* the fill, at the price they asked for. Charging for
it would be charging someone for the trade they wanted. Of the two available readings this is the
conservative one, which is the right bias for a number used to take money.

**The threshold is the pool's fee, and the charge applies to the excess above it.** A maker filled
by an ordinary swap has already collected the fee on their own fill, so below that line they are
not out of pocket and the hook must be silent. Only the part of the overshoot the fee did not
cover is compensable. This is why benign flow pays nothing without needing a special case for it.

**Rounding happens exactly once, in token units.** See below — this began as a failing test.

### Challenges

7. **Literal arithmetic in Solidity is exact rational.** `(4 * 7000) / 10_000` written as
   literals is `2.8`, not `2`, so it will not typecheck as a `uint256` — an expected value has to
   be the number the runtime actually produces. Mildly disorienting, and a good argument for
   writing expected values out longhand in tests rather than re-deriving them from the formula.

8. **A rounding bug the tests found before I did.** Computing the charge as whole basis points
   truncates 70% of a 1 bp overshoot to zero, and shaves 6.5 bps down to 6 on the measured tail
   mean — a double-digit share of the maker's compensation, silently. Fixed by keeping the
   rounded figure as a *view* for events and adding `chargeAmount`, which carries the unrounded
   value through and truncates once, in token units. It still truncates rather than rounds up:
   erring downward favours the party being charged, which is the right direction when the
   contract is taking someone's money.

---

## Day 5 — 21 Aug

**Goal: the charge stops being arithmetic and starts being money.**

### Built

`afterSwap` now prices every fill it detects and collects the total from the swap via
`afterSwapReturnDelta`, crediting each maker's order. 6 new tests (34 total, all green),
including the two that matter most: a gentle fill costs the swapper nothing, and running
yourself over is a losing trade.

### Decisions

**Take first, then return the delta.** The `take` leaves the hook owing the pool; the returned
delta cancels that, and the swapper ends up short by exactly the charge. Returning a delta
without taking would leave an unsettled balance and revert the entire swap — the charge has to be
built so that a mistake here fails loudly rather than quietly eating someone's trade.

**The rebate is booked per currency, not as one number.** The charge lands on the swap's
*unspecified* currency — the output of an exact-input swap, the input of an exact-output one —
which is not always the currency the order converted into. A single `accruedRebate` field would
have been silently wrong for half of all fills.

**Notional is denominated in the currency the charge is collected in.** The charge is a share of
a *price* move, so applying basis points to a notional measured in the other token would be an
arithmetic error across a units boundary. A fully converted single-tick position has an exact
value in both denominations, so the matching one is computed rather than approximated.

**Filling and pricing happen in one pass.** The context needed to price a fill is threaded down
the same walk that detects it. Two passes could disagree about which orders were filled, and a
maker filled without being compensated is precisely the outcome this hook exists to prevent.

### Challenges

9. **Tests calibrated by guessing a swap size.** The first version of the gentle-fill test picked
   an amount and hoped the price would stop somewhere reasonable; it overshot, charged, and
   failed. Displacement is the quantity under test, so it has to be *set*: both tests now drive
   the price to an exact tick with a `sqrtPriceLimitX96` and assert against a known distance.
   Much better tests than the ones I set out to write.

10. **`vm.prank` eaten by an approval — the same trap as day 3, in a new costume.** The self-fill
    test pranked the maker, then called a helper whose first statement was an `approve`, which
    consumed the prank; the swap arrived from the test contract and the measured cost was zero,
    so the assertion compared a real rebate against nothing. Rewritten to measure the fee paid on
    the swap directly, which is both correct and a stronger statement of the property.

---

## Day 6 — 22 Aug

**Goal: the maker gets paid, and the pool is protected from orders big enough to corrupt the
measurement.**

### Built

`claimOrder` — withdraws the converted position plus whatever Airbag credited, and burns the NFT.
A size guard at creation: an order may be at most 1% of the pool's active liquidity. 5 new tests
(39 total, all green).

### Decisions

**The rebate is paid from tokens the hook already holds.** They were taken from the filling swap
at the moment of the fill, not promised for later. Nothing about a claim depends on a future
price, a keeper, or anyone's solvency — which is the same reason deferred settlement was cut from
the design in the first place.

**Orders are capped at 1% of pool liquidity, for two structural reasons rather than one
stylistic one.** A position large relative to the pool moves the price on its own way out, which
would contaminate the very displacement it is compensated by; and an outsized order makes it
cheap for its own maker to walk the market across it deliberately. Active liquidity is a proxy
for depth — the order rests out of range, so they are not the same quantity — but it is the
honest measure available in-transaction without an oracle, which is a constraint this design
accepts everywhere else too.

**Validation order is part of the interface.** The size check initially ran before the
side-of-market check, so an order straddling the price reported "too large" instead of the
reason that actually mattered. Which side of the market an order is on is the more fundamental
question; it now answers first.

### Challenges

11. **The guard broke every earlier test, correctly.** Existing tests used order sizes that were
    a large fraction of the minimal fixture pool. Rather than shrink the orders, the pools are now
    deepened in setup — a realistic cap deserves a realistic pool.

12. **Deepening the pools then broke the swaps, for the third time in three days.** Every test
    that moved the price by *amount* stopped reaching its target once the pool got deep. This is
    the same failure as day 5, and the same fix: all of them now drive to an exact tick via
    `sqrtPriceLimitX96`. A test that guesses a swap size silently stops testing anything the
    moment pool depth changes; it took three separate encounters before I made it a rule.

13. **A helper that funded itself corrupted the assertions around it.** `_pushTo` called `deal`
    to make sure it could afford the swap, which reset balances that the surrounding test was
    measuring across — one assertion compared against a freshly dealt number, another underflowed.
    Funding belongs in setup, never inside a helper a measurement wraps.

---

## Day 7 — 22 Aug (same session as day 6)

**Goal: check the properties against states I would not have thought to construct.**

### Built

An invariant handler that places, cancels, claims and moves the market in arbitrary sequences,
plus three invariants. ~6,000 handler calls per run, no reverts, no violations. 42 tests total.

### Decisions

**The invariant that matters is that rebates are fully backed.** Every credit sitting on a live
order is a claim on tokens the hook is holding *right now* — nothing is owed out of a future
swap. If that could be broken, some maker's claim would fail at the exact moment they tried to
exercise it, which is the worst possible time to discover a shortfall. The other two invariants
guard against dangling records: an order that exists has an owner and liquidity, and an unfilled
order can never carry a credit.

This is also the payoff from cutting deferred settlement back in the design phase. Because the
charge is taken in the same transaction as the fill, "fully backed" is a property the contract
can actually hold, rather than a promise about someone's future solvency.

---

## Day 8 — 22 Aug (same session)

**Goal: make the headline number come from the contract, not from a model of it.**

### Built

`tools/fetch_fixture.py` — pulls a pool's Swap history straight from chain and writes the replay
fixture, plus the reference distribution the Solidity side is checked against. It lives in the
repo rather than in a scratch directory so the fixture is reproducible by anyone reading this.

`test/Backtest.t.sol` — replays that history through AirbagHook itself. First real result, from
48h of Base WETH/USDC: **1,055 swaps replayed, 520 orders filled, 180 of them compensated.**
Two thirds of fills cost the swapper nothing, which is the design working rather than the design
failing.

### Decisions

**The path is replayed as tick deltas, not absolute price.** The real pool sits near tick
-200000 and a fresh clone starts at zero; reproducing the absolute level would mean seeding
liquidity across an enormous range to no purpose, because displacement is measured in ticks and a
tick is a ratio. The shape of the path — the entire input — is preserved exactly.

**The maker placement rule is stated, then varied.** Where the makers sit is the free parameter
of any backtest like this, and it is the first thing a judge should poke at. So it is a named
constant with a comment rather than a buried magic number, and there is a second test that runs
the same history with a tight band and a wide one.

**The 48h fixture is for exercising the contract, not for the headline statistic.** That window
turned out far more volatile than typical: median displacement 6 bps against 2 bps over 30 days,
and a tail of 52% against ~20%. Quoting it as the product's economics would flatter the result by
roughly threefold. The 30-day measurement stays the number in the pitch, and this distinction
goes in the write-up rather than being quietly ignored.

### Challenges

14. **Scratch directories are not storage.** The 30-day fixture and the measurement script from
    before the window did not survive a session change. Annoying for an hour, right in the end:
    the tool now lives in the repo, which is where anything the submission's credibility rests on
    belongs.

15. **The replay silently did nothing.** Fixture ticks are absolute, around -200000; the clone
    starts at zero, and the guard keeping the price inside the seeded range skipped every single
    push. The test passed its "did we read the file" assertion and reported zero fills, which is
    exactly the kind of failure that looks like a boring empty result rather than a bug. Fixed by
    replaying deltas.

16. **Solidity truncates toward zero, which is not the same as flooring.** Aligning a negative
    tick with `(t / spacing) * spacing` rounds *up*, putting the grid base above the market, so
    half of every batch of orders was rejected as being on the wrong side of the price. Only
    visible once the path wandered below zero.

---

## Day 9 — 22 Aug (same session)

**Goal: close the hole that made the whole mechanism optional.**

### The attack

The charge is triggered by displacement measured at the moment a fill completes. That invites an
obvious dodge: clear the maker with a tiny swap so the fill is recorded at zero displacement,
then keep pushing the price with a second swap. Same actor, same block, same final price — and
the maker was paid nothing.

Splitting costs almost nothing. The pool fee is proportional, so two swaps of half the size pay
the same fee as one, plus a little gas. Written as a failing test first: one swap compensated the
maker, two swaps to the identical final price paid **zero**. The mechanism was decorative against
anyone who bothered.

### Built

Each actor's fills stay revisitable for the rest of the block. Any further displacement they add
later in the same block is charged as an *increment* against what the order has already been
compensated for, so five swaps now cost exactly what one swap costs. The test asserts that
equality rather than merely asserting a non-zero payment — "something was paid" would still leave
the dodge worth attempting for a smaller discount.

### Decisions

**Compensation is tracked as displacement already paid for, in ticks.** Ticks are
currency-agnostic, which is what lets a top-up land in a different currency than the original
charge without double counting — and it means a price that retreats never produces a refund,
because the increment is simply zero.

**Keyed on `tx.origin`.** The question being asked is which actor kept pushing the price, and a
router in between does not change the answer. This is accounting, not authorisation — `tx.origin`
is unsuitable for the latter and exactly right for the former.

**The revisit list is bounded.** It runs on the swap path, so it cannot be unbounded; an actor
filling more than eight orders in a single block is already past what the fee makes worthwhile.

### Challenges

17. **The prank trap, third time, third costume.** `hook.createOrder(key, t, manager.getLiquidity(...) / 500)`
    — the liquidity read sits in the *argument list*, so it executes after `vm.prank` and before
    the call it was meant to authorise. Same underflow-from-nowhere signature as day 3 and day 5.
    An external call in an argument is still an external call.

---

## Day 10 — 23 Aug

**Goal: know exactly where this lands before spending a wei.**

### Built

`script/AirbagConfig.sol`, `script/PredictAirbag.s.sol`, `script/DeployAirbag.s.sol`, and a fork
rehearsal that runs the whole deployment against the live chains. Both rehearsals pass: the mined
address reproduces against a real PoolManager and the pool initialises at the intended price.

Predicted, before any transaction:

| | Base | Unichain |
|---|---|---|
| hook | `0xc0D3834B3d0076139802096D0f56250bb234C0c4` | `0x6Fb9b0364ECAD42222E4F1EdE396F82CeBdb40C4` |
| currency0 | WETH | USDC |

### Decisions

**Deploy through the canonical CREATE2 factory, not from the sending account.** A hook address
has to be mined until it encodes the right permission bits, so unlike an ordinary deployment it
is not obvious in advance. Going through the factory makes the address depend only on the salt
and the init code — not on the deployer's nonce — so it can be predicted, written down, and then
*asserted* at deploy time rather than hoped for. The last time I deployed a hook, the address was
unknowable until the broadcast because the constructor path built a fresh dependency by nonce;
that is a mistake worth not repeating.

**Every chain difference lives in one config file.** Including one that would otherwise be a
latent bug: WETH sorts first on Base, USDC sorts first on Unichain, so `currency0` is a different
asset on each. Confining that to config means it cannot leak into the swap path as a
chain-specific branch.

**Rehearse on a fork of the real chain first.** The mined address, the permission-bit validation
and the pool initialisation now get exercised against the actual PoolManager before real gas is
involved. Opt-in via `RUN_FORK_TESTS=1` so the default suite stays offline.

---

## Day 11 — 23 Aug

**Goal: audit the thing properly before spending real money on it.**

### The audit

Ran an adversarial pre-deployment review: five independent lenses over the contracts, then a
separate skeptic per finding whose job was to *refute* it. 31 findings raised, 25 survived. The
verdict was **do not ship** — eight blockers.

Worth stating plainly: none of them risks a maker's principal or locks funds. The product breaks,
not custody. But three separate ways existed to defeat the compensation mechanism outright,
deterministically, for gas.

It also refuted six plausible-sounding claims, which is the part that makes the rest credible:
the take-then-return delta pairing, the unspecified-currency selection for *both* exact-input and
exact-output, the int128/uint128 casts, unlock reentrancy, the swap-and-pop bookkeeping, and the
edge-crossing predicates all hold.

### Fixed today (group 1)

**Every order now gets its own PoolManager position.** v4 keys a position on
`(owner, tickLower, tickUpper, salt)`, and the salt was a constant — so every order at a tick was
*one* position owned by the hook. `modifyLiquidity` settles a position's accrued fees to whoever
touches it, which meant the first maker to withdraw took everyone else's fees, and a one-wei
order placed after the fact harvested them outright. Measured before the fix: a 1-wei order
walked away with 75,052,546,522,085 wei of another maker's fees. Salting by order id makes each
maker's fees structurally their own.

This one mattered beyond the theft: the entire threshold argument — *below the pool fee the maker
is already compensated by the fee they earned on their own fill* — is only true if that fee is
actually theirs.

**The rising tick walk skipped the tick containing `preTick`.** v4's search with `lte == false`
begins at `compress(tick) + 1`, so the starting tick's own bit is excluded by construction — and
that is exactly where a partially-crossed order sits. Any order whose range contained `preTick`
was invisible to a rising sweep: never filled, never charged for, never removed from the bitmap.
The falling branch includes its starting tick, so the asymmetry was the bug rather than the
design. Seeding one spacing lower on the rising branch fixes it.

### Challenges

18. **My own regression tests had a blind spot shaped exactly like the bug.** The fragmentation
    tests from yesterday stopped their first leg on spacing boundaries — 20, 30, 40 — because
    round numbers are what you reach for when writing a test by hand. That is the one alignment
    this defect cannot reach. Stopping *strictly inside* a maker's range, which is the ordinary
    case in real price action, exposed it immediately. A test suite can be green and blind at the
    same time, and mine was.

19. **The non-adversarial version was worse than the attack.** Ordinary two-leg price movement
    left makers with a position the market had already converted and an order stuck unfilled:
    `claimOrder` reverting forever, and the only exit a `cancelOrder` no interface would offer
    for an order it displays as filled. Attacks get attention; this would have quietly stranded
    ordinary users.

---

## Day 12 — 23 Aug (same session)

**Goal: a fill has to be final, and a wall has to cost something to build.**

### Fixed (blockers 3, 4, 5)

**Proceeds are taken out of the pool at the moment of the fill.** Until now "filled" was a flag
over a position the market still owned, so a price retrace converted it straight back into the
token the maker had already sold — and a deliberate round trip through someone's range undid
their fill, atomically and permissionlessly. Measured before the fix: after a retrace the maker
was handed back 50,072,441,031,415,115 of the token they had sold and 250,300,205,112 of the one
they wanted. Their sale had simply un-happened.

This needs no keeper and no deferred settlement: `afterSwap` already runs inside the manager's
unlock. Removing a position that now sits wholly out of range returns one-sided tokens and does
not move the tick, so it cannot disturb the displacement measured moments earlier in the same
call. `claimOrder` becomes a transfer of tokens the contract already holds.

**A per-swap fill budget, and a floor on order size.** Settling a fill now costs real gas, which
made the crowded-tick problem worse rather than better, so the two had to be fixed together. The
tick budget counted ticks, not orders, so one tick packed with orders made crossing that price
level cost unbounded gas — a wall anyone could erect. And every starvation attack was affordable
only because dust was free: one-wei orders could exhaust the budget and starve a real maker of
their fill.

Orders must now be at least 1 bp of the pool's active liquidity, and a swap settles at most 24
fills. Crucially, truncation only ever *defers*: a later pass through the same region picks the
remainder up, and there is a test for that specifically. A budget that silently cancelled fills
would have replaced a gas problem with a correctness one.

### Challenges

20. **The audit's own proof-of-concept files got committed.** Four `Zz*` scratch files written by
    the review tooling to demonstrate the attacks ended up in yesterday's commit and therefore in
    a public repo. They are throwaway demonstrations, not maintained tests, and once the fixes
    landed they started failing — because they were written to prove the attacks *work*. Removed,
    and the properties they established rewritten as named regressions. Worth watching for: tools
    that write into the working tree leave their scaffolding behind.

21. **The prank trap, fourth time.** `hook.createOrder(key, 10, _minSize())` — the helper reads
    pool liquidity, so once more an external call in an argument position consumed the prank. At
    this point it is not a surprise, it is a habit I have to break: resolve every value before
    pranking, without exception.

---

## Day 13 — 23 Aug (same session)

**Goal: charge the right party for the right movement, and never bill a trade more than it made.**

### Fixed (blockers 6, 7)

**Top-up accounting moved from the actor to the pool.** It was keyed on `tx.origin`, which was
wrong in both directions at once. A filler with two wallets sent the second leg from a different
address and paid nothing — measured at zero against 4,371,938,768,347 for the same price path
from one address. And anyone *sharing* an origin — a bundler, a relayer, a 4337 bundle, a CoW
solver — was billed for a move they had not made.

The question a top-up answers is "did the market end up further past this maker", and the market
does not care which address pushed it. Keyed on the pool, both problems disappear: a second
wallet buys no discount, and no unrelated party is billed at all. The fixed eight-entry list also
went, and dust can no longer evict anyone now that orders have a size floor.

**The top-up base is this swap's own starting price.** Previously a swap inherited whatever the
price had already done and was billed for a level it did not set. The base is now
`max(already paid for, displacement at this swap's preTick)`, so a trade pays for its own
movement and nothing else.

**The returned delta is clamped to what the swap actually received.** A top-up is sized from the
*order's* notional, which bears no relation to whichever swap moves the price next, so a small
trade could be handed a delta several times its own output and simply revert. Under-collecting is
strictly better than destroying someone else's trade — and the shortfall is not written off,
since `paidDisplacement` only advances by what was actually charged, so a later swap picks up the
rest.

### Note to self

Every one of these changes alters the creation code, and therefore the mined hook address. The
addresses recorded on day 10 are stale; the prediction has to be re-run against the final
bytecode at deploy time, and the deploy script asserts the match rather than trusting it — which
is exactly why it was written that way.

---

## Day 14 — 23 Aug (same session)

**Goal: make the size cap actually cap something. Last of the eight blockers.**

### Fixed (blocker 8)

The cap was per *order*, so it bounded nothing: N calls just under the limit pile up arbitrarily
much at one price, and the wall it exists to prevent gets built one brick at a time.
Concentration is the thing being limited, so the limit is now cumulative — the hook tracks
liquidity resting at each tick and refuses an order that would push that tick past the ceiling.
Liquidity is released back on cancel and on fill.

### Honest limits, stated rather than papered over

The cap is measured against the pool's *active* liquidity read at creation, which is
manipulable: add liquidity around spot, place a maximal order, remove the liquidity again. Doing
that properly needs a time-weighted measure the hook cannot read in-transaction without an
oracle, and this design does not have one.

What makes that acceptable rather than ignored is that the damage it used to enable is now
bounded elsewhere. An inflated order cannot extract an oversized charge, because the delta is
clamped to what the paying swap actually received. It cannot wall off a price level, because the
per-swap fill budget bounds the cost of crossing one and a later pass settles the remainder. What
is left is a large order that dampens its own displacement and mostly disadvantages its owner.

This is worth writing down as it is, rather than claiming a guarantee the code does not provide.

### Where that leaves the audit

All eight blockers are closed. The non-blocking findings remain open and are next: the rho
discontinuity at the switch — where a maker run over *further* is paid 14% less, and the
project's own monotonicity test misses it because it checks the rounded view rather than the
money path — plus native-currency pools, dynamic-fee pools, the missing `key.hooks` check, and
keying the transient slot by pool.

Then the whole thing goes back through review before anything is deployed. Fixes this deep earn
a second pass, not a victory lap.

---

## Day 15 — 23 Aug (same session)

**Goal: the five non-blocking findings, including the one my own test lied about.**

### Fixed

**The rate switch no longer has a cliff.** Applying the near rate to the *whole* excess and then
switching made the payout step backwards: at a 5 bp threshold, 11 bps of displacement paid 14%
less than 10 bps did — a maker run over further took home less. The rate is now marginal, the way
a tax bracket works: the near rate applies only to the excess that actually falls in the near
band. Monotone by construction rather than by luck, and makers are paid slightly more throughout.

**And the test that was supposed to catch it now can.** The monotonicity property was fuzzed
against `chargeBps` — the *rounded view* — where dividing by 10,000 flattened the very jump it
existed to detect. It passed for weeks while the money path was discontinuous. It now fuzzes
`chargeAmount`, and fuzzes the fee too, since the cliff's position depends on the threshold. A
test aimed at the wrong function is worse than no test: it occupies the space where a real one
would have gone.

**Three guards at the door.** An order in a pool this hook is not attached to could never fill or
be compensated while looking live to any interface; native-currency pools would fail deep inside
somebody's swap because settlement uses `transferFrom` and there is no `receive()`;
dynamic-fee pools have no fixed fee for the threshold argument to stand on and would have
computed a charge of exactly zero — silently, which is the worst way to be wrong. All three are
now refused at creation with named errors, rather than half-supported.

**The pool's fee is read from `slot0`, not from the key.** Same call already being made, and
`slot0` is the authoritative value.

**The transient pre-tick slot is mixed with the pool id.** A single slot is safe today only
because v4 makes no external call between `beforeSwap` and `afterSwap` — a property of the
framework, not of this contract, and the hook is immutable.

---

## Day 16 — 23 Aug (same session)

**Goal: repair the repairs. The second audit found the first round's fix had opened a bigger
hole than it closed.**

### What the re-audit found

Two criticals, both introduced by my own fix for the previous round's blocker 7 — and unlike the
first audit, this time maker principal was genuinely at risk.

**Exact-output swaps paid nothing at all.** The clamp bounded the charge by `received > 0`. The
unspecified currency is the swap's *output* when the input is exact, but its *input* when the
output is exact — where the delta is always negative. So the bound evaluated to zero on 100% of
exact-output swaps, in both directions. Measured: the same 40 bp crossing collected 924,260,342,130
via exact input and exactly 0 via exact output. Not one swap in the suite used a positive
`amountSpecified`, so half the charge surface had never been executed.

**Credit was booked before the clamp, leaving the hook insolvent.** Makers were credited the full
amount while only the clamped part was collected, and `claimOrder` pays from a single shared
balance holding every other maker's banked principal. Reproduced: one maker owed
501,526,057,929,151 against 500,600,410,225,614 held — claim reverts, `cancelOrder` also reverts
because the order is filled, and there is no rescue function. Principal locked permanently. Worse
across pools: a second pool on the same tokens could be drained of an honest pool's funds.

### Fixed

**The payment budget is now carried into the walk instead of clamping afterwards.** Each charge
is taken against what remains of what this swap can actually pay; credited and collected are the
same number by construction rather than by hope. Where the budget binds, the paid-for mark
advances only as far as was actually paid — interpolated on the excess, exact within a rate band
and conservative across one — so the remainder is genuinely collectable later rather than
silently forgiven.

**Each branch of the budget now gets the quantity that belongs to it**, so exact-output swaps pay
like any other.

**`settleFills` exists.** I had referenced it in two comments as the recovery path for orders
skipped by the fill budget, and never written it — a guarantee that was false in a public
repository. It is now a real permissionless function: being crossed is a pure function of the
current tick against the order's own range, so no oracle and no trust in the caller are involved.
Its honest limit is documented in the code: it rescues the maker's principal, not their
compensation, because there is no swap present to charge and inventing a payer would be worse
than admitting the gap.

### Challenges

22. **The invariant was toothless, and that is why none of this was caught.** It summed only the
    rebates and ignored `owed0/owed1` — the banked principal, orders of magnitude larger, sitting
    in the same balance — so it passed on a contract that could not pay its makers. And the
    handler hard-coded a negative `amountSpecified`, so the fuzzer never once produced an
    exact-output swap. Sharpened both ways, it fails on the old code immediately and passes on the
    new. Fixing the detector before the defect was the right order; I should have done it first
    rather than second.

23. **Review tooling left scaffolding in the tree again**, this time whole directories. Removed,
    and `.gitignore` now covers the pattern so it cannot reach a commit a third time.

---

## Day 17 — 25 Aug

**Goal: stop the audit spiral at the right place, and be explicit about where it stopped.**

### Built

Bucket walking is now forward rather than backward, so the queue at a tick is served roughly in
the order it formed. Backwards made it strictly last-in-first-out, which turns queue position
into something an attacker can buy: place after a maker, get served before them, and spend the
fill budget on your own orders while theirs is left behind.

`BlockFillOverflow` is emitted when the block's fill list saturates, so the residual gap is
observable from the first block rather than invisible.

`docs/KNOWN-LIMITS.md` — the findings that are real, judged, and deliberately not fixed, each
with the reason and with what bounds the damage instead.

### Decision: three rounds of fixes is where this stops

Two audits, three rounds of repairs, and the second round found that my own fix for the first had
opened a larger hole than it closed. That pattern is a warning. The remaining findings are real
but none of them risks principal, whereas the presentation deliverables — video, frontend,
thumbnail, the three essays — are not started, and the video is a pass/fail gate: without it
nothing is judged at all.

So the remaining three are documented rather than patched: the JIT-manipulable size guards need a
time-weighted depth measure the design deliberately does not have, the block fill list needs to
key on ticks rather than orders, and exact queue ordering needs a head pointer and tombstones.
All three are restructures, and rushing a restructure is how the last two criticals got written.

Writing them down is not a consolation prize. A hook that says where it stops is more useful than
one that quietly falls short, and every one of these was found before anything was deployed
rather than after.

---
