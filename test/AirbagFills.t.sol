// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AirbagHook} from "../src/AirbagHook.sol";

/// @notice Day 3 — the market fills orders; the hook only has to notice. These tests pin what
///         "noticed correctly" means, including the case that must NOT count: a swap that stops
///         inside a maker's range.
contract AirbagFillsTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    AirbagHook internal hook;
    address internal maker = address(0xA11CE);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(AirbagHook).creationCode, abi.encode(address(manager)));
        hook = new AirbagHook{salt: salt}(manager);
        assertEq(address(hook), predicted);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        deal(Currency.unwrap(currency0), maker, 1000 ether);
        deal(Currency.unwrap(currency1), maker, 1000 ether);
        vm.startPrank(maker);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _isFilled(uint256 id) internal view returns (bool f) {
        (,,,,,, f,) = hook.orders(id);
    }

    function _alignedTick(int24 offsetSpacings) internal view returns (int24) {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        return ((tick / key.tickSpacing) + offsetSpacings) * key.tickSpacing;
    }

    function test_orderFillsWhenPriceCrossesIt() public {
        int24 target = _alignedTick(1);
        vm.prank(maker);
        uint256 id = hook.createOrder(key, target, 1e18);
        assertFalse(_isFilled(id));

        // Push the price up well past the order's upper bound.
        swap(key, false, -5e17, "");

        (, int24 after_,,) = manager.getSlot0(key.toId());
        assertGe(after_, target + key.tickSpacing, "price must clear the range");
        assertTrue(_isFilled(id), "fully crossed order must be marked filled");
    }

    function test_orderBelowMarketFillsOnFallingPrice() public {
        int24 target = _alignedTick(-3);
        vm.prank(maker);
        uint256 id = hook.createOrder(key, target, 1e18);
        assertFalse(_isFilled(id));

        swap(key, true, -5e17, "");

        (, int24 after_,,) = manager.getSlot0(key.toId());
        assertLt(after_, target, "price must fall below the range");
        assertTrue(_isFilled(id), "fully crossed order must be marked filled");
    }

    function test_untouchedOrderStaysWaiting() public {
        int24 far = _alignedTick(50);
        vm.prank(maker);
        uint256 id = hook.createOrder(key, far, 1e18);

        swap(key, false, -1e15, ""); // nudge upward, nowhere near `far`

        assertFalse(_isFilled(id), "an order the price never reached must stay waiting");
    }

    /// @dev The important negative case. A position the price only partly traversed is only
    ///      partly converted: the maker has not received their limit price, and there is no
    ///      displacement past their tick to compensate. Marking it filled would be a lie.
    function test_partiallyCrossedOrderIsNotFilled() public {
        int24 target = _alignedTick(1);
        vm.prank(maker);
        uint256 id = hook.createOrder(key, target, 1e18);

        // Stop the swap inside [target, target + spacing).
        uint160 limit = TickMath.getSqrtPriceAtTick(target + key.tickSpacing / 2);
        swapRouterStopAt(limit);

        (, int24 after_,,) = manager.getSlot0(key.toId());
        assertGe(after_, target, "price should be inside the range");
        assertLt(after_, target + key.tickSpacing, "price should not have cleared the range");
        assertFalse(_isFilled(id), "partially crossed order must not be marked filled");
    }

    function test_manyOrdersFillInOneSwap() public {
        uint256[] memory ids = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            // Resolve the tick BEFORE pranking: _alignedTick makes an external call of its own,
            // which would otherwise consume the prank and send createOrder from this contract.
            int24 t = _alignedTick(int24(int256(i)) + 1);
            vm.prank(maker);
            ids[i] = hook.createOrder(key, t, 1e17);
        }

        swap(key, false, -5e17, "");

        for (uint256 i; i < 5; ++i) {
            assertTrue(_isFilled(ids[i]), "every crossed order must be filled");
        }
    }

    /// @dev Cancelling must also clear the tick's waiting list, otherwise a later swap would walk
    ///      a tick that no longer holds anything.
    function test_cancelledOrderIsNotFilledLater() public {
        int24 target = _alignedTick(1);
        vm.prank(maker);
        uint256 id = hook.createOrder(key, target, 1e18);
        vm.prank(maker);
        hook.cancelOrder(id, key);

        swap(key, false, -5e17, "");

        (,,,,,, bool filled,) = hook.orders(id);
        assertFalse(filled, "a cancelled order has no state left to fill");
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function swapRouterStopAt(uint160 sqrtPriceLimitX96) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -5e17,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
