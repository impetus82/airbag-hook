// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AirbagMath} from "../src/AirbagMath.sol";

/// @notice The charge rule is where money changes hands, so it is pinned property-first rather
///         than example-first: the examples below exist to make the properties legible, not to
///         stand in for them.
contract AirbagMathTest is Test {
    int24 constant SPACING = 10;

    // ── displacement ──────────────────────────────────────────────────────────

    /// @dev Traversing the maker's own range is the fill, at the price they asked for. Only what
    ///      lies beyond it counts, so an order filled exactly at its edge is owed nothing.
    function test_displacement_isZeroAtTheFillBoundary() public pure {
        assertEq(AirbagMath.displacementBps(true, 100, SPACING, 110), 0, "rising, exactly cleared");
        assertEq(AirbagMath.displacementBps(false, 100, SPACING, 100), 0, "falling, exactly at edge");
    }

    function test_displacement_countsOnlyBeyondTheEdge() public pure {
        // Rising: cleared at 110, ended at 118 -> 8 bps past the maker.
        assertEq(AirbagMath.displacementBps(true, 100, SPACING, 118), 8);
        // Falling: edge at 100, ended at 93 -> 7 bps past the maker.
        assertEq(AirbagMath.displacementBps(false, 100, SPACING, 93), 7);
    }

    function test_displacement_neverNegative() public pure {
        assertEq(AirbagMath.displacementBps(true, 100, SPACING, 50), 0, "price never reached it");
        assertEq(AirbagMath.displacementBps(false, 100, SPACING, 500), 0, "price went the other way");
    }

    function testFuzz_displacement_isSymmetricAcrossDirections(int16 lower, uint8 past) public pure {
        int24 l = int24(lower) * SPACING;
        uint256 rising = AirbagMath.displacementBps(true, l, SPACING, l + SPACING + int24(uint24(past)));
        uint256 falling = AirbagMath.displacementBps(false, l, SPACING, l - int24(uint24(past)));
        assertEq(rising, uint256(past), "rising measured from the upper edge");
        assertEq(falling, uint256(past), "falling measured from the lower edge");
        assertEq(rising, falling, "a maker run over by the same distance is owed the same");
    }

    // ── charge ────────────────────────────────────────────────────────────────

    /// @dev The economic core. A maker filled by an ordinary swap already collected the pool fee
    ///      on their own fill, so at or below that line they are not out of pocket and the hook
    ///      must be silent. This is what keeps benign flow paying nothing.
    function test_charge_isSilentAtOrBelowTheFee() public pure {
        uint256 fee = AirbagMath.feeToBps(500); // 0.05% pool -> 5 bps
        assertEq(fee, 5);
        for (uint256 d; d <= 5; ++d) {
            assertEq(AirbagMath.chargeBps(d, fee, 1000), uint256(0), "no charge inside the fee");
        }
        // Just past the fee the whole-bps VIEW truncates to zero; the money path does not.
        assertEq(AirbagMath.chargeBps(6, fee, 1000), uint256(0), "rounded view loses sub-bp charges");
        assertGt(AirbagMath.chargeAmount(1e18, 6, fee, 1000), 0, "the amount actually owed is not zero");
    }

    function test_charge_isOnTheExcessNotTheWholeDisplacement() public pure {
        uint256 fee = 5;
        // 9 bps displacement -> 4 bps uncompensated -> 70% of 4 = 2.8, truncated to 2.
        // Integer division rounds the charge DOWN, i.e. against the maker and in favour of the
        // party being charged. That is the correct direction to err when taking someone's money.
        assertEq(AirbagMath.chargeBps(9, fee, 1000), uint256(2));
        // 25 bps displacement -> 20 bps uncompensated, split at the rate switch:
        // 5 bps at 70% + 15 bps at 50% = 3.5 + 7.5 = 11.
        assertEq(AirbagMath.chargeBps(25, fee, 1000), uint256(11));
    }

    function test_charge_respectsTheCap() public pure {
        assertEq(AirbagMath.chargeBps(10_000, 5, 40), 40, "cap binds");
    }

    function testFuzz_charge_neverExceedsCapOrExcess(uint256 d, uint256 fee, uint256 cap) public pure {
        d = bound(d, 0, 100_000);
        fee = bound(fee, 0, 100);
        cap = bound(cap, 0, 10_000);
        uint256 c = AirbagMath.chargeBps(d, fee, cap);
        assertLe(c, cap, "cap is a hard ceiling");
        if (d > fee) assertLe(c, d - fee, "never charge more than the uncompensated part");
        else assertEq(c, 0, "silent inside the fee");
    }

    /// @dev A maker run over further must never end up owed less; a discontinuity here would be
    ///      an arbitrage on the charge rule itself.
    ///
    ///      This originally fuzzed `chargeBps`, the ROUNDED view — where dividing by 10,000
    ///      flattened the very jump it was meant to catch, so it passed while the money path was
    ///      discontinuous. It now fuzzes the money path, and fuzzes the fee too, because the
    ///      discontinuity's position depends on the threshold.
    function testFuzz_charge_isMonotonicInDisplacement(uint256 a, uint256 b, uint256 fee) public pure {
        a = bound(a, 0, 5_000);
        b = bound(b, a, 5_000);
        fee = bound(fee, 0, 100);
        assertLe(
            AirbagMath.chargeAmount(1e24, a, fee, 10_000),
            AirbagMath.chargeAmount(1e24, b, fee, 10_000),
            "being run over further must never pay less"
        );
    }

    /// @dev The exact case the old test missed, pinned as an example so a refactor cannot
    ///      reintroduce it quietly.
    function test_charge_hasNoCliffAtTheRateSwitch() public pure {
        uint256 prev;
        for (uint256 d = 5; d <= 20; ++d) {
            uint256 got = AirbagMath.chargeAmount(1e24, d, 5, 10_000);
            assertGe(got, prev, "payout must not step backwards across the rate switch");
            prev = got;
        }
    }

    /// @dev The reason chargeAmount exists. Rounding to whole bps first would erase a double-digit
    ///      share of a typical tail charge, and all of a small one.
    function test_chargeAmount_doesNotLosePrecisionToWholeBps() public pure {
        uint256 fee = 5;
        uint256 notional = 10_000e6; // $10k, 6dp

        // 6 bps displacement: 70% of 1 bp = 0.7 bp. The rounded view says nothing is owed.
        assertEq(AirbagMath.chargeBps(6, fee, 1000), uint256(0));
        assertEq(AirbagMath.chargeAmount(notional, 6, fee, 1000), (notional * 7000) / 100_000_000);

        // 18 bps (the measured tail mean): 50% of 13 bps = 6.5 bps, not 6.
        // 13 bps uncompensated: 5 at 70% + 8 at 50% = 3.5 + 4.0 = 7.5 bps.
        assertEq(AirbagMath.chargeAmount(notional, 18, fee, 1000), (notional * 75_000) / 100_000_000);
        assertGt(
            AirbagMath.chargeAmount(notional, 18, fee, 1000),
            (notional * AirbagMath.chargeBps(18, fee, 1000)) / 10_000,
            "the money path pays more than the rounded view suggests"
        );
    }

    function testFuzz_chargeAmount_respectsCapAndSilence(uint256 notional, uint256 d, uint256 cap)
        public
        pure
    {
        notional = bound(notional, 0, 1e30);
        d = bound(d, 0, 10_000);
        cap = bound(cap, 0, 10_000);
        uint256 a = AirbagMath.chargeAmount(notional, d, 5, cap);
        assertLe(a, (notional * cap) / 10_000, "cap is a hard ceiling in tokens too");
        if (d <= 5) assertEq(a, uint256(0), "silent inside the fee");
    }

    function test_feeToBps_matchesTheCanonicalTiers() public pure {
        assertEq(AirbagMath.feeToBps(100), 1); // 0.01%
        assertEq(AirbagMath.feeToBps(500), 5); // 0.05%
        assertEq(AirbagMath.feeToBps(3000), 30); // 0.30%
        assertEq(AirbagMath.feeToBps(10000), 100); // 1.00%
    }

    /// @dev Anchored to the 30-day Base measurement that justified building this at all: median
    ///      displacement ~2 bps (silent), tail ~18-24 bps (pays). If a refactor ever breaks this
    ///      relationship, the pitch stops being true and the test should fail loudly.
    function test_charge_matchesTheMeasuredDistribution() public pure {
        uint256 fee = AirbagMath.feeToBps(500);
        assertEq(AirbagMath.chargeBps(2, fee, 1000), uint256(0), "median fill: airbag stays out of the way");
        assertEq(AirbagMath.chargeBps(18, fee, 1000), uint256(7), "tail mean: ~7 bps back to the maker");
        assertEq(AirbagMath.chargeBps(24, fee, 1000), uint256(10), "deep tail: ~10 bps back to the maker");
    }
}
