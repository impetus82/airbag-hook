# Deploy runbook

Addresses are predicted from the final bytecode before anything is broadcast, and the deploy
script asserts the deployed address matches rather than trusting it. If a prediction below does
not reproduce, the bytecode changed — rebuild and re-predict rather than pressing on.

## Predicted — bytecode as of 17 Sep, after the top-up fixes

| | Base (8453) | Unichain (130) |
|---|---|---|
| hook | `0xf328ff41720B6778d1610BB05a6CAB43D0CE40C4` | `0xCeC392D5388BB110c4082011901BD9FEBC6f00C4` |
| salt | `0x…06ec` | `0x…2004` |
| pool id | `0x2b6bb690…29a2b05a` | `0x7db1fe33…ea812f40` |
| currency0 | WETH | **USDC** |
| currency1 | USDC | **WETH** |
| `INITIAL_TICK` | `-198250` | `198250` |

Both hook addresses end in `C4` — those are the encoded permission bits, and a mined address that
does not end that way is the wrong address.

The currency ordering differs between the chains: WETH sorts first on Base, USDC first on Unichain.
That is handled in `script/AirbagConfig.sol` and is not something to correct by hand.

### The superseded deployment

| | Base | Unichain |
|---|---|---|
| hook | `0x100d7855…0100C4` | `0x82f8fF08…C6C0C4` |

Those are what UHI10 was judged on. They are immutable and carry both top-up defects — the
one-block window and the order-keyed ring. They stay where they are as the record of what was
submitted; nothing new should be pointed at them.

## INITIAL_TICK is required, and that is deliberate

It used to be a constant reading `-201000`, about 1,866 USDC per WETH, and it was still that on a
day the market was near 2,460 — carried forward from a project a year older and checked by nobody.
Both pools opened a quarter below the market, arbitrage walked them to the edge of the seeded band,
and the demo was left with no liquidity to fill an order against.

So there is no default. Read the market, align to the tick spacing, and pass it in:

```bash
cast call 0xd0b53D9277642d899DF5C87A3966A349A798F224 \
  "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --rpc-url base
```

The second value is the tick. Round it to a multiple of 10. Base takes it as-is (negative, because
WETH sorts first); Unichain takes its negation. The script refuses a wrong sign, an implausible
magnitude, and a misaligned tick — **before** it broadcasts anything, so the checks can be
exercised without a key.

## Before broadcasting

```bash
forge clean && forge build
forge test                                    # 71 passing
RUN_FORK_TESTS=1 forge test --mc DeployForkTest   # rehearses against both live chains
forge script script/PredictAirbag.s.sol --rpc-url base       # must match the table above
forge script script/PredictAirbag.s.sol --rpc-url unichain
```

Gas needed: the deploy plus one pool initialisation per chain. Small, but not zero.

## Broadcast

`vm.envUint` reads the process environment, not the shell's — a plain `source` sets shell
variables only, and forge will report the key as missing. Export it:

```bash
set -a && source .env && set +a
forge script script/DeployAirbag.s.sol --rpc-url base --broadcast --verify
forge script script/DeployAirbag.s.sol --rpc-url unichain --broadcast --verify
```

The script reverts if the deployed address differs from the prediction, so a mismatch stops
before the pool is initialised rather than after.

## After

1. Check both hooks verified in the explorers (Basescan, Uniscan).
2. Seed each pool with a dust position — enough to make the pool real, small enough that the
   documented limits stay theoretical. This is a hackathon deployment, not a venue for funds.
3. Record the addresses in the README, `site/index.html` and the frontend config.
4. Proof of life: create an order, cross it with a swap, claim. Keep the transaction hashes.

## Address literals in Solidity must be EIP-55 checksummed

An all-lowercase address copied out of `cast` will not compile in a `.sol` file. `.ts` and `.md`
do not care.
