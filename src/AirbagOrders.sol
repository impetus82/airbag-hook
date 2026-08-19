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

    struct Order {
        PoolId poolId;
        int24 tickLower; // order occupies [tickLower, tickLower + tickSpacing]
        int24 tickSpacing;
        bool zeroForOne; // true = maker deposited currency0 and wants currency1
        uint128 liquidity;
        uint128 accruedRebate; // credited by the Airbag charge; claimed with the proceeds
        bool filled;
        uint32 tickIndex; // slot in the tick's waiting list, for O(1) removal
    }

    enum Action {
        Add,
        Remove
    }

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
    event OrderFilled(uint256 indexed orderId, PoolId indexed poolId, int24 tickLower, int24 postTick);
    event FillScanTruncated(PoolId indexed poolId, int24 reachedTick);

    constructor(IPoolManager manager_) ERC721("Airbag Limit Order", "AIRBAG") {
        _manager = manager_;
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

        orderId = nextOrderId++;
        orders[orderId] = Order({
            poolId: key.toId(),
            tickLower: tickLower,
            tickSpacing: key.tickSpacing,
            zeroForOne: zeroForOne,
            liquidity: liquidity,
            accruedRebate: 0,
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

    /// @notice Mark every order the swap fully crossed as filled.
    /// @dev Only *fully* crossed orders count. If the price stops inside a range the position is
    ///      only partly converted, the maker has not received their limit price, and there is no
    ///      displacement past their tick to compensate — so it stays waiting.
    function _markFills(PoolId poolId, int24 spacing, int24 preTick, int24 postTick) internal {
        if (postTick == preTick) return;
        bool rising = postTick > preTick;
        int24 cursor = preTick;

        for (uint256 steps; steps < MAX_FILL_SCAN; ++steps) {
            (int24 next, bool initialized) =
                _orderTicks[poolId].nextInitializedTickWithinOneWord(cursor, spacing, !rising);

            // Leave the moment the fillable region ends. The bitmap is ordered, so everything
            // further out is unreachable by this swap and must not cost us gas.
            if (rising) {
                if (next > postTick - spacing) return;
            } else {
                if (next <= postTick) return;
            }

            if (initialized) _fillBucket(poolId, next, spacing, postTick);
            cursor = rising ? next : next - spacing;
        }
        emit FillScanTruncated(poolId, cursor);
    }

    function _fillBucket(PoolId poolId, int24 tick, int24 spacing, int24 postTick) private {
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
