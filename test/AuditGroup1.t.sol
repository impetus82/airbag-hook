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

/// @notice Regressions for the first group of pre-deployment audit blockers. Both were missed by
///         the existing suite for instructive reasons, noted on each test.
contract AuditGroup1Test is Test, Deployers {
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
        deal(Currency.unwrap(currency0), who, 1e28);
        deal(Currency.unwrap(currency1), who, 1e28);
        vm.startPrank(who);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _place(address who, int24 tick, uint128 liq) internal returns (uint256 id) {
        vm.prank(who);
        id = hook.createOrder(key, tick, liq);
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

    function _rebate(uint256 id) internal view returns (uint256) {
        AirbagOrders.Order memory o = hook.orderOf(id);
        return uint256(o.rebate0) + o.rebate1;
    }

    // ── Blocker 1: the rising walk skips the tick containing preTick ──────────

    /// @dev The existing fragmentation tests always stopped the first leg exactly ON a spacing
    ///      boundary — the one alignment this bug cannot reach. Stopping strictly INSIDE the
    ///      maker's range is the ordinary case, and it is where the order silently vanishes.
    function test_legStoppingInsideTheRange_stillFillsAndPays() public {
        uint256 id = _place(alice, 10, 1e20); // occupies [10, 20]

        _pushTo(15); // strictly inside the range: partially crossed, must not be filled yet
        assertFalse(hook.orderOf(id).filled, "half-crossed order is not filled yet");

        _pushTo(60); // now clear it and keep going

        assertTrue(hook.orderOf(id).filled, "an order the market walked clean through must fill");
        assertGt(_rebate(id), 0, "and must be compensated for the overshoot");
    }

    /// @dev The non-adversarial version of the same defect: ordinary two-leg price action leaves
    ///      the maker's position converted but the order stuck, so claim reverts forever and the
    ///      only way out is a cancel no interface would offer for a filled order.
    function test_orderIsNotStrandedByOrdinaryTwoLegPriceAction() public {
        uint256 id = _place(alice, 10, 1e20);
        _pushTo(14);
        _pushTo(40);

        assertTrue(hook.orderOf(id).filled, "order must not be stranded between two legs");
        vm.prank(alice);
        hook.claimOrder(id, key); // must not revert
    }

    // ── Blocker 2: one shared position per tick ──────────────────────────────

    /// @dev Every order at a tick shared a single PoolManager position, so the fees the position
    ///      accrued belonged to whoever withdrew first. Two makers at the same tick must each
    ///      leave with their own share, and neither should be able to take the other's.
    function test_makersAtTheSameTickDoNotShareEachOthersFees() public {
        uint256 a = _place(alice, 10, 1e20);
        uint256 b = _place(mallory, 10, 1e20);

        _pushTo(60);
        _pushTo(0); // round trip so the shared position accrues fees on the way through
        _pushTo(60);

        uint256 aliceBefore = IERC20(Currency.unwrap(currency1)).balanceOf(alice);
        vm.prank(alice);
        hook.claimOrder(a, key);
        uint256 aliceGot = IERC20(Currency.unwrap(currency1)).balanceOf(alice) - aliceBefore;

        uint256 malloryBefore = IERC20(Currency.unwrap(currency1)).balanceOf(mallory);
        vm.prank(mallory);
        hook.claimOrder(b, key);
        uint256 malloryGot = IERC20(Currency.unwrap(currency1)).balanceOf(mallory) - malloryBefore;

        assertApproxEqRel(
            aliceGot, malloryGot, 0.01e18, "equal orders at one tick must pay out equally"
        );
    }

    /// @dev The adversarial version: a one-wei order placed after the fact must not entitle its
    ///      owner to any of a real maker's accrued fees.
    function test_dustOrderCannotHarvestAnotherMakersFees() public {
        uint256 a = _place(alice, 10, 1e20);
        _pushTo(60);
        _pushTo(0);
        _pushTo(60); // Alice's position has accrued fees crossing back and forth

        // Two independent defences now stand between Mallory and Alice's fees, and the test
        // pins both. First: dust cannot be placed at all, so the cheap version of the attack
        // never reaches the position.
        vm.prank(mallory);
        vm.expectRevert(AirbagOrders.OrderTooSmallForPool.selector);
        hook.createOrder(key, 10, 1);

        // Second, and the one that actually matters: even a fully-sized order joining the same
        // tick gets its own position, so it cannot touch what Alice's has accrued.
        uint128 size = uint128(manager.getLiquidity(key.toId()) / 5_000);
        uint256 before1 = IERC20(Currency.unwrap(currency1)).balanceOf(mallory);
        uint256 before0 = IERC20(Currency.unwrap(currency0)).balanceOf(mallory);

        uint256 m = _place(mallory, 10, size);
        vm.prank(mallory);
        hook.cancelOrder(m, key);

        uint256 got1 = IERC20(Currency.unwrap(currency1)).balanceOf(mallory);
        uint256 got0 = IERC20(Currency.unwrap(currency0)).balanceOf(mallory);
        uint256 gained = (got1 > before1 ? got1 - before1 : 0) + (got0 > before0 ? got0 - before0 : 0);

        assertEq(gained, 0, "joining a tick must not pay out another maker's accrued fees");
        assertTrue(a != 0, "sanity");
    }
}
