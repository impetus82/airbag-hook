// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title AirbagMath — how far past a maker the market went, and what that is worth
/// @notice Pure arithmetic, deliberately isolated from the hook so it can be reasoned about and
///         cross-checked on its own. Everything here is integer tick arithmetic: one tick is
///         1.0001x, i.e. one basis point, so displacement never needs a price reconstruction and
///         there is no floating point anywhere to disagree about.
library AirbagMath {
    /// @dev Share of the excess handed back to the maker, in bps of the excess. Not free
    ///      parameters: at the measured median displacement, a filler paying ~70% of a small
    ///      excess still clears their edge, while a larger overshoot is thinner relative to the
    ///      cost of taking it, so the share drops. Push either higher and fillers route around
    ///      the pool, which helps no maker at all.
    uint256 internal constant RHO_NEAR = 7000; // 70% while the overshoot is small
    uint256 internal constant RHO_FAR = 5000; // 50% beyond that
    uint256 internal constant RHO_SWITCH_BPS = 10; // where "small" ends

    /// @notice How far the market ended beyond the point at which the order was fully filled.
    /// @dev Measured from the edge where conversion completed, NOT from the maker's near tick.
    ///      Traversing the maker's own range is the fill itself, at the price they asked for —
    ///      it is not displacement and must not be charged for. This makes the number the
    ///      conservative one of the two available readings, which is the right bias when the
    ///      figure is used to take money from someone.
    function displacementBps(bool zeroForOne, int24 tickLower, int24 tickSpacing, int24 postTick)
        internal
        pure
        returns (uint256)
    {
        unchecked {
            if (zeroForOne) {
                // Funded with currency0; fully converted once the market clears the upper edge.
                int256 d = int256(postTick) - int256(tickLower) - int256(tickSpacing);
                return d > 0 ? uint256(d) : 0;
            } else {
                // Funded with currency1; fully converted once the market drops below the lower edge.
                int256 d = int256(tickLower) - int256(postTick);
                return d > 0 ? uint256(d) : 0;
            }
        }
    }

    /// @notice The actual amount owed to this maker, in the token the charge is taken in.
    /// @dev The money path. Rounding happens exactly ONCE, here, in token units — an intermediate
    ///      rounding to whole basis points would silently erase up to a full bp, which on a
    ///      typical tail charge of ~6 bps is a double-digit percentage of the maker's
    ///      compensation, and would zero out small overshoots entirely.
    ///      It still truncates rather than rounds up: erring downward favours the party being
    ///      charged, which is the right direction when the contract is taking someone's money.
    function chargeAmount(uint256 notional, uint256 displacement, uint256 thresholdBps, uint256 capBps)
        internal
        pure
        returns (uint256)
    {
        if (displacement <= thresholdBps) return 0;
        unchecked {
            uint256 excess = displacement - thresholdBps;
            uint256 rho = displacement <= RHO_SWITCH_BPS ? RHO_NEAR : RHO_FAR;
            uint256 scaled = excess * rho; // bps x 1e4, kept unrounded
            uint256 capScaled = capBps * 10_000;
            if (scaled > capScaled) scaled = capScaled;
            return (notional * scaled) / 100_000_000; // 1e4 (bps) x 1e4 (rho)
        }
    }

    /// @notice The charge as whole basis points, for events and introspection.
    /// @dev A rounded VIEW of the rule, not the money path — see chargeAmount. Small overshoots
    ///      legitimately report zero here while still paying out a non-zero token amount.
    /// @param displacement How far past the maker the market ended, in bps.
    /// @param thresholdBps The pool's own fee, in bps.
    /// @param capBps Hard ceiling on the charge, in bps.
    /// @dev The threshold is the pool fee rather than a tuned constant, and that is the whole
    ///      economic argument: a maker filled by an ordinary swap has already been paid the fee
    ///      they earned on their own fill, so below that line they are not out of pocket and the
    ///      hook must charge nothing. Only the part of the overshoot the fee did not cover is
    ///      compensable — hence charging on the excess, not on the raw displacement.
    function chargeBps(uint256 displacement, uint256 thresholdBps, uint256 capBps)
        internal
        pure
        returns (uint256)
    {
        if (displacement <= thresholdBps) return 0; // already made whole by the fee
        unchecked {
            uint256 excess = displacement - thresholdBps;
            uint256 rho = displacement <= RHO_SWITCH_BPS ? RHO_NEAR : RHO_FAR;
            uint256 charge = (excess * rho) / 10_000;
            return charge > capBps ? capBps : charge;
        }
    }

    /// @notice A pool's fee expressed in basis points.
    /// @dev v4 fees are hundredths of a bip: 3000 means 0.30%, i.e. 30 bps.
    function feeToBps(uint24 fee) internal pure returns (uint256) {
        return uint256(fee) / 100;
    }
}
