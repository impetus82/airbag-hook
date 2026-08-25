// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AirbagHook} from "../src/AirbagHook.sol";
import {AirbagConfig} from "./AirbagConfig.sol";

/// @notice Minimal liquidity router for the demo pools.
/// @dev Deliberately supports REMOVING as well as adding. The equivalent router from the previous
///      hookathon could only add, so its seed is still stranded on Unichain — a small omission
///      that permanently costs whatever was put in.
contract SeedRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    error NotManager();
    error NotOwner();

    IPoolManager public immutable manager;
    address public immutable owner;

    struct Job {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        address funder;
    }

    constructor(IPoolManager m) {
        manager = m;
        owner = msg.sender;
    }

    function modify(PoolKey calldata key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        returns (BalanceDelta delta)
    {
        if (msg.sender != owner) revert NotOwner();
        delta = abi.decode(
            manager.unlock(abi.encode(Job(key, tickLower, tickUpper, liquidityDelta, msg.sender))),
            (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        Job memory j = abi.decode(raw, (Job));

        (BalanceDelta delta,) = manager.modifyLiquidity(
            j.key,
            ModifyLiquidityParams({
                tickLower: j.tickLower,
                tickUpper: j.tickUpper,
                liquidityDelta: j.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        _settle(j.key.currency0, j.funder, delta.amount0());
        _settle(j.key.currency1, j.funder, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency c, address funder, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            manager.sync(c);
            IERC20(Currency.unwrap(c)).safeTransferFrom(funder, address(manager), owed);
            manager.settle();
        } else if (amount > 0) {
            manager.take(c, funder, uint256(uint128(amount)));
        }
    }
}

/// @notice Put a dust position into the live pool so orders can actually be placed.
///
///         Order size is bounded relative to pool depth — at least 1bp of it, at most 1% — so the
///         seed decides what a demo order looks like. It is sized to be affordable, not to be a
///         venue: this is a hackathon deployment.
///
///         SEED_LIQUIDITY=... forge script script/SeedPool.s.sol --rpc-url base --broadcast
contract SeedPool is Script {
    using StateLibrary for IPoolManager;

    /// @dev Wide enough that the market can move without leaving the seeded band, which is what
    ///      would otherwise make orders unfillable halfway through a demo.
    int24 internal constant HALF_WIDTH_SPACINGS = 120;

    function run() external {
        AirbagConfig.Deployment memory d = AirbagConfig.forChain(block.chainid);
        address hook = vm.envAddress("HOOK");
        uint128 liquidity = uint128(vm.envOr("SEED_LIQUIDITY", uint256(2e9)));

        PoolKey memory key = AirbagConfig.poolKey(d, hook);
        (, int24 tick,,) = d.poolManager.getSlot0(key.toId());
        int24 lower = ((tick / d.tickSpacing) - HALF_WIDTH_SPACINGS) * d.tickSpacing;
        int24 upper = ((tick / d.tickSpacing) + HALF_WIDTH_SPACINGS) * d.tickSpacing;

        console2.log("chain      ", d.name);
        console2.log("current tick", int256(tick));
        console2.log("range lower", lower);
        console2.log("range upper", upper);
        console2.log("liquidity  ", liquidity);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        SeedRouter router = new SeedRouter(d.poolManager);
        IERC20(Currency.unwrap(key.currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(router), type(uint256).max);

        BalanceDelta delta = router.modify(key, lower, upper, int256(uint256(liquidity)));

        vm.stopBroadcast();

        console2.log("router     ", address(router));
        console2.log("spent currency0", -int256(delta.amount0()));
        console2.log("spent currency1", -int256(delta.amount1()));
        console2.log("pool liquidity now", d.poolManager.getLiquidity(key.toId()));
    }
}
