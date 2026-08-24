// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AirbagHook} from "../src/AirbagHook.sol";
import {AirbagOrders} from "../src/AirbagOrders.sol";

/// @notice Regressions for the dust-wall blockers. The audit demonstrated both by flooding a
///         tick until crossing it cost more gas than a block allows, and by starving the tick
///         budget with one-wei orders so a real maker was crossed but never filled. Both attacks
///         cost the attacker nothing, because dust is free.
contract AuditGroup3Test is Test, Deployers {
    using StateLibrary for IPoolManager;

    AirbagHook internal hook;
    address internal alice = address(0xA11CE);
    address internal mallory = address(0xBAD);

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
            ModifyLiquidityParams({tickLower: -30000, tickUpper: 30000, liquidityDelta: 10_000e18, salt: bytes32(0)}),
            ""
        );
        deal(Currency.unwrap(currency0), address(this), 1e30);
        deal(Currency.unwrap(currency1), address(this), 1e30);
        _fund(alice);
        _fund(mallory);
    }

    function _fund(address who) internal {
        deal(Currency.unwrap(currency0), who, 1e30);
        deal(Currency.unwrap(currency1), who, 1e30);
        vm.startPrank(who);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _minSize() internal view returns (uint128) {
        return uint128(manager.getLiquidity(key.toId()) / 10_000);
    }

    function _pushTo(int24 target) internal {
        (, int24 cur,,) = manager.getSlot0(key.toId());
        if (target == cur) return;
        bool up = target > cur;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !up,
                amountSpecified: -1e24,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Dust was free, which is what made every starvation attack affordable. A wall now
    ///      costs its builder real capital per rung.
    function test_dustOrdersAreRefused() public {
        vm.prank(mallory);
        vm.expectRevert(AirbagOrders.OrderTooSmallForPool.selector);
        hook.createOrder(key, 10, 1);

        // The floor is a fraction of pool depth, not an arbitrary constant.
        uint128 ok = _minSize(); // hoisted: _minSize reads the pool, which would eat the prank
        vm.prank(mallory);
        hook.createOrder(key, 10, ok);
    }

    /// @dev Crossing a crowded price level must stay affordable. Before the fill budget, a tick
    ///      packed with orders made the level cost unbounded gas and eventually revert every swap
    ///      that touched it — a price wall anyone could erect.
    function test_crossingACrowdedTickStaysAffordable() public {
        uint128 size = _minSize();
        for (uint256 i; i < 40; ++i) {
            vm.prank(mallory);
            hook.createOrder(key, 10, size);
        }

        uint256 before = gasleft();
        _pushTo(60);
        uint256 used = before - gasleft();

        assertLt(used, 15_000_000, "crossing a crowded tick must fit comfortably in a block");
    }

    /// @dev The size cap was per ORDER, so it bounded nothing: N calls just below the limit pile
    ///      up arbitrarily much at one price. The cap has to be cumulative per tick, or the wall
    ///      it is supposed to prevent is simply built one brick at a time.
    function test_sizeCapIsCumulativePerTick() public {
        uint128 poolLiq = manager.getLiquidity(key.toId());
        uint128 justUnder = poolLiq / 100; // exactly the 1% ceiling

        vm.prank(mallory);
        hook.createOrder(key, 10, justUnder);

        // A second order of the same size at the same tick would put 2% of the pool on one price.
        vm.prank(mallory);
        vm.expectRevert(AirbagOrders.TickTooCrowded.selector);
        hook.createOrder(key, 10, justUnder);

        // A different tick is fine — the limit is about concentration, not about the maker.
        vm.prank(mallory);
        hook.createOrder(key, 20, justUnder);
    }

    /// @dev And truncation must only defer. A maker beyond the budget is still owed their fill,
    ///      so a later swap through the same region has to pick them up rather than leave them
    ///      crossed-but-unfilled forever.
    function test_deferredFillsAreNotLost() public {
        uint128 size = _minSize();
        for (uint256 i; i < 40; ++i) {
            vm.prank(mallory);
            hook.createOrder(key, 10, size);
        }
        vm.prank(alice);
        uint256 victim = hook.createOrder(key, 20, size);

        _pushTo(60);
        _pushTo(0);
        _pushTo(60); // a second pass through the same region

        assertTrue(hook.orderOf(victim).filled, "a deferred fill must eventually be settled");
    }
}
