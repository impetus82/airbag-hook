// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {AirbagHook} from "../src/AirbagHook.sol";

/// @notice Day-1 plumbing test. Before a single line of displacement math is written, prove the
///         v4 wiring is sound: the hook address encodes the right permission bits, a pool
///         initializes with it attached, and a real swap round-trips through both callbacks.
///         Everything else is built on top of this.
contract AirbagHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    AirbagHook internal hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this), flags, type(AirbagHook).creationCode, abi.encode(address(manager))
        );
        hook = new AirbagHook{salt: salt}(manager);
        assertEq(address(hook), predicted, "mined address mismatch");

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1
        );
    }

    /// @dev The transient slot is a hard-coded literal because inline assembly cannot reference a
    ///      keccak256 constant. Pin the derivation here so the two can never silently diverge.
    function test_preTickSlot_matchesDerivation() public pure {
        assertEq(
            uint256(keccak256("airbag.preTick")),
            0xf39f4f275c965d88ccd39db7efb952551c40121db7dd5c014405e56626e0561b
        );
    }

    function test_hookAddressEncodesPermissions() public view {
        uint160 addr = uint160(address(hook));
        assertTrue(addr & uint160(Hooks.BEFORE_SWAP_FLAG) != 0, "beforeSwap bit");
        assertTrue(addr & uint160(Hooks.AFTER_SWAP_FLAG) != 0, "afterSwap bit");
        assertTrue(addr & uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) != 0, "afterSwapReturnDelta bit");
        // Permissions we deliberately do NOT hold — a stray bit here would silently enable a
        // callback that reverts with HookNotImplemented and brick every pool using the hook.
        assertTrue(addr & uint160(Hooks.BEFORE_INITIALIZE_FLAG) == 0, "no beforeInitialize");
        assertTrue(addr & uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) == 0, "no beforeAddLiquidity");
        assertTrue(addr & uint160(Hooks.BEFORE_DONATE_FLAG) == 0, "no beforeDonate");
    }

    function test_swapRoundTripsThroughHook() public {
        (, int24 tickBefore,,) = manager.getSlot0(key.toId());

        vm.recordLogs();
        swap(key, true, -1e15, "");

        (, int24 tickAfter,,) = manager.getSlot0(key.toId());
        assertLt(tickAfter, tickBefore, "zeroForOne must push the tick down");

        // Both callbacks fired, and beforeSwap saw the pre-swap tick.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawPre;
        bool sawSwap;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PreTickObserved(bytes32,int24)")) sawPre = true;
            if (logs[i].topics[0] == keccak256("SwapObserved(bytes32,int24,int24)")) {
                sawSwap = true;
                (int24 pre, int24 post) = abi.decode(logs[i].data, (int24, int24));
                assertEq(pre, tickBefore, "pre-tick snapshot wrong");
                assertEq(post, tickAfter, "post-tick read wrong");
            }
        }
        assertTrue(sawPre, "beforeSwap did not fire");
        assertTrue(sawSwap, "afterSwap did not fire");
    }
}
