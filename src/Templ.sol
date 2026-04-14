// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC2612 } from "./interfaces/IERC2612.sol";
import { IGovernance } from "./interfaces/IGovernance.sol";
import { ITempl } from "./interfaces/ITempl.sol";
import { ITreasury } from "./interfaces/ITreasury.sol";
import { CurveConfig, EntryFeeCurve } from "./libraries/EntryFeeCurve.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
// Transient storage variant - saves ~2,100 gas per guarded call on mainnet
import {
  ReentrancyGuardTransient
} from "solady/utils/ReentrancyGuardTransient.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @title Templ
/// @notice Membership contract - pay entry fee, become member.
///         Fee distribution delegated to Treasury.
/// @dev Free-to-join spam consideration: when entryFee is 0, any caller can
///      register any recipient across all four join methods (plain join() and
///      the three permit variants skip signature/permit verification when fee
///      is 0). The AlreadyMember guard limits the blast radius to one entry
///      per address, but a griefer can still inflate memberCount or force
///      unaware addresses into a templ for only the cost of gas. Creators who
///      want self-paid joins only should set a non-zero baseEntryFee. Tracked
///      for post-launch evaluation in templ-fun/templ.fun#154.
contract Templ is ITempl, ReentrancyGuardTransient {
  // ============ Constants ============

  ISignatureTransfer public constant PERMIT2 =
    ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

  /// @dev EIP-712 typehash for JoinIntent witness data
  bytes32 internal constant JOIN_INTENT_TYPEHASH = keccak256(
    "JoinIntent(address recipient,address referral,uint256 relayerTip)"
  );

  /// @dev Witness type string for Permit2. Follows EIP-712 alphabetical ordering:
  ///      closing paren of parent type, then witness type, then TokenPermissions.
  string internal constant WITNESS_TYPE_STRING = "JoinIntent witness)"
    "JoinIntent(address recipient,address referral,uint256 relayerTip)"
    "TokenPermissions(address token,uint256 amount)";

  // ============ Set once in constructor ============
  // Not marked `immutable` so all instances share identical runtime bytecode,
  // enabling auto-verification on Etherscan/Sourcify after a single verified
  // deployment. Gas difference is negligible on L2s (~2100 gas cold SLOAD vs
  // 3 gas PUSH). No setter exists; value is effectively immutable.

  address public override TOKEN;
  ITreasury public override TREASURY;

  // ============ State ============

  address public override priest;
  address public override governance;
  uint256 public override entryFee;
  uint256 public override baseEntryFee;
  uint64 public override memberCount;
  bool public override joinPaused;
  bool private _priestJoinAnnounced; // one-time guard for emitPriestJoin
  CurveConfig internal entryFeeCurve;
  mapping(address => Member) public override members;

  // ============ Constructor ============

  /// @param _priest Initial priest (admin) and first member
  /// @param _token ERC20 token used for entry fees and rewards
  /// @param _baseEntryFee Starting entry fee before curve adjustments
  /// @param _curve Entry fee curve config (growth segments applied on top of base fee)
  /// @param _treasury Treasury contract that handles fee distribution
  /// @param _governance Initial governance address (Factory passes itself, then hands off)
  constructor(
    address _priest,
    address _token,
    uint256 _baseEntryFee,
    CurveConfig memory _curve,
    address _treasury,
    address _governance
  ) {
    priest = _priest;
    governance = _governance;
    TOKEN = _token;
    baseEntryFee = _baseEntryFee;
    TREASURY = ITreasury(_treasury);

    // Store curve config
    entryFeeCurve.primary = _curve.primary;
    uint256 len = _curve.additionalSegments.length;
    for (uint256 i; i < len; ++i) {
      entryFeeCurve.additionalSegments.push(_curve.additionalSegments[i]);
    }

    entryFee = _baseEntryFee;

    // Priest is member #1 (free). MemberJoined is emitted later by
    // emitPriestJoin() so indexers see TemplCreated before the join event.
    members[_priest] =
      Member({ id: ++memberCount, joinedAt: uint64(block.timestamp) });
  }

  // ============ Modifiers ============

  modifier onlyPriest() {
    _checkPriest();
    _;
  }

  modifier onlyGovernance() {
    _checkGovernance();
    _;
  }

  // ============ Views ============

  /// @inheritdoc ITempl
  function isMember(
    address account
  ) external view override returns (bool) {
    return members[account].id != 0;
  }

  /// @inheritdoc ITempl
  function paidJoins() external view override returns (uint256) {
    return memberCount > 1 ? uint256(memberCount) - 1 : 0;
  }

  // ============ Join ============

  /// @inheritdoc ITempl
  function join(
    address recipient,
    address referral
  ) external override nonReentrant {
    _validateJoin(recipient);
    uint256 fee = entryFee;
    // Measure the actual Treasury delta to detect fee-on-transfer tokens.
    // If delivered != fee, _processJoin reverts with FeeTokenMismatch.
    uint256 delivered;
    if (fee > 0) {
      uint256 before = SafeTransferLib.balanceOf(TOKEN, address(TREASURY));
      SafeTransferLib.safeTransferFrom(
        TOKEN, msg.sender, address(TREASURY), fee
      );
      delivered = SafeTransferLib.balanceOf(TOKEN, address(TREASURY)) - before;
    }
    _processJoin(recipient, msg.sender, referral, delivered, fee);
  }

  /// @inheritdoc ITempl
  /// @dev When entryFee is 0, permit/signature parameters are ignored and the
  ///      function behaves like plain join() - any caller can register any
  ///      recipient. This matches the design of free-to-join Templs.
  function joinWithERC2612Permit(
    address recipient,
    address referral,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external override nonReentrant {
    _validateJoin(recipient);

    uint256 fee = entryFee;

    // Measure the actual Treasury delta to detect fee-on-transfer tokens.
    uint256 delivered;
    if (fee > 0) {
      // Set allowance from msg.sender to this contract via ERC-2612 permit.
      // Allowance is consumed immediately by safeTransferFrom below,
      // so no residual approval remains after the call.
      IERC2612(TOKEN).permit(msg.sender, address(this), fee, deadline, v, r, s);

      uint256 before = SafeTransferLib.balanceOf(TOKEN, address(TREASURY));
      SafeTransferLib.safeTransferFrom(
        TOKEN, msg.sender, address(TREASURY), fee
      );
      delivered = SafeTransferLib.balanceOf(TOKEN, address(TREASURY)) - before;
    }

    _processJoin(recipient, msg.sender, referral, delivered, fee);
  }

  /// @inheritdoc ITempl
  /// @dev When entryFee is 0, permit/signature parameters are ignored and the
  ///      function behaves like plain join() - any caller can register any
  ///      recipient. This matches the design of free-to-join Templs.
  function joinWithPermit2(
    address recipient,
    address referral,
    ISignatureTransfer.PermitTransferFrom calldata permit,
    bytes calldata signature
  ) external override nonReentrant {
    _validateJoin(recipient);

    uint256 fee = entryFee;
    // Measure the actual Treasury delta to detect fee-on-transfer tokens.
    uint256 delivered;
    if (fee > 0) {
      if (permit.permitted.token != TOKEN) revert WrongToken();

      uint256 before = SafeTransferLib.balanceOf(TOKEN, address(TREASURY));
      PERMIT2.permitTransferFrom(
        permit,
        ISignatureTransfer.SignatureTransferDetails({
          to: address(TREASURY), requestedAmount: fee
        }),
        msg.sender,
        signature
      );
      delivered = SafeTransferLib.balanceOf(TOKEN, address(TREASURY)) - before;
    }

    _processJoin(recipient, msg.sender, referral, delivered, fee);
  }

  /// @inheritdoc ITempl
  /// @dev When entryFee is 0 and intent.relayerTip is 0, permit/signature/witness
  ///      parameters are ignored and the function behaves like plain join() -
  ///      any caller can register any recipient. This matches the design of
  ///      free-to-join Templs. When relayerTip > 0, the witness signature is
  ///      still verified so the payer authorises the tip payment.
  function joinWithPermit2Witness(
    address payer,
    ISignatureTransfer.PermitTransferFrom calldata permit,
    bytes calldata signature,
    JoinIntent calldata intent
  ) external override nonReentrant {
    _validateJoin(intent.recipient);

    uint256 fee = entryFee;
    // Measure the actual Treasury delta to detect fee-on-transfer tokens.
    // This path pulls to address(this) first and then forwards to Treasury.
    uint256 deliveredFee;

    if (fee > 0 || intent.relayerTip > 0) {
      if (permit.permitted.token != TOKEN) revert WrongToken();

      uint256 totalAmount = fee + intent.relayerTip;

      bytes32 witness;
      {
        bytes memory encoded = abi.encode(
          JOIN_INTENT_TYPEHASH,
          intent.recipient,
          intent.referral,
          intent.relayerTip
        );
        assembly ("memory-safe") {
          witness := keccak256(add(encoded, 0x20), mload(encoded))
        }
      }

      uint256 selfBefore = SafeTransferLib.balanceOf(TOKEN, address(this));
      PERMIT2.permitWitnessTransferFrom(
        permit,
        ISignatureTransfer.SignatureTransferDetails({
          to: address(this), requestedAmount: totalAmount
        }),
        payer,
        witness,
        WITNESS_TYPE_STRING,
        signature
      );
      uint256 received =
        SafeTransferLib.balanceOf(TOKEN, address(this)) - selfBefore;

      uint256 payableTip =
        intent.relayerTip > received ? received : intent.relayerTip;
      uint256 feeToForward = received - payableTip;

      if (feeToForward > 0) {
        uint256 trBefore = SafeTransferLib.balanceOf(TOKEN, address(TREASURY));
        SafeTransferLib.safeTransfer(TOKEN, address(TREASURY), feeToForward);
        deliveredFee =
          SafeTransferLib.balanceOf(TOKEN, address(TREASURY)) - trBefore;
      }

      if (payableTip > 0) {
        SafeTransferLib.safeTransfer(TOKEN, msg.sender, payableTip);
      }
    }

    _processJoin(intent.recipient, payer, intent.referral, deliveredFee, fee);
  }

  // ============ Priest ============

  /// @inheritdoc ITempl
  function transferPriest(
    address newPriest
  ) external override onlyPriest {
    if (members[newPriest].id == 0) revert NotMember();
    address previousPriest = priest;
    priest = newPriest;
    emit PriestTransferred(previousPriest, newPriest);
  }

  /// @inheritdoc ITempl
  /// @dev Separate function because the constructor runs before Factory can
  ///      emit TemplCreated. Factory calls this after TemplCreated so indexers
  ///      see the Templ entity before the priest's MemberJoined event.
  function emitPriestJoin() external override onlyGovernance {
    if (_priestJoinAnnounced) revert AlreadyMember();
    _priestJoinAnnounced = true;
    emit MemberJoined(priest, address(0), 0, block.timestamp);
  }

  /// @inheritdoc ITempl
  function setGovernance(
    address _governance
  ) external override onlyGovernance nonReentrant {
    if (_governance == address(0)) revert RecipientIsRequired();

    // Emit GovernanceUpdated before calling emitConfig() so indexers that
    // dynamically register the new governance contract see its subsequent
    // config events in the same tx. Mirrors the Treasury.setFeeSplit call
    // Factory makes after TemplCreated.
    emit GovernanceUpdated(_governance);
    IGovernance(_governance).emitConfig();

    // Storage write is deferred until after emitConfig() returns. Treasury
    // reads `Templ.governance()` dynamically in its own _checkGovernance,
    // so writing here before the callback would let a malicious new
    // governance call Treasury.withdraw() from inside its own emitConfig
    // and drain the treasury in the same tx. The nonReentrant guard above
    // does not help because the attack path goes Templ -> Treasury, not
    // back into Templ.
    governance = _governance;
  }

  // ============ Governance ============

  /// @inheritdoc ITempl
  function setBaseEntryFee(
    uint256 _baseEntryFee
  ) external override onlyGovernance {
    EntryFeeCurve.validateBaseFee(_baseEntryFee);
    baseEntryFee = _baseEntryFee;
    _refreshEntryFee();
  }

  /// @inheritdoc ITempl
  function setJoinPaused(
    bool _paused
  ) external override onlyGovernance {
    joinPaused = _paused;
    emit JoinPausedUpdated(_paused);
  }

  /// @inheritdoc ITempl
  function updateMetadata(
    string calldata name,
    string calldata description,
    string calldata logoLink
  ) external override onlyGovernance {
    emit MetadataUpdated(name, description, logoLink);
  }

  // ============ Internal ============

  function _validateJoin(
    address recipient
  ) internal view {
    if (joinPaused) revert JoinsPaused();
    if (recipient == address(0)) revert RecipientIsRequired();
    if (members[recipient].id != 0) revert AlreadyMember();
  }

  /// @dev Process membership after payment is in the Treasury.
  ///      Records the member, distributes fees, and recalculates entry fee.
  /// @param member Address receiving the membership
  /// @param payer Address that paid the entry fee (may differ from member)
  /// @param referral Referral address (zero if none)
  /// @param deliveredFee Amount that actually arrived at the Treasury (measured delta)
  /// @param expectedFee Entry fee read before the transfer. Must match deliveredFee
  ///        exactly - any discrepancy (e.g. fee-on-transfer tax) reverts.
  function _processJoin(
    address member,
    address payer,
    address referral,
    uint256 deliveredFee,
    uint256 expectedFee
  ) internal {
    if (deliveredFee != expectedFee) revert FeeTokenMismatch();
    uint64 existingCount = memberCount;

    members[member] =
      Member({ id: ++memberCount, joinedAt: uint64(block.timestamp) });

    // Emit before Treasury.onJoin so indexers create the Member entity
    // before processing FeesDistributed / ReferralRewardPaid events.
    emit MemberJoined(member, payer, deliveredFee, block.timestamp);

    TREASURY.onJoin(deliveredFee, member, referral, uint256(existingCount));

    _refreshEntryFee();
  }

  function _checkPriest() internal view {
    if (msg.sender != priest) revert NotPriest();
  }

  function _checkGovernance() internal view {
    if (msg.sender != governance) revert NotGovernance();
  }

  /// @dev Recomputes entryFee from baseEntryFee and the curve at the current
  ///      paid join count. Called after every join and after setBaseEntryFee.
  ///      Safe from underflow: memberCount >= 1 (priest is always member #1).
  function _refreshEntryFee() internal {
    uint256 currentPaidJoins = uint256(memberCount) - 1;
    entryFee = EntryFeeCurve.normalize(
      EntryFeeCurve.priceAtJoinFromStorage(
        baseEntryFee, entryFeeCurve, currentPaidJoins
      )
    );
    emit EntryFeeUpdated(entryFee);
  }
}
