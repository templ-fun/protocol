// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Executable } from "./abstracts/Executable.sol";
import { IERC2612 } from "./interfaces/IERC2612.sol";
import { IFactory } from "./interfaces/IFactory.sol";
import { IGovernance } from "./interfaces/IGovernance.sol";
import { IMemberPool } from "./interfaces/IMemberPool.sol";
import { ITempl } from "./interfaces/ITempl.sol";
import { ITreasury } from "./interfaces/ITreasury.sol";
import { CurveConfig, EntryFeeCurve } from "./libraries/EntryFeeCurve.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @title Templ
/// @notice Membership contract - pay entry fee, become member.
/// @dev Templ is the splitter. Each paid join pulls the fee into this contract,
///      reads the current split BPS from local storage, and forwards each
///      slice directly to its destination (burnAddress, treasury, memberPool,
///      protocolFeeRecipient, optional referral). The member-pool slice is
///      forwarded first and MemberPool.onJoin is invoked immediately so the
///      new member's rewardSnapshot is pinned to cumulativeRewards BEFORE any
///      other transfer fires - this defeats the cross-contract reentrancy in
///      which a hook-bearing TOKEN's later transfer would reenter
///      MemberPool.claimRewards against the freshly-registered member while
///      their snapshot was still zero. Free-to-join consideration: when
///      entryFee is 0, any caller can register any recipient across all four
///      join methods - this is the design of free-to-join templs.
///
///      Templ owns the burn / treasury / member-pool / referral BPS knobs, the
///      burn destination, the immutable PROTOCOL_BPS, and the cumulative
///      `totalBurned` counter. Treasury is a minimal vault. Keeping the
///      splitting rules in one contract turns every per-join split read into a
///      local SLOAD.
contract Templ is ITempl, Executable {
  // ============ Constants ============

  uint256 internal constant BPS = 10_000;

  /// @dev Default destination for "burned" tokens when caller does not provide
  ///      one. Resolved in the constructor when `_burnAddress` is zero. Used by
  ///      the splitter as the literal transfer recipient for the burn slice.
  ///      The zero address is reserved by ERC-20 transfer semantics, so a
  ///      visible dead address is the convention.
  address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

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
  // deployment. No setter; effectively immutable. SCREAMING_SNAKE_CASE signals
  // that intent at the call site. The lint exemption is scoped to this block.

  // forge-lint: disable-start(mixed-case-variable)
  address public override TOKEN;
  ITreasury public override TREASURY;
  IMemberPool public override MEMBER_POOL;
  /// @inheritdoc ITempl
  uint256 public override PROTOCOL_BPS;
  // forge-lint: disable-end(mixed-case-variable)

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

  // ============ Split config ============
  // burnBps + treasuryBps + memberPoolBps + PROTOCOL_BPS must always equal
  // BPS; _setFeeSplit enforces this on every update.

  /// @inheritdoc ITempl
  uint256 public override burnBps;
  /// @inheritdoc ITempl
  uint256 public override treasuryBps;
  /// @inheritdoc ITempl
  uint256 public override memberPoolBps;
  /// @inheritdoc ITempl
  address public override burnAddress;
  /// @inheritdoc ITempl
  uint256 public override referralShareBps;
  /// @inheritdoc ITempl
  uint256 public override totalBurned;

  // ============ Constructor ============

  /// @param _priest Initial priest (admin) and first member
  /// @param _token ERC20 token used for entry fees and rewards
  /// @param _baseEntryFee Starting entry fee before curve adjustments
  /// @param _curve Entry fee curve config (growth segments applied on top of base fee)
  /// @param _treasury Treasury contract that holds the treasury slice
  /// @param _memberPool MemberPool contract that holds member rewards
  /// @param _governance Initial governance address (Factory passes itself, then hands off)
  /// @param _protocolBps Protocol fee share in basis points (effectively immutable;
  ///        no setter). Stored as `PROTOCOL_BPS` and treated as the fixed share
  ///        of every paid join that flows to the protocol fee recipient. The
  ///        remaining `BPS - _protocolBps` is partitioned across burn, treasury,
  ///        and member-pool by `setFeeSplit`.
  /// @param _burnAddress Initial burn destination. When zero, the constructor
  ///        falls back to `DEAD` so the splitter always has a valid recipient.
  constructor(
    address _priest,
    address _token,
    uint256 _baseEntryFee,
    CurveConfig memory _curve,
    address _treasury,
    address _memberPool,
    address _governance,
    uint256 _protocolBps,
    address _burnAddress
  ) {
    priest = _priest;
    governance = _governance;
    TOKEN = _token;
    baseEntryFee = _baseEntryFee;
    TREASURY = ITreasury(_treasury);
    MEMBER_POOL = IMemberPool(_memberPool);
    PROTOCOL_BPS = _protocolBps;

    // Resolve the default burn destination here so callers (Factory, tests)
    // can pass zero and get a valid recipient without an extra setter call.
    burnAddress = _burnAddress == address(0) ? DEAD : _burnAddress;

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
    uint256 delivered;
    if (fee > 0) {
      uint256 before = SafeTransferLib.balanceOf(TOKEN, address(this));
      SafeTransferLib.safeTransferFrom(TOKEN, msg.sender, address(this), fee);
      delivered = SafeTransferLib.balanceOf(TOKEN, address(this)) - before;
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
    uint256 delivered;
    if (fee > 0) {
      // Set allowance from msg.sender to this contract via ERC-2612 permit.
      // Allowance is consumed immediately by safeTransferFrom below,
      // so no residual approval remains after the call.
      IERC2612(TOKEN).permit(msg.sender, address(this), fee, deadline, v, r, s);

      uint256 before = SafeTransferLib.balanceOf(TOKEN, address(this));
      SafeTransferLib.safeTransferFrom(TOKEN, msg.sender, address(this), fee);
      delivered = SafeTransferLib.balanceOf(TOKEN, address(this)) - before;
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
    uint256 delivered;
    if (fee > 0) {
      if (permit.permitted.token != TOKEN) revert WrongToken();

      uint256 before = SafeTransferLib.balanceOf(TOKEN, address(this));
      PERMIT2.permitTransferFrom(
        permit,
        ISignatureTransfer.SignatureTransferDetails({
          to: address(this), requestedAmount: fee
        }),
        msg.sender,
        signature
      );
      delivered = SafeTransferLib.balanceOf(TOKEN, address(this)) - before;
    }

    _processJoin(recipient, msg.sender, referral, delivered, fee);
  }

  /// @inheritdoc ITempl
  /// @dev When entryFee is 0 and intent.relayerTip is 0, permit/signature/witness
  ///      parameters are ignored and the function behaves like plain join() -
  ///      any caller can register any recipient. When relayerTip > 0, the
  ///      witness signature is still verified so the payer authorises the tip.
  function joinWithPermit2Witness(
    address payer,
    ISignatureTransfer.PermitTransferFrom calldata permit,
    bytes calldata signature,
    JoinIntent calldata intent
  ) external override nonReentrant {
    _validateJoin(intent.recipient);

    uint256 fee = entryFee;
    uint256 delivered;

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
      delivered = received - payableTip;

      if (payableTip > 0) {
        SafeTransferLib.safeTransfer(TOKEN, msg.sender, payableTip);
      }
    }

    _processJoin(intent.recipient, payer, intent.referral, delivered, fee);
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
    // config events in the same tx. `governance` still holds the old pointer
    // here because the storage write below is deferred until after emitConfig
    // returns; passing it as oldGovernance lets indexers retire stale rows
    // (e.g. CouncilMember entries) without a lookup.
    emit GovernanceUpdated(governance, _governance);
    IGovernance(_governance).emitConfig();

    // Storage write is deferred until after emitConfig() returns. Treasury and
    // MemberPool read `Templ.governance()` dynamically in their own
    // _checkGovernance, so writing here before the callback would let a
    // malicious new governance call governance-only functions on those
    // contracts from inside emitConfig and bypass the intended ordering.
    governance = _governance;
  }

  // ============ Governance ============

  /// @inheritdoc ITempl
  function setBaseEntryFee(
    uint256 _baseEntryFee
  ) external override onlyGovernance {
    EntryFeeCurve.validateBaseFee(_baseEntryFee);
    baseEntryFee = _baseEntryFee;
    emit BaseEntryFeeUpdated(address(this), _baseEntryFee);
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

  /// @inheritdoc ITempl
  /// @dev PROTOCOL_BPS is excluded from the triple because it is set once in
  ///      the constructor and not adjustable. _setFeeSplit enforces that the
  ///      caller-supplied triple plus PROTOCOL_BPS sums to BPS, so the
  ///      protocol slice is preserved across every governance update.
  function setFeeSplit(
    uint256 burnBpsValue,
    uint256 treasuryBpsValue,
    uint256 memberPoolBpsValue
  ) external override onlyGovernance {
    _setFeeSplit(burnBpsValue, treasuryBpsValue, memberPoolBpsValue);
  }

  /// @inheritdoc ITempl
  function setBurnAddress(
    address burnAddressValue
  ) external override onlyGovernance {
    if (burnAddressValue == address(0)) revert ZeroBurnAddress();
    burnAddress = burnAddressValue;
    emit BurnAddressUpdated(address(this), burnAddressValue);
  }

  /// @inheritdoc ITempl
  function setReferralShareBps(
    uint256 bps
  ) external override onlyGovernance {
    if (bps > BPS) revert InvalidSplit();
    referralShareBps = bps;
    emit ReferralShareBpsUpdated(address(this), bps);
  }

  // ============ Internal ============

  /// @dev Validates the triple, writes storage, and emits FeeSplitUpdated.
  ///      Used by both the bootstrap path (Factory calls setFeeSplit right
  ///      after deploy) and ongoing governance updates. The triple plus
  ///      PROTOCOL_BPS must sum exactly to BPS (10_000).
  function _setFeeSplit(
    uint256 burnBpsValue,
    uint256 treasuryBpsValue,
    uint256 memberPoolBpsValue
  ) internal {
    if (
      burnBpsValue + treasuryBpsValue + memberPoolBpsValue + PROTOCOL_BPS != BPS
    ) revert InvalidSplit();
    burnBps = burnBpsValue;
    treasuryBps = treasuryBpsValue;
    memberPoolBps = memberPoolBpsValue;
    emit FeeSplitUpdated(
      address(this), burnBpsValue, treasuryBpsValue, memberPoolBpsValue
    );
  }

  function _validateJoin(
    address recipient
  ) internal view {
    if (joinPaused) revert JoinsPaused();
    if (recipient == address(0)) revert RecipientIsRequired();
    if (members[recipient].id != 0) revert AlreadyMember();
  }

  /// @dev Record the new member, split the fee across the five destinations,
  ///      notify MemberPool for accounting, and recompute entryFee.
  /// @param member Address receiving the membership
  /// @param payer Address that paid the entry fee (may differ from member)
  /// @param referral Referral address (zero if none)
  /// @param deliveredFee Amount that actually arrived at this contract (measured delta)
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

    // Emit MemberJoined first so indexers create the Member entity before
    // FeesDistributed and ReferralRewardPaid events arrive.
    emit MemberJoined(member, payer, deliveredFee, block.timestamp);

    if (deliveredFee > 0) {
      // Snapshot-before-transfer: _splitAndForward sends the member-pool slice
      // first and calls MEMBER_POOL.onJoin to pin rewardSnapshot[member] to
      // cumulativeRewards BEFORE any other transfer. A hook-bearing TOKEN
      // reentering MemberPool.claimRewards from a later burn/treasury/protocol/
      // referral transfer will see snapshot == cumulative and revert with
      // NoRewardsToClaim. See _splitAndForward NatSpec for the rationale.
      _splitAndForward(member, referral, deliveredFee, existingCount);
    } else {
      // Free-join: no fee distribution, but still notify MemberPool so the new
      // member's snapshot tracks cumulativeRewards. existingCount carries any
      // stranded rewardRemainder forward to existing members.
      MEMBER_POOL.onJoin(0, member, uint256(existingCount));
    }

    _refreshEntryFee();
  }

  /// @dev Read the BPS knobs from local storage once, compute the five
  ///      amounts (treasury absorbs rounding dust), forward the member-pool
  ///      slice to MemberPool and call onJoin to pin the new member's
  ///      snapshot, then forward the remaining slices. Emits FeesDistributed
  ///      and (if applicable) ReferralRewardPaid for indexer continuity.
  ///
  ///      `totalBurned` is updated inline. The protocol fee recipient is the
  ///      one piece of state that lives off-contract: it is read from Factory
  ///      via Treasury's FACTORY pointer, which keeps Templ from needing its
  ///      own factory reference.
  ///
  ///      Snapshot-before-transfer ordering: the MemberPool transfer + onJoin
  ///      call MUST happen before any other external transfer. Any of the
  ///      other recipients (burn, treasury, protocol, referral) could be a
  ///      contract whose token receive hook reenters MemberPool.claimRewards
  ///      against the new member. By pinning rewardSnapshot[newMember] to
  ///      cumulativeRewards in the first external call, we guarantee
  ///      snapshot >= cumulative for the new member at the moment any later
  ///      hook fires, so any reentrant claim reverts with NoRewardsToClaim.
  ///      The fee is fully owned by Templ at this point (already pulled via
  ///      transferFrom), so the order of forwarding does not affect solvency.
  function _splitAndForward(
    address member,
    address referral,
    uint256 fee,
    uint64 existingCount
  ) internal {
    ITreasury treasury = TREASURY;
    address burnDest = burnAddress;
    uint256 burnBps_ = burnBps;
    uint256 memberPoolBps_ = memberPoolBps;
    uint256 protocolBps_ = PROTOCOL_BPS;
    uint256 referralShareBps_ = referralShareBps;

    uint256 burnAmt = (fee * burnBps_) / BPS;
    uint256 memberPoolAmt = (fee * memberPoolBps_) / BPS;
    uint256 protocolAmt = (fee * protocolBps_) / BPS;
    // Treasury absorbs rounding dust from integer division.
    uint256 treasuryAmt = fee - burnAmt - memberPoolAmt - protocolAmt;

    // Carve referral from the member-pool slice when valid.
    uint256 referralAmt;
    address referralTarget;
    if (
      referral != address(0) && referral != member && referralShareBps_ > 0
        && members[referral].id != 0
    ) {
      referralAmt = (memberPoolAmt * referralShareBps_) / BPS;
      referralTarget = referral;
    }

    uint256 distributablePool = memberPoolAmt - referralAmt;

    // Step 1: forward the member-pool slice and notify MemberPool.
    //
    // This MUST run before any other transfer. onJoin pins
    // rewardSnapshot[member] to the post-distribution cumulativeRewards, so a
    // later hook-bearing transfer cannot reenter MemberPool.claimRewards and
    // drain accumulated rewards for `member`. onJoin is called even when
    // distributablePool == 0 (e.g. referralShareBps == 10000) so the snapshot
    // is still pinned.
    if (distributablePool > 0) {
      SafeTransferLib.safeTransfer(
        TOKEN, address(MEMBER_POOL), distributablePool
      );
    }
    MEMBER_POOL.onJoin(distributablePool, member, uint256(existingCount));

    // Step 2: forward the remaining slices. Skip zero-amount transfers to save
    // gas and avoid surprising downstream contracts with no-op receive
    // callbacks. Any token receive hook on these recipients is now safe: the
    // new member's snapshot is already pinned, and Templ holds no other
    // member's rewards (those live in MemberPool, which has its own
    // nonReentrant guard on claimRewards).
    if (burnAmt > 0) {
      SafeTransferLib.safeTransfer(TOKEN, burnDest, burnAmt);
      totalBurned += burnAmt;
    }
    if (treasuryAmt > 0) {
      SafeTransferLib.safeTransfer(TOKEN, address(treasury), treasuryAmt);
    }
    if (protocolAmt > 0) {
      SafeTransferLib.safeTransfer(
        TOKEN, IFactory(treasury.FACTORY()).protocolFeeRecipient(), protocolAmt
      );
    }
    if (referralAmt > 0) {
      SafeTransferLib.safeTransfer(TOKEN, referralTarget, referralAmt);
      emit ReferralRewardPaid(
        address(this), referralTarget, member, referralAmt
      );
    }

    emit FeesDistributed(
      address(this),
      fee,
      burnAmt,
      treasuryAmt,
      memberPoolAmt,
      protocolAmt,
      referralTarget,
      referralAmt
    );
  }

  function _checkPriest() internal view {
    if (msg.sender != priest) revert NotPriest();
  }

  function _checkGovernance() internal view override {
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
    emit EntryFeeUpdated(address(this), entryFee);
  }
}
