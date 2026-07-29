// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IFactory } from "../../interfaces/IFactory.sol";
import { ILinkContest } from "../../interfaces/ILinkContest.sol";
import { ITempl } from "../../interfaces/ITempl.sol";
import { ITreasury } from "../../interfaces/ITreasury.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import {
  ReentrancyGuardTransient
} from "solady/utils/ReentrancyGuardTransient.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @title LinkContest
/// @notice A per-templ contest plugin. Each submission pays an ERC-20 fee that
///         is split 90/10 between the templ Treasury and the protocol, lands in
///         a fixed time-window round, and is ranked later by the owner.
/// @dev The protocol cut and recipient are read from the Factory, not stored
///      locally (`IFactory(FACTORY).PROTOCOL_FEE_BPS()` and
///      `.protocolFeeRecipient()`), mirroring `Templ._splitAndForward`. This
///      keeps one source of truth and picks up `setProtocolFeeRecipient`
///      changes automatically. A submission carries a raw link and an off-chain
///      normalized form; both are emitted in `Submitted` and never stored
///      on-chain. The contract does not normalize: it trusts the caller's
///      normalized string (honest-client design) and dedups on its hash. The
///      owner can mark addresses fee-exempt so they submit without paying.
contract LinkContest is ILinkContest, Ownable, ReentrancyGuardTransient {
  // ============ Constants ============

  uint256 internal constant BPS = 10_000;

  // ============ Set once in constructor ============
  // Not marked `immutable` so all instances share identical runtime bytecode,
  // enabling auto-verification on Etherscan/Sourcify after a single verified
  // deployment. No setter; effectively immutable. SCREAMING_SNAKE_CASE signals
  // that intent at the call site, matching Treasury.sol. The lint exemption is
  // scoped to this block alone.

  // forge-lint: disable-start(mixed-case-variable)
  address public override TEMPL;
  address public override TREASURY;
  address public override FACTORY;
  uint256 public override ROUND_DURATION;
  // forge-lint: disable-end(mixed-case-variable)

  // ============ Owner-editable ============
  // Mutable so the priest can retune the contest after deployment. Kept off
  // `immutable` for the same auto-verification reason as the set-once block.

  /// @inheritdoc ILinkContest
  address public override token;

  /// @inheritdoc ILinkContest
  uint256 public override submissionFee;

  /// @inheritdoc ILinkContest
  uint256 public override firstRoundStart;

  /// @inheritdoc ILinkContest
  bool public override paused;

  /// @inheritdoc ILinkContest
  mapping(address account => bool exempt) public override feeExempt;

  // ============ State ============

  /// @inheritdoc ILinkContest
  mapping(uint256 round => uint256 count) public override submissionCount;

  /// @inheritdoc ILinkContest
  mapping(uint256 round => mapping(uint256 id => address submitter))
    public
    override submitterOf;

  // Global per-contest dedup set. Stores only `keccak256(bytes(normalizedLink))`
  // so the link strings stay event-only, never on-chain. Global across rounds
  // matches the dialog's prior behavior of flagging a link present in any round.
  mapping(bytes32 linkHash => bool submitted) internal _submitted;

  // ============ Constructor ============

  /// @param templ Templ membership contract. Derives TREASURY and FACTORY.
  /// @param token_ ERC20 token used for submission fees
  /// @param submissionFee_ Amount each submission pays
  /// @param roundDuration Round length in seconds (e.g. 7 days)
  /// @param firstRoundStart_ Unix timestamp round 0 begins. Lets the deployer
  ///        anchor rounds to a calendar boundary (e.g. Monday 00:00 UTC).
  /// @param owner_ The judge; initialize to the priest
  constructor(
    address templ,
    address token_,
    uint256 submissionFee_,
    uint256 roundDuration,
    uint256 firstRoundStart_,
    address owner_
  ) {
    if (templ == address(0) || token_ == address(0)) revert ZeroAddress();
    if (roundDuration == 0) revert ZeroDuration();

    address treasury = address(ITempl(templ).TREASURY());

    TEMPL = templ;
    TREASURY = treasury;
    FACTORY = ITreasury(treasury).FACTORY();
    ROUND_DURATION = roundDuration;
    token = token_;
    submissionFee = submissionFee_;
    firstRoundStart = firstRoundStart_;

    _initializeOwner(owner_);
  }

  // ============ Views ============

  /// @inheritdoc ILinkContest
  /// @dev Clamps to round 0 before the start so views stay safe for the UI
  ///      (no underflow). `submit` separately rejects pre-start entries with
  ///      `ContestNotStarted`, so the clamp only ever shows a not-yet-open
  ///      round 0 in read paths.
  function currentRound() public view override returns (uint256) {
    if (block.timestamp < firstRoundStart) return 0;
    return (block.timestamp - firstRoundStart) / ROUND_DURATION;
  }

  /// @inheritdoc ILinkContest
  function roundEndsAt(
    uint256 round
  ) public view override returns (uint256) {
    return firstRoundStart + (round + 1) * ROUND_DURATION;
  }

  /// @inheritdoc ILinkContest
  function isSubmitted(
    string calldata normalizedLink
  ) external view override returns (bool) {
    return _submitted[keccak256(bytes(normalizedLink))];
  }

  // ============ Actions ============

  /// @inheritdoc ILinkContest
  /// @dev Pulls the fee with a balance-delta measurement to reject
  ///      fee-on-transfer tokens (the `FeeTokenMismatch` pattern in
  ///      `Templ._processJoin`), splits the protocol slice off to the protocol
  ///      recipient and forwards the remainder (including division dust) to the
  ///      Treasury, then records the submission in the current round. Dedup
  ///      hashes the caller-supplied `normalizedLink`; the contract does not
  ///      normalize and trusts the client to do so (honest-client design).
  ///      Checks run in order: paused, then started, then duplicate (before the
  ///      fee pull, so a rejected entry is never charged), then the fee pull and
  ///      split. The duplicate flag is set before the transfer (checks-effects).
  ///      A fee-exempt submitter skips the pull and split entirely; the dedup
  ///      check still runs first so an exempt wallet cannot double-submit, and
  ///      `feePaid`/`treasuryAmount` emit 0.
  function submit(
    string calldata rawLink,
    string calldata normalizedLink
  ) external override nonReentrant {
    if (paused) revert ContestPaused();
    if (block.timestamp < firstRoundStart) revert ContestNotStarted();

    bytes32 linkHash = keccak256(bytes(normalizedLink));
    if (_submitted[linkHash]) revert DuplicateLink();
    _submitted[linkHash] = true;

    uint256 feePaid;
    uint256 treasuryAmount;

    if (!feeExempt[msg.sender]) {
      address feeToken = token;
      uint256 fee = submissionFee;

      uint256 before = SafeTransferLib.balanceOf(feeToken, address(this));
      SafeTransferLib.safeTransferFrom(feeToken, msg.sender, address(this), fee);
      uint256 delivered =
        SafeTransferLib.balanceOf(feeToken, address(this)) - before;
      if (delivered != fee) revert FeeTokenMismatch();

      uint256 protocolBps = IFactory(FACTORY).PROTOCOL_FEE_BPS();
      uint256 protocolAmt = (fee * protocolBps) / BPS;
      uint256 treasuryAmt = fee - protocolAmt;

      if (protocolAmt > 0) {
        SafeTransferLib.safeTransfer(
          feeToken, IFactory(FACTORY).protocolFeeRecipient(), protocolAmt
        );
      }
      if (treasuryAmt > 0) {
        SafeTransferLib.safeTransfer(feeToken, TREASURY, treasuryAmt);
      }

      feePaid = fee;
      treasuryAmount = treasuryAmt;
    }

    uint256 round = currentRound();
    uint256 id = ++submissionCount[round];
    submitterOf[round][id] = msg.sender;

    emit Submitted(
      round,
      id,
      msg.sender,
      rawLink,
      normalizedLink,
      linkHash,
      feePaid,
      treasuryAmount
    );
  }

  /// @inheritdoc ILinkContest
  /// @dev Owner-only and callable only once a round has closed. Ranking is
  ///      event-only; no winner storage drives a payout because fees were
  ///      already split on submission. 1st place is required; 2nd and 3rd are
  ///      optional (0 = unset) so a round with one or two entrants stays
  ///      finalizable. A 3rd place requires a 2nd (no gaps).
  function setWinners(
    uint256 round,
    uint256 first,
    uint256 second,
    uint256 third
  ) external override onlyOwner {
    if (block.timestamp < roundEndsAt(round)) revert RoundNotClosed();

    uint256 count = submissionCount[round];

    // 1st is mandatory and must be a real submission.
    if (first == 0 || first > count) revert InvalidSubmission();

    // No 3rd without a 2nd.
    if (third != 0 && second == 0) revert InvalidSubmission();

    // Each set place must be a real submission and distinct from the others.
    if (second != 0) {
      if (second > count || second == first) revert InvalidSubmission();
    }
    if (third != 0) {
      if (third > count || third == first || third == second) {
        revert InvalidSubmission();
      }
    }

    emit WinnersSet(round, first, second, third);
  }

  // ============ Owner config ============

  /// @inheritdoc ILinkContest
  function setToken(
    address newToken
  ) external override onlyOwner {
    if (newToken == address(0)) revert ZeroAddress();
    token = newToken;
    emit TokenUpdated(newToken);
  }

  /// @inheritdoc ILinkContest
  function setSubmissionFee(
    uint256 newFee
  ) external override onlyOwner {
    submissionFee = newFee;
    emit SubmissionFeeUpdated(newFee);
  }

  /// @inheritdoc ILinkContest
  /// @dev Only retunable before round 0 begins, and only to a future time.
  function setFirstRoundStart(
    uint256 newStart
  ) external override onlyOwner {
    if (block.timestamp >= firstRoundStart) revert ContestAlreadyStarted();
    if (newStart <= block.timestamp) revert InvalidStart();
    firstRoundStart = newStart;
    emit FirstRoundStartUpdated(newStart);
  }

  /// @inheritdoc ILinkContest
  function setPaused(
    bool paused_
  ) external override onlyOwner {
    paused = paused_;
    emit PausedUpdated(paused_);
  }

  /// @inheritdoc ILinkContest
  function setFeeExempt(
    address[] calldata accounts,
    bool exempt
  ) external override onlyOwner {
    for (uint256 i; i < accounts.length; ++i) {
      feeExempt[accounts[i]] = exempt;
      emit FeeExemptUpdated(accounts[i], exempt);
    }
  }
}
