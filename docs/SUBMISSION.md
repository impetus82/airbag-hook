# UHI10 final submission — prepared answers

Form: https://tally.so/r/mVNEAE · Project ID `HK-UHI10-1033` · cohort **UHI9**, not UHI10.

---

## 1–2 sentence description

Airbag is a Uniswap v4 hook that pays a resting limit-order maker for the price displacement
caused by the swap that filled them. It measures the overshoot inside the same transaction from
the pool's own tick, charges that swap a capped share of it, and credits it to the specific
ERC-721 order that was run over.

## Project tags

Limit Orders · MEV Protection · Fee Rebate Systems · Loss-Versus-Rebalancing · ERC-721 Positions ·
Oracle-Free Design · Price Impact Recapture

## Partners

None yet.

---

## Problem / Background
*What inspired the idea? What problems are you solving?*

A resting limit order is a free option written to the market. You ask to sell at $1,866; a large
trade arrives and does not merely touch your price, it shoves the market to $1,875. You are filled
at exactly the price you asked for, so formally nothing is wrong — but the extra move was captured
by whoever ran through you, and it only existed because your order was sitting in the way. The
maker supplied the inventory that made the move possible and kept none of it.

What actually started this project was not that argument, though. It was deciding to measure
before writing any Solidity, because the argument is easy to make and easy to make wrongly.

I pulled thirty days of Base WETH/USDC — 253,135 swap events — reconstructed roughly 11,400 fills
against them, and measured how far past each one the price ended up. The median displacement was
**2.00 basis points**. Three independent pools and two separate time windows produced the same
figure.

That number reshaped the design more than anything else. At two basis points the maker has already
been made whole by the fee earned on their own fill, so the honest answer is that most fills need
no compensation at all. The problem lives entirely in the tail: **22.5% of fills averaged 24 bps**,
and that tail is where a maker is genuinely worse off for having been in the way.

So Airbag deploys only on impact. The threshold is not a tuned constant — it is the pool's own fee,
which is precisely the amount the maker has already recovered. Below it the hook stays silent and
benign flow pays nothing, without needing a special case to say so.

## Impact
*What makes this project unique? What impact will this make?*

**The recipient is the difference.** Designs that recapture value at fill time — Angstrom, Detox,
KyberSwap's variants — return it to the LP pool at large. That is correct for a pool, and it is
useless to the person who was actually run over, because they own a slice of the pool at best.
Airbag pays the specific maker. That is only possible because each order is an ERC-721 with an
identity, so there is somewhere to send the money.

Three other things fall out of building it that way:

**No oracle, no keeper, no deferred settlement.** Everything is computed inside the transaction
that caused it, from the pool's own tick. One tick is one basis point, so the measurement is exact
integer arithmetic rather than an approximation. Settlement is never deferred to a later block on
purpose: a future price is a value the filler themselves could write, which makes deferred
markouts a mechanism for paying the attacker.

**The charge is bounded by what the swap actually moved.** It is a share of the overshoot, capped
at 200 bps of the order's notional, and it is marginal — 70% of the first band above the fee, 50%
beyond. A swap that lands inside the fee pays nothing at all. In a 48-hour replay through the
contract itself, 1,055 swaps filled 611 orders and only **280 were compensated**: more than half
of all fills cost the swapper nothing.

**What the impact actually is, stated honestly:** this is a redistribution, not free money. The
tail stops being a pure loss for the maker, which lets makers quote tighter, which is what
sustainable liquidity at a low fee has to be built out of. Whether that nets positive at real
volume is a hypothesis my data does not settle — I measured the size of the tail, not how makers
respond to being compensated for it. It is live on Base and Unichain mainnet and the mechanism is
verified to the basis point; the economics need depth that two dust-seeded pools cannot supply.

## Challenges
*What was challenging about building this project?*

**The two worst bugs were introduced by my own fixes.** Two adversarial audit rounds ran before
deployment. Round one found eight blockers — the sharpest being a shared position salt that let a
one-wei order harvest another maker's fees. Round two found two criticals, and both were mine, both
written while fixing round one, and unlike round one they put maker principal at risk.

The first: the charge was bounded by `received > 0`, but the unspecified currency is the swap's
*input* on an exact-output swap, not its output. So **every exact-output swap paid nothing**, and
no test in the suite had ever passed a positive `amountSpecified`. The second was worse — credit
was booked before that clamp, so the hook owed makers more than it held. Claims exceeded balance,
`claimOrder` reverted, and principal was locked. Fixed by carrying the payment budget *into* the
fill walk, so what is credited and what is collected are the same number by construction.

The invariant that should have caught both was toothless in two independent ways: it summed only
rebates while ignoring `owed`, which is orders of magnitude larger and sits in the same balance,
and its handler hard-coded a negative `amountSpecified` so exact-output was never fuzzed. **Fix the
detector before the defect** — I repaired the invariant first, and it immediately caught the
insolvency that had been sitting there.

