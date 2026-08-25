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

## This is a hackathon deployment

The pools are seeded with dust. The contract is immutable and permissionless, so anyone can
create their own pool against this hook — please read [KNOWN-LIMITS.md](KNOWN-LIMITS.md) before
putting anything you care about behind it. Two adversarial audits ran before deployment and three
findings remain open by choice; none risks a maker's principal, and all three are written down.
