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

    /// @dev A fresh pool has to start somewhere, and this used to be a constant. It read -201000,
    ///      about 1,866 USDC per WETH, and it was still that on the day the market was near 2,460 —
    ///      copied forward from a project a year older and checked by nobody. Both pools were born
    ///      a quarter below the market, arbitrage walked them to the edge of the seeded band, and
    ///      the demo was left with no liquidity to fill an order against.
    ///
    ///      So it is no longer a constant. INITIAL_TICK is required, has no default, and is
    ///      checked for both sign and plausibility before anything is broadcast. A value nobody
    ///      had to supply is a value nobody had to look at.
    ///
    ///      Read the market first — the canonical v3 WETH/USDC 0.05% pool on Base is the
    ///      reference, and Unichain's tick is its negation because the pair sorts the other way:
    ///
    ///        cast call 0xd0b53D9277642d899DF5C87A3966A349A798F224 \
    ///          "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --rpc-url base
    int24 internal constant TICK_SANITY_MIN = 150_000;
    int24 internal constant TICK_SANITY_MAX = 250_000;

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

        // Validate before broadcasting, not after. Everything below this line costs gas and is
        // irreversible; everything above it is free to get wrong. The checks also have to be
        // reachable without a private key, or they can only be exercised for real.
        bool wethIsCurrency0 = uint160(AirbagConfig.WETH) < uint160(d.usdc);

        int24 initialTick = int24(vm.envInt("INITIAL_TICK"));
        // Sign follows the currency ordering: WETH first means the raw price is USDC per wei, so
        // the tick is negative. Getting this backwards would open the pool at the reciprocal of
        // the intended price, which is a 10^6-scale error, not a rounding one.
        require(
            wethIsCurrency0 ? initialTick < 0 : initialTick > 0,
            "INITIAL_TICK has the wrong sign for this chain's currency ordering"
        );
        int24 magnitude = initialTick < 0 ? -initialTick : initialTick;
        require(
            magnitude >= TICK_SANITY_MIN && magnitude <= TICK_SANITY_MAX,
            "INITIAL_TICK is outside any plausible WETH/USDC range - check it against the market"
        );
        require(initialTick % d.tickSpacing == 0, "INITIAL_TICK must be a multiple of the tick spacing");
        console2.log("initial tick  ", initialTick);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        AirbagHook hook = new AirbagHook{salt: salt}(d.poolManager);
        require(address(hook) == predicted, "address drifted from the prediction");

        PoolKey memory key = AirbagConfig.poolKey(d, address(hook));

        d.poolManager.initialize(key, TickMath.getSqrtPriceAtTick(initialTick));

        vm.stopBroadcast();

        console2.log("deployed hook ", address(hook));
        console2.log("WETH is currency0", wethIsCurrency0);
        console2.log("initial tick  ", initialTick);
        console2.log("pool id       ");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }
}
