# Demo video — script and shot list

**Hard requirements:** ≤ 5 minutes · **your own live voice**, no AI narration. Failing either means
the project is not judged at all, and is disqualified from Demo Day. Everything else is a preference.

**Narration is 545 words.** At 120 words a minute — a slow, careful pace — that is 4:16, and even
with the live transaction it lands under 4:45. That margin is deliberate: the cap is the one thing
here that cannot be argued with afterwards. Do not try to fill
five minutes; a tight four beats a padded five.

Record in **English**. An accent is entirely normal in this cohort; reading too fast is not. Read it
aloud once before recording, and wherever you stumble, change the wording rather than your delivery.

---

## 0:00 – 0:33 · The problem

**На экране:** объяснительная страница `site/index.html`, верхний экран. Не листать.

> You place a limit order: sell my ETH at eighteen sixty-six. It rests, waiting.
>
> A large trade arrives, and it doesn't just touch your price — it shoves the market past it, to
> eighteen seventy-five. You were filled at exactly the price you asked for, so formally nothing
> went wrong. But that extra move existed only because your order was in the way, and somebody else
> kept all of it.
>
> A resting limit order is a free option written to the market.

## 0:33 – 1:00 · What the hook does

**На экране:** лесенка тиков — с обложки или со страницы: своп проходит сквозь ордер и не
останавливается.

> Airbag is a Uniswap v4 hook that gives that part back. At fill time it measures how far past your
> price the swap pushed the market, charges that swap a capped share of the overshoot, and credits
> it to your order.
>
> All inside the same transaction, from the pool's own tick. No oracle, no keeper, and nothing
> settled at a later block — a future price is a number the filler themselves could write.

## 1:00 – 1:35 · The measurement, and why it shaped the design

**На экране:** `tools/fetch_fixture.py`, затем таблица с цифрами из README.

> Before I wrote any Solidity, I measured. Thirty days of Base WETH/USDC — two hundred fifty-three
> thousand swaps, eleven thousand reconstructed fills.
>
> The median displacement was **two basis points**. That is below the pool fee, which means the
> median maker was already made whole by the fee they earned. So Airbag charges nothing there. The
> threshold is not a tuned constant — it is the pool's own fee.
>
> The problem is in the tail: twenty-two percent of fills, averaging twenty-four basis points. That
> tail is what this hook exists for.

## 1:35 – 2:15 · Live on mainnet

**На экране:** https://impetus82.github.io/airbag-hook/ — кошелёк подключён **до** старта записи.
Ставите настоящий ордер на Base, размер минимальный (кнопка `Min`).

⚠️ Подключение кошелька, переключение сети и подтверждение MetaMask **отрепетировать заранее**.
Если транзакция идёт дольше 15 секунд — говорите следующий абзац поверх ожидания, не молчите
в камеру.

> This is live on Base and Unichain mainnet. Real pools, real money — dust, but real. I'll place an
> order now.
>
> One tick spacing of liquidity, and the order is an ERC-721 — because a rebate needs a specific
> recipient, and a token has one. Other designs return recaptured value to the pool at large:
> correct for a pool, useless to the person who got run over.

## 2:15 – 3:05 · The proof

**На экране:** BaseScan с тремя транзакциями из `docs/DEPLOYMENTS.md`, затем Uniscan с зеркальным
циклом. Все вкладки открыть **до** записи.

> Here is a complete cycle that already ran on Base. Order placed. A swap crossed it and carried
> seventy basis points past it. Then the claim.
>
> The rule: subtract the five basis point fee, charge what's left marginally — seventy percent of
> the first band, fifty beyond. That is **thirty-three point five** basis points of the order's
> notional. It paid thirty-three point five. Not approximately.
>
> Same cycle on Unichain, where the pair sorts the other way round. Same seventy. Same
> thirty-three point five.

## 3:05 – 3:50 · What was hard, and what is still open

**На экране:** `docs/KNOWN-LIMITS.md`, затем прогон `forge test` с 66 зелёными.

> Two adversarial audit rounds ran before deployment. Round one found eight blockers. Round two
> found two criticals — and both were mine, written while fixing round one.
>
> One left the hook owing more than it held, which locks maker principal. The invariant that should
> have caught it was summing the wrong field — so I fixed the detector first, and it caught the
> insolvency immediately.
>
> Three findings are open on purpose and written down. Two honest limits here too: the pools hold
> dust, and the crossing swaps were mine.

## 3:50 – 4:10 · Close

**На экране:** GitHub-репозиторий, README сверху.

> So: the mechanism is verified on mainnet to the basis point. Whether paying the tail makes makers
> quote tighter at real volume is a hypothesis my data does not settle — I measured the size of the
> tail, not the response to it.
>
> Everything is public: the contract, sixty-six tests, the measurement tool, the front end.
> Thank you for watching.

---

## Чек-лист перед записью

- [ ] Кошелёк подключён, сеть Base, баланс проверен — **до** старта записи
- [ ] Вкладки открыты заранее: сайт, BaseScan ×3, Uniscan ×3, GitHub, KNOWN-LIMITS
- [ ] **Пулы живые:** `getLiquidity` ≠ 0 на обеих сетях — проверить утром 1-го, цена может уйти
      из полосы, и тогда «Place order» отревертит прямо в кадре
- [ ] Уведомления и Telegram выключены, «Не беспокоить» включён
- [ ] Микрофон гарнитуры, не встроенный в ноутбук
- [ ] Крупный шрифт в терминале и в браузере — судья смотрит в небольшом окне
- [ ] Полный прогон с таймером **до** чистовой записи
- [ ] Итоговый файл ≤ 5:00 по факту, а не по замыслу

## Чем записывать

QuickTime Player → File → New Screen Recording, звук с гарнитуры: бесплатно, уже установлен, пишет
экран и голос одной дорожкой. Выложить на YouTube как **unlisted** и дать эту ссылку в форму —
не «private», иначе судья её не откроет.

## Проверка живости пулов (утро 1 сентября)

```bash
cast call 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71 "getLiquidity(bytes32)(uint128)" 0xfa9bfd56f6bea998f1d5f20ead8b36cc5fe813ed66460c567a6180eba6bfba67 --rpc-url https://mainnet.base.org
```
