# Demo video — script and shot list

**Hard requirements:** ≤ 5 minutes · **your own live voice**, no AI narration. Failing either means
the project is not judged at all and is disqualified from Demo Day. Everything else is a preference.

**Target: 4 minutes 30.** Narration below is ~630 words ≈ 4:05 spoken at a calm pace, leaving ~25
seconds of slack for the live transaction and pauses. Do not try to fill five minutes.

Record in **English**. An accent is completely normal in this cohort; reading too fast is not.
Read it out loud once before recording — where you stumble, change the wording, not your delivery.

---

## 0:00 – 0:35 · The problem

**На экране:** объяснительная страница `site/index.html`, верхний экран. Не листать.

> You place a limit order: sell my ETH at eighteen sixty-six. It rests, waiting.
>
> A large trade arrives — and it doesn't just touch your price. It shoves the market past it, to
> eighteen seventy-five. You were filled at exactly the price you asked for, so formally nothing
> went wrong. But that extra move only existed because your order was sitting in the way, and
> somebody else kept all of it.
>
> A resting limit order is a free option written to the market.

## 0:35 – 1:08 · What the hook does

**На экране:** диаграмма-лесенка тиков с обложки или со страницы — та, где своп проходит сквозь
ордер и не останавливается.

> Airbag is a Uniswap v4 hook that gives that part back. At fill time it measures how far past your
> price the swap pushed the market, charges that swap a capped share of the overshoot, and credits
> it to your order.
>
> All of it happens inside the same transaction, from the pool's own tick. No oracle. No keeper.
> And nothing is ever settled at a later block — because a price in a future block is a number the
> filler themselves could write.

## 1:08 – 1:50 · The measurement, and why it shaped the design

**На экране:** `tools/fetch_fixture.py` и рядом цифры из README. Можно просто показать таблицу.

> Before I wrote any Solidity, I measured. Thirty days of Base WETH/USDC — two hundred fifty-three
> thousand swap events, about eleven thousand four hundred reconstructed fills.
>
> The median displacement was **two basis points**. Two. That is below the pool fee — which means
> on a median fill the maker has already been made whole by the fee they earned on their own fill.
> So Airbag charges nothing there. The threshold is not a tuned constant; it is the pool's own fee.
>
> The problem lives in the tail: twenty-two and a half percent of fills, averaging twenty-four
> basis points. That tail is what this hook exists for.

## 1:50 – 2:35 · Live on mainnet

**На экране:** https://impetus82.github.io/airbag-hook/ — кошелёк уже подключён **до записи**.
Ставите настоящий ордер на Base. Размер — минимальный, кнопка `Min`.

⚠️ Подключение кошелька, переключение сети и подтверждение MetaMask **отрепетировать заранее**.
Если транзакция подтверждается дольше 15 секунд — говорите следующий абзац поверх ожидания, не
молчите в камеру.

> This is live on Base and Unichain mainnet. Real pools, real money — dust, but real. I'll place an
> order right now.
>
> One tick spacing of liquidity, and the order is an ERC-721. That matters more than it sounds:
> a rebate needs a specific recipient, and a token has one. This is the difference from designs
> that recapture value at fill time and return it to the pool at large — that is correct for a
> pool, and useless to the person who actually got run over.

## 2:35 – 3:25 · The proof

**На экране:** BaseScan, три транзакции из `docs/DEPLOYMENTS.md` открыты во вкладках заранее.
Затем Uniscan с зеркальным циклом. Вкладки открыть **до записи**.

> Here is a complete cycle that already ran on Base. Order placed. A swap crossed it and carried on
> seventy basis points past it. Then the claim.
>
> The hook recorded seventy basis points of displacement. The rule says: subtract the five basis
> point fee, then charge what's left marginally — seventy percent of the first band, fifty percent
> beyond. That comes to **thirty-three point five** basis points of the order's notional.
>
> It paid thirty-three point five. Not approximately.
>
> And here is the same cycle on Unichain, where the pair sorts the other way round — so the order
> rests below the market and sells into a falling tick. Same seventy basis points. Same thirty-three
> point five.

## 3:25 – 4:10 · What was hard, and what is still open

**На экране:** `docs/KNOWN-LIMITS.md`, затем прокрутка `forge test` с 66 зелёными.

> Two adversarial audit rounds ran before deployment. Round one found eight blockers. Round two
> found two criticals — and both of those were mine, written while fixing round one.
>
> One of them made every exact-output swap pay nothing. The other booked credit before a clamp, so
> the hook owed makers more than it held — which locks their principal. The invariant that should
> have caught both was summing the wrong field. I fixed the detector first, and it caught the
> insolvency immediately.
>
> Three findings are still open on purpose, and they are written down. Two honest limits on this
> demo, too: the pools hold dust, and the crossing swaps were mine. A pool this shallow does not
> attract arbitrage.

## 4:10 – 4:35 · Close

**На экране:** GitHub-репозиторий, README сверху.

> So — the mechanism is verified on mainnet to the basis point. Whether compensating the tail makes
> makers quote tighter at real volume is a hypothesis my data does not settle: I measured the size
> of the tail, not how makers respond to being paid for it.
>
> Everything is public — the contract, sixty-six tests, the measurement tool, and the front end.
> Thank you for watching.

---

## Чек-лист перед записью

- [ ] Кошелёк подключён, сеть Base, баланс проверен — **до** старта записи
- [ ] Вкладки открыты заранее: сайт, BaseScan ×3, Uniscan ×3, GitHub, KNOWN-LIMITS
- [ ] Пулы живые: `getLiquidity` ≠ 0 на обеих сетях (проверить утром 1-го — цена может уйти из полосы)
- [ ] Уведомления и Telegram выключены, «Не беспокоить» включён
- [ ] Микрофон: гарнитура, не встроенный микрофон ноутбука
- [ ] Экран 1600×900 или больше, шрифт терминала крупный — судья смотрит в окне
- [ ] Пробный прогон целиком с таймером **до** чистовой записи
- [ ] Файл ≤ 5:00 по факту, не по замыслу

## Чем записывать

QuickTime Player → File → New Screen Recording, звук с гарнитуры. Бесплатно, уже стоит, пишет
экран и голос одной дорожкой. Загрузить на YouTube как **unlisted** и дать ссылку в форму —
не «private», иначе судья её не откроет.
