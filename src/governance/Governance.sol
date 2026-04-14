// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC2612 } from "../interfaces/IERC2612.sol";
import { IGovernance } from "../interfaces/IGovernance.sol";
import { ITempl } from "../interfaces/ITempl.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
// Transient storage variant - saves ~2,100 gas per guarded call vs regular
// ReentrancyGuard on networks that support EIP-1153 (Cancun+).
import {
  ReentrancyGuardTransient
} from "solady/utils/ReentrancyGuardTransient.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @title Governance
/// @notice Shared proposal and voting logic for all governance types.
///         Two-threshold model aligned with OZ Governor:
///         - quorumBps: minimum participation (for + against + abstain) / eligible
///         - approvalThresholdBps: minimum approval (for) / (for + against)
///         Execution delay starts from quorum, not creation.
///         Vote values: 0=Against, 1=For, 2=Abstain (OZ Governor standard).
/// @dev Subclasses override _canPropose, _canVote, and _quorumDenominator
abstract contract Governance is IGovernance, ReentrancyGuardTransient {
  // ============ Constants ============

  uint256 internal constant BPS = 10_000;

  /// @inheritdoc IGovernance
  uint256 public constant override MAX_PROPOSAL_FEE_BPS = BPS; // 100% cap

  uint8 public constant VOTE_AGAINST = 0;
  uint8 public constant VOTE_FOR = 1;
  uint8 public constant VOTE_ABSTAIN = 2;
  uint8 internal constant VOTE_UNCAST = 255;

  ISignatureTransfer internal constant PERMIT2 =
    ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

  /// @dev EIP-712 typehash for ProposalIntent witness data
  bytes32 internal constant PROPOSAL_INTENT_TYPEHASH =
    keccak256("ProposalIntent(bytes32 proposalHash)");

  /// @dev Witness type string for Permit2 permitWitnessTransferFrom.
  ///      Follows EIP-712 alphabetical ordering of referenced types.
  string internal constant PROPOSAL_WITNESS_TYPE_STRING = "ProposalIntent witness)"
    "ProposalIntent(bytes32 proposalHash)"
    "TokenPermissions(address token,uint256 amount)";

  /// @dev EIP-712 typehash for VoteIntent witness data
  bytes32 internal constant VOTE_INTENT_TYPEHASH =
    keccak256("VoteIntent(uint256 proposalId,uint8 support)");

  /// @dev Witness type string for Permit2 permitWitnessTransferFrom (vote).
  string internal constant VOTE_WITNESS_TYPE_STRING = "VoteIntent witness)"
    "TokenPermissions(address token,uint256 amount)"
    "VoteIntent(uint256 proposalId,uint8 support)";

  // ============ Set once in constructor ============
  // Not marked `immutable` so all instances share identical runtime bytecode,
  // enabling auto-verification on Etherscan/Sourcify after a single verified
  // deployment. Gas difference is negligible on L2s (~2100 gas cold SLOAD vs
  // 3 gas PUSH). No setter exists; value is effectively immutable.

  /// @inheritdoc IGovernance
  ITempl public override TEMPL;

  // ============ Configurable Parameters ============

  /// @inheritdoc IGovernance
  uint256 public override approvalThresholdBps;

  /// @inheritdoc IGovernance
  uint256 public override quorumBps;

  /// @inheritdoc IGovernance
  uint256 public override executionDelay;

  /// @inheritdoc IGovernance
  uint256 public override votingPeriod;

  /// @inheritdoc IGovernance
  uint256 public override immediateExecutionBps;

  /// @inheritdoc IGovernance
  uint256 public override proposalFeeBps;

  // ============ State ============

  /// @inheritdoc IGovernance
  uint256 public override proposalCount;

  /// @dev Proposal state - batch-aware with OZ-aligned vote values
  struct Proposal {
    address proposer;
    address[] targets;
    uint256[] values;
    bytes[] calldatas;
    uint48 createdAt;
    bool executed;
    bool cancelled;
    bool quorumExempt; // skips quorum threshold, still requires FOR > AGAINST
    uint256 forVotes;
    uint256 againstVotes;
    uint256 abstainVotes;
    uint64 snapshotMemberCount; // members with id <= this can vote
    uint48 quorumReachedAt; // timestamp when quorum first reached (0 = not yet)
    uint256 snapshotVotingPeriod;
    uint256 snapshotQuorumBps;
    uint256 snapshotApprovalThresholdBps;
    uint256 snapshotExecutionDelay;
    uint256 snapshotImmediateExecutionBps;
  }

  string private _governanceType;

  mapping(uint256 => Proposal) internal _proposals;
  mapping(uint256 => mapping(address => bool)) internal _hasVoted;
  mapping(uint256 => mapping(address => uint8)) internal _votes;

  /// @inheritdoc IGovernance
  mapping(address => uint256) public override activeProposal;

  // ============ Constructor ============

  constructor(
    address _templ,
    string memory governanceType_,
    uint256 _approvalThresholdBps,
    uint256 _quorumBps,
    uint256 _executionDelay,
    uint256 _votingPeriod,
    uint256 _immediateExecutionBps,
    uint256 _proposalFeeBps
  ) {
    // Upper bounds on every bps field. Without these, a caller could pass
    // values > 10_000 that are mathematically unreachable (threshold /
    // quorum never met) and brick the templ. The Factory does not substitute
    // defaults, so the contract must enforce its own bounds.
    if (_approvalThresholdBps > BPS) revert InvalidQuorumConfig();
    if (_quorumBps > BPS) revert InvalidQuorumConfig();
    if (_immediateExecutionBps > BPS) revert InvalidQuorumConfig();

    // Cross-field: immediate execution requires at least as many FOR votes
    // as the normal approval threshold, otherwise a proposal could
    // fast-track with fewer votes than it needs to pass normally.
    if (_immediateExecutionBps < _approvalThresholdBps) {
      revert InvalidQuorumConfig();
    }

    // Execution delay is unreachable when immediateExecutionBps is zero:
    // any single FOR vote (including the proposer's auto-FOR) satisfies
    // `forVotes * BPS / denominator >= 0`, firing the instant branch and
    // skipping the delay check entirely. Reject the contradictory config.
    // Edge case: when both immediateExecutionBps and approvalThresholdBps
    // are 0, the instant path always fires and executionDelay is bypassed
    // even if set to 0. The constructor rejects executionDelay > 0 with
    // immediateExecutionBps == 0 below, but does not reject both being 0.
    // NOTE: Minimum-value enforcement tracked in #179.
    if (_executionDelay > 0 && _immediateExecutionBps == 0) {
      revert InvalidQuorumConfig();
    }

    // Proposal fee has its own hard cap (capped at 100% of entry fee).
    if (_proposalFeeBps > MAX_PROPOSAL_FEE_BPS) {
      revert InvalidQuorumConfig();
    }

    // Voting period must be non-zero, otherwise every proposal expires the
    // instant it is created and the only vote that can be recorded is the
    // proposer's auto-FOR. That plus quorum = 0 would let any proposer
    // single-handedly pass arbitrary proposals.
    if (_votingPeriod == 0) revert InvalidQuorumConfig();

    TEMPL = ITempl(_templ);
    _governanceType = governanceType_;
    approvalThresholdBps = _approvalThresholdBps;
    quorumBps = _quorumBps;
    executionDelay = _executionDelay;
    votingPeriod = _votingPeriod;
    immediateExecutionBps = _immediateExecutionBps;
    proposalFeeBps = _proposalFeeBps;
  }

  // ============ Receive ETH ============

  /// @dev Accept ETH so it can be forwarded via proposals. Also receives excess
  ///      ETH returned by execute() calls that send less value than provided.
  ///      There is no sweep mechanism - ETH accumulates permanently unless a
  ///      proposal explicitly forwards it.
  // NOTE: ETH sweep mechanism tracked in #182.
  receive() external payable { }

  // ============ Init ============

  /// @inheritdoc IGovernance
  function emitConfig() external override {
    if (msg.sender != address(TEMPL)) revert NotAuthorized();

    address t = address(TEMPL);
    emit GovernanceInitialized(t, _governanceType);
    emit ApprovalThresholdUpdated(t, approvalThresholdBps);
    emit QuorumUpdated(t, quorumBps);
    emit ExecutionDelayUpdated(t, executionDelay);
    emit VotingPeriodUpdated(t, votingPeriod);
    emit ImmediateExecutionUpdated(t, immediateExecutionBps);
    emit ProposalFeeUpdated(t, proposalFeeBps);

    _afterEmitConfig();
  }

  function _afterEmitConfig() internal virtual { }

  // ============ Abstract: Access Control ============

  function _canPropose(
    address account
  ) internal view virtual returns (bool);
  function _canVote(
    address account
  ) internal view virtual returns (bool);
  function _quorumDenominator(
    uint256 proposalId,
    uint64 snapshotMemberCount
  ) internal view virtual returns (uint256);
  function _afterProposalCreated(
    uint256 proposalId
  ) internal virtual { }

  // ============ Views ============

  /// @inheritdoc IGovernance
  function hasVoted(
    uint256 proposalId,
    address account
  ) external view override returns (bool) {
    return _hasVoted[proposalId][account];
  }

  /// @inheritdoc IGovernance
  function state(
    uint256 proposalId
  ) external view override returns (ProposalState) {
    return _state(proposalId, _proposals[proposalId]);
  }

  /// @inheritdoc IGovernance
  function getProposal(
    uint256 proposalId
  ) external view returns (IGovernance.ProposalView memory view_) {
    Proposal storage p = _proposals[proposalId];
    view_ = IGovernance.ProposalView({
      proposer: p.proposer,
      targets: p.targets,
      values: p.values,
      calldatas: p.calldatas,
      createdAt: p.createdAt,
      executed: p.executed,
      cancelled: p.cancelled,
      quorumExempt: p.quorumExempt,
      forVotes: p.forVotes,
      againstVotes: p.againstVotes,
      abstainVotes: p.abstainVotes,
      snapshotMemberCount: p.snapshotMemberCount,
      quorumReachedAt: p.quorumReachedAt,
      snapshotVotingPeriod: p.snapshotVotingPeriod,
      snapshotQuorumBps: p.snapshotQuorumBps,
      snapshotApprovalThresholdBps: p.snapshotApprovalThresholdBps,
      snapshotExecutionDelay: p.snapshotExecutionDelay,
      snapshotImmediateExecutionBps: p.snapshotImmediateExecutionBps
    });
  }

  /// @inheritdoc IGovernance
  function getVote(
    uint256 proposalId,
    address account
  ) external view override returns (uint8) {
    if (!_hasVoted[proposalId][account]) return VOTE_UNCAST;
    return _votes[proposalId][account];
  }

  // ============ Actions ============

  /// @inheritdoc IGovernance
  function propose(
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata calldatas,
    string calldata description
  ) external override nonReentrant returns (uint256 proposalId) {
    uint256 fee = _proposalFee(msg.sender);
    if (fee > 0) {
      address token = TEMPL.TOKEN();
      address treasury = address(TEMPL.TREASURY());
      SafeTransferLib.safeTransferFrom(token, msg.sender, treasury, fee);
    }
    return _propose(msg.sender, targets, values, calldatas, description);
  }

  /// @inheritdoc IGovernance
  function proposeWithPermitWitness(
    address proposer,
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata calldatas,
    string calldata description,
    ISignatureTransfer.PermitTransferFrom calldata permit,
    bytes calldata signature
  ) external override nonReentrant returns (uint256 proposalId) {
    if (permit.permitted.token != TEMPL.TOKEN()) revert WrongToken();

    // Hash the proposal content so the signer commits to it
    bytes32 witness;
    {
      bytes memory encoded = abi.encode(
        PROPOSAL_INTENT_TYPEHASH,
        keccak256(abi.encode(targets, values, calldatas, description))
      );
      assembly ("memory-safe") {
        witness := keccak256(add(encoded, 0x20), mload(encoded))
      }
    }

    uint256 fee = _proposalFee(proposer);
    address treasury = address(TEMPL.TREASURY());

    // Always verify the signature - even when fee is 0 the witness
    // authenticates the proposer and binds them to the proposal content.
    PERMIT2.permitWitnessTransferFrom(
      permit,
      ISignatureTransfer.SignatureTransferDetails({
        to: treasury, requestedAmount: fee
      }),
      proposer,
      witness,
      PROPOSAL_WITNESS_TYPE_STRING,
      signature
    );

    // Safe: proposer is verified by Permit2 witness signature
    return _propose(proposer, targets, values, calldatas, description);
  }

  /// @inheritdoc IGovernance
  /// @dev Self-submit only: proposer is always msg.sender and fee is charged
  ///      from msg.sender. ERC-2612 cannot bind proposal content to the
  ///      signature, so accepting a separate proposer param would let anyone
  ///      create proposals in another member's name. For relayed proposals
  ///      where proposer != msg.sender, use proposeWithPermitWitness.
  // NOTE: Proposal fee payment model tracked in #167.
  function proposeWithERC2612Permit(
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata calldatas,
    string calldata description,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external override nonReentrant returns (uint256 proposalId) {
    uint256 fee = _proposalFee(msg.sender);
    if (fee > 0) {
      // Set allowance from msg.sender to this contract via ERC-2612 permit.
      // Allowance is consumed immediately by safeTransferFrom below,
      // so no residual approval remains after the call.
      IERC2612(TEMPL.TOKEN())
        .permit(msg.sender, address(this), fee, deadline, v, r, s);

      address treasury = address(TEMPL.TREASURY());
      SafeTransferLib.safeTransferFrom(TEMPL.TOKEN(), msg.sender, treasury, fee);
    }
    return _propose(msg.sender, targets, values, calldatas, description);
  }

  function _propose(
    address proposer,
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata calldatas,
    string calldata description
  ) internal returns (uint256 proposalId) {
    if (!_canPropose(proposer)) revert NotAuthorized();
    if (
      targets.length == 0 || targets.length != values.length
        || targets.length != calldatas.length
    ) revert ArrayLengthMismatch();

    // One active proposal per proposer
    uint256 existing = activeProposal[proposer];
    if (existing != 0 && _isVotingOpen(_proposals[existing])) {
      revert ActiveProposalExists();
    }

    proposalId = ++proposalCount;
    Proposal storage p = _proposals[proposalId];
    p.proposer = proposer;
    p.targets = targets;
    p.values = values;
    p.calldatas = calldatas;
    p.createdAt = uint48(block.timestamp);
    p.snapshotMemberCount = TEMPL.memberCount();
    p.snapshotVotingPeriod = votingPeriod;
    p.snapshotQuorumBps = quorumBps;
    p.snapshotApprovalThresholdBps = approvalThresholdBps;
    p.snapshotExecutionDelay = executionDelay;
    p.snapshotImmediateExecutionBps = immediateExecutionBps;

    activeProposal[proposer] = proposalId;
    _afterProposalCreated(proposalId);

    emit ProposalCreated(
      address(TEMPL),
      proposalId,
      proposer,
      targets,
      values,
      calldatas,
      description
    );

    // Auto-vote FOR if proposer is eligible to vote
    if (_canVote(proposer)) {
      _hasVoted[proposalId][proposer] = true;
      _votes[proposalId][proposer] = VOTE_FOR;
      p.forVotes = 1;

      _checkQuorum(p, proposalId);

      emit Voted(
        address(TEMPL),
        proposalId,
        proposer,
        VOTE_FOR,
        p.forVotes,
        p.againstVotes,
        p.abstainVotes
      );
    }
  }

  /// @inheritdoc IGovernance
  function vote(
    uint256 proposalId,
    uint8 support
  ) external override nonReentrant {
    _vote(msg.sender, proposalId, support);
  }

  function _vote(
    address voter,
    uint256 proposalId,
    uint8 support
  ) internal {
    if (!_canVote(voter)) revert NotAuthorized();
    if (support > VOTE_ABSTAIN) revert InvalidVoteValue();

    Proposal storage p = _proposals[proposalId];
    if (p.proposer == address(0) || p.executed || p.cancelled) {
      revert ProposalNotActive();
    }
    if (block.timestamp >= p.createdAt + p.snapshotVotingPeriod) {
      revert VotingEnded();
    }

    bool voted = _hasVoted[proposalId][voter];
    uint8 previousVote = _votes[proposalId][voter];
    if (voted && previousVote == support) revert SameVote();

    // Snapshot check on first vote only - prevents join-and-vote attacks.
    // Side effect: in Council mode, this also blocks council members who
    // are not templ members (memberId == 0) or who joined after proposal
    // creation, even though _canVote would pass them.
    // NOTE: Council voter eligibility tracked in #166.
    if (!voted) {
      (uint64 memberId,) = TEMPL.members(voter);
      if (memberId == 0 || memberId > p.snapshotMemberCount) {
        revert JoinedAfterProposal();
      }
    }

    // Undo previous vote if changing
    if (voted) {
      if (previousVote == VOTE_FOR) --p.forVotes;
      if (previousVote == VOTE_AGAINST) --p.againstVotes;
      if (previousVote == VOTE_ABSTAIN) --p.abstainVotes;
    }

    // Apply new vote
    _hasVoted[proposalId][voter] = true;
    _votes[proposalId][voter] = support;
    if (support == VOTE_FOR) ++p.forVotes;
    if (support == VOTE_AGAINST) ++p.againstVotes;
    if (support == VOTE_ABSTAIN) ++p.abstainVotes;

    // Check quorum
    _checkQuorum(p, proposalId);

    emit Voted(
      address(TEMPL),
      proposalId,
      voter,
      support,
      p.forVotes,
      p.againstVotes,
      p.abstainVotes
    );
  }

  /// @inheritdoc IGovernance
  function voteWithPermitWitness(
    address voter,
    uint256 proposalId,
    uint8 support,
    ISignatureTransfer.PermitTransferFrom calldata permit,
    bytes calldata signature
  ) external override nonReentrant {
    if (permit.permitted.token != TEMPL.TOKEN()) revert WrongToken();

    // Build the witness hash from the vote intent
    bytes32 witness;
    {
      bytes memory encoded =
        abi.encode(VOTE_INTENT_TYPEHASH, proposalId, support);
      assembly ("memory-safe") {
        witness := keccak256(add(encoded, 0x20), mload(encoded))
      }
    }

    // Verify the voter's signature via Permit2 (0-amount transfer for auth only)
    PERMIT2.permitWitnessTransferFrom(
      permit,
      ISignatureTransfer.SignatureTransferDetails({
        to: address(this), requestedAmount: 0
      }),
      voter,
      witness,
      VOTE_WITNESS_TYPE_STRING,
      signature
    );

    // Apply the vote using the verified voter address
    _vote(voter, proposalId, support);
  }

  /// @inheritdoc IGovernance
  function execute(
    uint256 proposalId
  ) external payable override nonReentrant {
    Proposal storage p = _proposals[proposalId];
    if (p.proposer == address(0) || p.executed || p.cancelled) {
      revert ProposalNotActive();
    }

    // FOR must exceed AGAINST (abstain doesn't count toward decision)
    if (p.forVotes == 0 || p.forVotes <= p.againstVotes) revert QuorumNotMet();

    uint256 denominator = _quorumDenominator(proposalId, p.snapshotMemberCount);

    // Voting period must have ended OR instant quorum reached
    bool votingEnded = block.timestamp >= p.createdAt + p.snapshotVotingPeriod;
    bool instant =
      denominator > 0
      && p.forVotes * BPS / denominator >= p.snapshotImmediateExecutionBps;
    if (!votingEnded && !instant) revert TooEarly();

    if (!p.quorumExempt) {
      // Two-threshold check:
      // 1. Quorum: (for + against + abstain) / eligible >= quorumBps
      uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;
      if (
        denominator == 0 || totalVotes * BPS / denominator < p.snapshotQuorumBps
      ) {
        revert QuorumNotMet();
      }

      // 2. Approval threshold: for / (for + against) >= approvalThresholdBps
      uint256 decidingVotes = p.forVotes + p.againstVotes;
      if (
        decidingVotes == 0
          || p.forVotes * BPS / decidingVotes < p.snapshotApprovalThresholdBps
      ) {
        revert QuorumNotMet();
      }
    }

    if (!instant) {
      // Quorum-exempt proposals use createdAt as delay base (no quorum tracking)
      uint48 delayBase = p.quorumExempt ? p.createdAt : p.quorumReachedAt;
      if (delayBase == 0) revert TooEarly();
      if (block.timestamp < delayBase + p.snapshotExecutionDelay) {
        revert TooEarly();
      }
    }

    p.executed = true;
    _clearActiveProposal(p.proposer, proposalId);

    // Execute all operations in batch
    for (uint256 i; i < p.targets.length; ++i) {
      (bool ok,) = p.targets[i].call{ value: p.values[i] }(p.calldatas[i]);
      if (!ok) revert ExecutionFailed();
    }

    emit ProposalExecuted(address(TEMPL), proposalId);
  }

  /// @inheritdoc IGovernance
  function cancel(
    uint256 proposalId
  ) external override {
    Proposal storage p = _proposals[proposalId];
    if (p.proposer == address(0) || p.executed || p.cancelled) {
      revert ProposalNotActive();
    }
    if (msg.sender != p.proposer) revert NotAuthorized();

    p.cancelled = true;
    _clearActiveProposal(p.proposer, proposalId);

    emit ProposalCancelled(address(TEMPL), proposalId);
  }

  // ============ Emergency ============

  /// @inheritdoc IGovernance
  function proposeDissolution(
    string calldata description
  ) external virtual override returns (uint256 proposalId) {
    if (msg.sender != TEMPL.priest()) revert NotAuthorized();
    return _proposeDissolution(description);
  }

  function _proposeDissolution(
    string calldata description
  ) internal returns (uint256 proposalId) {
    if (!_canPropose(msg.sender)) revert NotAuthorized();

    uint256 existing = activeProposal[msg.sender];
    if (existing != 0 && _isVotingOpen(_proposals[existing])) {
      revert ActiveProposalExists();
    }

    proposalId = ++proposalCount;
    Proposal storage p = _proposals[proposalId];
    p.proposer = msg.sender;

    // Single-target dissolution
    p.targets = new address[](1);
    p.targets[0] = address(TEMPL.TREASURY());
    p.values = new uint256[](1);
    p.calldatas = new bytes[](1);
    p.calldatas[0] = abi.encodeCall(TEMPL.TREASURY().dissolve, ());

    p.createdAt = uint48(block.timestamp);
    p.snapshotMemberCount = TEMPL.memberCount();
    p.snapshotVotingPeriod = votingPeriod;
    p.snapshotQuorumBps = quorumBps;
    p.snapshotApprovalThresholdBps = approvalThresholdBps;
    p.snapshotExecutionDelay = executionDelay;
    p.snapshotImmediateExecutionBps = immediateExecutionBps;
    p.quorumExempt = true;

    activeProposal[msg.sender] = proposalId;
    _afterProposalCreated(proposalId);

    emit ProposalCreated(
      address(TEMPL),
      proposalId,
      msg.sender,
      p.targets,
      p.values,
      p.calldatas,
      description
    );

    // Auto-vote FOR if proposer is eligible
    if (_canVote(msg.sender)) {
      _hasVoted[proposalId][msg.sender] = true;
      _votes[proposalId][msg.sender] = VOTE_FOR;
      p.forVotes = 1;
      emit Voted(
        address(TEMPL),
        proposalId,
        msg.sender,
        VOTE_FOR,
        p.forVotes,
        p.againstVotes,
        p.abstainVotes
      );
    }
  }

  // ============ Parameter Setters ============

  /// @inheritdoc IGovernance
  function setApprovalThresholdBps(
    uint256 _bps
  ) external override {
    if (msg.sender != address(this)) revert NotAuthorized();
    if (_bps > BPS) revert InvalidQuorumConfig();
    if (_bps > immediateExecutionBps) revert InvalidQuorumConfig();
    approvalThresholdBps = _bps;
    emit ApprovalThresholdUpdated(address(TEMPL), _bps);
  }

  /// @inheritdoc IGovernance
  function setQuorumBps(
    uint256 _bps
  ) external override {
    if (msg.sender != address(this)) revert NotAuthorized();
    if (_bps > BPS) revert InvalidQuorumConfig();
    quorumBps = _bps;
    emit QuorumUpdated(address(TEMPL), _bps);
  }

  /// @inheritdoc IGovernance
  function setExecutionDelay(
    uint256 _seconds
  ) external override {
    if (msg.sender != address(this)) revert NotAuthorized();
    executionDelay = _seconds;
    emit ExecutionDelayUpdated(address(TEMPL), _seconds);
  }

  /// @inheritdoc IGovernance
  function setVotingPeriod(
    uint256 _seconds
  ) external override {
    if (msg.sender != address(this)) revert NotAuthorized();
    // Must stay strictly positive. A zero voting period expires every
    // future proposal the instant it is created, leaving only the
    // proposer's auto-FOR vote in the tally - effectively letting any
    // proposer pass arbitrary proposals solo.
    if (_seconds == 0) revert InvalidQuorumConfig();
    votingPeriod = _seconds;
    emit VotingPeriodUpdated(address(TEMPL), _seconds);
  }

  /// @inheritdoc IGovernance
  function setImmediateExecutionBps(
    uint256 _bps
  ) external override {
    if (msg.sender != address(this)) revert NotAuthorized();
    if (_bps > BPS) revert InvalidQuorumConfig();
    if (_bps < approvalThresholdBps) revert InvalidQuorumConfig();
    immediateExecutionBps = _bps;
    emit ImmediateExecutionUpdated(address(TEMPL), _bps);
  }

  /// @inheritdoc IGovernance
  function setProposalFeeBps(
    uint256 _bps
  ) external override {
    if (msg.sender != address(this)) revert NotAuthorized();
    if (_bps > MAX_PROPOSAL_FEE_BPS) revert InvalidQuorumConfig();
    proposalFeeBps = _bps;
    emit ProposalFeeUpdated(address(TEMPL), _bps);
  }

  // ============ Internal ============

  /// @dev A proposal is in its voting window (not yet expired, executed, or cancelled)
  function _isVotingOpen(
    Proposal storage p
  ) internal view returns (bool) {
    if (p.proposer == address(0) || p.executed || p.cancelled) return false;
    return block.timestamp < p.createdAt + p.snapshotVotingPeriod;
  }

  /// @dev Compute the full proposal state
  function _state(
    uint256 proposalId,
    Proposal storage p
  ) internal view returns (ProposalState) {
    if (p.proposer == address(0)) return ProposalState.Pending;
    if (p.executed) return ProposalState.Executed;
    if (p.cancelled) return ProposalState.Cancelled;

    // Voting still open
    if (block.timestamp < p.createdAt + p.snapshotVotingPeriod) {
      return ProposalState.Active;
    }

    // Voting ended - check if it passed
    if (p.forVotes > 0 && p.forVotes > p.againstVotes) {
      uint256 denominator =
        _quorumDenominator(proposalId, p.snapshotMemberCount);
      if (p.quorumExempt) return ProposalState.Succeeded;

      uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;
      if (
        denominator > 0 && totalVotes * BPS / denominator >= p.snapshotQuorumBps
      ) {
        uint256 decidingVotes = p.forVotes + p.againstVotes;
        if (
          decidingVotes > 0
            && p.forVotes * BPS / decidingVotes
              >= p.snapshotApprovalThresholdBps
        ) {
          return ProposalState.Succeeded;
        }
      }
    }

    return ProposalState.Defeated;
  }

  function _clearActiveProposal(
    address proposer,
    uint256 proposalId
  ) internal {
    if (activeProposal[proposer] == proposalId) {
      activeProposal[proposer] = 0;
    }
  }

  function _proposalFee(
    address /* proposer */
  ) internal view virtual returns (uint256) {
    if (proposalFeeBps == 0) return 0;
    return (TEMPL.entryFee() * proposalFeeBps) / BPS;
  }

  /// @dev Check if quorum is newly reached and record timestamp
  function _checkQuorum(
    Proposal storage p,
    uint256 proposalId
  ) internal {
    if (p.quorumReachedAt != 0 || p.quorumExempt) return;

    uint256 denominator = _quorumDenominator(proposalId, p.snapshotMemberCount);
    if (denominator == 0) return;

    uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;
    if (totalVotes * BPS / denominator >= p.snapshotQuorumBps) {
      p.quorumReachedAt = uint48(block.timestamp);
      emit QuorumReached(address(TEMPL), proposalId, p.quorumReachedAt);
    }
  }
}
