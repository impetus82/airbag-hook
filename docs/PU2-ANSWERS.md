# Progress Update 2 — готовые ответы для копирования

Форма: **https://tally.so/r/wdMO5D** · срок: понедельник 31 августа · ответы приватные, видит
только команда Atrium.

Открывайте форму в своём браузере и копируйте отсюда.

---

## Project ID

```
HK-UHI10-1033
```

## What's the email you use for the cohort

```
egoshin_crypto@proton.me
```

## Brief Progress update (optional)

```
The hook has been live on Base and Unichain mainnet since 25 August - not testnet - both verified, with a full place / cross / claim cycle run on each. Both recorded 70 bps of displacement and paid 33.50 bps of the maker’s notional, which is exactly what the charge rule specifies, on two chains whose pairs sort opposite ways.

Two adversarial audit rounds ran before deploying. Round one produced eight blockers. Round two produced two criticals that I had introduced while fixing round one, both of which risked maker principal. The more useful lesson was that the invariant which should have caught them was summing the wrong field, so I repaired the detector before the defect. Three findings are open by choice and written up in docs/KNOWN-LIMITS.md.

No sponsor technology integrated: the design is deliberately oracle-free and keeper-free, so there was nothing it needed that a partner supplies.

Remaining: the demo video, and the submission itself.

Repo: https://github.com/impetus82/airbag-hook  |  Front end: https://impetus82.github.io/airbag-hook/
```

---

## Радиокнопки

| вопрос | ответ |
|---|---|
| Is your hook demoable? | **Yes** |
| Do you have a working hook contract deployed locally? | **Yes** |
| Test Coverage Level | **High coverage, including edge cases (80–100%)** — пятый вариант |
| Do you have a deployment script? | **Yes** |
| Have you deployed to a testnet? | **Yes** — см. оговорку ниже |
| Can your hook be quoted by routers? | **Yes** |
| Have you tested integration with a frontend? | **Yes** |

---

## General Feedback (optional)

```
One small thing on this form: "Have you deployed to a testnet?" is Yes/No, and cannot express "deployed to mainnet". I answered Yes, because No would read as "hasn’t deployed yet" - but a third option, or wording it as "testnet or mainnet", would collect cleaner data from the projects that are furthest along.
```

---

## Обоснования, если спросят

**Покрытие 80–100%.** `forge coverage --ir-minimum` с включёнными инвариантными тестами, по `src/`
(скрипты деплоя в знаменатель не входят — это оснастка, не хук):

| файл | % строк |
|---|---|
| `AirbagMath.sol` | 100.00% (22/22) |
| `AirbagOrders.sol` | 87.13% (176/202) |
| `AirbagHook.sol` | 56.86% (29/51) |
| **итого `src/`** | **82.5% (227/275)** |

Низкая цифра у `AirbagHook.sol` — это десять неиспользуемых колбэков `IHooks`, существующих
только чтобы ревертить `HookNotImplemented`. Покрывать их значило бы тестировать, что revert
ревертит.

**Котируемость роутерами.** `BaseV4Quoter._swap` вызывает настоящий `poolManager.swap` внутри
unlock и ревертит результатом, поэтому `beforeSwap` и `afterSwap` отрабатывают и котировка
приходит уже с вычтенным зарядом. Ончейн-котировка через штатный v4 Quoter корректна;
оффчейн-котировка по состоянию пула — нет, и это записано в `docs/KNOWN-LIMITS.md`.

**«Deployed to a testnet» → Yes.** В тестнет не деплоили — деплоили в мейннет, Base и Unichain.
Буквальный «No» прочитается как «ещё не деплоил», что неверно и хуже по смыслу. Первая строка
апдейта снимает двусмысленность прямым текстом: *live on Base and Unichain mainnet — not testnet*.
Если предпочитаете буквальность, ставьте No: текст всё равно всё объясняет.
