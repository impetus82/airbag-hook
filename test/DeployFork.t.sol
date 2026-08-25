// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {AirbagHook} from "../src/AirbagHook.sol";
import {AirbagConfig} from "../script/AirbagConfig.sol";

/// @notice Rehearses the real deployment against a fork of each live chain, so the first time
///         the mined address, the permission bits and the pool initialisation are exercised
///         against a real PoolManager is not the time real gas is being spent.
///
///         Needs network access, so it is opt-in:
///             RUN_FORK_TESTS=1 forge test --mc DeployForkTest
contract DeployForkTest is Test {
    using StateLibrary for IPoolManager;

    function _enabled() internal view returns (bool) {
        try vm.envUint("RUN_FORK_TESTS") returns (uint256 v) {
            return v == 1;
        } catch {
            return false;
        }
    }

    function _rehearse(string memory rpcAlias, uint256 expectedChainId) internal {
        vm.createSelectFork(vm.rpcUrl(rpcAlias));
        assertEq(block.chainid, expectedChainId, "fork landed on the wrong chain");

        AirbagConfig.Deployment memory d = AirbagConfig.forChain(block.chainid);
        assertGt(address(d.poolManager).code.length, 0, "no PoolManager at the configured address");

        (address predicted, bytes32 salt) = HookMiner.find(
            AirbagConfig.CREATE2_FACTORY,
            AirbagConfig.flags(),
            type(AirbagHook).creationCode,
            abi.encode(address(d.poolManager))
        );

        // Deploy exactly as the script does: through the canonical factory, with the mined salt.
        vm.prank(AirbagConfig.CREATE2_FACTORY);
        AirbagHook hook = new AirbagHook{salt: salt}(d.poolManager);
        assertEq(address(hook), predicted, "mined address did not reproduce on a real chain");

        PoolKey memory key = AirbagConfig.poolKey(d, address(hook));
        bool wethIsCurrency0 = uint160(AirbagConfig.WETH) < uint160(d.usdc);
        int24 tick = wethIsCurrency0 ? int24(-201000) : int24(201000);

        d.poolManager.initialize(key, TickMath.getSqrtPriceAtTick(tick));

        (, int24 got,,) = d.poolManager.getSlot0(key.toId());
        assertEq(got, tick, "pool did not initialise at the intended price");
    }

    function test_baseDeploymentRehearsal() public {
        if (!_enabled()) return;
        _rehearse("base", AirbagConfig.BASE);
    }

    function test_unichainDeploymentRehearsal() public {
        if (!_enabled()) return;
        _rehearse("unichain", AirbagConfig.UNICHAIN);
    }
}
