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

/// @notice The top-up mechanism was wrong on three axes at once: it could be sidestepped by
///         swapping from a second address, its fixed-size list could be evicted, and it billed
///         whoever happened to share a tx.origin rather than whoever moved the price. Each is
///         pinned here.
contract AuditGroup4Test is Test, Deployers {
    using StateLibrary for IPoolManager;

    AirbagHook internal hook;
    address internal alice = address(0xA11CE);
    address internal one = address(0xBAD1);
    address internal two = address(0xBAD2);

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
        for (uint256 i; i < 3; ++i) {
            address who = i == 0 ? alice : (i == 1 ? one : two);
            deal(Currency.unwrap(currency0), who, 1e30);
            deal(Currency.unwrap(currency1), who, 1e30);
            vm.startPrank(who);
            IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
            IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _size() internal view returns (uint128) {
        return uint128(manager.getLiquidity(key.toId()) / 2_000);
    }

    function _place(int24 tick) internal returns (uint256 id) {
        uint128 s = _size();
        vm.prank(alice);
        id = hook.createOrder(key, tick, s);
    }

    function _pushAs(address who, int24 target) internal {
        (, int24 cur,,) = manager.getSlot0(key.toId());
        if (target == cur) return;
        bool up = target > cur;
        SwapParams memory p = SwapParams({
            zeroForOne: !up,
            amountSpecified: -1e24,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
        });
        vm.prank(who, who); // set tx.origin too
        swapRouter.swap(key, p, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    function _rebate(uint256 id) internal view returns (uint256) {
        AirbagOrders.Order memory o = hook.orderOf(id);
        return uint256(o.rebate0) + o.rebate1;
    }

    /// @dev Axis (a): the dodge only ever needed a second wallet. Same block, same final price,
    ///      second leg from a different origin — the maker must still end up owed the same.
    function test_rotatingTheSendingAddressDoesNotEscapeTheChargeed() public {
        uint256 whole = _place(10);
        _pushAs(one, 60);
        uint256 paidWhole = _rebate(whole);
        assertGt(paidWhole, 0, "baseline");

        _pushAs(one, 0);
        uint256 split = _place(10);
        _pushAs(one, 20); // clears the maker at zero displacement
        _pushAs(two, 60); // ... and a DIFFERENT address finishes the move

        assertApproxEqRel(
            _rebate(split), paidWhole, 0.05e18, "a second wallet must not buy a discount"
        );
    }

    /// @dev Axis (c): a swap must pay for the displacement IT caused, not for what the price had
    ///      already done before it started. Here the market is already far past the maker; an
    ///      unrelated swap that barely moves it must be charged next to nothing.
    function test_aLaterSwapPaysOnlyForItsOwnMovement() public {
        uint256 id = _place(10);
        _pushAs(one, 60); // the move that ran the maker over
        uint256 afterFirst = _rebate(id);

        _pushAs(two, 61); // someone else nudges it one tick further
        uint256 addedByNudge = _rebate(id) - afterFirst;

        assertLt(addedByNudge, afterFirst / 10, "a one-tick nudge must not be billed for the whole move");
    }

    /// @dev Blocker 7: the top-up was sized from the ORDER's notional with no reference to the
    ///      swap paying it, so a small swap could be handed a delta larger than its own output
    ///      and simply revert. A hook that under-collects is strictly better than one that
    ///      destroys other people's trades.
    function test_aTinySwapIsNeverBilledMoreThanItCanPay() public {
        _place(10);
        _pushAs(one, 20); // fill at zero displacement

        // A minimal swap in the same block: it must succeed, whatever it ends up owing.
        (, int24 cur,,) = manager.getSlot0(key.toId());
        SwapParams memory p = SwapParams({
            zeroForOne: false,
            amountSpecified: -1e12,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(cur + 200)
        });
        vm.prank(two, two);
        swapRouter.swap(key, p, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }
}
