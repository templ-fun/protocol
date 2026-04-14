// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Governance } from "./Governance.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @title Quadratic
/// @notice All members can propose and vote (one member, one vote) - same as
///         Democracy - but the quorum denominator is the square root of the
///         snapshotted member count instead of the raw count.
///
///         This makes quorum scale sublinearly with membership:
///           - 9 members   -> quorum denominator = 3
///           - 100 members -> quorum denominator = 10
///           - 10_000 members -> quorum denominator = 100
///
///         Large groups no longer need an unrealistic percentage of members
///         to show up, while small groups still require meaningful turnout.
///
/// @dev    INFRA IMPACT - none. This template emits only the standard base
///         events (GovernanceInitialized, config updates). The indexer picks
///         it up as governanceType "quadratic" with no schema or handler
///         changes. The UI can display it as-is.
///
///         This is an example of a "logic-only" governance template: it
///         changes how quorum is calculated without introducing new state
///         or custom events. Compare with Elders.sol, which requires both
///         indexer and UI changes due to its custom EldersInitialized event.
contract Quadratic is Governance {
  constructor(
    address _templ,
    uint256 _approvalThresholdBps,
    uint256 _quorumBps,
    uint256 _executionDelay,
    uint256 _votingPeriod,
    uint256 _immediateExecutionBps,
    uint256 _proposalFeeBps
  )
    Governance(
      _templ,
      "quadratic",
      _approvalThresholdBps,
      _quorumBps,
      _executionDelay,
      _votingPeriod,
      _immediateExecutionBps,
      _proposalFeeBps
    )
  { }

  /// @dev Any templ member can propose
  function _canPropose(
    address account
  ) internal view override returns (bool) {
    return TEMPL.isMember(account);
  }

  /// @dev Any templ member can vote
  function _canVote(
    address account
  ) internal view override returns (bool) {
    return TEMPL.isMember(account);
  }

  /// @dev Quorum denominator is sqrt(snapshotMemberCount).
  ///      With 51% quorumBps, a 100-member templ needs ~6 voters (51% of 10)
  ///      instead of 51. Participation requirement still grows with membership,
  ///      just not linearly.
  function _quorumDenominator(
    uint256, /* proposalId */
    uint64 snapshotMemberCount
  ) internal pure override returns (uint256) {
    return FixedPointMathLib.sqrt(uint256(snapshotMemberCount));
  }
}
