# Known limits

Written because a hook that quietly falls short is worse than one that says where it stops.
Everything still open here is deliberately so, with the reason stated, and none of it risks a
maker's principal. Most came out of adversarial review before deployment; two sections are
properties of the design rather than findings against it, and are here because a reader deserves
to meet them in the documentation rather than in production.

> ⚠️ **The deployed hooks predate the top-up fixes.** The instances listed in
> [DEPLOYMENTS.md](DEPLOYMENTS.md) are immutable and were compiled before the block-boundary
> defect below was found, so **they still carry it**. The fix is in `main`; putting it on chain
> means a fresh deployment at a fresh address. Said plainly here because a repository that
> documents a fix while the live contract still has the bug is worse than one that documents
> neither.

## Size guards are measured against instantaneous liquidity

`createOrder` bounds an order against `getLiquidity()` — the pool's *active* liquidity at that
moment. That figure is manipulable inside a single transaction: add liquidity around the market,
place a maximal order, remove the liquidity again. All three size guards (maximum per order,
minimum per order, cumulative per tick) inherit the weakness.

Doing this properly needs a time-weighted measure of depth, which the hook cannot read
in-transaction without an oracle — and being oracle-free is the point of the design, not an
accident of it.

**What bounds the damage instead.** The charge can never exceed what the paying swap actually
received, because the payment budget is established before anything is credited. An inflated
order therefore cannot extract an oversized charge, and it cannot wall off a price level either,
since the per-swap fill budget bounds the cost of crossing one and `settleFills` recovers the
remainder. What is left is a large order that dampens its own displacement — which mostly
disadvantages its owner.

## Top-ups are bounded work, and the bounds are reachable

Three of them, all deliberate, all observable, and none of them the one that used to be here.

**32 ticks in the ring.** The ring remembers the *ticks* recently filled into, not the orders, so
a swap that fills twenty-four orders across three ticks spends three slots. Pushing someone out of
it means crossing 32 distinct ticks — which costs price movement, not dust. Evicting a live tick
emits `RecentTickEvicted`.

There is one way to spend slots more cheaply than crossing fresh ground: re-touch the same tick
after another one, alternating, so each visit takes a new slot. Only the newest entry is checked
for a repeat, because scanning all 32 on every fill is a cost every maker would pay forever. The
attack needs the price to oscillate *and* fresh orders placed at the tick each time, each at least
1 bp of pool liquidity — expensive on both axes, and stated here rather than left to be found.

**8 orders per tick.** Beyond that the ninth fill at one tick inside the window is not revisitable
and emits `TickFillsSaturated`. Orders at a tick share a displacement base, so what is lost is that
order's own share, not the tick's protection.

**32 orders of work per top-up.** The nested walk is 32 ticks by 8 orders, and an `afterSwap` that
prices 256 fills is the sort of unbounded work that makes a busy pool unswappable. When the budget
runs out, `TopUpTruncated` fires.

The budget is spent **oldest first**, and that direction was itself a bug found by the detector. A
bounded budget spent newest-first simply moves the eviction out of the ring and into the budget —
the crowding test kept failing after the ring was fixed, for exactly that reason. A maker filled
twenty-nine seconds ago is about to leave the window and has no further chances; one filled a
second ago has the rest of it. The last chance goes to whoever is running out of them.

### What used to be here, and is now fixed

Two separate defects lived in this paragraph.

**The window was one block wide.** Cross a maker by a hair, wait a single block, finish the move —
the top-up returned on its first line and the maker ate the overshoot. Measured: the maker was
short **89.6%** of what the same move in one swap would have paid. Reported by the UHI10 judge.

**The ring was keyed on orders.** `MAX_FILLS_PER_SWAP` is 24 against 32 slots, so **two swaps**
saturated it and pushed a maker out of reach for good. Confirmed by test before it was fixed: the
victim's rebate did not move by a single wei on the swap that followed.

Neither adversarial audit round found either one, and the reason is worth more than the bugs:
**no test in the suite had ever advanced the block number.** `vm.roll` and `vm.warp` appeared
nowhere across fifteen files, so every branch keyed on elapsed time was unreachable rather than
merely uncovered — and an unreachable branch hides behind a coverage number instead of lowering it.
The invariant handler now has a `passTime` action, and `test/AirbagTopUp.t.sol` pins both edges of
the window and the crowding case.

A long enough wait still escapes the window; no finite window prevents that. What it removes is the
*free* split.

## Bucket ordering is approximately, not exactly, first-in-first-out

Orders resting at one tick are served in the order they were placed, but removal is swap-and-pop,
so the order moved into a vacated slot is examined next and jumps ahead of its neighbours. Exact
ordering needs a head pointer and tombstones.

This matters only when the fill budget truncates mid-tick, and `settleFills` recovers anything
left behind — a maker can lose their place in a queue, not their money.

## Truncation costs compensation, not principal

A swap settles at most `MAX_FILLS_PER_SWAP` orders. Anything beyond that is recoverable by
anyone through `settleFills`, which materialises an order the market has already crossed. But
there is no swap present at that point to charge, and inventing a payer would be worse than
admitting the gap, so an order rescued this way is filled at its limit price with no displacement
rebate.

## The charge lands inside the swapper's slippage check

v4 applies a hook's returned delta to the caller — `swapDelta = swapDelta - hookDelta`, under the
comment *"the caller has to pay for (or receive) the hook's delta"* in `v4-core`'s `Hooks.sol`. So
on an exact-input swap the charge comes out of what the swapper receives, and a router comparing
the result against `amountOutMinimum` compares the **post-charge** amount.

That is the right way round for safety. A swapper is never quietly shortchanged past the tolerance
they set; the transaction reverts instead, which is what slippage protection is for.

**The canonical quoting path already accounts for it.** `BaseV4Quoter._swap` calls
`poolManager.swap` for real inside an unlock and reverts with the result, so `beforeSwap` and
`afterSwap` both run and the delta it reports is the post-charge one. A router quoting on-chain
through the v4 Quoter sees the true number, and its slippage bound is therefore set against
reality.

What does not see it is a quote computed off-chain from pool state alone, which is how much of
routing actually prices a hop. Those quotes come out too good, swaps sized against them can revert
here, and failing routes get a pool deprioritised — which is where the fee arithmetic already
pointed from the other direction: a taker's effective cost through an Airbag pool is the pool fee
*plus* the expected charge, so all else equal a router prefers the pool next door.

There is no fix inside the hook, and it is worth being clear about why. The charge has to be
visible to the swapper or it would be a silent tax — and being visible is exactly what makes it
possible to route around. What is meant to close the gap is the other half of the mechanism: a
maker who knows the tail will be compensated can quote tighter, so the pool competes on price
rather than by concealing a cost. Whether that is enough to win routing at real depth is an open
commercial question, not a solved one.

## Not supported, refused at the door

Native-currency pools, dynamic-fee pools, and orders in pools this hook is not attached to are
rejected by `createOrder` rather than half-supported. Each would otherwise fail somewhere less
obvious: inside a stranger's swap, or as a charge that silently computes to zero.
