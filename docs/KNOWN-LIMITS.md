# Known limits

Written because a hook that quietly falls short is worse than one that says where it stops.
Everything still open here is deliberately so, with the reason stated, and none of it risks a
maker's principal. Most came out of adversarial review before deployment; two sections are
properties of the design rather than findings against it, and are here because a reader deserves
to meet them in the documentation rather than in production.

> ⚠️ **The deployed hooks predate the top-up fix.** The instances listed in
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

## The recent-fill ring holds 32 entries

Top-ups — the mechanism that stops a filler from splitting one swap into two and paying for
neither — reach only fills still recorded in the pool's ring. Past 32 fills inside the window,
the oldest entry is overwritten, and a filler who saturates the ring can then split their swap
and escape.

Raising the constant does not fix it: the number of fills in a window is unbounded. The real fix
is to remember the *ticks* touched rather than the orders, because orders resting at one tick
share a displacement base, and a bounded set of ticks then covers an unbounded set of orders.
That is a restructure rather than a patch, and it is the piece still outstanding here.

Overwriting a live entry emits `RecentFillEvicted`, so the gap is observable from the first
occurrence rather than invisible — and the event fires only when the displaced entry was still
inside the window and unclaimed, which is genuine capacity pressure rather than routine recycling.

### What used to be here, and is now fixed

The window was one **block** wide, and that was worse than the capacity limit: no saturation was
needed at all. Cross a maker by a hair, wait a single block, finish the move — the top-up returned
on its first line and the maker ate the overshoot. Measured, the maker was short **89.6%** of what
the same move in one swap would have paid.

Reported by the UHI10 judge. Neither adversarial audit round found it, and the reason is worth
more than the bug: **no test in the suite had ever advanced the block number**, so the branch was
not merely uncovered, it was unreachable. The window is now measured in seconds
(`TOPUP_WINDOW_SECONDS`), the invariant handler can move the clock, and
`test/AirbagTopUp.t.sol` pins both edges — that a split across a boundary still pays, and that
the window does expire.

A long enough wait still escapes; no finite window can prevent that. What it removes is the
*free* split: holding a half-finished move for thirty seconds carries price risk and invites
anyone else to take the opportunity first.

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
