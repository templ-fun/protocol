// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Governance } from "./Governance.sol";

/// @title Democracy
/// @notice All members can propose and vote. One member, one vote.
contract Democracy is Governance {
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
      "democracy",
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

  /// @dev Quorum is calculated against snapshotted member count
  function _quorumDenominator(
    uint256, /* proposalId */
    uint64 snapshotMemberCount
  ) internal pure override returns (uint256) {
    return snapshotMemberCount;
  }
}
