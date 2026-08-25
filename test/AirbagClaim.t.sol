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

/// @notice Day 6 — the maker gets paid, and the pool is protected from orders big enough to
///         distort the very measurement they would be compensated by.
contract AirbagClaimTest is Test, Deployers {
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
        _deepenPool();
        deal(Currency.unwrap(currency0), address(this), 50_000 ether);
        deal(Currency.unwrap(currency1), address(this), 50_000 ether);

        deal(Currency.unwrap(currency0), maker, 1000 ether);
        deal(Currency.unwrap(currency1), maker, 1000 ether);
        vm.startPrank(maker);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _place(int24 offsetSpacings, uint128 liq) internal returns (uint256 id) {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 t = ((tick / key.tickSpacing) + offsetSpacings) * key.tickSpacing;
        vm.prank(maker);
        id = hook.createOrder(key, t, liq);
    }

    function test_claim_paysProceedsAndRebate() public {
        uint256 id = _place(1, 1e18);
        _pushTo(60); // well past the maker

        AirbagOrders.Order memory o = hook.orderOf(id);
        assertTrue(o.filled, "must be filled first");
        assertGt(uint256(o.rebate0) + o.rebate1, 0, "and credited");

        uint256 before0 = IERC20(Currency.unwrap(currency0)).balanceOf(maker);
        uint256 before1 = IERC20(Currency.unwrap(currency1)).balanceOf(maker);

        vm.prank(maker);
        hook.claimOrder(id, key);

        uint256 got0 = IERC20(Currency.unwrap(currency0)).balanceOf(maker) - before0;
        uint256 got1 = IERC20(Currency.unwrap(currency1)).balanceOf(maker) - before1;

        // The order sold currency0 for currency1, so the proceeds arrive in currency1; the
        // rebate arrives in whichever currency the filling swap was charged in.
        assertGt(got1, 0, "maker receives their proceeds");
        assertGe(got0, o.rebate0, "maker receives the credited rebate");

        vm.expectRevert();
        hook.ownerOf(id);
    }

    function test_claim_requiresFilled() public {
        uint256 id = _place(1, 1e18);
        vm.prank(maker);
        vm.expectRevert(AirbagOrders.OrderNotFilled.selector);
        hook.claimOrder(id, key);
    }

    function test_claim_onlyOwner() public {
        uint256 id = _place(1, 1e18);
        _pushTo(60);
        vm.expectRevert(AirbagOrders.NotOrderOwner.selector);
        hook.claimOrder(id, key);
    }

    function test_claim_cannotBeDoneTwice() public {
        uint256 id = _place(1, 1e18);
        _pushTo(60);
        vm.prank(maker);
        hook.claimOrder(id, key);
        vm.prank(maker);
        vm.expectRevert();
        hook.claimOrder(id, key);
    }

    /// @dev A position large relative to the pool moves the price on its own way out, which would
    ///      contaminate the displacement it is compensated by — and makes it cheap for its own
    ///      maker to walk the market across it deliberately. Both are reasons to refuse, not to
    ///      handle.
    function test_oversizedOrderIsRefused() public {
        uint128 poolLiquidity = manager.getLiquidity(key.toId());
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 t = ((tick / key.tickSpacing) + 1) * key.tickSpacing;

        vm.prank(maker);
        vm.expectRevert(AirbagOrders.OrderTooLargeForPool.selector);
        hook.createOrder(key, t, poolLiquidity / 50); // 2% — over the 1% cap

        // Just under the cap is accepted.
        vm.prank(maker);
        hook.createOrder(key, t, poolLiquidity / 200);
    }

    function _deepenPool() internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: bytes32(0)}),
            ""
        );
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
}
