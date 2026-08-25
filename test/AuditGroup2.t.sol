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

/// @notice A fill has to be final. Until it is, "filled" is only a flag over a position the
///         market can still convert back — which turns an ordinary price retrace into an
///         un-fill, and a deliberate round trip into a way to destroy someone's order.
contract AuditGroup2Test is Test, Deployers {
    using StateLibrary for IPoolManager;

    AirbagHook internal hook;
    address internal alice = address(0xA11CE);

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
        deal(Currency.unwrap(currency0), alice, 1e28);
        deal(Currency.unwrap(currency1), alice, 1e28);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
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

    /// @dev The core property. Alice sold currency0 for currency1 at her limit. Once the market
    ///      has taken her currency0, no later price action can hand it back to her — a limit
    ///      order that un-executes is not a limit order.
    function test_fillIsFinalAcrossARetrace() public {
        vm.prank(alice);
        uint256 id = hook.createOrder(key, 10, 1e20);

        _pushTo(60); // fills: currency0 -> currency1
        assertTrue(hook.orderOf(id).filled);

        _pushTo(-60); // the market walks all the way back through the range

        uint256 before0 = IERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 before1 = IERC20(Currency.unwrap(currency1)).balanceOf(alice);
        vm.prank(alice);
        hook.claimOrder(id, key);
        uint256 got0 = IERC20(Currency.unwrap(currency0)).balanceOf(alice) - before0;
        uint256 got1 = IERC20(Currency.unwrap(currency1)).balanceOf(alice) - before1;

        assertGt(got1, 0, "a filled sell must pay out in the token the maker asked for");
        assertLt(got0, got1 / 100, "and must not hand back the token they already sold");
    }

    /// @dev The adversarial form: a round trip in a single transaction must not be able to
    ///      un-execute somebody else's order. Otherwise anyone can reach out and destroy a
    ///      specific maker's position for the price of a round-trip fee.
    function test_roundTripCannotUnexecuteSomeoneElsesOrder() public {
        vm.prank(alice);
        uint256 id = hook.createOrder(key, 10, 1e20);

        _pushTo(60);
        _pushTo(0); // attacker's round trip

        AirbagOrders.Order memory o = hook.orderOf(id);
        assertTrue(o.filled, "the order stays filled");

        // And the maker can still get their money out through the normal path.
        vm.prank(alice);
        hook.claimOrder(id, key);
    }
}
