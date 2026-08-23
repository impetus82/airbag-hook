// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {AirbagHook} from "../src/AirbagHook.sol";
import {AirbagConfig} from "./AirbagConfig.sol";

/// @notice Deploy the hook to a mined address and initialise its pool.
///
///         Deployment goes through the canonical CREATE2 factory rather than from the sending
///         EOA, so the resulting address depends only on the salt and the init code. It is
///         therefore identical to whatever `PredictAirbag` printed beforehand, on any chain, at
///         any nonce — and the script asserts that rather than trusting it.
///
///         set -a && source .env && set +a
///         forge script script/DeployAirbag.s.sol --rpc-url base --broadcast --verify
contract DeployAirbag is Script {
    using StateLibrary for IPoolManager;

    /// @dev A fresh pool has to start somewhere. Chosen to be close to the market so the first
    ///      orders are placed against a sane price rather than an arbitrary one; the pool is a
    ///      demonstration venue, not a claim about where WETH/USDC should trade.
    int24 internal constant INITIAL_TICK_WETH_FIRST = -201000; // ~1866 USDC per WETH
    int24 internal constant INITIAL_TICK_USDC_FIRST = 201000;

    function run() external {
        AirbagConfig.Deployment memory d = AirbagConfig.forChain(block.chainid);

        (address predicted, bytes32 salt) = HookMiner.find(
            AirbagConfig.CREATE2_FACTORY,
            AirbagConfig.flags(),
            type(AirbagHook).creationCode,
            abi.encode(address(d.poolManager))
        );

        console2.log("chain         ", d.name);
        console2.log("predicted hook", predicted);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        AirbagHook hook = new AirbagHook{salt: salt}(d.poolManager);
        require(address(hook) == predicted, "address drifted from the prediction");

        PoolKey memory key = AirbagConfig.poolKey(d, address(hook));
        bool wethIsCurrency0 = uint160(AirbagConfig.WETH) < uint160(d.usdc);
        int24 initialTick = wethIsCurrency0 ? INITIAL_TICK_WETH_FIRST : INITIAL_TICK_USDC_FIRST;

        d.poolManager.initialize(key, TickMath.getSqrtPriceAtTick(initialTick));

        vm.stopBroadcast();

        console2.log("deployed hook ", address(hook));
        console2.log("WETH is currency0", wethIsCurrency0);
        console2.log("initial tick  ", initialTick);
        console2.log("pool id       ");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }
}
