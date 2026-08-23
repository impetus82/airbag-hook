// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AirbagHook} from "../src/AirbagHook.sol";
import {AirbagOrders} from "../src/AirbagOrders.sol";

/// @notice A hook whose add-liquidity callbacks run inside AirbagOrders.unlockCallback.
contract EvilHook {
    IPoolManager public immutable pm;
    AirbagHook public target;
    bool public armed;
    bytes public lastRevert;
    uint256 public reentryAttempts;

    constructor(IPoolManager _pm) { pm = _pm; }
    function arm(AirbagHook t) external { target = t; armed = true; }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return EvilHook.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external returns (bytes4)
    {
        if (armed) {
            PoolKey memory dummy;
            // try to re-enter every money path Airbag exposes
            try target.createOrder(dummy, 0, 1) {} catch (bytes memory e) { lastRevert = e; reentryAttempts++; }
            try target.cancelOrder(1, dummy) {} catch { reentryAttempts++; }
            try target.claimOrder(1, dummy) {} catch { reentryAttempts++; }
            try target.unlockCallback("") {} catch { reentryAttempts++; }
        }
        return EvilHook.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata
    ) external view returns (bytes4, BalanceDelta) {
        return (EvilHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}

contract ZzForeignKeyRefute is Test, Deployers {
    using StateLibrary for IPoolManager;

    AirbagHook internal hook;
    address internal maker = address(0xA11CE);
    PoolKey internal airbagKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(AirbagHook).creationCode, abi.encode(address(manager)));
        hook = new AirbagHook{salt: salt}(manager);
        assertEq(address(hook), predicted);

        (airbagKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        key = airbagKey;

        deal(Currency.unwrap(currency0), maker, 100 ether);
        deal(Currency.unwrap(currency1), maker, 100 ether);
        vm.startPrank(maker);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /// Consequence (1): does createOrder succeed against a pool that is not an Airbag pool,
    /// and are the funds recoverable afterwards?
    function test_foreignHooklessPool_createSucceeds_and_cancelRecovers() public {
        (PoolKey memory otherKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 500, SQRT_PRICE_1_1);

        (, int24 tick,,) = manager.getSlot0(otherKey.toId());
        int24 target = ((tick / otherKey.tickSpacing) + 2) * otherKey.tickSpacing;

        uint256 b0 = IERC20(Currency.unwrap(currency0)).balanceOf(maker);

        vm.prank(maker);
        uint256 id = hook.createOrder(otherKey, target, 1e16);

        assertEq(hook.ownerOf(id), maker, "order minted against a foreign pool");
        uint256 spent = b0 - IERC20(Currency.unwrap(currency0)).balanceOf(maker);
        assertGt(spent, 0, "maker paid into the foreign pool");
        emit log_named_uint("currency0 pulled into foreign pool", spent);

        // ... and it comes straight back out.
        vm.prank(maker);
        hook.cancelOrder(id, otherKey);
        uint256 back = IERC20(Currency.unwrap(currency0)).balanceOf(maker);
        emit log_named_uint("recovered", b0 - back);
        assertLe(b0 - back, 2, "funds fully recoverable (rounding dust only)");
    }

    /// Consequence (2): attacker-authored hook code runs inside unlockCallback. Does it gain
    /// anything — can it re-enter Airbag or move Airbag's own token balance?
    function test_evilHookInsideUnlockCallback_gainsNothing() public {
        uint160 eflags = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);
        (address epred, bytes32 esalt) =
            HookMiner.find(address(this), eflags, type(EvilHook).creationCode, abi.encode(address(manager)));
        EvilHook evil = new EvilHook{salt: esalt}(manager);
        assertEq(address(evil), epred);

        (PoolKey memory evilKey,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(evil)), 3000, SQRT_PRICE_1_1);

        // give Airbag a token balance to try to steal (simulating accumulated rebates)
        deal(Currency.unwrap(currency0), address(hook), 5 ether);
        deal(Currency.unwrap(currency1), address(hook), 5 ether);
        uint256 h0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 h1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));

        evil.arm(hook);

        (, int24 tick,,) = manager.getSlot0(evilKey.toId());
        int24 target = ((tick / evilKey.tickSpacing) + 2) * evilKey.tickSpacing;

        vm.prank(maker);
        hook.createOrder(evilKey, target, 1e16);

        emit log_named_uint("reentry attempts that reverted", evil.reentryAttempts());
        assertEq(evil.reentryAttempts(), 4, "every re-entry into Airbag reverted");
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(hook)), h0, "airbag c0 untouched");
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), h1, "airbag c1 untouched");
    }
}
