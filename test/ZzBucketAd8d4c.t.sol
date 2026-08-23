// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AirbagHook} from "../src/AirbagHook.sol";
import {AirbagOrders} from "../src/AirbagOrders.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract ZzBucketAd8d4c is Test, Deployers {
    using StateLibrary for IPoolManager;

    AirbagHook internal hook;
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
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1_000e18, salt: bytes32(0)}),
            ""
        );
        deal(Currency.unwrap(currency0), mallory, 100_000_000 ether);
        deal(Currency.unwrap(currency1), mallory, 100_000_000 ether);
        deal(Currency.unwrap(currency0), address(this), 100_000_000 ether);
        deal(Currency.unwrap(currency1), address(this), 100_000_000 ether);
        IERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.startPrank(mallory);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _tick(int24 off) internal view returns (int24) {
        (, int24 t,,) = manager.getSlot0(key.toId());
        return ((t / key.tickSpacing) + off) * key.tickSpacing;
    }

    /// minimum-size order: liquidity == 1
    function _spam(int24 t, uint256 n) internal returns (uint256 totalPlaceGas) {
        for (uint256 i; i < n; ++i) {
            vm.prank(mallory);
            uint256 g = gasleft();
            hook.createOrder(key, t, 1);
            totalPlaceGas += g - gasleft();
        }
    }

    function _crossGas(int24 t) internal returns (uint256) {
        uint256 g = gasleft();
        swap(key, false, -50e18, "");
        uint256 used = g - gasleft();
        (, int24 post,,) = manager.getSlot0(key.toId());
        console2.log("   postTick", int256(post)); console2.log("   targetTick", int256(t));
        return used;
    }

    function _run(uint256 n) internal {
        int24 t = _tick(1);
        uint256 place = n == 0 ? 0 : _spam(t, n);
        uint256 cross = _crossGas(t);
        console2.log("N", n);
        console2.log("  place gas total", place);
        console2.log("  place gas/order", n == 0 ? 0 : place / n);
        console2.log("  CROSSING SWAP GAS", cross);
    }

    function test_bucket_0() public { _run(0); }
    function test_bucket_1() public { _run(1); }
    function test_bucket_100() public { _run(100); }
    function test_bucket_400() public { _run(400); }
    function test_bucket_1000() public { _run(1000); }
    function test_bucket_3000() public { _run(3000); }

    function _swapWithGas(int256 amt, uint256 gasCap) internal returns (bool ok) {
        bytes memory cd = abi.encodeCall(
            PoolSwapTest.swap,
            (
                key,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: amt,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            )
        );
        (ok,) = address(swapRouter).call{gas: gasCap}(cd);
    }

    /// Hard brick: with N dust orders resting at T, no swap that crosses T fits in a block.
    function test_brick_at30MGasLimit() public {
        int24 t = _tick(1);
        _spam(t, 5000);
        // a swap that stops SHORT of T still works fine
        bool small = _swapWithGas(-1e14, 30_000_000);
        (, int24 midTick,,) = manager.getSlot0(key.toId());
        console2.log("small swap ok?", small);
        console2.log("tick after small swap", int256(midTick));
        console2.log("target tick", int256(t));
        // a swap that must cross T reverts inside a 30M-gas budget
        bool big = _swapWithGas(-50e18, 30_000_000);
        console2.log("crossing swap ok at 30M gas?", big);
        // and it needs this much to succeed at all
        uint256 g = gasleft();
        bool huge = _swapWithGas(-50e18, 500_000_000);
        console2.log("crossing swap ok at 500M gas?", huge);
        console2.log("gas actually consumed", g - gasleft());
        assertTrue(small, "non-crossing swap should work");
        assertFalse(big, "crossing swap should be un-executable at a 30M gas budget");
    }

    /// can a dust order at liquidity==1 even be created, and what does it cost in tokens?
    function test_dustOrderIsFree() public {
        int24 t = _tick(1);
        uint256 b0 = IERC20(Currency.unwrap(currency0)).balanceOf(mallory);
        uint256 b1 = IERC20(Currency.unwrap(currency1)).balanceOf(mallory);
        vm.prank(mallory);
        uint256 id = hook.createOrder(key, t, 1);
        console2.log("token0 spent", b0 - IERC20(Currency.unwrap(currency0)).balanceOf(mallory));
        console2.log("token1 spent", b1 - IERC20(Currency.unwrap(currency1)).balanceOf(mallory));
        console2.log("order id", id);
    }
}
