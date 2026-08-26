# Known limits

Written because a hook that quietly falls short is worse than one that says where it stops.
Everything here was found by adversarial review before deployment, judged real, and deliberately
not fixed — with the reason stated. None of it risks a maker's principal.

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

## The block's fill list holds 32 orders

Top-ups — the mechanism that stops a filler from splitting one swap into two and paying for
neither — reach only orders recorded in the current block's fill list. Past 32 fills in a block,
further orders are not recorded, and a filler who first saturates the list can then split their
swap and escape.

Raising the constant does not fix it: the number of swaps in a block is unbounded. The real fix
is to remember the *ticks* touched rather than the orders, because orders resting at one tick
share a displacement base, and a bounded set of ticks then covers an unbounded set of orders.
That is a restructure rather than a patch.

Until then the overflow emits `BlockFillOverflow`, so the gap is observable from the first block
rather than invisible.

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

It is the wrong way round for distribution, and that is the honest cost of this design. A swap
sized against a quote from a pool *without* the hook can revert here, and an aggregator quoting
off-chain without simulating `afterSwap` will produce routes that fail. Failing routes get a pool
deprioritised, and a deprioritised pool sees no flow — which is where the fee arithmetic already
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
