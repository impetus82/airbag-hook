// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AirbagHook} from "../src/AirbagHook.sol";
import {AirbagOrders} from "../src/AirbagOrders.sol";

contract ZzUnfillRefute is Test, Deployers {
    using StateLibrary for IPoolManager;

    AirbagHook internal hook;
    address internal victim = address(0xA11CE);
    address internal attacker = address(0xBEEF);

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
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -12000, tickUpper: 12000, liquidityDelta: 5_000e18, salt: bytes32(0)}),
            ""
        );
        deal(Currency.unwrap(currency0), address(this), 500_000 ether);
        deal(Currency.unwrap(currency1), address(this), 500_000 ether);
        _fund(victim);
        _fund(attacker);
    }

    function _fund(address who) internal {
        deal(Currency.unwrap(currency0), who, 100_000 ether);
        deal(Currency.unwrap(currency1), who, 100_000 ether);
        vm.startPrank(who);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _pushTo(int24 targetTick) internal {
        (, int24 cur,,) = manager.getSlot0(key.toId());
        if (targetTick == cur) return;
        bool up = targetTick > cur;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !up,
                amountSpecified: -400_000 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    int24 constant T = 3900;

    function test_fillThenRetrace() public {
        uint256 c0Before = IERC20(Currency.unwrap(currency0)).balanceOf(victim);

        vm.prank(victim);
        uint256 vid = hook.createOrder(key, T, 5e18);
        uint256 deposited = c0Before - IERC20(Currency.unwrap(currency0)).balanceOf(victim);
        console2.log("deposited currency0", deposited);

        _pushTo(4260); // clears T+60 by 300 ticks
        AirbagOrders.Order memory o = hook.orderOf(vid);
        (, int24 p1,,) = manager.getSlot0(key.toId());
        console2.log("postTick after fill swap", p1);
        console2.log("filled", o.filled);
        console2.log("rebate0", o.rebate0);
        console2.log("rebate1", o.rebate1);
        assertTrue(o.filled, "should be filled");

        // market retraces well below the maker's range
        vm.roll(block.number + 1);
        _pushTo(900);
        (, int24 p2,,) = manager.getSlot0(key.toId());
        console2.log("postTick after retrace", p2);

        // cancelOrder locked out?
        vm.prank(victim);
        vm.expectRevert(AirbagOrders.OrderAlreadyFilled.selector);
        hook.cancelOrder(vid, key);

        uint256 a0 = IERC20(Currency.unwrap(currency0)).balanceOf(victim);
        uint256 a1 = IERC20(Currency.unwrap(currency1)).balanceOf(victim);
        vm.prank(victim);
        hook.claimOrder(vid, key);
        uint256 got0 = IERC20(Currency.unwrap(currency0)).balanceOf(victim) - a0;
        uint256 got1 = IERC20(Currency.unwrap(currency1)).balanceOf(victim) - a1;
        console2.log("claim got currency0", got0);
        console2.log("claim got currency1", got1);
    }

    /// Same, but a single attacker tx that round-trips through the range.
    function test_sameTxRoundTrip() public {
        vm.prank(victim);
        uint256 vid = hook.createOrder(key, T, 5e18);

        vm.startPrank(attacker, attacker);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        // up through the range
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -400_000 ether, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(4260)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        console2.log("mid filled", hook.orderOf(vid).filled);
        // straight back down
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -400_000 ether, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(0)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        (, int24 p,,) = manager.getSlot0(key.toId());
        console2.log("final tick", p);
        AirbagOrders.Order memory o = hook.orderOf(vid);
        console2.log("filled", o.filled, "rebate0", o.rebate0);
        console2.log("rebate1", o.rebate1);

        uint256 a0 = IERC20(Currency.unwrap(currency0)).balanceOf(victim);
        uint256 a1 = IERC20(Currency.unwrap(currency1)).balanceOf(victim);
        vm.prank(victim);
        hook.claimOrder(vid, key);
        console2.log("claim got c0", IERC20(Currency.unwrap(currency0)).balanceOf(victim) - a0);
        console2.log("claim got c1", IERC20(Currency.unwrap(currency1)).balanceOf(victim) - a1);
    }
}
