// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {AirbagMath} from "./AirbagMath.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Only the PoolManager may invoke hook callbacks and the unlock callback.
///         Declared at file scope so the hook base and the order book share one definition
///         instead of each declaring their own and colliding on inheritance.
error NotPoolManager();

/// @title AirbagOrders — tokenized limit orders held as single-tick liquidity
/// @notice A limit order here is one tick-spacing-wide liquidity position, entirely on one side
///         of the current price. Concentrated liquidity then does the filling for free: when the
///         market crosses the range, the position converts from the token the maker deposited
///         into the token they asked for. "Executing" an order is therefore bookkeeping, not a
///         second swap — no counterparty inventory, no routing through the pool, and nothing that
///         perturbs the price we are about to measure displacement against.
///
///         Ownership is an ERC-721, which is what lets Airbag credit a rebate to the specific
///         maker who was run over, rather than to the pool at large.
abstract contract AirbagOrders is ERC721, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using TickBitmap for mapping(int16 => uint256);

    error TickNotAligned();
    error WrongSideOfPrice();
    error ZeroLiquidity();
    error NotOrderOwner();
    error OrderAlreadyFilled();
    error PoolKeyMismatch();
    error OrderNotFilled();
    error OrderTooLargeForPool();
    error PoolHasNoLiquidity();

    struct Order {
        PoolId poolId;
        int24 tickLower; // order occupies [tickLower, tickLower + tickSpacing]
        int24 tickSpacing;
        bool zeroForOne; // true = maker deposited currency0 and wants currency1
        uint128 liquidity;
        uint128 rebate0; // Airbag credit owed in currency0
        uint128 rebate1; // Airbag credit owed in currency1
        bool filled;
        uint32 tickIndex; // slot in the tick's waiting list, for O(1) removal
    }

    enum Action {
        Add,
        Remove
    }

    /// @dev An order may be at most this share of the pool's active liquidity, in hundredths of
    ///      a percent. Two distinct reasons, both structural rather than stylistic:
    ///      a position large relative to the pool moves the price on its own way out, which would
    ///      contaminate the very displacement we charge for; and an outsized order makes it
    ///      cheap for its own maker to walk the price across it deliberately.
    ///      Active liquidity is a proxy for depth — the order rests out of range, so the two are
    ///      not the same quantity — but it is the honest on-chain measure available in-transaction
    ///      without an oracle, which is a constraint this design accepts everywhere else too.
    uint256 internal constant MAX_ORDER_SHARE_BPS = 100; // 1%

    struct Callback {
        Action action;
        PoolKey key;
        address maker;
        int24 tickLower;
        uint128 liquidity;
    }

    /// @dev A swap may sweep an unbounded number of ticks, so the fill walk is capped. The cap
    ///      is only ever spent on ticks inside the region the swap actually crossed: the walk is
    ///      anchored at the market and stops the moment it leaves that region. Orders resting far
    ///      away therefore cannot be used to exhaust the budget — a cheap-to-mount denial of
    ///      service I have shipped once before and do not intend to ship twice.
    uint256 internal constant MAX_FILL_SCAN = 64;

    IPoolManager internal immutable _manager;
    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) public orders;

    /// @dev Ticks that currently host at least one waiting order, per pool.
    mapping(PoolId => mapping(int16 => uint256)) private _orderTicks;
    mapping(PoolId => mapping(int24 => uint256[])) private _waiting;

    event OrderCreated(
        uint256 indexed orderId, address indexed maker, PoolId indexed poolId, int24 tickLower, bool zeroForOne, uint128 liquidity
    );
    event OrderCancelled(uint256 indexed orderId, address indexed maker);
    event OrderClaimed(uint256 indexed orderId, address indexed maker, uint256 rebate0, uint256 rebate1);
    event OrderFilled(uint256 indexed orderId, PoolId indexed poolId, int24 tickLower, int24 postTick);
    event RebateCredited(uint256 indexed orderId, bool inCurrency0, uint256 amount, uint256 displacementBps);
    event FillScanTruncated(PoolId indexed poolId, int24 reachedTick);

    constructor(IPoolManager manager_) ERC721("Airbag Limit Order", "AIRBAG") {
        _manager = manager_;
    }

    /// @notice Read an order as a struct.
    /// @dev The autogenerated `orders` getter returns a positional tuple, so every added field
    ///      silently shifts callers. This is the interface for anything outside the contract.
    function orderOf(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /// @notice Place a limit order at `tickLower`, occupying one tick spacing.
    /// @dev The side is implied by where the tick sits relative to the market: a range strictly
    ///      above the current price can only be funded with currency0, and one strictly below can
    ///      only be funded with currency1. We derive the direction rather than trusting a flag,
    ///      so a maker cannot ask for a position that is already partly filled at creation.
    function createOrder(PoolKey calldata key, int24 tickLower, uint128 liquidity)
        external
        returns (uint256 orderId)
    {
        if (liquidity == 0) revert ZeroLiquidity();
        if (tickLower % key.tickSpacing != 0) revert TickNotAligned();

        (, int24 currentTick,,) = _manager.getSlot0(key.toId());
        int24 tickUpper = tickLower + key.tickSpacing;


        bool zeroForOne;
        if (currentTick < tickLower) {
            zeroForOne = true; // range is above the market: funded with currency0
        } else if (currentTick >= tickUpper) {
            zeroForOne = false; // range is below the market: funded with currency1
        } else {
            revert WrongSideOfPrice(); // straddles the market — would be born half-filled
        }
        uint128 poolLiquidity = _manager.getLiquidity(key.toId());
        if (poolLiquidity == 0) revert PoolHasNoLiquidity();
        if (uint256(liquidity) * 10_000 > uint256(poolLiquidity) * MAX_ORDER_SHARE_BPS) {
            revert OrderTooLargeForPool();
        }

        orderId = nextOrderId++;
        orders[orderId] = Order({
            poolId: key.toId(),
            tickLower: tickLower,
            tickSpacing: key.tickSpacing,
            zeroForOne: zeroForOne,
            liquidity: liquidity,
            rebate0: 0,
            rebate1: 0,
            filled: false,
            tickIndex: 0
        });
        _mint(msg.sender, orderId);

        uint256[] storage bucket = _waiting[key.toId()][tickLower];
        if (bucket.length == 0) _orderTicks[key.toId()].flipTick(tickLower, key.tickSpacing);
        orders[orderId].tickIndex = uint32(bucket.length);
        bucket.push(orderId);

        _manager.unlock(
            abi.encode(
                Callback({
                    action: Action.Add,
                    key: key,
                    maker: msg.sender,
                    tickLower: tickLower,
                    liquidity: liquidity
                })
            )
        );

        emit OrderCreated(orderId, msg.sender, key.toId(), tickLower, zeroForOne, liquidity);
    }

    /// @notice Withdraw an unfilled order and burn the NFT.
    function cancelOrder(uint256 orderId, PoolKey calldata key) external {
        if (ownerOf(orderId) != msg.sender) revert NotOrderOwner();
        Order memory o = orders[orderId];
        if (o.filled) revert OrderAlreadyFilled();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(o.poolId)) revert PoolKeyMismatch();

        _unlist(o.poolId, o.tickLower, o.tickSpacing, o.tickIndex);
        delete orders[orderId];
        _burn(orderId);

        _manager.unlock(
            abi.encode(
                Callback({
                    action: Action.Remove,
                    key: key,
                    maker: msg.sender,
                    tickLower: o.tickLower,
                    liquidity: o.liquidity
                })
            )
        );

        emit OrderCancelled(orderId, msg.sender);
    }

    /// @notice Withdraw a filled order: the converted proceeds plus whatever Airbag credited.
    /// @dev The position is already fully converted by the market, so this is a withdrawal, not
    ///      an execution. The rebate is paid from tokens the hook already holds — they were taken
    ///      from the filling swap at the moment of the fill, not promised for later.
    function claimOrder(uint256 orderId, PoolKey calldata key) external {
        if (ownerOf(orderId) != msg.sender) revert NotOrderOwner();
        Order memory o = orders[orderId];
        if (!o.filled) revert OrderNotFilled();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(o.poolId)) revert PoolKeyMismatch();

        delete orders[orderId];
        _burn(orderId);

        _manager.unlock(
            abi.encode(
                Callback({
                    action: Action.Remove,
                    key: key,
                    maker: msg.sender,
                    tickLower: o.tickLower,
                    liquidity: o.liquidity
                })
            )
        );

        if (o.rebate0 != 0) {
            IERC20(Currency.unwrap(key.currency0)).safeTransfer(msg.sender, o.rebate0);
        }
        if (o.rebate1 != 0) {
            IERC20(Currency.unwrap(key.currency1)).safeTransfer(msg.sender, o.rebate1);
        }

        emit OrderClaimed(orderId, msg.sender, o.rebate0, o.rebate1);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(_manager)) revert NotPoolManager();
        Callback memory cb = abi.decode(raw, (Callback));

        int256 liquidityDelta = cb.action == Action.Add
            ? int256(uint256(cb.liquidity))
            : -int256(uint256(cb.liquidity));

        (BalanceDelta delta,) = _manager.modifyLiquidity(
            cb.key,
            ModifyLiquidityParams({
                tickLower: cb.tickLower,
                tickUpper: cb.tickLower + cb.key.tickSpacing,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        _settleOrTake(cb.key.currency0, cb.maker, delta.amount0());
        _settleOrTake(cb.key.currency1, cb.maker, delta.amount1());
        return "";
    }

    /// @dev Everything the charge needs, carried down the walk so filling and pricing happen in
    ///      one pass over the same orders. Two passes could disagree, and a maker filled without
    ///      being compensated is the one outcome this hook exists to prevent.
    struct ChargeCtx {
        int24 spacing;
        uint256 thresholdBps; // the pool's own fee
        uint256 capBps;
        bool chargeInCurrency0; // the swap's unspecified currency
    }

    /// @notice Mark every order the swap fully crossed as filled.
    /// @dev Only *fully* crossed orders count. If the price stops inside a range the position is
    ///      only partly converted, the maker has not received their limit price, and there is no
    ///      displacement past their tick to compensate — so it stays waiting.
    function _markFills(PoolId poolId, ChargeCtx memory ctx, int24 preTick, int24 postTick)
        internal
        returns (uint256 total)
    {
        if (postTick == preTick) return 0;
        int24 spacing = ctx.spacing;
        bool rising = postTick > preTick;
        int24 cursor = preTick;

        for (uint256 steps; steps < MAX_FILL_SCAN; ++steps) {
            (int24 next, bool initialized) =
                _orderTicks[poolId].nextInitializedTickWithinOneWord(cursor, spacing, !rising);

            // Leave the moment the fillable region ends. The bitmap is ordered, so everything
            // further out is unreachable by this swap and must not cost us gas.
            if (rising) {
                if (next > postTick - spacing) return total;
            } else {
                if (next <= postTick) return total;
            }

            if (initialized) total += _fillBucket(poolId, ctx, next, postTick);
            cursor = rising ? next : next - spacing;
        }
        emit FillScanTruncated(poolId, cursor);
    }

    function _fillBucket(PoolId poolId, ChargeCtx memory ctx, int24 tick, int24 postTick)
        private
        returns (uint256 subtotal)
    {
        int24 spacing = ctx.spacing;
        uint256[] storage bucket = _waiting[poolId][tick];
        uint256 len = bucket.length;
        for (uint256 i = len; i > 0;) {
            unchecked {
                --i;
            }
            uint256 id = bucket[i];
            Order storage o = orders[id];
            // Both directions can rest on the same tick at different times, so decide per order.
            bool crossed = o.zeroForOne ? (postTick >= tick + spacing) : (postTick < tick);
            if (!crossed) continue;

            o.filled = true;
            emit OrderFilled(id, poolId, tick, postTick);
            subtotal += _priceFill(o, id, ctx, tick, postTick);

            uint256 last = bucket.length - 1;
            if (i != last) {
                uint256 moved = bucket[last];
                bucket[i] = moved;
                orders[moved].tickIndex = uint32(i);
            }
            bucket.pop();
        }
        if (bucket.length == 0 && len != 0) _orderTicks[poolId].flipTick(tick, spacing);
    }

    /// @dev What this fill is worth to its maker, and book it.
    ///      The charge is a share of a *price* move, so the notional it applies to has to be
    ///      denominated in the same currency the charge is collected in — otherwise the bps are
    ///      being applied across a units boundary. For a fully converted single-tick position
    ///      both denominations are exactly computable, so we take the matching one.
    function _priceFill(Order storage o, uint256 id, ChargeCtx memory ctx, int24 tick, int24 postTick)
        private
        returns (uint256 amount)
    {
        uint256 displacement = AirbagMath.displacementBps(o.zeroForOne, tick, ctx.spacing, postTick);
        if (displacement == 0) return 0;

        uint160 sa = TickMath.getSqrtPriceAtTick(tick);
        uint160 sb = TickMath.getSqrtPriceAtTick(tick + ctx.spacing);
        uint256 notional = ctx.chargeInCurrency0
            ? SqrtPriceMath.getAmount0Delta(sa, sb, o.liquidity, false)
            : SqrtPriceMath.getAmount1Delta(sa, sb, o.liquidity, false);

        amount = AirbagMath.chargeAmount(notional, displacement, ctx.thresholdBps, ctx.capBps);
        if (amount == 0) return 0;

        if (ctx.chargeInCurrency0) o.rebate0 += uint128(amount);
        else o.rebate1 += uint128(amount);
        emit RebateCredited(id, ctx.chargeInCurrency0, amount, displacement);
    }

    function _unlist(PoolId poolId, int24 tick, int24 spacing, uint32 idx) private {
        uint256[] storage bucket = _waiting[poolId][tick];
        uint256 last = bucket.length - 1;
        if (idx != last) {
            uint256 moved = bucket[last];
            bucket[idx] = moved;
            orders[moved].tickIndex = idx;
        }
        bucket.pop();
        if (bucket.length == 0) _orderTicks[poolId].flipTick(tick, spacing);
    }

    /// @dev Negative delta: the pool is owed, so pull from the maker. Positive: pay the maker out.
    function _settleOrTake(Currency currency, address maker, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            _manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(maker, address(_manager), owed);
            _manager.settle();
        } else if (amount > 0) {
            _manager.take(currency, maker, uint256(uint128(amount)));
        }
    }
}
