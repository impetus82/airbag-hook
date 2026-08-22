// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AirbagHook} from "../src/AirbagHook.sol";
import {AirbagOrders} from "../src/AirbagOrders.sol";
import {AirbagOrders} from "../src/AirbagOrders.sol";

/// @notice Day 2 — an order is one tick-spacing of liquidity, entirely on one side of the
///         market, owned as an ERC-721. These tests pin the properties the whole design leans
///         on: the maker's tokens actually reach the pool, the side is derived from the market
///         rather than trusted from the caller, and an unfilled order is fully recoverable.
contract AirbagOrdersTest is Test, Deployers {
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

        // Fund the maker and let the hook pull on their behalf.
        _deepenPool();

        deal(Currency.unwrap(currency0), maker, 100 ether);
        deal(Currency.unwrap(currency1), maker, 100 ether);
        vm.startPrank(maker);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function test_createOrder_aboveMarket_isSellingCurrency0() public {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 target = ((tick / key.tickSpacing) + 2) * key.tickSpacing;

        uint256 bal0Before = IERC20(Currency.unwrap(currency0)).balanceOf(maker);
        uint256 bal1Before = IERC20(Currency.unwrap(currency1)).balanceOf(maker);

        vm.prank(maker);
        uint256 id = hook.createOrder(key, target, 1e18);

        assertEq(hook.ownerOf(id), maker, "maker owns the order NFT");
        AirbagOrders.Order memory o = hook.orderOf(id);
        bool zeroForOne = o.zeroForOne;
        uint128 liq = o.liquidity;
        bool filled = o.filled;
        assertTrue(zeroForOne, "range above the market must be funded with currency0");
        assertEq(liq, 1e18);
        assertFalse(filled);

        // Only currency0 was taken: a one-sided range cannot consume the other token.
        assertLt(IERC20(Currency.unwrap(currency0)).balanceOf(maker), bal0Before, "currency0 spent");
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(maker), bal1Before, "currency1 untouched");
    }

    function test_createOrder_belowMarket_isSellingCurrency1() public {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 target = ((tick / key.tickSpacing) - 3) * key.tickSpacing;

        uint256 bal0Before = IERC20(Currency.unwrap(currency0)).balanceOf(maker);

        vm.prank(maker);
        uint256 id = hook.createOrder(key, target, 1e18);

        bool zeroForOne = hook.orderOf(id).zeroForOne;
        assertFalse(zeroForOne, "range below the market must be funded with currency1");
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(maker), bal0Before, "currency0 untouched");
    }

    /// @dev A range straddling the market would be born partially filled, which makes both the
    ///      side and the displacement measurement ambiguous. Reject it at creation.
    function test_createOrder_straddlingMarket_reverts() public {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 target = (tick / key.tickSpacing) * key.tickSpacing;

        vm.prank(maker);
        vm.expectRevert(AirbagOrders.WrongSideOfPrice.selector);
        hook.createOrder(key, target, 1e18);
    }

    function test_createOrder_unalignedTick_reverts() public {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 target = ((tick / key.tickSpacing) + 2) * key.tickSpacing + 1;

        vm.prank(maker);
        vm.expectRevert(AirbagOrders.TickNotAligned.selector);
        hook.createOrder(key, target, 1e18);
    }

    function test_cancelOrder_returnsFundsAndBurns() public {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 target = ((tick / key.tickSpacing) + 2) * key.tickSpacing;

        uint256 before = IERC20(Currency.unwrap(currency0)).balanceOf(maker);
        vm.prank(maker);
        uint256 id = hook.createOrder(key, target, 1e18);
        uint256 mid = IERC20(Currency.unwrap(currency0)).balanceOf(maker);
        assertLt(mid, before);

        vm.prank(maker);
        hook.cancelOrder(id, key);

        // Rounding in liquidity math can keep a wei or two; the maker must not lose more.
        uint256 refunded = IERC20(Currency.unwrap(currency0)).balanceOf(maker) - mid;
        assertApproxEqAbs(refunded, before - mid, 2, "cancel returns the deposit");
        vm.expectRevert();
        hook.ownerOf(id);
    }

    function test_cancelOrder_onlyOwner() public {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 target = ((tick / key.tickSpacing) + 2) * key.tickSpacing;
        vm.prank(maker);
        uint256 id = hook.createOrder(key, target, 1e18);

        vm.expectRevert(AirbagOrders.NotOrderOwner.selector);
        hook.cancelOrder(id, key);
    }

    /// @dev Orders are capped at 1% of the pool's active liquidity, so a realistic test needs a
    ///      realistically deep pool rather than the minimum one the fixtures create.
    function _deepenPool() internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -6000,
                tickUpper: 6000,
                liquidityDelta: 1_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }
}
