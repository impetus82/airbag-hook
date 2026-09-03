# Финальная подача — лист для копирования

**Форма: https://tally.so/r/mVNEAE** · дедлайн **4 сентября 09:59 МСК**

Заполняйте сверху вниз. Всё, что в блоках кода — копируется целиком.

---

## Project ID
```
HK-UHI10-1033
```

## Project Title
```
Airbag
```

## Email
```
egoshin_crypto@proton.me
```

## Confirm each team member's x.com handle
```
@luckyimpetus
```

## Select your cohort?
**UHI9** — это когорта, в которой вы учились, а не текущая. Не перепутайте.

## 1–2 sentence description
```
Airbag is a Uniswap v4 hook that pays a resting limit-order maker for the price displacement caused by the swap that filled them. It measures the overshoot inside the same transaction from the pool's own tick, charges that swap a capped share of it, and credits it to the specific ERC-721 order that was run over.
```

## Submission Type
**Hook Incubator (UHI)** — первый вариант из трёх.

Вы пришли через инкубатор, когорту UHI9; форма потому и спрашивает cohort отдельным полем.
*Hook Self Paced Course* — самостоятельный курс без когорты, *Open Submission* — для тех, кто
в программе не участвовал.

## Project Thumbnail
Загрузить файл:
```
/Users/tonchain/projects/airbag-hook/site/thumbnail.png
```
В диалоге выбора файла — **Cmd+Shift+G**, вставить путь.

## Did you integrate with any of the following partners?
Ничего не отмечаете.

## How did you integrate our partners, if any?
```
None. The design is deliberately oracle-free and keeper-free, so there was nothing it needed that a partner supplies.
```

## Does your project address the current Uniswap Hookathon theme?
**A — Yes, my project addresses the theme.**

## What are some of your project tags?
```
Limit Orders, MEV Protection, Fee Rebate Systems, Loss-Versus-Rebalancing, ERC-721 Positions, Oracle-Free Design, Price Impact Recapture
```

## GitHub Repo
```
https://github.com/impetus82/airbag-hook
```

## My Github repo is public, so it can be judged
**A — Yes**

## Slide Deck link
Оставить пустым — поле необязательное.

## Demo video link
```
https://youtu.be/k7tu_8_INFc
```

## Project link, if there's a front end
```
https://impetus82.github.io/airbag-hook/
```

---

## Problem / Background
*What inspired the idea? What problems are you solving?*

```
A resting limit order is a free option written to the market. You ask to sell at $1,866; a large trade arrives and does not merely touch your price, it shoves the market to $1,875. You are filled at exactly the price you asked for, so formally nothing is wrong — but the extra move was captured by whoever ran through you, and it only existed because your order was sitting in the way. The maker supplied the inventory that made the move possible and kept none of it.

What actually started this project was not that argument, though. It was deciding to measure before writing any Solidity, because the argument is easy to make and easy to make wrongly.

I pulled thirty days of Base WETH/USDC — 253,135 swap events — reconstructed roughly 11,400 fills against them, and measured how far past each one the price ended up. The median displacement was 2.00 basis points. Three independent pools and two separate time windows produced the same figure.

That number reshaped the design more than anything else. At two basis points the maker has already been made whole by the fee earned on their own fill, so the honest answer is that most fills need no compensation at all. The problem lives entirely in the tail: 22.5% of fills averaged 24 bps, and that tail is where a maker is genuinely worse off for having been in the way.

So Airbag deploys only on impact. The threshold is not a tuned constant — it is the pool's own fee, which is precisely the amount the maker has already recovered. Below it the hook stays silent and benign flow pays nothing, without needing a special case to say so.
```

## Impact
*What makes this project unique? What impact will this make?*

