// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILinkContest
/// @notice Interface for the LinkContest plugin: a per-templ contest that
///         collects an ERC-20 submission fee per entry, splits it between the
///         templ treasury and the protocol, records submissions in fixed
///         rounds, and lets the owner (the priest) rank 1st/2nd/3rd per round.
/// @dev A submission carries a raw link and an off-chain normalized form. The
///      contract is content-agnostic and does not normalize: it trusts the
///      caller's normalized string (honest-client design) and dedups on its
///      hash. Both strings are event-only, never stored. Fees are split on
///      submission, so judging is ranking-only with no payout.
interface ILinkContest {
  // ============ Events ============

  /// @notice Emitted on every paid submission after the fee has been split.
  /// @param round Round index the submission landed in
  /// @param id Incrementing submission id within the round (1-based)
  /// @param submitter Address that paid the submission fee
  /// @param link Raw link as supplied by the user (event-only, not stored)
  /// @param normalizedLink Off-chain normalized link the dedup hash is taken
  ///        from (event-only, not stored). Emitting raw alongside normalized
  ///        makes any client-side mismatch visible to the indexer and judge.
  /// @param linkHash `keccak256(bytes(normalizedLink))`, the dedup key
  /// @param feePaid Total the submitter paid for this entry. 0 when the
  ///        submitter is fee-exempt and the fee was waived.
  /// @param treasuryAmount Slice of the fee forwarded to the templ Treasury.
  ///        0 when the fee was waived.
  event Submitted(
    uint256 indexed round,
    uint256 indexed id,
    address indexed submitter,
    string link,
    string normalizedLink,
    bytes32 linkHash,
    uint256 feePaid,
    uint256 treasuryAmount
  );

  /// @notice Emitted when the owner records the ranking for a closed round.
  /// @param round Round index the ranking applies to
  /// @param first Submission id ranked first (always set)
  /// @param second Submission id ranked second (0 if unset)
  /// @param third Submission id ranked third (0 if unset)
  event WinnersSet(
    uint256 indexed round, uint256 first, uint256 second, uint256 third
  );

  /// @notice Emitted when the owner changes the fee token.
  /// @param newToken New ERC20 token used for submission fees
  event TokenUpdated(address newToken);

  /// @notice Emitted when the owner changes the submission fee.
  /// @param newFee New fee paid by each submission
  event SubmissionFeeUpdated(uint256 newFee);

  /// @notice Emitted when the owner moves the first round start.
  /// @param newStart New Unix timestamp round 0 begins
  event FirstRoundStartUpdated(uint256 newStart);

  /// @notice Emitted when the owner pauses or resumes submissions.
  /// @param paused New paused state
  event PausedUpdated(bool paused);

  /// @notice Emitted per account when the owner changes its fee-exempt status.
  /// @param account Address whose fee-exempt status changed
  /// @param exempt New fee-exempt status (true = submits without paying)
  event FeeExemptUpdated(address indexed account, bool exempt);

  // ============ Errors ============

  /// @notice Constructor was passed the zero address for templ or token.
  error ZeroAddress();
  /// @notice Constructor was passed a zero round duration, which would brick
  ///         `currentRound` (division by zero).
  error ZeroDuration();
  /// @notice Delivered fee did not match the configured fee (fee-on-transfer).
  error FeeTokenMismatch();
  /// @notice `submit` was called before `firstRoundStart`.
  error ContestNotStarted();
  /// @notice `submit` was called while the contest is paused.
  error ContestPaused();
  /// @notice `setFirstRoundStart` was called after round 0 already began.
  error ContestAlreadyStarted();
  /// @notice `setFirstRoundStart` was passed a non-future timestamp.
  error InvalidStart();
  /// @notice `setWinners` was called before the round closed.
  error RoundNotClosed();
  /// @notice A winner ranking was invalid: 1st place missing or out of range,
  ///         a set place out of range or duplicated, or a 3rd place with no
  ///         2nd (gaps are not allowed).
  error InvalidSubmission();
  /// @notice The normalized link already exists in this contest. Dedup is
  ///         global across rounds and matches on `keccak256(normalizedLink)`.
  error DuplicateLink();

  // ============ Views ============
  // SCREAMING_SNAKE_CASE marks "morally immutable" storage set once in the
  // constructor with no setter, matching the convention in Treasury.sol. The
  // owner-editable values (`token`, `submissionFee`, `firstRoundStart`,
  // `paused`) are plain camelCase since they each have a setter.

  /// @notice The Templ membership contract this contest is attached to
  function TEMPL() external view returns (address);

  /// @notice The templ Treasury that receives the treasury slice of each fee
  function TREASURY() external view returns (address);

  /// @notice The Factory that supplies the protocol fee rate and recipient
  function FACTORY() external view returns (address);

  /// @notice Round length in seconds
  function ROUND_DURATION() external view returns (uint256);