Two smaller ones taught the same lesson from the other end. A front-end address with two characters
of wrong case failed its EIP-55 checksum, and viem rejects such an address *before* issuing any
request — so the panel showed em-dashes with no error, no console warning and nothing on the wire.
It cost a day, and what found it was not a clever hypothesis but making the panel say "broken"
instead of printing the same glyph it uses for "loading". Separately, both demo pools were seeded
around a price constant inherited from an older project — 1,866 USDC per WETH against a market near
2,460, a quarter below it. Arbitrage ate them to the edge of the seeded band and left the live demo
with no liquidity to fill an order against.

The through-line: every one of these was silent. A test that never ran a case, an invariant that
summed the wrong field, an address rejected before the network saw it, a stale constant nobody had
re-read. None of them threw. The hard part of this project was not writing the mechanism — it was
building the things that refuse to stay quiet when the mechanism is wrong.

---

# Progress Update 2 — due Monday 31 August

Form: https://tally.so/r/wdMO5D · короткая, все ответы приватные (видит только команда Atrium).

| поле | ответ |
|---|---|
| Project ID | `HK-UHI10-1033` |
| Email | `egoshin_crypto@proton.me` |
| Is your hook demoable? | **Yes** |
| Working hook contract deployed locally? | **Yes** |
| Test Coverage Level | **High coverage, including edge cases (80–100%)** |
| Deployment script? | **Yes** |
| Deployed to a testnet? | **Yes** — но см. оговорку ниже |
| Can your hook be quoted by routers? | **Yes** |
| Tested integration with a frontend? | **Yes** |

## Оговорка к «deployed to a testnet»

Мы деплоили **не в тестнет, а в мейннет** — Base и Unichain. Буквальный ответ «No» прочитается как
«ещё не деплоил», что неправда и хуже по смыслу. Поэтому **Yes** плюс первая же строка апдейта
снимает двусмысленность. Если предпочитаете буквальность — ответ «No» тоже защитим, но тогда
оговорку в тексте надо оставить обязательно.

## Основание для «Test Coverage 80–100%»

Замерено `forge coverage`, по `src/` (скрипты деплоя в знаменатель не входят — это оснастка,
не хук):

| файл | % строк | % ветвлений |
|---|---|---|
| `AirbagMath.sol` | 100.00% (22/22) | 100.00% (5/5) |
| `AirbagOrders.sol` | 87.13% (176/202) | 71.19% (42/59) |
| `AirbagHook.sol` | 56.86% (29/51) | 50.00% (1/2) |
| **итого по `src/`** | **82.5% (227/275)** | |

Замер с включёнными инвариантными тестами (`forge coverage --ir-minimum`); без них выходит 81%.

Низкая цифра у `AirbagHook.sol` — это десять неиспользуемых колбэков `IHooks`, которые существуют
только чтобы ревертить `HookNotImplemented` (6 покрытых функций из 16 = ровно эти десять заглушек).
Покрывать их означало бы тестировать, что revert ревертит.

## Основание для «can be quoted by routers»

`BaseV4Quoter._swap` вызывает настоящий `poolManager.swap` внутри unlock и ревертит результатом,
поэтому `beforeSwap` и `afterSwap` отрабатывают, и котировка приходит **уже с вычтенным зарядом**.
Ончейн-котировка через штатный v4 Quoter корректна. Оффчейн-котировка по состоянию пула — нет;
это записано в `docs/KNOWN-LIMITS.md`.

## Brief progress update

> The hook has been live on Base and Unichain mainnet since 25 August — not testnet — both
> verified, with a full place → cross → claim cycle run on each. Both recorded 70 bps of
> displacement and paid 33.50 bps of the maker's notional, which is exactly what the charge rule
> specifies, on two chains whose pairs sort opposite ways.
>
> Two adversarial audit rounds ran before deploying. Round one produced eight blockers. Round two
> produced two criticals that I had introduced while fixing round one, both of which risked maker
> principal — the more useful lesson being that the invariant which should have caught them was
> summing the wrong field, so I repaired the detector before the defect. Three findings are open by
> choice and written up in docs/KNOWN-LIMITS.md.
>
> No sponsor technology integrated: the design is deliberately oracle-free and keeper-free, so
> there was nothing it needed that a partner supplies.
>
> Remaining: the demo video, and the submission itself.

## General feedback (optional)

> One small thing on this form: "Have you deployed to a testnet?" is Yes/No, and it cannot express
> "deployed to mainnet". I answered Yes because No would read as "hasn't deployed yet", but a third
> option — or "deployed to a testnet or mainnet" — would collect cleaner data from the projects
> furthest along.
