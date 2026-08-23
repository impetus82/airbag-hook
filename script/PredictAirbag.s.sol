// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {AirbagHook} from "../src/AirbagHook.sol";
import {AirbagConfig} from "./AirbagConfig.sol";

/// @notice Work out where the hook will land, and the pool id that follows from it, without
///         touching a key or broadcasting anything.
///
///         Deploying a hook means mining a salt until the address encodes the right permission
///         bits, so the address is not known in advance the way an ordinary deployment's is.
///         Running this first means the deployment can be checked, written down and verified
///         against what actually appears on chain — a mismatch then means something changed,
///         rather than being something to shrug at.
///
///         forge script script/PredictAirbag.s.sol --rpc-url base
contract PredictAirbag is Script {
    function run() external view {
        AirbagConfig.Deployment memory d = AirbagConfig.forChain(block.chainid);

        (address hookAddr, bytes32 salt) = HookMiner.find(
            AirbagConfig.CREATE2_FACTORY,
            AirbagConfig.flags(),
            type(AirbagHook).creationCode,
            abi.encode(address(d.poolManager))
        );

        PoolKey memory key = AirbagConfig.poolKey(d, hookAddr);

        console2.log("chain          ", d.name);
        console2.log("pool manager   ", address(d.poolManager));
        console2.log("predicted hook ", hookAddr);
        console2.log("salt           ");
        console2.logBytes32(salt);
        console2.log("currency0      ", address(uint160(uint256(bytes32(abi.encode(key.currency0))))));
        console2.log("currency1      ", address(uint160(uint256(bytes32(abi.encode(key.currency1))))));
        console2.log("pool id        ");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }
}
