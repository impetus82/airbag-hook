// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AirbagHook} from "../src/AirbagHook.sol";
import {AirbagOrders} from "../src/AirbagOrders.sol";
import {AirbagConfig} from "./AirbagConfig.sol";

/// @notice Place a resting order in the path of live flow.
/// @dev The pool was initialised below the wider market, so arbitrage is pushing the price up.
///      An order to sell the rising asset therefore sits directly in that path and can be filled
///      by whoever is already doing the arbitrage — which is a better demonstration than crossing
///      it myself, because nothing about it is staged.
///
///      HOOK=0x… forge script script/ProofOfLife.s.sol --tc PlaceOrder --rpc-url base --broadcast
contract PlaceOrder is Script {
    using StateLibrary for IPoolManager;

    function run() external {
        AirbagConfig.Deployment memory d = AirbagConfig.forChain(block.chainid);
        address hookAddr = vm.envAddress("HOOK");
        AirbagHook hook = AirbagHook(hookAddr);
        PoolKey memory key = AirbagConfig.poolKey(d, hookAddr);

        (, int24 tick,,) = d.poolManager.getSlot0(key.toId());
        uint128 poolLiq = d.poolManager.getLiquidity(key.toId());

        // A couple of spacings above the market: close enough that live flow reaches it soon,
        // far enough that it is not already crossed when the transaction lands.
        int24 offset = int24(int256(vm.envOr("OFFSET_SPACINGS", uint256(2))));
        int24 target = ((tick / d.tickSpacing) + offset) * d.tickSpacing;
        uint128 size = uint128(vm.envOr("ORDER_LIQUIDITY", uint256(poolLiq) / 1000));

        console2.log("chain        ", d.name);
        console2.log("current tick ", int256(tick));
        console2.log("order tick   ", int256(target));
        console2.log("size         ", size);
        console2.log("bounds       ", uint256(poolLiq) / 10000, uint256(poolLiq) / 100);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        // Above the market means funded with whichever token is currency0 here.
        IERC20(Currency.unwrap(key.currency0)).approve(hookAddr, type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(hookAddr, type(uint256).max);
        uint256 id = hook.createOrder(key, target, size);
        vm.stopBroadcast();

        console2.log("ORDER ID     ", id);
    }
}

/// @notice Cross the order deliberately.
/// @dev The intent was for live arbitrage to do this — the pool was initialised below the wider
///      market, so flow should have walked the price up through the order. It moved partway and
///      stopped, which turns out to be the honest answer: this pool holds about thirty cents, so
///      the remaining mispricing is worth less than the gas to capture it. A dust pool does not
///      attract arbitrage, which is a fact about demonstration pools rather than about the hook.
contract TriggerSwap is Script {
    using StateLibrary for IPoolManager;

    function run() external {
        AirbagConfig.Deployment memory d = AirbagConfig.forChain(block.chainid);
        address hookAddr = vm.envAddress("HOOK");
        PoolKey memory key = AirbagConfig.poolKey(d, hookAddr);
        // envInt, not envUint: ticks are routinely negative — on Base this pool lives near
        // −199800 — and reading one as unsigned turns a target price into a nonsense number.
        int24 target = int24(vm.envInt("TARGET_TICK"));

        (, int24 tick,,) = d.poolManager.getSlot0(key.toId());
        console2.log("from tick", int256(tick));
        console2.log("to tick  ", int256(target));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        PoLSwapper s = new PoLSwapper(d.poolManager);
        IERC20(Currency.unwrap(key.currency0)).approve(address(s), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(s), type(uint256).max);
        s.swapTo(key, target);
        vm.stopBroadcast();

        console2.log("swapper  ", address(s));
    }
}

/// @notice Claim a filled order: proceeds plus whatever the airbag credited.
contract ClaimOrder is Script {
    function run() external {
        AirbagConfig.Deployment memory d = AirbagConfig.forChain(block.chainid);
        address hookAddr = vm.envAddress("HOOK");
        AirbagHook hook = AirbagHook(hookAddr);
        PoolKey memory key = AirbagConfig.poolKey(d, hookAddr);
        uint256 id = vm.envUint("ORDER_ID");

        AirbagOrders.Order memory o = hook.orderOf(id);
        console2.log("filled       ", o.filled);
        console2.log("owed0        ", o.owed0);
        console2.log("owed1        ", o.owed1);
        console2.log("rebate0      ", o.rebate0);
        console2.log("rebate1      ", o.rebate1);
        console2.log("displacement ", o.paidDisplacement);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        hook.claimOrder(id, key);
        vm.stopBroadcast();
    }
}

contract PoLSwapper is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;
    address public immutable owner;

    struct Job { PoolKey key; int24 target; address funder; }

    constructor(IPoolManager m) { manager = m; owner = msg.sender; }

    function swapTo(PoolKey calldata key, int24 target) external {
        require(msg.sender == owner, "owner");
        manager.unlock(abi.encode(Job(key, target, msg.sender)));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        Job memory j = abi.decode(raw, (Job));
        (, int24 cur,,) = StateLibrary.getSlot0(manager, j.key.toId());
        bool up = j.target > cur;

        BalanceDelta delta = manager.swap(
            j.key,
            SwapParams({
                zeroForOne: !up,
                amountSpecified: -int256(uint256(1e15)),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(j.target)
            }),
            ""
        );
        _settle(j.key.currency0, j.funder, delta.amount0());
        _settle(j.key.currency1, j.funder, delta.amount1());
        return "";
    }

    function _settle(Currency c, address funder, int128 amount) private {
        if (amount < 0) {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).safeTransferFrom(funder, address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(c, funder, uint256(uint128(amount)));
        }
    }
}
