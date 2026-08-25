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

## Not supported, refused at the door

Native-currency pools, dynamic-fee pools, and orders in pools this hook is not attached to are
rejected by `createOrder` rather than half-supported. Each would otherwise fail somewhere less
obvious: inside a stranger's swap, or as a charge that silently computes to zero.