```
The recipient is the difference. Designs that recapture value at fill time — Angstrom, Detox, KyberSwap's variants — return it to the LP pool at large. That is correct for a pool, and it is useless to the person who was actually run over, because they own a slice of the pool at best. Airbag pays the specific maker. That is only possible because each order is an ERC-721 with an identity, so there is somewhere to send the money.

Three other things fall out of building it that way.

No oracle, no keeper, no deferred settlement. Everything is computed inside the transaction that caused it, from the pool's own tick. One tick is one basis point, so the measurement is exact integer arithmetic rather than an approximation. Settlement is never deferred to a later block on purpose: a future price is a value the filler themselves could write, which makes deferred markouts a mechanism for paying the attacker.

The charge is bounded by what the swap actually moved. It is a share of the overshoot, capped at 200 bps of the order's notional, and it is marginal — 70% of the first band above the fee, 50% beyond. A swap that lands inside the fee pays nothing at all. In a 48-hour replay through the contract itself, 1,055 swaps filled 611 orders and only 280 were compensated: more than half of all fills cost the swapper nothing.

What the impact actually is, stated honestly: this is a redistribution, not free money. The tail stops being a pure loss for the maker, which lets makers quote tighter, which is what sustainable liquidity at a low fee has to be built out of. Whether that nets positive at real volume is a hypothesis my data does not settle — I measured the size of the tail, not how makers respond to being compensated for it. It is live on Base and Unichain mainnet and the mechanism is verified to the basis point; the economics need depth that two dust-seeded pools cannot supply.
```

## Challenges
*What was challenging about building this project?*

```
The two worst bugs were introduced by my own fixes. Two adversarial audit rounds ran before deployment. Round one found eight blockers — the sharpest being a shared position salt that let a one-wei order harvest another maker's fees. Round two found two criticals, and both were mine, both written while fixing round one, and unlike round one they put maker principal at risk.

The first: the charge was bounded by `received > 0`, but the unspecified currency is the swap's input on an exact-output swap, not its output. So every exact-output swap paid nothing, and no test in the suite had ever passed a positive amountSpecified. The second was worse — credit was booked before that clamp, so the hook owed makers more than it held. Claims exceeded balance, claimOrder reverted, and principal was locked. Fixed by carrying the payment budget into the fill walk, so what is credited and what is collected are the same number by construction.

The invariant that should have caught both was toothless in two independent ways: it summed only rebates while ignoring `owed`, which is orders of magnitude larger and sits in the same balance, and its handler hard-coded a negative amountSpecified so exact-output was never fuzzed. Fix the detector before the defect — I repaired the invariant first, and it immediately caught the insolvency that had been sitting there.

Two smaller ones taught the same lesson from the other end. A front-end address with two characters of wrong case failed its EIP-55 checksum, and viem rejects such an address before issuing any request — so the panel showed em-dashes with no error, no console warning and nothing on the wire. It cost a day, and what found it was not a clever hypothesis but making the panel say "broken" instead of printing the same glyph it uses for "loading". Separately, both demo pools were seeded around a price constant inherited from an older project — 1,866 USDC per WETH against a market near 2,460, a quarter below it. Arbitrage ate them to the edge of the seeded band and left the live demo with no liquidity to fill an order against.

The through-line: every one of these was silent. A test that never ran a case, an invariant that summed the wrong field, an address rejected before the network saw it, a stale constant nobody had re-read. None of them threw. The hard part of this project was not writing the mechanism — it was building the things that refuse to stay quiet when the mechanism is wrong.
```

---

## Did you work with a team?
**B — No**

## Do you plan to continue working on this or another Hook project after graduation
**A — Yes :)**

## On a scale from 1-5, how would you rate your UHI experience?
Ваша оценка.

## Tell us more about what's parts of UHI you found most helpful and what you would want to change
```
The most useful part was the pressure to ship something live rather than something demoable. Deploying to mainnet forced questions a testnet never would have — what the pool is priced at, whether arbitrage will eat a seed, whether a router can quote the hook at all.

The workshops on testing and deployment were the ones I came back to. What I would change: office hours land in the middle of the working day for anyone in Europe or further east, and this time the only session with the Uniswap team was on the last Monday. An earlier one, or a repeat at a different hour, would reach more of the cohort.
```

---

## После отправки

1. Появится публичная страница хука на **hooks.atrium.academy** — проверьте, что открывается.
2. NFT-форма (если подойдёте по критерию «current dev in UHI10»): https://tally.so/r/NpAjZb
