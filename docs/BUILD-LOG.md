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

## Day 2 — 18 Aug

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
