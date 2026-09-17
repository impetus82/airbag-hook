# Live deployments

Deployed 17 September 2026 from the bytecode that carries both top-up fixes. Both addresses
reproduced their prediction exactly — the deploy script asserts the match before initialising the
pool, so a bytecode drift would have stopped the transaction rather than silently deploying
something else. Both contracts are verified: the source on the explorer is the source here.

| | Base (8453) | Unichain (130) |
|---|---|---|
| hook | [`0xf328ff41…CE40C4`](https://basescan.org/address/0xf328ff41720b6778d1610bb05a6cab43d0ce40c4) | [`0xCeC392D5…6f00C4`](https://uniscan.xyz/address/0xcec392d5388bb110c4082011901bd9febc6f00c4) |
| pool id | `0x2b6bb690…29a2b05a` | `0x7db1fe33…ea812f40` |
| pair | WETH / USDC, 0.05%, spacing 10 | USDC / WETH, 0.05%, spacing 10 |
| currency0 | WETH | **USDC** — the tokens sort the other way here |
| initial tick | −198250 (≈2,458 USDC per WETH) | +198250 |
| deploy tx | [`0xbb2d0c0e…69c0fc`](https://basescan.org/tx/0xbb2d0c0e45e1c52dc00b796a3d367d518f0e58123e458cdbf907dd19e569c0fc) | [`0x25fb9c4d…5c97d5`](https://uniscan.xyz/tx/0x25fb9c4d8080837e8b3d91ac2c0f9d1735645fed88c266fe0b726ad3645c97d5) |
| seed router | `0x03E970002dAdF53Aab0476b74E7810b1f41200Ea` | `0xEC4A0be5dB220D397C4E521879598251010e08eE` |
| seed tx | [`0x1b7a1446…2ce608`](https://basescan.org/tx/0x1b7a14469e4df3b50ca13ec688b10b4943b248592559e8798356ad2d662ce608) | [`0x0c6d6c6b…f024c43`](https://uniscan.xyz/tx/0x0c6d6c6b841faad7e3425e4e9f080cd7a50af106e6dd5009aa1180dbbf024c43) |
| seeded band | [−199450, −197050] | [197050, 199450] |
| cost | 0.0000269 ETH | 0.0000026 ETH |

Both pools hold **40,000,000,000** units of liquidity, and both cost the same to seed —
46,984,574,649,618 wei of WETH plus 115,478 units of USDC — because the bands are exact mirrors.
An order runs from 4,000,000 to 400,000,000 liquidity units: at least 1 bp of pool depth, at most 1%.

The pools were opened **at the market**, not at a constant. `INITIAL_TICK` is now a required input
with sign, magnitude and alignment all checked before anything broadcasts — see the runbook for why
that stopped being a constant.

Both hook addresses end in `C4`. That is not decoration — a v4 hook's permissions are encoded in
its address, and those bits are what the PoolManager checks before calling any callback.

## The superseded deployment — what UHI10 was judged on

| | Base | Unichain |
|---|---|---|
| hook | [`0x100d7855…0100C4`](https://basescan.org/address/0x100d7855adac79d90a75b7a89cf99a9f2b0100c4) | [`0x82f8fF08…C6C0C4`](https://uniscan.xyz/address/0x82f8ff08608a4357a9bb12f7439b43453cf6c0c4) |
| pool id | `0xfa9bfd56…a6bfba67` | `0xbc9274f6…8b4dcbf5` |

Deployed 25 August, verified. They are **immutable and carry both top-up defects** — the one-block
window and the order-keyed ring — so nothing new should be pointed at them. They stay live as the
record of what was submitted, and the proof-of-life cycles below ran against them.

**Their seed was withdrawn on 17 September, and both pools now hold zero active liquidity.**
`createOrder` reverts with `PoolHasNoLiquidity` when that is the case, so the easy path into a
version known to be broken is closed.

Closed, not recalled — and the difference is the point. These hooks are immutable and
permissionless: anyone can add their own liquidity to these pools, or open a fresh pool against
either hook, and the defects come back with them. A contract like this cannot be withdrawn from
the chain. What can be done is to stop advertising it, stop funding it, and write down plainly that
it is broken. All three are done.

## Seeded pools — the superseded deployment

Both pools carry **50,000,000,000 units of liquidity** across ±120 tick spacings around the
initial price, confirmed on chain rather than from the broadcast log. Cost per chain: 0.0000674
WETH + 0.126 USDC.

| | Base | Unichain |
|---|---|---|
| seed router | `0x17d2458D25D3254844EeC70457860CDEEdeAf258` | `0xeEED1F1923CEC50217911B1E9843f717435e7DB7` |
| seed tx | [`0xf6d793ec…52bd6b`](https://basescan.org/tx/0xf6d793ec21c1b77e4e517f5dcf0cc1203233ffc2d93e6647628c07166152bd6b) | [`0x60da201a…3bbecd4`](https://uniscan.xyz/tx/0x60da201a84eecc8b4e3fe091e2697e1af1251bfb70ac1bc6734065c653bbecd4) |

The routers can **remove** liquidity as well as add it, so the seed is recoverable by its owner.
That is not a given: the equivalent router from the previous hookathon could only add, and its
seed is still stranded on Unichain. A one-line omission that costs whatever went in.

Order size is bounded relative to pool depth — at least 1 bp of it, at most 1% — so with this seed
a demo order runs from 5,000,000 to 500,000,000 liquidity units.

### Re-priced to the market and re-seeded, 25 August

That first seed was centred on a price copied from an older project — about 1,866 USDC per WETH
against a market near 2,460. Arbitrage walked each pool to the edge of its band and stopped there,
the proof-of-life swaps carried the price the rest of the way out, and both pools were left holding
**zero active liquidity**: nothing to fill an order against, and a front end correctly reporting a
depth of nought.

Zero liquidity has one useful property. There is nothing to trade against, so moving the price
costs only gas — each pool was walked to the live market tick for a few cents of it, and only then
re-seeded, so the band is centred where the market actually is and arbitrage has no reason to eat
it.

| | Base | Unichain |
|---|---|---|
| re-price swap | [`0x88ac8157…35c7b3`](https://basescan.org/tx/0x88ac815743aaa5adb38d28dbfe784bf7eb1106002e25683d18c4c1d8d535c7b3) | [`0xb200ef7e…dff9ac`](https://uniscan.xyz/tx/0xb200ef7e1bf2aa8ea1bc422c09df84be4d4e75bca65911f980e9a68a7ddff9ac) |
| tick, before → after | −199700 → −198240 | 199740 → 198240 |
| seed router | `0x9188D9F888068F34457fCe9E1A6Af6F7CAF21eb4` | `0x87fBa32fc0eDB3bC1E059a297928095719300463` |
| seed tx | [`0x75eab8e6…eda74d`](https://basescan.org/tx/0x75eab8e67326413da3a8a1ae3ce88d2a5a8a78158945a2b7e38906f72aeda74d) | [`0x341c252f…dea9be`](https://uniscan.xyz/tx/0x341c252f51bdb63da981affe85182cd5f3a2ae81e5fd261f583dc44538dea9be) |
| range | [−199440, −197040] | [197040, 199440] |
| cost | 0.0000587 WETH + 0.1444 USDC | 0.1340 USDC + 0.0000633 WETH |

Both pools now hold 50,000,000,000 units again, at ±198240 against a market tick of −198261 — 21
ticks, a fifth of a percent. The ranges are exact mirrors because the pairs sort opposite ways.

The lesson is the one from the first seed, generalised: **a band is only as good as the price it
was centred on**, and that price has a shelf life. The first seed inherited a constant from a
project a year older; this one reads the market immediately before writing.

## Proof of life — Base, 25 August

A full cycle against the live contract: an order placed, crossed by a swap that carried on past
it, measured, charged, credited and claimed.

| | |
|---|---|
| place order #1 (tick −199780) | [`0x7fce3af9…6f539b`](https://basescan.org/tx/0x7fce3af9d3a92001ec85a613c6a865fe231a388c4f04631be8264230206f539b) |
| swap through it, on to −199700 | [`0x46a3f13f…547af7`](https://basescan.org/tx/0x46a3f13febfad4ed45d4248afed118703329da9018b636060aff3f39de547af7) |
| claim | [`0x728e0aff…419534`](https://basescan.org/tx/0x728e0aff7d4b77558b670cba2fd0351031d9582044b0f2b6c80045dab9419534) |

**The numbers match the rule exactly.** The hook recorded 70 bps of displacement. The threshold is
the pool's 5 bps fee, so 65 bps were uncompensated, charged marginally: 5 bps at 70% plus 60 bps
at 50% = **33.50 bps**. It credited 1,823,077 wei of WETH against an order notional of 544,202,355
wei — **33.50 bps**. Not approximately.

Three honest notes, and the third one corrects the second.

The amounts are dust because the pool is: the order was worth a fraction of a cent, and the
rebate proportionally less.

The crossing swap was mine. The intent was for live arbitrage to do it — the pool was initialised
below the wider market precisely so that flow would walk the price up through the order — and it
moved partway before stopping.

I first wrote that stop down as a gas argument: with thirty cents in the pool, the remaining
mispricing is worth less than the fee to capture it. That is true and it is **not the binding
reason**, which I only found when the same thing happened on Unichain. The seed spans ±120 tick
spacings around the price *at seeding time*, so Base's liquidity ends at exactly −199800 — and
−199800 is exactly where arbitrage stopped. Past the edge of the band there is nothing to trade
against, so no further arbitrage is possible at any gas price.

That has a consequence worth stating plainly. The order rested above the band, so the 70 bps the
swap travelled past the fill edge crossed **empty ticks** and cost the swapper nothing to create.
The hook measured and charged exactly what the rule says, to the wei — that part is real. What a
pool this shallow cannot demonstrate is the premise underneath the rule: that displacement is
profitable to create, and therefore worth charging for. That needs depth, and dust has none.

## Proof of life — Unichain, 25 August

The same cycle on the other chain, and deliberately its mirror image. The pair sorts the other way
round here, so the order rests **below** the market and sells into a falling tick rather than a
rising one.

| | |
|---|---|
| place order #1 (tick 199810) | [`0xdb369a2e…4b60d6`](https://uniscan.xyz/tx/0xdb369a2e59b935792025ea3c7df95df9856a1477aa2264fbf616cc23a84b60d6) |
| swap through it, on to 199740 | [`0xd00b743f…f28174`](https://uniscan.xyz/tx/0xd00b743f1e5de166c22c9662e32abb1cae73df84b04d083915599aba41f28174) |
| claim | [`0x9d5c36f3…33e006`](https://uniscan.xyz/tx/0x9d5c36f3b0bdd647c6e96dc234bcebe082ad64e24cd49b2f58c2ab28e833e006) |

| | Base | Unichain |
|---|---|---|
| order funded in | WETH, as currency0 | WETH, as currency1 |
| notional | 544,202,355 wei | 545,291,795 wei |
| tick travels | up | down |
| displacement | 70 bps | 70 bps |
| rebate | 1,823,077 wei | 1,826,727 wei |
| **rebate / notional** | **33.50 bps** | **33.50 bps** |

Two chains, opposite currency ordering, opposite swap direction — and the rule lands on the same
number to four significant figures.

**The orientation nearly produced a silent failure.** The script placed orders a fixed offset
*above* the tick, and an order above the tick is funded entirely in currency0. On Base that is
WETH and buys 5.4e8 wei. On Unichain currency0 is USDC, and the same offset buys **one raw unit** —
a notional against which a 33.50 bps rebate truncates to zero. Every transaction would have
succeeded and the demonstration would have reported a rebate of nothing. The offset is signed now,
and the reason is written above it in the script.

After the claim the hook holds **zero of both currencies**. Everything it charged the swap it paid
to the maker, with nothing stranded — the exact property the second audit's insolvency critical was
about, confirmed on a live chain rather than in a test.

Of the 70 bps here, the first 10 consumed real liquidity before the price left the seeded band;
the remaining 60 crossed empty ticks. The same caveat as Base, and the reason it is stated twice
is that it is the honest limit of what these pools can show.

Both pools were re-priced to the live market and re-seeded straight afterwards — see above. That
does not retrospectively deepen either demonstration; it means an order placed today rests in a
band centred on the real price, with liquidity on both sides of it.

## This is a hackathon deployment

The pools are seeded with dust. The contract is immutable and permissionless, so anyone can
create their own pool against this hook — please read [KNOWN-LIMITS.md](KNOWN-LIMITS.md) before
putting anything you care about behind it. Two adversarial audits ran before deployment and three
findings remain open by choice; none risks a maker's principal, and all three are written down.
