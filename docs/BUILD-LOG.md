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
