// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITempl } from "./ITempl.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";

/// @title IGovernance
/// @notice Shared interface for all governance types (Democracy, Council)
interface IGovernance {
  // ============ Enums ============

  /// @notice Proposal lifecycle states (OZ Governor-aligned)
  enum ProposalState {
    Pending,
    Active,
    Succeeded,
    Executed,
    Defeated,
    Cancelled
  }

  // ============ Structs ============

  /// @notice Read-only view of proposal state returned by getProposal
  struct ProposalView {
    address proposer;
    address[] targets;
    uint256[] values;
    bytes[] calldatas;
    uint48 createdAt;
    bool executed;
    bool cancelled;
    bool quorumExempt;
    uint256 forVotes;
    uint256 againstVotes;
    uint256 abstainVotes;
    uint64 snapshotMemberCount;
    uint48 quorumReachedAt;
    uint256 snapshotVotingPeriod;
    uint256 snapshotQuorumBps;
    uint256 snapshotApprovalThresholdBps;
    uint256 snapshotExecutionDelay;
    uint256 snapshotImmediateExecutionBps;
  }

  // ============ Events ============

  /// @notice Emitted when a proposal is created (batch-aware)
  event ProposalCreated(
    address indexed templ,
    uint256 indexed proposalId,
    address indexed proposer,
    address[] targets,
    uint256[] values,
    bytes[] calldatas,
    string description
  );

  /// @notice Emitted when a member votes (OZ-aligned: 0=Against, 1=For, 2=Abstain)
  event Voted(
    address indexed templ,
    uint256 indexed proposalId,
    address indexed voter,
    uint8 support,
    uint256 forVotes,
    uint256 againstVotes,
    uint256 abstainVotes
  );

  /// @notice Emitted when a proposal is executed
  event ProposalExecuted(address indexed templ, uint256 indexed proposalId);

  /// @notice Emitted when a proposal is cancelled
  event ProposalCancelled(address indexed templ, uint256 indexed proposalId);

  /// @notice Emitted when quorum is first reached for a proposal
  event QuorumReached(
    address indexed templ, uint256 indexed proposalId, uint48 quorumReachedAt
  );

  /// @notice Emitted when approval threshold is updated
  event ApprovalThresholdUpdated(address indexed templ, uint256 bps);

  /// @notice Emitted when quorum threshold is updated
  event QuorumUpdated(address indexed templ, uint256 bps);

  /// @notice Emitted when execution delay is updated
  event ExecutionDelayUpdated(address indexed templ, uint256 seconds_);

  /// @notice Emitted when voting period is updated
  event VotingPeriodUpdated(address indexed templ, uint256 seconds_);

  /// @notice Emitted when immediate execution threshold is updated
  event ImmediateExecutionUpdated(address indexed templ, uint256 bps);

  /// @notice Emitted when proposal fee is updated
  event ProposalFeeUpdated(address indexed templ, uint256 bps);

  /// @notice Emitted by emitConfig() so indexers know the governance type
  event GovernanceInitialized(address indexed templ, string governanceType);

  // ============ Errors ============

  error NotAuthorized();
  error ProposalNotActive();
  error SameVote();
  error InvalidVoteValue();
  error QuorumNotMet();
  error ExecutionFailed();
  error TooEarly();
  error VotingEnded();
  error JoinedAfterProposal();
  error ActiveProposalExists();
  error InvalidQuorumConfig();
  error ArrayLengthMismatch();
  error WrongToken();

  // ============ Constants ============

  /// @notice Upper bound for proposalFeeBps (100% of entry fee)
  function MAX_PROPOSAL_FEE_BPS() external pure returns (uint256);

  // ============ Views ============

  /// @notice The templ this governance controls
  function TEMPL() external view returns (ITempl);

  /// @notice FOR vote threshold in basis points (e.g. 5100 = 51% of for+against)
  function approvalThresholdBps() external view returns (uint256);

  /// @notice Quorum threshold in basis points (e.g. 1000 = 10% participation)
  function quorumBps() external view returns (uint256);

  /// @notice Seconds after quorum is reached before execution is allowed
  function executionDelay() external view returns (uint256);

  /// @notice Duration of the voting window
  function votingPeriod() external view returns (uint256);

  /// @notice FOR vote threshold (bps) to bypass execution delay (e.g. 10000 = 100%)
  function immediateExecutionBps() external view returns (uint256);

  /// @notice Proposal creation fee in bps of the current entry fee (0 = free)
  function proposalFeeBps() external view returns (uint256);

