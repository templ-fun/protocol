// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Governance } from "./Governance.sol";

/// @title Elders
/// @notice Governance type where only founding members can vote.
///         Any member can propose, but only members who joined within the
///         first `elderThreshold` slots have voting power. Quorum is
///         calculated against the elder count, not total membership.
///
///         Use this as a starting point for building custom governance types.
///         See Democracy.sol (simplest) and Council.sol (with state) for
///         comparison. The four extension points are:
///
///         _canPropose      - who is allowed to create proposals
///         _canVote         - who is allowed to cast votes
///         _quorumDenominator - what the eligible voter count is for quorum math
///         _afterEmitConfig - emit custom events for indexer registration
///
/// @dev    INFRA IMPACT - this template requires indexer and UI changes.
///
///         The elder threshold is custom state that cannot be derived from
///         the base governance events. The `EldersInitialized` event exists
///         so the indexer can capture this value at registration time.
///
///         Before deploying this template to production:
///         1. Indexer: register `EldersInitialized` in config.yaml, add an
///            `elderThreshold` field to the Templ entity in schema.graphql,
///            and write a handler that stores the value.
///         2. UI: read `elderThreshold` from the indexed data and display
///            which members are elders (memberId <= threshold).
///
///         For an example of a governance template that works with zero
///         infra changes, see Quadratic.sol — it uses only the base events
///         and the standard quorum denominator.
contract Elders is Governance {
  // ============ State ============

  /// @notice Member IDs up to this value are elders with voting rights
  uint64 public elderThreshold;

  // ============ Events ============

  /// @notice Emitted during emitConfig so the indexer can track elder threshold
  event EldersInitialized(address indexed templ, uint64 elderThreshold);

  // ============ Errors ============

  error InvalidElderThreshold();

  // ============ Constructor ============

  constructor(
    address _templ,
    uint256 _approvalThresholdBps,
    uint256 _quorumBps,
    uint256 _executionDelay,
    uint256 _votingPeriod,
    uint256 _immediateExecutionBps,
    uint256 _proposalFeeBps,
    uint64 _elderThreshold
  )
    Governance(
      _templ,
      "elders",
      _approvalThresholdBps,
      _quorumBps,
      _executionDelay,
      _votingPeriod,
      _immediateExecutionBps,
      _proposalFeeBps
    )
  {
    if (_elderThreshold == 0) revert InvalidElderThreshold();
    elderThreshold = _elderThreshold;
  }

  // ============ Indexer Hook ============

  /// @dev Emit custom state so the indexer captures the elder threshold
  ///      at governance registration time. Without this, the indexer has
  ///      no way to know the elder cutoff for this governance instance.
  ///
  ///      This is what makes Elders an infra-heavy template: the custom
  ///      event means the indexer must add a handler and the UI must read
  ///      the new field. Templates that only override logic (access control,
  ///      quorum math) without introducing new state can skip this hook
  ///      entirely - see Quadratic.sol for that pattern.
  function _afterEmitConfig() internal override {
    emit EldersInitialized(address(TEMPL), elderThreshold);
  }

  // ============ Access Control ============

  /// @dev Any templ member can propose
  function _canPropose(
    address account
  ) internal view override returns (bool) {
    return TEMPL.isMember(account);
  }

  /// @dev Only members who joined within the first elderThreshold slots
  function _canVote(
    address account
  ) internal view override returns (bool) {
    (uint64 memberId,) = TEMPL.members(account);
    return memberId > 0 && memberId <= elderThreshold;
  }

  /// @dev Quorum denominator is the smaller of snapshotted member count
  ///      and elder threshold. If the templ has fewer members than the
  ///      threshold, all members are elders.
  function _quorumDenominator(
    uint256, /* proposalId */
    uint64 snapshotMemberCount
  ) internal view override returns (uint256) {
    if (snapshotMemberCount < elderThreshold) return snapshotMemberCount;
    return elderThreshold;
  }
}
