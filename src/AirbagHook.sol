// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {AirbagOrders, NotPoolManager} from "./AirbagOrders.sol";
import {AirbagMath} from "./AirbagMath.sol";

/// @title AirbagHook — impact protection for limit orders
/// @notice A resting limit order is a free option written to the market. When a violent swap
///         crosses one, the maker gets their limit price, but the swap shoves the market well
///         past it — and whoever ran through the order captures the move the order made possible.
///
///         Airbag measures that displacement INSIDE THE SAME TRANSACTION, from the pool's own
///         tick, charges the swap a capped share of it, and credits it to that specific maker's
///         order. Like a real airbag it only deploys on impact: below the threshold the maker is
///         already compensated by the fee they earned on their own fill, so the hook stays out
///         of the way and benign flow pays nothing.
///
///         No oracle. No off-chain infrastructure. No keeper. No deferred settlement — the price
///         at a future block is a value the filler themselves could write, so it is never read.
///
/// @dev Written from scratch for the UHI10 Hookathon (Aug 2026). Deliberately implements IHooks
///      directly rather than inheriting a periphery BaseHook: fewer moving dependencies, and the
///      permission surface is explicit and auditable in one file.
abstract contract AirbagHookBase is IHooks {
    error HookNotImplemented();

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice The permission bits this hook's address must encode.
    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    // ── unused callbacks: revert loudly rather than silently succeed ──────────

    function beforeInitialize(address, PoolKey calldata, uint160) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}

contract AirbagHook is AirbagHookBase, AirbagOrders {
    using StateLibrary for IPoolManager;

    /// @dev Transient slot holding the pool tick observed before the current swap.
    ///      Transient, not storage: it is only meaningful within one transaction, and a
    ///      cold SSTORE on every swap would be pure waste.
    ///      Literal because inline assembly cannot reference a keccak256 constant.
    ///      Derivation: keccak256("airbag.preTick") — asserted in AirbagHook.t.sol.
    ///
    ///      Mixed with the pool id rather than used bare. Today a single slot would be safe,
    ///      because v4 makes no external call between beforeSwap and afterSwap of one swap, so
    ///      two pools cannot interleave their snapshots. That is a property of the current
    ///      framework rather than of this contract, and the hook is immutable — cheap insurance
    ///      against the day it stops holding.
    uint256 private constant PRE_TICK_SLOT =
        0xf39f4f275c965d88ccd39db7efb952551c40121db7dd5c014405e56626e0561b;

    function _preTickSlot(PoolId id) private pure returns (uint256) {
        return PRE_TICK_SLOT ^ uint256(PoolId.unwrap(id));
    }

    /// @dev Hard ceiling on what a single fill can be charged, in bps of that order's notional.
    ///      Not a tuning knob: without it a pathological tick span would let the charge approach
    ///      the whole position. The measured p99 displacement is ~50 bps, so this sits far above
    ///      anything observed while still bounding the worst case.
    uint256 internal constant CAP_BPS = 200;

    event PreTickObserved(PoolId indexed id, int24 preTick);
    event SwapObserved(PoolId indexed id, int24 preTick, int24 postTick);
    event AirbagDeployed(PoolId indexed id, bool inCurrency0, uint256 charge);

    constructor(IPoolManager _poolManager) AirbagHookBase(_poolManager) AirbagOrders(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // record the pre-swap tick
            afterSwap: true, // measure displacement, charge, credit
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true, // the charge is taken from the swap's unspecified currency
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Snapshot the tick before the swap moves it. The pair (preTick, postTick) is the
    ///         only thing the displacement metric needs — one tick is one basis point.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        uint256 slot = _preTickSlot(key.toId());
        assembly ("memory-safe") {
            tstore(slot, tick)
        }
        emit PreTickObserved(key.toId(), tick);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Settle every order the swap crossed. The displacement charge and the ERC-721
    ///         credit land on top of this, using the same (preTick, postTick) pair.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        int24 preTick;
        uint256 slot = _preTickSlot(key.toId());
        assembly ("memory-safe") {
            preTick := tload(slot)
        }
        (, int24 postTick,, uint24 lpFee) = poolManager.getSlot0(key.toId());
        emit SwapObserved(key.toId(), preTick, postTick);

        // The returned delta lands on the swap's *unspecified* currency: the output for an
        // exact-input swap, the input for an exact-output one.
        bool exactInput = params.amountSpecified < 0;
        bool chargeInCurrency0 = (exactInput != params.zeroForOne);

        uint256 charge = _markFills(
            key.toId(),
            ChargeCtx({
                key: key,
                fillBudget: MAX_FILLS_PER_SWAP,
                spacing: key.tickSpacing,
                thresholdBps: AirbagMath.feeToBps(lpFee), // slot0 is authoritative, not the key
                capBps: CAP_BPS,
                chargeInCurrency0: chargeInCurrency0
            }),
            preTick,
            postTick
        );

        if (charge == 0) return (IHooks.afterSwap.selector, int128(0));

        // Never ask a swap for more than it actually received. A top-up is sized from the
        // ORDER's notional, which has no relation to the size of whichever swap happens to move
        // the price next — so a small trade could be handed a delta several times its own output
        // and simply revert. Under-collecting is strictly better than destroying someone's trade;
        // the shortfall is not written off either, because paidDisplacement is only advanced by
        // what was actually charged, so a later swap picks the rest up.
        int128 received = chargeInCurrency0 ? swapDelta.amount0() : swapDelta.amount1();
        uint256 payable_ = received > 0 ? uint256(uint128(received)) : 0;
        if (charge > payable_) charge = payable_;
        if (charge == 0) return (IHooks.afterSwap.selector, int128(0));

        // Take first, then return the matching delta: the take leaves the hook owing the pool,
        // the returned delta cancels it, and the swapper is the one who ends up short. Returning
        // without taking would leave an unsettled balance and revert the whole swap.
        Currency paid = chargeInCurrency0 ? key.currency0 : key.currency1;
        poolManager.take(paid, address(this), charge);

        emit AirbagDeployed(key.toId(), chargeInCurrency0, charge);
        return (IHooks.afterSwap.selector, int128(int256(charge)));
    }
}
