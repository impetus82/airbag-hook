# Deploy runbook

Addresses are predicted from the final bytecode before anything is broadcast, and the deploy
script asserts the deployed address matches rather than trusting it. If a prediction below does
not reproduce, the bytecode changed — rebuild and re-predict rather than pressing on.

## Predicted (bytecode as of 25 Aug)

| | Base (8453) | Unichain (130) |
|---|---|---|
| hook | `0x100d7855ADAC79D90A75B7A89Cf99A9f2B0100C4` | `0x82f8fF08608a4357a9BB12F7439b43453CF6C0C4` |
| salt | `0x…3779` | `0x…2c25` |
| currency0 | WETH | **USDC** |
| currency1 | USDC | **WETH** |
| pool id | `0xfa9bfd56…a6bfba67` | `0xbc9274f6…8b4dcbf5` |

Both hook addresses end in `C4` — those are the encoded permission bits, and a mined address that
does not end that way is the wrong address.

Note the currency ordering differs between the chains: WETH sorts first on Base, USDC first on
Unichain. That is handled in `script/AirbagConfig.sol` and is not something to correct by hand.

## Before broadcasting

```bash
forge clean && forge build
forge test                                    # 66 passing
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
