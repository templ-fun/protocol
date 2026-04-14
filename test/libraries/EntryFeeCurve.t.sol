// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
  CurveConfig,
  CurveSegment,
  CurveStyle,
  EntryFeeCurve
} from "../../src/libraries/EntryFeeCurve.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Wrapper to expose library functions as external calls (needed for vm.expectRevert)
contract CurveHarness {
  function validate(
    CurveConfig memory curve
  ) external pure {
    EntryFeeCurve.validate(curve);
  }

  function validateEntryFee(
    uint256 amount
  ) external pure {
    EntryFeeCurve.validateEntryFee(amount);
  }

  function validateBaseFee(
    uint256 amount
  ) external pure {
    EntryFeeCurve.validateBaseFee(amount);
  }
}

/// @title EntryFeeCurveTest
/// @notice Tests for the entry fee curve math library
contract EntryFeeCurveTest is Test {
  using EntryFeeCurve for CurveConfig;

  CurveHarness internal harness;

  function setUp() public {
    harness = new CurveHarness();
  }

  // ============ Helpers ============

  /// @dev Mirrors v1 factory defaults: exponential 0.94%/join for 248 joins, then static tail
  uint32 constant V1_RATE_BPS = 10_094;
  uint32 constant V1_GROWTH_LENGTH = 248;

  function _defaultCurve() internal pure returns (CurveConfig memory) {
    return EntryFeeCurve.exponentialWithTail(V1_RATE_BPS, V1_GROWTH_LENGTH);
  }

  function _staticCurve() internal pure returns (CurveConfig memory config) {
    config.primary =
      CurveSegment({ style: CurveStyle.Static, rateBps: 0, length: 0 });
  }

  function _linearCurve(
    uint32 rateBps
  ) internal pure returns (CurveConfig memory config) {
    config.primary =
      CurveSegment({ style: CurveStyle.Linear, rateBps: rateBps, length: 0 });
  }

  function _expCurve(
    uint32 rateBps
  ) internal pure returns (CurveConfig memory config) {
    config.primary = CurveSegment({
      style: CurveStyle.Exponential, rateBps: rateBps, length: 0
    });
  }

  function _threePhase() internal pure returns (CurveConfig memory curve) {
    curve.primary =
      CurveSegment({ style: CurveStyle.Linear, rateBps: 200, length: 10 });
    curve.additionalSegments = new CurveSegment[](2);
    curve.additionalSegments[0] = CurveSegment({
      style: CurveStyle.Exponential, rateBps: 10_500, length: 50
    });
    curve.additionalSegments[1] =
      CurveSegment({ style: CurveStyle.Static, rateBps: 0, length: 0 });
  }

  // ================================================================
  //                      STATIC CURVE
  // ================================================================

  function testFuzz_static_priceAlwaysEqualsBase(
    uint128 baseFee,
    uint16 joins
  ) public pure {
    vm.assume(baseFee >= 10);
    CurveConfig memory curve = _staticCurve();
    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, joins), baseFee);
  }

  // ================================================================
  //                      LINEAR CURVE
  // ================================================================

  function test_linear_knownValues() public pure {
    // 1% per join (100 bps)
    CurveConfig memory curve = _linearCurve(100);
    uint256 baseFee = 10_000;

    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 0), 10_000);
    // Join 1: 10000 * (10000 + 100) / 10000 = 10100
    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 1), 10_100);
    // Join 10: 10000 * (10000 + 1000) / 10000 = 11000
    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 10), 11_000);
    // Join 100: 10000 * (10000 + 10000) / 10000 = 20000
    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 100), 20_000);
  }

  function testFuzz_linear_monotonicallyIncreasing(
    uint16 joins
  ) public pure {
    vm.assume(joins > 0 && joins < 5000);
    CurveConfig memory curve = _linearCurve(100);
    uint256 baseFee = 10_000;

    uint256 prev = EntryFeeCurve.priceAtJoin(baseFee, curve, joins - 1);
    uint256 curr = EntryFeeCurve.priceAtJoin(baseFee, curve, joins);

    assertGe(curr, prev, "linear curve must be monotonic");
  }

  // ================================================================
  //                    EXPONENTIAL CURVE
  // ================================================================

  function test_exponential_knownValues() public pure {
    // 10% per join (11000 bps)
    CurveConfig memory curve = _expCurve(11_000);
    uint256 baseFee = 10_000;

    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 0), 10_000);
    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 1), 11_000);
    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 2), 12_100);
    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 3), 13_310);
  }

  function test_exponential_identityWhenRateEqualsBps() public pure {
    // rate = 10_000 means multiplier is 1x - price never changes
    CurveConfig memory curve = _expCurve(10_000);
    uint256 baseFee = 1_000_000;

    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 1), baseFee);
    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 100), baseFee);
    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 255), baseFee);
  }

  function testFuzz_exponential_monotonicallyIncreasing(
    uint8 joins
  ) public pure {
    vm.assume(joins > 0);
    CurveConfig memory curve = _expCurve(10_094); // 0.94% per join
    uint256 baseFee = 1_000_000;

    uint256 prev = EntryFeeCurve.priceAtJoin(baseFee, curve, uint256(joins) - 1);
    uint256 curr = EntryFeeCurve.priceAtJoin(baseFee, curve, uint256(joins));

    assertGe(curr, prev, "exponential curve must be monotonic");
  }

  // ================================================================
  //                    DEFAULT CURVE (EXP + TAIL)
  // ================================================================

  function test_default_growthThenFlat() public pure {
    CurveConfig memory curve = _defaultCurve();
    uint256 baseFee = 1_000_000;

    // Join 0 is baseFee
    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 0), baseFee);

    // Exponential growth phase: each milestone higher than the last
    uint256 at50 = EntryFeeCurve.priceAtJoin(baseFee, curve, 50);
    uint256 at100 = EntryFeeCurve.priceAtJoin(baseFee, curve, 100);
    uint256 at200 = EntryFeeCurve.priceAtJoin(baseFee, curve, 200);
    uint256 at248 = EntryFeeCurve.priceAtJoin(baseFee, curve, 248);
    assertGt(at50, baseFee);
    assertGt(at100, at50);
    assertGt(at200, at100);
    assertGt(at248, at200);

    // Static tail: flat after growth phase
    uint256 at500 = EntryFeeCurve.priceAtJoin(baseFee, curve, 500);
    uint256 at1000 = EntryFeeCurve.priceAtJoin(baseFee, curve, 1000);
    assertEq(at500, at248, "tail should be flat");
    assertEq(at1000, at248, "tail should be flat");
  }

  function testFuzz_default_tailIsAlwaysFlat(
    uint16 extraJoins
  ) public pure {
    vm.assume(extraJoins > 0);
    CurveConfig memory curve = _defaultCurve();
    uint256 baseFee = 1_000_000;

    uint256 tailPrice = EntryFeeCurve.priceAtJoin(baseFee, curve, 248);
    uint256 laterPrice =
      EntryFeeCurve.priceAtJoin(baseFee, curve, 248 + uint256(extraJoins));

    assertEq(laterPrice, tailPrice, "default tail must stay flat");
  }

  // ================================================================
  //                   ROUND-TRIP (SOLVE BASE FEE)
  // ================================================================

  function test_solveBaseFee_staticRoundTrip() public pure {
    CurveConfig memory curve = _staticCurve();
    uint256 baseFee = 5000;
    uint256 price = EntryFeeCurve.priceAtJoin(baseFee, curve, 50);
    uint256 solved = EntryFeeCurve.solveBaseFee(price, curve, 50);

    assertEq(solved, baseFee, "static round-trip must be exact");
  }

  function test_solveBaseFee_linearRoundTrip() public pure {
    CurveConfig memory curve = _linearCurve(100);
    uint256 baseFee = 10_000;

    uint256 price = EntryFeeCurve.priceAtJoin(baseFee, curve, 50);
    uint256 solved = EntryFeeCurve.solveBaseFee(price, curve, 50);

    // Linear inverse uses ceiling division, allow 1 unit tolerance
    assertApproxEqAbs(solved, baseFee, 1, "linear round-trip within 1 unit");
  }

  function test_solveBaseFee_exponentialRoundTrip() public pure {
    CurveConfig memory curve = _expCurve(10_094);
    uint256 baseFee = 1_000_000;

    uint256 price = EntryFeeCurve.priceAtJoin(baseFee, curve, 100);
    uint256 solved = EntryFeeCurve.solveBaseFee(price, curve, 100);

    assertApproxEqRel(
      solved, baseFee, 0.001e18, "exponential round-trip within 0.1%"
    );
  }

  function test_solveBaseFee_multiSegmentRoundTrip() public pure {
    CurveConfig memory curve = _threePhase();
    uint256 baseFee = 100_000;

    // Round-trip spanning all three phases (10 linear + 50 exp + tail)
    uint256 price = EntryFeeCurve.priceAtJoin(baseFee, curve, 55);
    uint256 solved = EntryFeeCurve.solveBaseFee(price, curve, 55);

    assertApproxEqRel(
      solved, baseFee, 0.005e18, "multi-segment round-trip within 0.5%"
    );
  }

  function testFuzz_solveBaseFee_roundTrip(
    uint8 joins
  ) public pure {
    vm.assume(joins > 0 && joins <= 248);
    CurveConfig memory curve = _defaultCurve();
    uint256 baseFee = 1_000_000;

    uint256 price = EntryFeeCurve.priceAtJoin(baseFee, curve, joins);
    uint256 solved = EntryFeeCurve.solveBaseFee(price, curve, joins);

    assertApproxEqRel(
      solved, baseFee, 0.005e18, "default curve round-trip within 0.5%"
    );
  }

  // ================================================================
  //                    MULTI-SEGMENT
  // ================================================================

  function test_multiSegment_threePhases() public pure {
    CurveConfig memory curve = _threePhase();
    uint256 baseFee = 100_000;

    // Phase 1 (linear 2%): join 5 → 100000 * (10000 + 200*5) / 10000 = 110000
    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 5), 110_000);
    // End of phase 1: 100000 * (10000 + 2000) / 10000 = 120000
    assertEq(EntryFeeCurve.priceAtJoin(baseFee, curve, 10), 120_000);
    // Phase 2 starts growing from 120000
    uint256 at11 = EntryFeeCurve.priceAtJoin(baseFee, curve, 11);
    assertGt(at11, 120_000, "phase 2 should grow from phase 1");

    // Phase 3 (static tail): flat after join 60
    uint256 at60 = EntryFeeCurve.priceAtJoin(baseFee, curve, 60);
    uint256 at100 = EntryFeeCurve.priceAtJoin(baseFee, curve, 100);
    uint256 at500 = EntryFeeCurve.priceAtJoin(baseFee, curve, 500);
    assertEq(at100, at60, "tail should be flat");
    assertEq(at500, at60, "tail should be flat");
  }

  // ================================================================
  //                      NORMALIZATION
  // ================================================================

  function test_normalize_knownValues() public pure {
    // Zero stays zero (free-to-join)
    assertEq(EntryFeeCurve.normalize(0), 0);
    // Clamps to minimum of 10 for non-zero
    assertEq(EntryFeeCurve.normalize(1), 10);
    assertEq(EntryFeeCurve.normalize(9), 10);
    // Rounds down to multiple of 10
    assertEq(EntryFeeCurve.normalize(10), 10);
    assertEq(EntryFeeCurve.normalize(11), 10);
    assertEq(EntryFeeCurve.normalize(19), 10);
    assertEq(EntryFeeCurve.normalize(20), 20);
    assertEq(EntryFeeCurve.normalize(999), 990);
    assertEq(EntryFeeCurve.normalize(1005), 1000);
  }

  function testFuzz_normalize_alwaysValid(
    uint128 amount
  ) public pure {
    uint256 result = EntryFeeCurve.normalize(amount);
    if (amount == 0) {
      assertEq(result, 0, "zero stays zero");
    } else {
      assertGe(result, 10, "non-zero normalized fee >= 10");
    }
    assertEq(result % 10, 0, "normalized fee divisible by 10");
  }

  // ================================================================
  //                      VALIDATION
  // ================================================================

  function test_validate_acceptsValidCurves() public pure {
    EntryFeeCurve.validate(_defaultCurve());
    EntryFeeCurve.validate(_staticCurve());
    EntryFeeCurve.validate(_linearCurve(100));
    EntryFeeCurve.validate(_expCurve(10_094));
    EntryFeeCurve.validate(_threePhase());
  }

  function test_validate_rejectsSingleSegmentWithFiniteLength() public {
    CurveConfig memory curve;
    curve.primary = CurveSegment({
      style: CurveStyle.Static,
      rateBps: 0,
      length: 100 // invalid - single segment must be infinite
    });

    vm.expectRevert(EntryFeeCurve.InvalidCurveConfig.selector);
    harness.validate(curve);
  }

  function test_validate_rejectsMultiSegmentWithInfinitePrimary() public {
    CurveConfig memory curve;
    curve.primary = CurveSegment({
      style: CurveStyle.Exponential,
      rateBps: 10_094,
      length: 0 // invalid - must be finite when there are extra segments
    });
    curve.additionalSegments = new CurveSegment[](1);
    curve.additionalSegments[0] =
      CurveSegment({ style: CurveStyle.Static, rateBps: 0, length: 0 });

    vm.expectRevert(EntryFeeCurve.InvalidCurveConfig.selector);
    harness.validate(curve);
  }

  function test_validate_rejectsLastSegmentWithFiniteLength() public {
    CurveConfig memory curve;
    curve.primary = CurveSegment({
      style: CurveStyle.Exponential, rateBps: 10_094, length: 100
    });
    curve.additionalSegments = new CurveSegment[](1);
    curve.additionalSegments[0] = CurveSegment({
      style: CurveStyle.Static,
      rateBps: 0,
      length: 50 // invalid - last segment must be infinite
    });

    vm.expectRevert(EntryFeeCurve.InvalidCurveConfig.selector);
    harness.validate(curve);
  }

  function test_validate_rejectsStaticWithNonZeroRate() public {
    CurveConfig memory curve;
    curve.primary = CurveSegment({
      style: CurveStyle.Static,
      rateBps: 100, // invalid
      length: 0
    });

    vm.expectRevert(EntryFeeCurve.InvalidCurveConfig.selector);
    harness.validate(curve);
  }

  function test_validate_rejectsExponentialWithZeroRate() public {
    CurveConfig memory curve;
    curve.primary = CurveSegment({
      style: CurveStyle.Exponential,
      rateBps: 0, // invalid
      length: 0
    });

    vm.expectRevert(EntryFeeCurve.InvalidCurveConfig.selector);
    harness.validate(curve);
  }

  function test_validate_rejectsTooManySegments() public {
    CurveConfig memory curve;
    curve.primary =
      CurveSegment({ style: CurveStyle.Static, rateBps: 0, length: 10 });
    // 8 additional + 1 primary = 9 > MAX_SEGMENTS
    curve.additionalSegments = new CurveSegment[](8);
    for (uint256 i; i < 8; ++i) {
      curve.additionalSegments[i] = CurveSegment({
        style: CurveStyle.Static, rateBps: 0, length: i == 7 ? 0 : 10
      });
    }

    vm.expectRevert(EntryFeeCurve.InvalidCurveConfig.selector);
    harness.validate(curve);
  }

  function test_validateEntryFee_acceptsZero() public pure {
    EntryFeeCurve.validateEntryFee(0);
  }

  function test_validateEntryFee_rejectsTooSmall() public {
    vm.expectRevert(EntryFeeCurve.EntryFeeTooSmall.selector);
    harness.validateEntryFee(9);
  }

  function test_validateEntryFee_rejectsNotDivisibleBy10() public {
    vm.expectRevert(EntryFeeCurve.InvalidCurveConfig.selector);
    harness.validateEntryFee(15);
  }

  function test_validateEntryFee_acceptsValid() public pure {
    EntryFeeCurve.validateEntryFee(10);
    EntryFeeCurve.validateEntryFee(100);
    EntryFeeCurve.validateEntryFee(1_000_000);
  }

  function test_validateBaseFee_acceptsZero() public pure {
    EntryFeeCurve.validateBaseFee(0);
  }

  // ================================================================
  //                     hasGrowth
  // ================================================================

  function test_hasGrowth() public pure {
    assertFalse(EntryFeeCurve.hasGrowth(_staticCurve()));
    assertTrue(EntryFeeCurve.hasGrowth(_expCurve(10_094)));
    assertTrue(EntryFeeCurve.hasGrowth(_linearCurve(100)));
  }

  // ================================================================
  //                    OVERFLOW SATURATION
  // ================================================================

  function test_exponential_saturatesAtMaxEntryFee() public pure {
    // 100% per join - will overflow fast
    CurveConfig memory curve = _expCurve(20_000);
    uint256 price = EntryFeeCurve.priceAtJoin(1e18, curve, 200);
    assertLe(price, type(uint128).max, "should saturate");
  }

  function test_linear_saturatesAtMaxEntryFee() public pure {
    CurveConfig memory curve = _linearCurve(type(uint32).max);
    uint256 price = EntryFeeCurve.priceAtJoin(1e18, curve, 1000);
    assertLe(price, type(uint128).max, "should saturate");
  }

  // ================================================================
  //                    EDGE CASES
  // ================================================================

  function test_zeroJoins_alwaysReturnsInput() public pure {
    CurveConfig memory curve = _defaultCurve();

    // priceAtJoin: returns baseFee for any value
    assertEq(EntryFeeCurve.priceAtJoin(1, curve, 0), 1);
    assertEq(EntryFeeCurve.priceAtJoin(1e18, curve, 0), 1e18);
    assertEq(
      EntryFeeCurve.priceAtJoin(type(uint128).max, curve, 0), type(uint128).max
    );

    // solveBaseFee: returns targetPrice
    assertEq(EntryFeeCurve.solveBaseFee(5000, curve, 0), 5000);
  }

  function test_defaultCurve_matchesV1Defaults() public pure {
    CurveConfig memory curve = _defaultCurve();

    assertEq(uint8(curve.primary.style), uint8(CurveStyle.Exponential));
    assertEq(curve.primary.rateBps, 10_094);
    assertEq(curve.primary.length, 248);
    assertEq(curve.additionalSegments.length, 1);
    assertEq(uint8(curve.additionalSegments[0].style), uint8(CurveStyle.Static));
    assertEq(curve.additionalSegments[0].rateBps, 0);
    assertEq(curve.additionalSegments[0].length, 0);
  }
}
