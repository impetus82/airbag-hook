# Live deployments

Deployed 25 August 2026 from the final audited bytecode. Both addresses reproduced their
prediction exactly — the deploy script asserts the match before initialising the pool, so a
bytecode drift would have stopped the transaction rather than silently deploying something else.

Both contracts are verified: the source on the explorer is the source in this repository.

## Base — chain 8453

| | |
|---|---|
| hook | [`0x100d7855ADAC79D90A75B7A89Cf99A9f2B0100C4`](https://basescan.org/address/0x100d7855adac79d90a75b7a89cf99a9f2b0100c4) |
| pool id | `0xfa9bfd56f6bea998f1d5f20ead8b36cc5fe813ed66460c567a6180eba6bfba67` |
| pair | WETH / USDC, 0.05%, tick spacing 10 |
| currency0 | WETH |
| initial tick | −201000 (≈1866 USDC per WETH) |
| deploy tx | [`0x56d8f0a8…83ceca`](https://basescan.org/tx/0x56d8f0a8baf8701d8f9095d44b83cb0c8e082bbd0ce914783c2ce6e02b83ceca) |
| pool init tx | [`0x6106d881…49e931`](https://basescan.org/tx/0x6106d8813714a92c6a691b63d8dc5b760a17b67c7de34f05a7e42af90c49e931) |
| cost | 0.0000223 ETH |

## Unichain — chain 130

| | |
|---|---|
| hook | [`0x82f8fF08608a4357a9BB12F7439b43453CF6C0C4`](https://uniscan.xyz/address/0x82f8ff08608a4357a9bb12f7439b43453cf6c0c4) |
| pool id | `0xbc9274f6583561fd0e69fa1f9a133b2063fe0815e9ab53d6ff1e17c38b4dcbf5` |
| pair | USDC / WETH, 0.05%, tick spacing 10 |
| currency0 | **USDC** — the tokens sort the other way round here than on Base |
| initial tick | +201000 |
| deploy tx | [`0xbd47f706…e3a84b`](https://uniscan.xyz/tx/0xbd47f70642d7f7e0ad249e47d87cb40fb92f76ee6f14e592aa6b2e0417e3a84b) |
| pool init tx | [`0x4156fc6b…635988`](https://uniscan.xyz/tx/0x4156fc6b24e61fb301d7564b8059e85bba32f789c9ab6522a0b4ea3d11635988) |
| cost | 0.0000021 ETH |

Both hook addresses end in `C4`. That is not decoration — a v4 hook's permissions are encoded in
its address, and those bits are what the PoolManager checks before calling any callback. An
address that does not end that way would not be this hook.

## Seeded pools

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
