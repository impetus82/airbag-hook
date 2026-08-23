// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title Chain differences live here and nowhere else
/// @notice The hook itself has no idea which chain it is on. Every address, fee tier and price
///         that varies between deployments is confined to this file, so adding a chain is a
///         config change rather than a code change — and so no chain-specific branch can ever
///         creep into the swap path.
library AirbagConfig {
    /// @dev Canonical CREATE2 factory, present at the same address on every EVM chain. Deploying
    ///      through it rather than from an EOA is what makes the hook address predictable before
    ///      a single transaction is broadcast: the address depends only on the salt and the
    ///      init code, not on the deployer's nonce.
    address internal constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 internal constant BASE = 8453;
    uint256 internal constant UNICHAIN = 130;

    /// @dev WETH is the same OP-stack predeploy on both chains.
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    struct Deployment {
        IPoolManager poolManager;
        address usdc;
        uint24 fee;
        int24 tickSpacing;
        string name;
    }

    function forChain(uint256 chainId) internal pure returns (Deployment memory d) {
        if (chainId == BASE) {
            return Deployment({
                poolManager: IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b),
                usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
                fee: 500, // 0.05% — the tier the 30-day measurement was taken on
                tickSpacing: 10,
                name: "Base"
            });
        }
        if (chainId == UNICHAIN) {
            return Deployment({
                poolManager: IPoolManager(0x1F98400000000000000000000000000000000004),
                usdc: 0x078D782b760474a361dDA0AF3839290b0EF57AD6,
                fee: 500,
                tickSpacing: 10,
                name: "Unichain"
            });
        }
        revert("AirbagConfig: unsupported chain");
    }

    /// @notice The permission bits the mined hook address has to encode.
    function flags() internal pure returns (uint160) {
        return uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
    }

    /// @notice Build the pool key, sorting currencies the way v4 requires.
    /// @dev Note the two chains disagree about which token is currency0 — on Base WETH sorts
    ///      first, on Unichain USDC does. That is exactly the kind of difference that belongs in
    ///      config and would be a latent bug if hard-coded anywhere else.
    function poolKey(Deployment memory d, address hook) internal pure returns (PoolKey memory) {
        (address c0, address c1) = uint160(WETH) < uint160(d.usdc) ? (WETH, d.usdc) : (d.usdc, WETH);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: d.fee,
            tickSpacing: d.tickSpacing,
            hooks: IHooks(hook)
        });
    }
}
