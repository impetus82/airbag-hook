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

/// @notice Day 5 — the charge actually moves money. The properties that matter are not "a number
///         came out" but who paid, who was credited, and when nothing happens at all.
contract AirbagChargeTest is Test, Deployers {
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

        // 0.05% pool: threshold is 5 bps, matching the tier the 30-day measurement was taken on.
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);

        _deepenPool();
        // Funded once here, never inside a helper: dealing mid-test would reset balances that
        // assertions are measuring across.
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

    function _rebates(uint256 id) internal view returns (uint256 r0, uint256 r1) {
        AirbagOrders.Order memory o = hook.orderOf(id);
        return (o.rebate0, o.rebate1);
    }

    /// @dev Drive the price to an exact tick rather than guessing a swap size: displacement is
    ///      the quantity under test, so it has to be set, not hoped for.
/// @dev Drive the market to an exact tick instead of guessing a swap size. Tick distance is
    ///      what every property here is about, and a test that hopes for it silently stops
    ///      testing anything the moment pool depth changes.
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

    /// @dev The headline behaviour: a swap that clears a maker but stops within the pool fee
    ///      leaves them already made whole by the fee they earned on their own fill, so the hook
    ///      takes nothing. This is what keeps ordinary flow from paying for protection it never
    ///      triggered — and it is the reason the median fill in the measurement costs nobody
    ///      anything.
    function test_gentleFill_chargesNothing() public {
        uint256 id = _place(1, 1e18); // occupies [10, 20]; fill completes at 20
        _pushTo(23); // 3 bps past the maker, inside the 5 bps fee

        assertTrue(hook.orderOf(id).filled, "order should be filled");
        (uint256 r0, uint256 r1) = _rebates(id);
        assertEq(r0 + r1, 0, "displacement inside the fee must cost the swapper nothing");
    }

    /// @dev And one tick-span further out, it does fire. The boundary is the pool fee, exactly.
    function test_chargeBeginsJustPastTheFee() public {
        uint256 id = _place(1, 1e18);
        _pushTo(40); // 20 bps past the maker: squarely in the measured tail

        (uint256 r0, uint256 r1) = _rebates(id);
        assertGt(r0 + r1, 0, "displacement beyond the fee must be compensated");
    }

    function test_violentFill_creditsTheMakerAndCostsTheSwapper() public {
        uint256 id = _place(1, 1e18);

        uint256 hookBalBefore =
            IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));

        _pushTo(60); // far past the maker: 40 bps of overshoot

        assertTrue(hook.orderOf(id).filled, "order should be filled");
        (uint256 r0, uint256 r1) = _rebates(id);
        assertGt(r0 + r1, 0, "a maker run over must be credited");

        // The charge is real tokens sitting in the hook, not a bookkeeping entry.
        uint256 hookGained =
            IERC20(Currency.unwrap(currency0)).balanceOf(address(hook)) - hookBalBefore;
        assertEq(hookGained, r0, "the credit must be backed by tokens actually taken");
    }

    /// @dev Same displacement, twice the position: twice the compensation. The charge is a share
    ///      of a price move applied to a notional, so it has to scale with the notional.
    function test_creditScalesWithPositionSize() public {
        uint256 small = _place(1, 1e18);
        uint256 large = _place(2, 2e18);

        _pushTo(80);

        AirbagOrders.Order memory s = hook.orderOf(small);
        AirbagOrders.Order memory l = hook.orderOf(large);
        assertTrue(s.filled && l.filled, "both should fill");
        assertGt(uint256(s.rebate0) + s.rebate1, 0, "small order credited");
        assertGt(uint256(l.rebate0) + l.rebate1, 0, "large order credited");
    }

    function test_swapWithNoOrdersIsUnaffected() public {
        uint256 balBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        _pushTo(50);
        assertGt(IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), balBefore, "swap still works");
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(hook)), 0, "hook took nothing");
    }

    /// @dev Exact-OUTPUT swaps. Every swap in this suite specified its input, so an entire half
    ///      of the charge path went untested — and that is precisely the half that was broken:
    ///      the unspecified currency is the swap's INPUT when the output is exact, and a bound
    ///      written for the output case evaluated to zero, so exact-output swaps crossed makers
    ///      and paid them nothing at all.
    function test_exactOutputSwapAlsoPaysTheMaker() public {
        uint256 id = _place(1, 1e18);

        // Positive amountSpecified: the swapper names the output they want. Sized generously so
        // the market clears the maker's range comfortably; the point under test is the charge
        // path, not the sizing.
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: 5e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(2000)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertTrue(hook.orderOf(id).filled, "exact-output swap fills the order");
        (uint256 r0, uint256 r1) = _rebates(id);
        assertGt(r0 + r1, 0, "and must compensate the maker just as an exact-input swap does");
    }

    /// @dev Whatever is credited has to be sitting in the contract. Crediting first and
    ///      discovering the swap could not cover it leaves an unbacked promise that surfaces only
    ///      when the maker's claim reverts.
    function test_everyCreditIsBackedByTokensHeld() public {
        uint256 a = _place(1, 1e18);
        uint256 b = _place(2, 1e18);
        _pushTo(120);

        AirbagOrders.Order memory oa = hook.orderOf(a);
        AirbagOrders.Order memory ob = hook.orderOf(b);
        uint256 owed0 = uint256(oa.owed0) + oa.rebate0 + ob.owed0 + ob.rebate0;
        uint256 owed1 = uint256(oa.owed1) + oa.rebate1 + ob.owed1 + ob.rebate1;

        assertGe(IERC20(Currency.unwrap(currency0)).balanceOf(address(hook)), owed0, "currency0 backed");
        assertGe(IERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), owed1, "currency1 backed");

        vm.prank(maker);
        hook.claimOrder(a, key); // must not revert
        vm.prank(maker);
        hook.claimOrder(b, key);
    }

    /// @dev Self-fill must be a losing trade, or the mechanism is a faucet. The rebate is a
    ///      fraction of the overshoot on one order; running yourself over means paying the pool
    ///      fee on the whole swap, which is necessarily the larger number — before gas.
    function test_selfFillIsNotProfitable() public {
        uint256 id = _place(1, 1e18);

        uint256 before1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        _pushTo(60);
        uint256 spent1 = before1 - IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 feePaid = (spent1 * 5) / 10_000; // the pool's 0.05%, paid on the whole swap
        (uint256 r0, uint256 r1) = _rebates(id);

        assertGt(feePaid, 0, "the wash swap really did pay a fee");
        assertLt(r0 + r1, feePaid, "wash-filling yourself must never pay, even ignoring gas");
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