  /// @notice ERC20 token used for submission fees. Owner-editable.
  function token() external view returns (address);

  /// @notice Fee paid by each submission. Owner-editable.
  function submissionFee() external view returns (uint256);

  /// @notice Unix timestamp round 0 begins. Owner-editable until round 0
  ///         opens. Lets rounds anchor to a calendar boundary.
  function firstRoundStart() external view returns (uint256);

  /// @notice Whether submissions are paused. Owner-editable.
  function paused() external view returns (bool);

  /// @notice Whether an address submits without paying the fee. Owner-editable
  ///         via `setFeeExempt`. The UI reads this to skip the fee steps.
  /// @param account Address to query
  function feeExempt(
    address account
  ) external view returns (bool);

  /// @notice Number of submissions recorded in a round
  /// @param round Round index to query
  function submissionCount(
    uint256 round
  ) external view returns (uint256);

  /// @notice Submitter address for a given round and submission id
  /// @param round Round index
  /// @param id Submission id within the round
  function submitterOf(
    uint256 round,
    uint256 id
  ) external view returns (address);

  /// @notice The currently open round, derived from `block.timestamp`.
  ///         Returns 0 before `firstRoundStart` so views never underflow.
  function currentRound() external view returns (uint256);

  /// @notice Timestamp at which a round closes
  /// @param round Round index to query
  function roundEndsAt(
    uint256 round
  ) external view returns (uint256);

  /// @notice Whether a normalized link has already been submitted to this
  ///         contest. The caller passes the link already normalized; dedup
  ///         matches on `keccak256(normalizedLink)` and spans all rounds. The
  ///         UI reads this to block a duplicate before the user pays gas.
  /// @param normalizedLink Off-chain normalized link string to check
  function isSubmitted(
    string calldata normalizedLink
  ) external view returns (bool);

  // ============ Actions ============

  /// @notice Pay the submission fee and record an entry in the current round.
  ///         Splits the fee between the protocol recipient and the Treasury,
  ///         then emits `Submitted`. Callable any number of times per address.
  ///         The fee is skipped entirely for a fee-exempt sender (`feeExempt`),
  ///         which submits for free; `Submitted` then carries `feePaid == 0`
  ///         and `treasuryAmount == 0`.
  ///         The contract does not normalize: it trusts the caller's
  ///         `normalizedLink` and dedups on `keccak256(normalizedLink)`.
  ///         Reverts `ContestPaused` while paused, `ContestNotStarted` before
  ///         `firstRoundStart`, and `DuplicateLink` if a matching normalized
  ///         link was already submitted to this contest (the duplicate check
  ///         runs before the fee is pulled, so a rejected entry is never
  ///         charged, and applies to fee-exempt senders too).
  /// @param rawLink Raw link as supplied by the user, emitted but not stored
  /// @param normalizedLink Off-chain normalized link, the dedup key source,
  ///        emitted but not stored
  function submit(
    string calldata rawLink,
    string calldata normalizedLink
  ) external;

  /// @notice Record the ranking for a closed round. Owner-only (the priest).
  ///         Ranking only: fees were split on submission, so no payout occurs.
  ///         1st place is required; 2nd and 3rd are optional (pass 0 to leave
  ///         a place unset). A 3rd place requires a 2nd. Set places must be
  ///         distinct, valid submission ids.
  /// @param round Round index (must be closed)
  /// @param first Submission id ranked first (required)
  /// @param second Submission id ranked second (0 = unset)
  /// @param third Submission id ranked third (0 = unset)
  function setWinners(
    uint256 round,
    uint256 first,
    uint256 second,
    uint256 third
  ) external;

  // ============ Owner config ============

  /// @notice Change the fee token. Owner-only. Reverts `ZeroAddress` on the
  ///         zero address.
  /// @param newToken New ERC20 token used for submission fees
  function setToken(
    address newToken
  ) external;

  /// @notice Change the submission fee. Owner-only.
  /// @param newFee New fee paid by each submission
  function setSubmissionFee(
    uint256 newFee
  ) external;

  /// @notice Move the first round start. Owner-only, callable only before
  ///         round 0 opens (`ContestAlreadyStarted` otherwise), and only to a
  ///         future timestamp (`InvalidStart` otherwise).
  /// @param newStart New Unix timestamp round 0 begins
  function setFirstRoundStart(
    uint256 newStart
  ) external;

  /// @notice Pause or resume submissions. Owner-only.
  /// @param paused_ New paused state
  function setPaused(
    bool paused_
  ) external;

  /// @notice Set the fee-exempt status for a batch of addresses. Owner-only.
  ///         Exempt addresses submit without paying the fee. Emits
  ///         `FeeExemptUpdated` per account.
  /// @param accounts Addresses to update
  /// @param exempt New fee-exempt status applied to every address
  function setFeeExempt(
    address[] calldata accounts,
    bool exempt
  ) external;
}
