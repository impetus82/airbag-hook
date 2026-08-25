# Airbag Hook — impact protection for limit orders

A Uniswap v4 hook that pays a resting limit-order maker for the price displacement caused by
the swap that filled them.

## The problem

You place a limit order: *sell my ETH at $1,866*. It rests, waiting.

A large trade arrives and blows straight through your price — it does not merely touch $1,866,
it shoves the market to $1,875. Your order fills at $1,866, exactly as you asked. Formally,
nothing is wrong. But the extra move was captured by whoever ran through you, and it only
existed because your order was sitting in the way. A resting limit order is a free option
written to the market.

## What Airbag does

At fill time the hook measures **how far past your price the swap pushed the market**, charges
that swap a capped share of the overshoot, and credits it to your order. You claim it together
with your proceeds.

It deploys **only on impact**. Below the threshold the maker is already compensated by the fee
they earned on their own fill, so the hook stays out of the way and benign flow pays nothing.

## Why it needs no oracle

Everything is computed **inside the same transaction**, from the pool's own tick: where the
price was before the swap, and where it ended relative to the maker's tick. One tick is one
basis point, so the measurement is exact integer arithmetic.

Nothing is read at a later block — a future price is a value the filler themselves could write,
which is precisely why deferred settlement is not part of this design.

## Honest framing

The maker was not robbed: they got their limit price. Airbag returns the part of the move that
their own order made possible. On a median fill the maker is already net positive and the hook
correctly pays nothing; it matters in the tail.

## Live

| | Base | Unichain |
|---|---|---|
| hook | [`0x100d7855…0100C4`](https://basescan.org/address/0x100d7855adac79d90a75b7a89cf99a9f2b0100c4) | [`0x82f8fF08…C6C0C4`](https://uniscan.xyz/address/0x82f8ff08608a4357a9bb12f7439b43453cf6c0c4) |
| pair | WETH/USDC 0.05% | USDC/WETH 0.05% |

Both verified; addresses, pool ids and transactions in [docs/DEPLOYMENTS.md](docs/DEPLOYMENTS.md).
A hackathon deployment on dust-seeded pools — read the known limits first.

## It works on mainnet, to the basis point

A full cycle on Base — [place](https://basescan.org/tx/0x7fce3af9d3a92001ec85a613c6a865fe231a388c4f04631be8264230206f539b),
[cross](https://basescan.org/tx/0x46a3f13febfad4ed45d4248afed118703329da9018b636060aff3f39de547af7),
[claim](https://basescan.org/tx/0x728e0aff7d4b77558b670cba2fd0351031d9582044b0f2b6c80045dab9419534).
The hook measured 70 bps of displacement past the maker, and the charge rule says 33.50 bps of
their notional is owed. It paid 33.50 bps. See [docs/DEPLOYMENTS.md](docs/DEPLOYMENTS.md).

## Try it

**https://impetus82.github.io/airbag-hook/** — reads both live pools, places orders, shows the
rebate on your own. Static: everything is client-side, so there is no backend to trust.

## Explainer

A one-page walkthrough of the mechanism, the measured evidence, and the known limits:
https://claude.ai/code/artifact/1ccfe6d2-3cb0-4284-a266-c75fd0de1512 (source in `site/`)

## Known limits

See [docs/KNOWN-LIMITS.md](docs/KNOWN-LIMITS.md). Found by adversarial review before deployment,
judged real, and deliberately left — with the reasoning written down. None risks maker principal.

## Partner integrations

None yet.

## Status

Built from scratch for the UHI10 Hookathon (17 Aug – 3 Sep 2026).

## Build

Dependencies are git submodules, so clone recursively:

```bash
git clone --recurse-submodules https://github.com/impetus82/airbag-hook.git
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

Then:

```bash
forge build
forge test -vv
```
