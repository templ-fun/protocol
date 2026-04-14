// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Governance } from "./Governance.sol";

/// @title Council
/// @notice Any templ member can propose standard proposals; only the priest or
///         council members can propose dissolution. Only council members vote.
// NOTE: Council access control model tracked in #166.
contract Council is Governance {
  // ============ State ============

  /// @notice Whether an address is a council member
  mapping(address => bool) public isCouncilMember;

  /// @notice Number of council members
  uint256 public councilSize;

  /// @notice Snapshotted council size at proposal creation
  mapping(uint256 => uint256) public snapshotCouncilSize;

  // ============ Events ============

  event CouncilInitialized(address indexed templ, uint256 councilSize);
  event CouncilMemberAdded(address indexed templ, address indexed member);
  event CouncilMemberRemoved(address indexed templ, address indexed member);

  // ============ Errors ============

  error EmptyCouncil();
  error AlreadyCouncilMember();
  error NotCouncilMember();
  error ZeroAddress();
  error OnlyGovernance();

  // ============ Constructor ============

  constructor(
    address _templ,
    uint256 _approvalThresholdBps,
    uint256 _quorumBps,
    uint256 _executionDelay,
    uint256 _votingPeriod,
    uint256 _immediateExecutionBps,
    uint256 _proposalFeeBps,
    address[] memory _council
  )
    Governance(
      _templ,
      "council",
      _approvalThresholdBps,
      _quorumBps,
      _executionDelay,
      _votingPeriod,
      _immediateExecutionBps,
      _proposalFeeBps
    )
  {
    if (_council.length == 0) revert EmptyCouncil();

    for (uint256 i; i < _council.length; ++i) {
      if (_council[i] == address(0)) revert ZeroAddress();
      if (isCouncilMember[_council[i]]) revert AlreadyCouncilMember();
      isCouncilMember[_council[i]] = true;
    }
    councilSize = _council.length;
  }

  /// @dev Initial council size isn't captured by CouncilMemberAdded (constructor events
  ///      fire before the indexer registers this contract), so emit it explicitly
  function _afterEmitConfig() internal override {
    emit CouncilInitialized(address(TEMPL), councilSize);
  }

  // ============ Council Management (via proposals targeting this contract) ============

  /// @notice Add a new council member. Only callable via governance proposal.
  /// @param account Address to add to the council
  function addCouncilMember(
    address account
  ) external {
    if (msg.sender != address(this)) revert OnlyGovernance();
    if (account == address(0)) revert ZeroAddress();
    if (isCouncilMember[account]) revert AlreadyCouncilMember();

    isCouncilMember[account] = true;
    ++councilSize;

    emit CouncilMemberAdded(address(TEMPL), account);
  }

  /// @notice Remove a council member. Only callable via governance proposal.
  ///         Council cannot be emptied - at least one member must remain.
  /// @param account Address to remove from the council
  function removeCouncilMember(
    address account
  ) external {
    if (msg.sender != address(this)) revert OnlyGovernance();
    if (!isCouncilMember[account]) revert NotCouncilMember();
    if (councilSize <= 1) revert EmptyCouncil();

    isCouncilMember[account] = false;
    --councilSize;

    emit CouncilMemberRemoved(address(TEMPL), account);
  }

  // ============ Emergency ============

  /// @dev Priest or council members can create quorum-exempt dissolution proposals
  function proposeDissolution(
    string calldata description
  ) external override returns (uint256 proposalId) {
    if (msg.sender != TEMPL.priest() && !isCouncilMember[msg.sender]) {
      revert NotAuthorized();
    }
    return _proposeDissolution(description);
  }

  // ============ Access Control ============

  /// @dev Any templ member can propose
  function _canPropose(
    address account
  ) internal view override returns (bool) {
    return TEMPL.isMember(account);
  }

  /// @dev Council membership is checked here; Governance._vote additionally
  ///      requires templ membership via the snapshot check, so a council member
  ///      who is not a templ member cannot vote.
  // NOTE: Council voter eligibility tracked in #166.
  function _canVote(
    address account
  ) internal view override returns (bool) {
    return isCouncilMember[account];
  }

  /// @dev Council members are exempt from proposal fees
  function _proposalFee(
    address proposer
  ) internal view override returns (uint256) {
    if (isCouncilMember[proposer]) return 0;
    return super._proposalFee(proposer);
  }

  /// @dev Snapshot council size (not identity set) at proposal creation.
  ///      Quorum denominator is fixed, but individual membership changes during
  ///      voting affect eligibility without changing the quorum denominator.
  // NOTE: Council identity snapshotting tracked in #177.
  function _afterProposalCreated(
    uint256 proposalId
  ) internal override {
    snapshotCouncilSize[proposalId] = councilSize;
  }

  /// @dev Quorum is calculated against snapshotted council size at proposal creation
  function _quorumDenominator(
    uint256 proposalId,
    uint64 /* snapshotMemberCount */
  ) internal view override returns (uint256) {
    return snapshotCouncilSize[proposalId];
  }
}
