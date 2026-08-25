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

/// @notice The charge is triggered by displacement measured at the moment a fill completes. That
///         invites an obvious dodge: cross the maker with a tiny swap so the fill is recorded at
///         zero displacement, then keep pushing the price with further swaps in the same block.
///         The maker ends up run over just as far, and paid nothing.
///
///         Splitting costs the attacker almost nothing — the pool fee is proportional, so two
///         swaps of half the size pay the same fee as one, plus a little gas. If this works, the
///         mechanism is decorative.
contract AirbagFragmentationTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    AirbagHook internal hook;
    address internal maker = address(0xA11CE);
    address internal attacker = address(0xBAD);

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
        deal(Currency.unwrap(currency0), maker, 1e28);
        deal(Currency.unwrap(currency1), maker, 1e28);
        vm.startPrank(maker);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _place() internal returns (uint256 id) {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 t = ((tick / key.tickSpacing) + 1) * key.tickSpacing;
        // Read liquidity BEFORE pranking: an external call sitting in an argument list is still
        // an external call, and it would consume the prank before createOrder ever runs.
        uint128 liq = manager.getLiquidity(key.toId()) / 500;
        vm.prank(maker);
        id = hook.createOrder(key, t, liq);
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

    /// @dev The honest baseline: one swap all the way out, maker compensated.
    function test_singleSwap_compensatesTheMaker() public {
        uint256 id = _place();
        _pushTo(60); // 40 bps past the order's upper edge
        assertTrue(hook.orderOf(id).filled);
        assertGt(_rebate(id), 0, "one swap: maker is compensated");
    }

    /// @dev The dodge: clear the maker by a hair, then keep going. Same actor, same block, same
    ///      final price — so the maker must end up owed the same.
    function test_splitSwapMustNotEscapeTheCharge() public {
        uint256 id = _place();

        _pushTo(20); // just clears [10,20]: fill recorded at zero displacement
        assertTrue(hook.orderOf(id).filled, "the tiny swap does fill the order");

        _pushTo(60); // and now push exactly as far as the single-swap case

        assertGt(
            _rebate(id),
            0,
            "splitting one swap into two must not let the same actor run a maker over for free"
        );
    }

    /// @dev The property that actually matters: not merely "something was paid", but that the
    ///      maker ends up owed the same whether they were run over in one move or in five.
    ///      Anything less and the dodge is still worth attempting, just for a smaller discount.
    function test_splitPaysTheSameAsOneSwap() public {
        uint256 whole = _place();
        _pushTo(60);
        uint256 paidWhole = _rebate(whole);

        // Reset to the starting price and repeat in five steps.
        _pushTo(0);
        uint256 split = _place();
        _pushTo(20);
        _pushTo(30);
        _pushTo(40);
        _pushTo(50);
        _pushTo(60);
        uint256 paidSplit = _rebate(split);

        assertGt(paidWhole, 0, "baseline must be non-trivial");
        assertApproxEqRel(paidSplit, paidWhole, 0.02e18, "five swaps must cost what one swap costs");
    }
}
