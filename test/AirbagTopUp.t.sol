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
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AirbagHook} from "../src/AirbagHook.sol";
import {AirbagOrders} from "../src/AirbagOrders.sol";

/// @notice The top-up window: a fill that is finished in a *later* block than it was started.
///
/// @dev Reported by the UHI10 judge, and neither of the two adversarial audit rounds found it —
///      for a reason worth recording. Every test in this suite ran inside a single block. Nothing
///      anywhere called `vm.roll`, so the one branch that asks whether the recorded fills belong
///      to the current block had no test that could ever take it the other way. The defect was not
///      merely unnoticed, it was unreachable by the suite.
///
///      That is the same shape as the exact-output critical from audit round two, where no test
///      had ever passed a positive `amountSpecified`. A branch no test can reach is not covered by
///      a high coverage number; it is hidden by one.
contract AirbagTopUpTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    AirbagHook internal hook;
    address internal maker = address(0xA11CE);

    /// @dev One spacing past the order's far edge is the fill; everything beyond it is
    ///      displacement. 10 bps clears the 5 bps pool fee by enough to produce a real charge,
    ///      and 70 bps is the figure both mainnet proof-of-life cycles measured.
    int24 internal constant FIRST_LEG_BPS = 10;
    int24 internal constant SECOND_LEG_BPS = 70;

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

        // Start somewhere the window arithmetic cannot underflow into a false pass.
        vm.roll(1000);
        vm.warp(1_000_000);
    }

    // ── harness ──────────────────────────────────────────────────────────────

    function _place(int24 offsetSpacings, uint128 liq) internal returns (uint256 id, int24 tickLower) {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        tickLower = ((tick / key.tickSpacing) + offsetSpacings) * key.tickSpacing;
        vm.prank(maker);
        id = hook.createOrder(key, tickLower, liq);
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

    function _rebate0(uint256 id) internal view returns (uint256) {
        return hook.orderOf(id).rebate0;
    }

    /// @dev Advance far enough that the fill is in a strictly earlier block, without leaving the
    ///      top-up window. One block is all the reported attack needs.
    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2); // Base block time; the window is measured in seconds
    }

    function _deepenPool() internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: bytes32(0)}),
            ""
        );
    }

    // ── the reported defect ──────────────────────────────────────────────────

    /// @dev THE DETECTOR. Cross a maker by a hair, let the block tick over, then finish the move.
    ///      The second leg displaces the price exactly as far as a single swap would have, so the
    ///      maker must end up compensated the same either way — otherwise splitting a swap across
    ///      a block boundary is a free way to run someone over.
    function test_topUpSurvivesABlockBoundary() public {
        (uint256 id, int24 tickLower) = _place(2, 1e18);
        int24 fillEdge = tickLower + key.tickSpacing;

        _pushTo(fillEdge + FIRST_LEG_BPS);
        uint256 afterFirstLeg = _rebate0(id);
        assertTrue(hook.orderOf(id).filled, "order should be filled by the first leg");
        assertGt(afterFirstLeg, 0, "10 bps clears the 5 bps fee, so the first leg owes something");

        _nextBlock();

        _pushTo(fillEdge + SECOND_LEG_BPS);
        uint256 afterSecondLeg = _rebate0(id);

        assertGt(
            afterSecondLeg,
            afterFirstLeg,
            "a swap that pushes further past a just-filled maker must pay for its own increment, "
            "even when the fill happened in an earlier block"
        );
    }

    /// @dev The other edge of the same rule. Thirty seconds is a deliberate number, so it gets a
    ///      test that fails if anyone widens it by accident: past the window the fill is history,
    ///      the maker's position has long since been banked, and a later swap owes them nothing.
    ///      Without this the fix would be "make the window bigger" with no upper bound stated
    ///      anywhere a compiler can check.
    function test_topUpStopsOnceTheWindowHasPassed() public {
        (uint256 id, int24 tickLower) = _place(2, 1e18);
        int24 fillEdge = tickLower + key.tickSpacing;

        _pushTo(fillEdge + FIRST_LEG_BPS);
        uint256 afterFirstLeg = _rebate0(id);
        assertGt(afterFirstLeg, 0, "the fill itself must have charged something");

        // One second past TOPUP_WINDOW_SECONDS, hardcoded on purpose: the constant and the test
        // must not be able to drift together.
        vm.roll(block.number + 20);
        vm.warp(block.timestamp + 31);

        _pushTo(fillEdge + SECOND_LEG_BPS);
        assertEq(_rebate0(id), afterFirstLeg, "outside the window a later swap owes the maker nothing");
    }

    /// @dev The same move inside one block is what the hook already handled. Kept as the control:
    ///      if this ever fails the fix has broken the case that used to work, not just the one
    ///      that did not.
    function test_topUpStillWorksWithinOneBlock() public {
        (uint256 id, int24 tickLower) = _place(2, 1e18);
        int24 fillEdge = tickLower + key.tickSpacing;

        _pushTo(fillEdge + FIRST_LEG_BPS);
        uint256 afterFirstLeg = _rebate0(id);

        _pushTo(fillEdge + SECOND_LEG_BPS);
        assertGt(_rebate0(id), afterFirstLeg, "the single-block top-up is the behaviour that already existed");
    }

    /// @dev THE SECOND DETECTOR — the ring's capacity, which the window fix did not touch.
    ///
    ///      The arithmetic is the whole argument: `MAX_FILLS_PER_SWAP` is 24 and the ring holds 32,
    ///      so **two swaps saturate it**. That is not a thirty-two-transaction siege, it is two
    ///      swaps — and the maker they push out stops being reachable by a top-up while the price
    ///      is still moving past them.
    ///
    ///      Keyed on orders this is unavoidable. Keyed on the TICKS touched it mostly goes away:
    ///      a swap that fills twenty-four orders resting at three ticks writes three entries
    ///      instead of twenty-four, because orders at one tick share a displacement base.
    function test_crowdingTheRingEvictsAMakerFromTopUpReach() public {
        (uint256 victim, int24 victimLower) = _place(2, 1e18);
        int24 victimEdge = victimLower + key.tickSpacing;

        _pushTo(victimEdge + FIRST_LEG_BPS);
        assertTrue(hook.orderOf(victim).filled, "victim must be filled before the crowd arrives");

        // 36 fills after the victim — comfortably more than the 32-entry ring. Four to a tick so
        // no single tick trips TickTooCrowded, nine ticks so one swap's 64-tick scan covers them.
        uint256[] memory crowd = new uint256[](36);
        uint256 w;
        int24 highest;
        int24 lowest = type(int24).max;
        for (int24 t = 3; t < 12; ++t) {
            for (uint256 n; n < 4; ++n) {
                (uint256 cid, int24 cl) = _place(t, 1e18);
                crowd[w++] = cid;
                if (cl > highest) highest = cl;
                if (cl < lowest) lowest = cl;
            }
        }

        // Climb in stages. A swap settles at most MAX_FILLS_PER_SWAP orders and the walk is
        // anchored at the market, so anything left behind by a budget-truncated swap is not
        // revisited by the next one — it has to be crossed fresh. Three ticks a step keeps each
        // swap at twelve fills, well inside the budget.
        int24 clear = highest + 2 * key.tickSpacing;
        for (int24 step = lowest + 3 * key.tickSpacing; step <= clear; step += 3 * key.tickSpacing) {
            _pushTo(step);
        }
        _pushTo(clear);

        uint256 filled;
        for (uint256 i; i < crowd.length; ++i) {
            if (hook.orderOf(crowd[i]).filled) ++filled;
        }
        assertGe(filled, 32, "the crowd must actually fill, or the ring was never wrapped");

        uint256 beforeFinalPush = _rebate0(victim);

        // One more push, still inside the window. The victim is no longer in the ring.
        _nextBlock();
        _pushTo(clear + 40);

        assertGt(
            _rebate0(victim),
            beforeFinalPush,
            "a maker crowded out of the ring stops being topped up while the price is still "
            "moving past them"
        );
    }

    /// @dev Splitting must not be cheaper than not splitting. This is the property the whole
    ///      mechanism exists for, stated directly: two legs across a boundary owe what one leg
    ///      covering the same distance owes.
    function test_splittingAcrossBlocksIsNotCheaperThanOneSwap() public {
        (uint256 split, int24 lowerA) = _place(2, 1e18);
        int24 edgeA = lowerA + key.tickSpacing;
        _pushTo(edgeA + FIRST_LEG_BPS);
        _nextBlock();
        _pushTo(edgeA + SECOND_LEG_BPS);
        uint256 splitCharge = _rebate0(split);

        // Fresh pool state for the honest comparison: same order, same distance, one swap.
        setUp();
        (uint256 single, int24 lowerB) = _place(2, 1e18);
        int24 edgeB = lowerB + key.tickSpacing;
        _pushTo(edgeB + SECOND_LEG_BPS);
        uint256 singleCharge = _rebate0(single);

        assertApproxEqRel(
            splitCharge,
            singleCharge,
            0.02e18, // 2%: the two paths round at different points, the totals must still agree
            "splitting a swap across a block boundary must not buy a discount"
        );
    }
}
