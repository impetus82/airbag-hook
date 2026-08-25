// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AirbagHook} from "../src/AirbagHook.sol";
import {AirbagOrders} from "../src/AirbagOrders.sol";

/// @notice Drives the hook through arbitrary sequences of placing, cancelling, claiming and
///         moving the market, so the invariants below are checked against states no
///         hand-written test would think to construct.
contract AirbagHandler is Test {
    AirbagHook public hook;
    IPoolManager public manager;
    PoolSwapTest public router;
    PoolKey public key;

    uint256[] public live; // orders believed outstanding
    uint256 public claimedRebate0;
    uint256 public claimedRebate1;

    constructor(AirbagHook h, IPoolManager m, PoolSwapTest r, PoolKey memory k) {
        hook = h;
        manager = m;
        router = r;
        key = k;
        deal(Currency.unwrap(k.currency0), address(this), 1e30);
        deal(Currency.unwrap(k.currency1), address(this), 1e30);
        IERC20(Currency.unwrap(k.currency0)).approve(address(h), type(uint256).max);
        IERC20(Currency.unwrap(k.currency1)).approve(address(h), type(uint256).max);
        IERC20(Currency.unwrap(k.currency0)).approve(address(r), type(uint256).max);
        IERC20(Currency.unwrap(k.currency1)).approve(address(r), type(uint256).max);
    }

    function placeOrder(int16 offset, uint96 liq) public {
        (, int24 tick,,) = StateLibrary.getSlot0(manager, key.toId());
        int24 off = int24(offset) % 40;
        if (off == 0) off = 1;
        int24 t = ((tick / key.tickSpacing) + off) * key.tickSpacing;

        uint128 poolLiq = StateLibrary.getLiquidity(manager, key.toId());
        uint128 amount = uint128(bound(uint256(liq), 1e12, uint256(poolLiq) / 200));

        try hook.createOrder(key, t, amount) returns (uint256 id) {
            live.push(id);
        } catch {}
    }

    function cancelOrder(uint256 seed) public {
        if (live.length == 0) return;
        uint256 i = seed % live.length;
        try hook.cancelOrder(live[i], key) {
            _drop(i);
        } catch {}
    }

    function claimOrder(uint256 seed) public {
        if (live.length == 0) return;
        uint256 i = seed % live.length;
        uint256 id = live[i];
        AirbagOrders.Order memory o = hook.orderOf(id);
        try hook.claimOrder(id, key) {
            claimedRebate0 += o.rebate0;
            claimedRebate1 += o.rebate1;
            _drop(i);
        } catch {}
    }

    /// @dev Exact-OUTPUT leg. The original handler hard-coded a negative amountSpecified, so the
    ///      fuzzer never once exercised the exact-output branch — which is exactly where the
    ///      charge path turned out to be broken. Half the surface was formally untested while the
    ///      suite reported full health.
    function moveMarketExactOutput(int16 targetOffset, bool zeroForOne) public {
        (, int24 cur,,) = StateLibrary.getSlot0(manager, key.toId());
        int24 target = cur + (int24(targetOffset) % 400);
        if (target == cur) return;
        if (target > TickMath.MAX_TICK - 10 || target < TickMath.MIN_TICK + 10) return;
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: 1e18, // positive: exact output
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {} catch {}
    }

    /// @dev Pile orders onto a single tick, so the fill budget and the per-tick cap are actually
    ///      reached rather than assumed unreachable.
    function crowdOneTick(uint8 count) public {
        (, int24 tick,,) = StateLibrary.getSlot0(manager, key.toId());
        int24 t = ((tick / key.tickSpacing) + 1) * key.tickSpacing;
        uint128 poolLiq = StateLibrary.getLiquidity(manager, key.toId());
        uint128 size = poolLiq / 5_000;
        uint256 n = uint256(count) % 30;
        for (uint256 i; i < n; ++i) {
            try hook.createOrder(key, t, size) returns (uint256 id) {
                live.push(id);
            } catch {
                break;
            }
        }
    }

    function moveMarket(int16 targetOffset) public {
        (, int24 cur,,) = StateLibrary.getSlot0(manager, key.toId());
        int24 target = cur + (int24(targetOffset) % 600);
        if (target == cur) return;
        if (target > TickMath.MAX_TICK - 10 || target < TickMath.MIN_TICK + 10) return;
        bool up = target > cur;
        try router.swap(
            key,
            SwapParams({
                zeroForOne: !up,
                amountSpecified: -1e21,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {} catch {}
    }

    function _drop(uint256 i) private {
        live[i] = live[live.length - 1];
        live.pop();
    }

    function liveCount() external view returns (uint256) {
        return live.length;
    }

    function liveAt(uint256 i) external view returns (uint256) {
        return live[i];
    }
}

contract AirbagInvariantsTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    AirbagHook internal hook;
    AirbagHandler internal handler;

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

        handler = new AirbagHandler(hook, manager, swapRouter, key);
        targetContract(address(handler));
    }

    /// @dev The one that matters, and the one that was quietly toothless. It summed only the
    ///      rebates, ignoring `owed0/owed1` — the banked principal, two to three orders of
    ///      magnitude larger and sitting in the very same balance. So it passed on a contract
    ///      that could no longer pay its makers. Every claim a live order can make has to be
    ///      backed by tokens the hook holds right now, and that means all of it.
    function invariant_claimsAreFullyBacked() public view {
        uint256 owed0;
        uint256 owed1;
        uint256 n = handler.liveCount();
        for (uint256 i; i < n; ++i) {
            AirbagOrders.Order memory o = hook.orderOf(handler.liveAt(i));
            owed0 += uint256(o.owed0) + o.rebate0;
            owed1 += uint256(o.owed1) + o.rebate1;
        }
        assertGe(
            IERC20(Currency.unwrap(currency0)).balanceOf(address(hook)),
            owed0,
            "hook must hold every currency0 claim it has promised"
        );
        assertGe(
            IERC20(Currency.unwrap(currency1)).balanceOf(address(hook)),
            owed1,
            "hook must hold every currency1 claim it has promised"
        );
    }

    /// @dev An order that exists has an owner, and one that does not exist has nothing left
    ///      behind. A dangling record would be either an unclaimable position or a double claim.
    function invariant_liveOrdersHaveOwners() public view {
        uint256 n = handler.liveCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.liveAt(i);
            assertTrue(hook.ownerOf(id) != address(0), "live order must have an owner");
            assertGt(hook.orderOf(id).liquidity, 0, "live order must still hold liquidity");
        }
    }

    /// @dev A maker can never be charged: the rebate is a credit, and the only paths that touch
    ///      it add to it. A negative would mean the hook took from the party it protects.
    function invariant_rebateNeverExceedsCap() public view {
        uint256 n = handler.liveCount();
        for (uint256 i; i < n; ++i) {
            AirbagOrders.Order memory o = hook.orderOf(handler.liveAt(i));
            if (!o.filled) {
                assertEq(uint256(o.rebate0) + o.rebate1, 0, "an unfilled order cannot be credited");
            }
        }
    }
}
