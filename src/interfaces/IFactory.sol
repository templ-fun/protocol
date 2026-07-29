// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CurveConfig } from "../libraries/EntryFeeCurve.sol";

/// @title IFactory
/// @notice Interface for the Templ factory contract
/// @author templ.fun

/// @notice Governance mode for new templs
enum GovMode {
  Democracy,
  Council
}

/// @notice Governance configuration passed during templ creation
/// @dev All values are stored as-is. The Factory does not substitute defaults
///      for any field - callers must provide explicit values. The convenience
///      layer (UI / SDK) is the right place for "sensible defaults".
/// @param mode Democracy (all members vote) or Council (only council votes)
/// @param approvalThresholdBps FOR vote threshold in bps of for+against. Typical: 5100 (51%).
/// @param quorumBps Minimum participation threshold in bps. Typical: 1000 (10%).
/// @param votingPeriod Voting window in seconds. Typical: 3 days.
/// @param executionDelay Seconds after quorum before execution. Typical: 1 day.
/// @param immediateExecutionBps FOR threshold to bypass execution delay. Typical: 10000 (100%).
/// @param proposalFeeBps Proposal fee in bps of entry fee. Typical: 2500 (25%). 0 = free proposals.
/// @param council Initial council members (Council mode only, ignored for Democracy)
struct GovernanceConfig {
  GovMode mode;
  uint256 approvalThresholdBps;
  uint256 quorumBps;
  uint256 votingPeriod;
  uint256 executionDelay;
  uint256 immediateExecutionBps;
  uint256 proposalFeeBps;
  address[] council;
}

/// @notice Full configuration for creating a new templ
/// @dev All values are stored as-is. The Factory does not substitute defaults
///      for any field. Splits must sum to (10000 - PROTOCOL_FEE_BPS), the curve
///      must validate via EntryFeeCurve.validate, and governance values are
///      passed straight through to the Governance constructor.
/// @param token ERC20 token for entry fees and rewards
/// @param baseEntryFee Starting entry fee before curve adjustments
/// @param slug URL-safe identifier (a-z, 0-9, hyphens only). Enforced unique on-chain.
/// @param name Templ display name (emitted in event, not stored on-chain)
/// @param description Templ description (emitted in event, not stored)
/// @param logoLink Logo URL or IPFS hash (emitted in event, not stored)
/// @param burnBps Burn share in bps. Typical: 3000 (30%).
/// @param treasuryBps Treasury share in bps. Typical: 3000 (30%).
/// @param memberPoolBps Member pool share in bps. Typical: 3000 (30%).
/// @param referralShareBps Referral share of member pool in bps. Typical: 2500 (25%).
/// @param curve Entry fee curve. Must pass EntryFeeCurve.validate.
///        For a flat curve, pass `{ primary: { Static, 0, 0 }, additionalSegments: [] }`.
/// @param governance Governance configuration (always deployed)
struct CreateConfig {
  address token;
  uint256 baseEntryFee;
  string slug;
  string name;
  string description;
  string logoLink;
  uint256 burnBps;
  uint256 treasuryBps;
  uint256 memberPoolBps;
  uint256 referralShareBps;
  CurveConfig curve;
  GovernanceConfig governance;
}

interface IFactory {
  // ============ Events ============

  /// @notice Emitted when a new templ is created. `memberPool` is the
  ///         deterministically-deployed MemberPool that holds member rewards;
  ///         indexers should subscribe to its events from this address.
  event TemplCreated(
    address indexed templ,
    address indexed priest,
    address indexed token,
    address treasury,
    address memberPool,
    address creator,
    uint256 baseEntryFee,
    string slug,
    string name,
    string description,
    string logoLink
  );

  /// @notice Emitted when a templ's slug is updated via governance
  event SlugUpdated(address indexed templ, string oldSlug, string newSlug);

  /// @notice Emitted when the creation gate is toggled
  event OpenUpdated(bool isOpen);

  /// @notice Emitted when the protocol fee recipient changes
  event ProtocolFeeRecipientUpdated(address indexed recipient);

  // ============ Errors ============

  error InvalidToken();
  error InvalidPriest();
  error InvalidFeeRecipient();
  error InvalidSplit();
  error InvalidCouncil();
  error InvalidSlug();
  error SlugTaken();
  error NotRegisteredTempl();
  error NotGovernance();

  // ============ Views ============

  /// @notice Address that receives the protocol fee from every join
  function protocolFeeRecipient() external view returns (address);

  /// @notice Protocol fee in basis points (immutable constant)
  function PROTOCOL_FEE_BPS() external view returns (uint256);

  /// @notice Whether the creation gate is open (true = anyone, false = owner only)
  function isOpen() external view returns (bool);

  /// @notice All registered templ addresses
  function getTempls() external view returns (address[] memory);

  /// @notice Number of templs created through this factory
  function templCount() external view returns (uint256);

  /// @notice Whether an address is a factory-registered templ
  /// @param templ Address to check
  function isTempl(
    address templ
  ) external view returns (bool);

  /// @notice Paginated templ list for large registries
  /// @param offset Starting index
  /// @param limit Maximum number of results
  function getTemplsPaginated(
    uint256 offset,
    uint256 limit
  ) external view returns (address[] memory);

  /// @notice Resolve a slug to its templ address (zero if not registered)
  function slugToTempl(
    string calldata slug
  ) external view returns (address);

  /// @notice Get the slug for a templ address
  function templSlug(
    address templ
  ) external view returns (string memory);

  // ============ Actions ============

  /// @notice Create a new templ with the caller as priest
  /// @param config Full templ configuration including governance
  /// @return templ Address of the created templ
  function createTempl(
    CreateConfig calldata config
  ) external returns (address templ);

  /// @notice Create a new templ with a specific priest
  /// @param priest Address to set as priest
  /// @param config Full templ configuration including governance
  /// @return templ Address of the created templ
  function createTemplFor(
    address priest,
    CreateConfig calldata config
  ) external returns (address templ);

  /// @notice Update a templ's slug. Only callable by the templ's governance contract.
  /// @param templ Address of the templ to update
  /// @param newSlug New slug (must be valid and not taken)
  function updateSlug(
    address templ,
    string calldata newSlug
  ) external;

  /// @notice Toggle the creation gate (owner-only when closed)
  /// @param _isOpen true = anyone can create, false = owner only
  function setOpen(
    bool _isOpen
  ) external;

  /// @notice Update the protocol fee recipient
  /// @param _recipient New recipient address (must not be zero)
  function setProtocolFeeRecipient(
    address _recipient
  ) external;
}