  /// @notice Total proposals created
  function proposalCount() external view returns (uint256);

  /// @notice The active proposal ID for a proposer (0 = none)
  function activeProposal(
    address proposer
  ) external view returns (uint256);

  /// @notice Whether an account has voted on a proposal
  function hasVoted(
    uint256 proposalId,
    address account
  ) external view returns (bool);

  /// @notice Get a member's vote on a proposal
  /// @return vote 0 = against, 1 = for, 2 = abstain (255 = not voted)
  function getVote(
    uint256 proposalId,
    address account
  ) external view returns (uint8 vote);

  /// @notice Get the current state of a proposal
  function state(
    uint256 proposalId
  ) external view returns (ProposalState);

  /// @notice Get proposal details
  function getProposal(
    uint256 proposalId
  ) external view returns (ProposalView memory);

  // ============ Init ============

  /// @notice Emit config events so indexers can populate governance parameters
  function emitConfig() external;

  // ============ Actions ============

  /// @notice Create a proposal (batch-aware, OZ Governor style)
  function propose(
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata calldatas,
    string calldata description
  ) external returns (uint256 proposalId);

  /// @notice Create a proposal via Permit2 witness - trustless relaying.
  ///         The signature binds the proposer to the exact proposal content
  ///         (targets, values, calldatas, description) via a ProposalIntent witness.
  ///         Anyone can relay the transaction; no trust required.
  function proposeWithPermitWitness(
    address proposer,
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata calldatas,
    string calldata description,
    ISignatureTransfer.PermitTransferFrom calldata permit,
    bytes calldata signature
  ) external returns (uint256 proposalId);

  /// @notice Create a proposal, paying the fee via ERC-2612 native permit.
  ///         For tokens that implement EIP-2612. No Permit2 dependency.
  ///         Allowance is consumed atomically - no residual approval remains.
  ///         Self-submit only (proposer = msg.sender). Not relayable - ERC-2612
  ///         cannot bind proposal content to the signature. Use
  ///         proposeWithPermitWitness for gasless relay.
  function proposeWithERC2612Permit(
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata calldatas,
    string calldata description,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external returns (uint256 proposalId);

  /// @notice Vote on a proposal (OZ-aligned: 0=Against, 1=For, 2=Abstain)
  function vote(
    uint256 proposalId,
    uint8 support
  ) external;

  /// @notice Vote on a proposal via Permit2 witness - trustless relaying.
  ///         The signature binds the voter to the exact proposal and vote choice
  ///         via a VoteIntent witness. Anyone can relay the transaction.
  function voteWithPermitWitness(
    address voter,
    uint256 proposalId,
    uint8 support,
    ISignatureTransfer.PermitTransferFrom calldata permit,
    bytes calldata signature
  ) external;

  /// @notice Execute a passed proposal
  function execute(
    uint256 proposalId
  ) external payable;

  /// @notice Cancel a proposal (proposer only)
  function cancel(
    uint256 proposalId
  ) external;

  /// @notice Create a quorum-exempt dissolution proposal
  function proposeDissolution(
    string calldata description
  ) external returns (uint256 proposalId);

  // ============ Parameter Setters (via governance proposals) ============

  /// @notice Update the approval threshold (only callable by the governance contract itself via proposal)
  /// @param _bps New threshold in basis points
  function setApprovalThresholdBps(
    uint256 _bps
  ) external;

  /// @notice Update the quorum threshold (only callable by the governance contract itself via proposal)
  /// @param _bps New quorum in basis points
  function setQuorumBps(
    uint256 _bps
  ) external;

  /// @notice Update the execution delay (only callable by the governance contract itself via proposal)
  /// @param _seconds New delay in seconds
  function setExecutionDelay(
    uint256 _seconds
  ) external;

  /// @notice Update the voting period (only callable by the governance contract itself via proposal)
  /// @param _seconds New period in seconds (must be > 0)
  function setVotingPeriod(
    uint256 _seconds
  ) external;

  /// @notice Update the immediate execution threshold (only callable by the governance contract itself via proposal)
  /// @param _bps New threshold in basis points (must be >= approvalThresholdBps)
  function setImmediateExecutionBps(
    uint256 _bps
  ) external;

  /// @notice Update the proposal fee (only callable by the governance contract itself via proposal)
  /// @param _bps New fee in basis points of current entry fee
  function setProposalFeeBps(
    uint256 _bps
  ) external;
}
