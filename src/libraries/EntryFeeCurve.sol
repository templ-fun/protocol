// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @notice How entry fees scale as members join
enum CurveStyle {
  Static,
  Linear,
  Exponential
}

/// @notice A segment of the pricing curve
/// @param style Growth style applied while this segment is active
/// @param rateBps Rate parameter (interpretation depends on style)
/// @param length Paid joins covered by this segment (0 = infinite tail)
struct CurveSegment {
  CurveStyle style;
  uint32 rateBps;
  uint32 length;
}

/// @notice Pricing curve as a sequence of segments
/// @param primary First segment applied to new joins
/// @param additionalSegments Follow-on segments processed in order
struct CurveConfig {
  CurveSegment primary;
  CurveSegment[] additionalSegments;
}

/// @title EntryFeeCurve
/// @notice Pure math library for computing entry fees along a piecewise curve
/// @dev Ported from v1 TemplCurveMath. Uses Solady FixedPointMathLib instead of OZ Math.
///      Supports Static, Linear, and Exponential segments composed in sequence.
library EntryFeeCurve {
  uint256 internal constant BPS = 10_000;
  uint256 internal constant MAX_ENTRY_FEE = type(uint128).max;
  uint256 internal constant MAX_SEGMENTS = 8;

  error InvalidCurveConfig();
  error EntryFeeTooSmall();
  error EntryFeeTooLarge();

  // ============ Price Computation ============

  /// @notice Compute the entry fee for a given number of completed paid joins
  /// @param baseFee Base entry fee anchor
  /// @param curve Curve configuration
  /// @param paidJoins Number of completed paid joins
  /// @return price Entry fee for the next join
  function priceAtJoin(
    uint256 baseFee,
    CurveConfig memory curve,
    uint256 paidJoins
  ) internal pure returns (uint256 price) {
    if (paidJoins == 0) return baseFee;

    uint256 remaining = paidJoins;
    uint256 amount = baseFee;

    (amount, remaining) =
      _consumeSegment(amount, curve.primary, remaining, true);
    if (remaining == 0) return amount;

    uint256 len = curve.additionalSegments.length;
    for (uint256 i; i < len && remaining > 0; ++i) {
      (amount, remaining) =
        _consumeSegment(amount, curve.additionalSegments[i], remaining, true);
    }

    if (remaining > 0) revert InvalidCurveConfig();
    return amount;
  }

  /// @notice Same as priceAtJoin but reads curve from storage
  function priceAtJoinFromStorage(
    uint256 baseFee,
    CurveConfig storage curve,
    uint256 paidJoins
  ) internal view returns (uint256 price) {
    if (paidJoins == 0) return baseFee;

    uint256 remaining = paidJoins;
    uint256 amount = baseFee;

    (amount, remaining) =
      _consumeSegment(amount, curve.primary, remaining, true);
    if (remaining == 0) return amount;

    CurveSegment[] storage extras = curve.additionalSegments;
    uint256 len = extras.length;
    for (uint256 i; i < len && remaining > 0; ++i) {
      (amount, remaining) = _consumeSegment(amount, extras[i], remaining, true);
    }

    if (remaining > 0) revert InvalidCurveConfig();
    return amount;
  }

  // ============ Inverse: Solve Base Fee ============

  /// @notice Derive the base fee that produces a target price after N paid joins
  /// @param targetPrice Desired current entry fee
  /// @param curve Curve configuration
  /// @param paidJoins Number of completed paid joins
  /// @return baseFee Base entry fee that yields targetPrice
  function solveBaseFee(
    uint256 targetPrice,
    CurveConfig memory curve,
    uint256 paidJoins
  ) internal pure returns (uint256 baseFee) {
    if (paidJoins == 0) return targetPrice;

    CurveSegment[] memory extras = curve.additionalSegments;
    uint256 len = extras.length;

    // Single segment - direct inverse
    if (len == 0) {
      return _applySegment(targetPrice, curve.primary, paidJoins, false);
    }

    // Multi-segment - compute steps per segment, then walk backwards
    uint256 remaining = paidJoins;
    uint256 primarySteps = _min(remaining, uint256(curve.primary.length));
    unchecked {
      remaining -= primarySteps;
    }

    uint256[] memory extraSteps = new uint256[](len);
    for (uint256 i; i < len && remaining > 0; ++i) {
      uint256 segLen = uint256(extras[i].length);
      uint256 steps = segLen == 0 ? remaining : _min(remaining, segLen);
      extraSteps[i] = steps;
      if (segLen == 0) {
        remaining = 0;
      } else {
        unchecked {
          remaining -= steps;
        }
      }
    }
    if (remaining > 0) revert InvalidCurveConfig();

    // Walk segments in reverse
    uint256 amount = targetPrice;
    for (uint256 i = len; i > 0; --i) {
      if (extraSteps[i - 1] == 0) continue;
      amount = _applySegment(amount, extras[i - 1], extraSteps[i - 1], false);
    }
    if (primarySteps > 0) {
      amount = _applySegment(amount, curve.primary, primarySteps, false);
    }

    return amount > MAX_ENTRY_FEE ? MAX_ENTRY_FEE : amount;
  }

  // ============ Normalization ============

  /// @notice Normalize entry fee: zero stays zero, values 1-9 are rounded up
  ///         to 10, values >= 10 are rounded down to the nearest multiple of 10
  function normalize(
    uint256 amount
  ) internal pure returns (uint256) {
    if (amount == 0) return 0;
    if (amount < 10) return 10;
    return amount - (amount % 10);
  }

  // ============ Queries ============

  /// @notice Whether any segment introduces dynamic pricing
  function hasGrowth(
    CurveConfig memory curve
  ) internal pure returns (bool) {
    if (curve.primary.style != CurveStyle.Static) return true;
    uint256 len = curve.additionalSegments.length;
    for (uint256 i; i < len; ++i) {
      if (curve.additionalSegments[i].style != CurveStyle.Static) return true;
    }
    return false;
  }

  // ============ Validation ============

  /// @notice Validate a complete curve configuration
  function validate(
    CurveConfig memory curve
  ) internal pure {
    _validateSegment(curve.primary);
    uint256 len = curve.additionalSegments.length;

    if (len + 1 > MAX_SEGMENTS) revert InvalidCurveConfig();

    // Single segment must be infinite (length == 0)
    if (len == 0) {
      if (curve.primary.length != 0) revert InvalidCurveConfig();
      return;
    }

    // Multi-segment: primary must have finite length
    if (curve.primary.length == 0) revert InvalidCurveConfig();

    for (uint256 i; i < len; ++i) {
      _validateSegment(curve.additionalSegments[i]);
      bool isLast = i == len - 1;
      // Only the last segment can be infinite (length == 0)
      if (!isLast && curve.additionalSegments[i].length == 0) {
        revert InvalidCurveConfig();
      }
      // The last segment must be infinite
      if (isLast && curve.additionalSegments[i].length != 0) {
        revert InvalidCurveConfig();
      }
    }
  }

  /// @notice Validate entry fee amount (zero or >= 10, divisible by 10, within max)
  function validateEntryFee(
    uint256 amount
  ) internal pure {
    if (amount == 0) return;
    if (amount < 10) revert EntryFeeTooSmall();
    if (amount % 10 != 0) revert InvalidCurveConfig();
    if (amount > MAX_ENTRY_FEE) revert EntryFeeTooLarge();
  }

  /// @notice Validate base entry fee amount (zero or >= 10, within max)
  function validateBaseFee(
    uint256 amount
  ) internal pure {
    if (amount == 0) return;
    if (amount < 10) revert EntryFeeTooSmall();
    if (amount > MAX_ENTRY_FEE) revert EntryFeeTooLarge();
  }

  // ============ Curve Builders ============

  /// @notice Build an exponential growth curve with a static tail
  /// @param rateBps Exponential rate in basis points (e.g. 10_094 for ~0.94%/join)
  /// @param growthLength Paid joins before price flattens (0 = exponential forever)
  /// @return config Curve configuration
  function exponentialWithTail(
    uint32 rateBps,
    uint32 growthLength
  ) internal pure returns (CurveConfig memory config) {
    config.primary = CurveSegment({
      style: CurveStyle.Exponential, rateBps: rateBps, length: growthLength
    });
    config.additionalSegments = new CurveSegment[](1);
    config.additionalSegments[0] =
      CurveSegment({ style: CurveStyle.Static, rateBps: 0, length: 0 });
  }

  // ============ Internal: Segment Application ============

  /// @dev Consume up to `remaining` steps of a segment
  function _consumeSegment(
    uint256 amount,
    CurveSegment memory segment,
    uint256 remaining,
    bool forward
  ) private pure returns (uint256, uint256) {
    if (remaining == 0) return (amount, 0);

    uint256 segLen = uint256(segment.length);
    uint256 steps = segLen == 0 ? remaining : _min(remaining, segLen);

    if (steps > 0) {
      amount = _applySegment(amount, segment, steps, forward);
      unchecked {
        remaining -= steps;
      }
    }

    // Infinite tail consumes all remaining
    if (segLen == 0) remaining = 0;

    return (amount, remaining);
  }

  /// @dev Apply a segment forward or inverse for N steps
  function _applySegment(
    uint256 amount,
    CurveSegment memory segment,
    uint256 steps,
    bool forward
  ) private pure returns (uint256) {
    if (steps == 0 || segment.style == CurveStyle.Static) return amount;

    if (segment.style == CurveStyle.Linear) {
      return _applyLinear(amount, segment.rateBps, steps, forward);
    }

    if (segment.style == CurveStyle.Exponential) {
      return _applyExponential(amount, segment.rateBps, steps, forward);
    }

    revert InvalidCurveConfig();
  }

  /// @dev Linear: amount * (BPS + rate * steps) / BPS
  function _applyLinear(
    uint256 amount,
    uint256 rateBps,
    uint256 steps,
    bool forward
  ) private pure returns (uint256) {
    if (rateBps == 0) return amount;
    if (steps > type(uint256).max / rateBps) return MAX_ENTRY_FEE;

    uint256 scaled = rateBps * steps;
    uint256 offset;
    unchecked {
      offset = BPS + scaled;
    }
    if (offset < BPS) return MAX_ENTRY_FEE; // overflow wrapped

    if (forward) {
      if (_mulOverflows(amount, offset)) return MAX_ENTRY_FEE;
      uint256 fwd = FixedPointMathLib.mulDiv(amount, offset, BPS);
      return fwd > MAX_ENTRY_FEE ? MAX_ENTRY_FEE : fwd;
    }

    // Inverse: amount * BPS / offset (round up)
    if (_mulOverflows(amount, BPS)) return MAX_ENTRY_FEE;
    uint256 inv = FixedPointMathLib.mulDivUp(amount, BPS, offset);
    return inv > MAX_ENTRY_FEE ? MAX_ENTRY_FEE : inv;
  }

  /// @dev Exponential: amount * (rateBps / BPS)^steps
  function _applyExponential(
    uint256 amount,
    uint256 rateBps,
    uint256 steps,
    bool forward
  ) private pure returns (uint256) {
    (uint256 factor, bool overflow) = _powBps(rateBps, steps);
    if (overflow) return MAX_ENTRY_FEE;

    return
      forward ? _scaleForward(amount, factor) : _scaleInverse(amount, factor);
  }

  // ============ Internal: BPS Exponentiation ============

  /// @dev Exponentiation by squaring in BPS space.
  ///      When intermediate products round to 0, they are clamped to 1 to avoid
  ///      collapsing the entire result to 0. This introduces a small upward bias -
  ///      safe for growing curves (fee only slightly higher than exact) but would
  ///      prevent a shrinking curve from reaching 0. In practice all deployed
  ///      curves grow or stay flat, so the bias has no adverse effect.
  function _powBps(
    uint256 factorBps,
    uint256 exponent
  ) private pure returns (uint256 result, bool overflow) {
    if (exponent == 0) return (BPS, false);

    result = BPS;
    uint256 base = factorBps;

    while (exponent > 0) {
      if (exponent & 1 == 1) {
        if (_mulOverflows(result, base)) return (0, true);
        result = FixedPointMathLib.mulDiv(result, base, BPS);
        if (result == 0) result = 1;
      }
      exponent >>= 1;
      if (exponent == 0) break;
      if (_mulOverflows(base, base)) return (0, true);
      base = FixedPointMathLib.mulDiv(base, base, BPS);
      if (base == 0) base = 1;
    }
  }

  /// @dev Scale forward: amount * multiplier / BPS, saturating at MAX_ENTRY_FEE
  function _scaleForward(
    uint256 amount,
    uint256 multiplier
  ) private pure returns (uint256) {
    if (_mulOverflows(amount, multiplier)) return MAX_ENTRY_FEE;
    uint256 result = FixedPointMathLib.mulDiv(amount, multiplier, BPS);
    return result > MAX_ENTRY_FEE ? MAX_ENTRY_FEE : result;
  }

  /// @dev Scale inverse: amount * BPS / divisor, rounding up
  function _scaleInverse(
    uint256 amount,
    uint256 divisor
  ) private pure returns (uint256) {
    if (divisor == 0) revert InvalidCurveConfig();
    if (_mulOverflows(amount, BPS)) return MAX_ENTRY_FEE;
    uint256 result = FixedPointMathLib.mulDivUp(amount, BPS, divisor);
    return result > MAX_ENTRY_FEE ? MAX_ENTRY_FEE : result;
  }

  // ============ Internal: Helpers ============

  function _mulOverflows(
    uint256 a,
    uint256 b
  ) private pure returns (bool) {
    return a != 0 && b != 0 && a > type(uint256).max / b;
  }

  function _min(
    uint256 a,
    uint256 b
  ) private pure returns (uint256) {
    return a < b ? a : b;
  }

  function _validateSegment(
    CurveSegment memory segment
  ) private pure {
    if (segment.style == CurveStyle.Static) {
      if (segment.rateBps != 0) revert InvalidCurveConfig();
      return;
    }
    if (segment.style == CurveStyle.Linear) return;
    if (segment.style == CurveStyle.Exponential) {
      if (segment.rateBps == 0) revert InvalidCurveConfig();
      return;
    }
    revert InvalidCurveConfig();
  }
}
