// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IFactory } from "./interfaces/IFactory.sol";
import { ITempl } from "./interfaces/ITempl.sol";
import { ITreasury } from "./interfaces/ITreasury.sol";
// Transient storage variant - saves ~2,100 gas per guarded call vs regular
// ReentrancyGuard on networks that support EIP-1153 (Cancun+).
import {
  ReentrancyGuardTransient
} from "solady/utils/ReentrancyGuardTransient.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @title Treasury
/// @notice Distributes entry fees: burn, treasury, member pool, protocol, referral.
///         Referral is carved from the member pool when a valid referrer exists.
///         Members claim their share of the pool via cumulative-snapshot accounting.
contract Treasury is ITreasury, ReentrancyGuardTransient {
  // ============ Constants ============

  uint256 internal constant BPS = 10_000;
  address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

  // ============ Set once in constructor ============
  // Not marked `immutable` so all instances share identical runtime bytecode,
  // enabling auto-verification on Etherscan/Sourcify after a single verified
  // deployment. Gas difference is negligible on L2s (~2100 gas cold SLOAD vs
  // 3 gas PUSH).
  //
  // TOKEN, FACTORY, and PROTOCOL_BPS have no setter - effectively immutable.
  // `templ` has setTempl(), a one-shot initializer callable only by FACTORY
  // (reverts after first call via AlreadyInitialized guard).

  address public override TOKEN;
  address public override FACTORY;
  uint256 public override PROTOCOL_BPS;
  address public override templ;

  // ============ State: fee config (mutable by governance) ============

  uint256 public override burnBps;
  uint256 public override treasuryBps;
  uint256 public override memberPoolBps;
  address public override burnAddress;
  uint256 public override referralShareBps;

  // ============ State: accounting ============

  uint256 public override memberPoolBalance;
  uint256 public override totalBurned;
  uint256 public override cumulativeMemberRewards;
  uint256 public override memberRewardRemainder;

  mapping(address => uint256) public override rewardSnapshot;
  mapping(address => uint256) public override memberPoolClaims;

  // ============ Modifiers ============

  modifier onlyTempl() {
    _checkTempl();
    _;
  }

  modifier onlyGovernance() {
    _checkGovernance();
    _;
  }

  // ============ Constructor ============

  /// @param _token ERC20 token used for all fee operations
  /// @param _protocolBps Protocol fee in bps (set once in constructor)
  /// @param _burnAddress Token burn destination (defaults to 0xdead if zero)
  /// @param _referralShareBps Referral's cut of the member pool in bps
  constructor(
    address _token,
    uint256 _protocolBps,
    address _burnAddress,
    uint256 _referralShareBps
  ) {
    if (_burnAddress == address(0)) _burnAddress = DEAD;
    if (_referralShareBps > BPS) revert InvalidSplit();

    FACTORY = msg.sender;
    TOKEN = _token;
    PROTOCOL_BPS = _protocolBps;
    burnAddress = _burnAddress;
    referralShareBps = _referralShareBps;

    // Fee splits (burnBps, treasuryBps, memberPoolBps) start at zero.
    // The Factory calls setFeeSplit() after TemplCreated to set them
    // in the same transaction.
  }

  // ============ Init ============

  /// @inheritdoc ITreasury
  function setTempl(
    address _templ
  ) external override {
    if (msg.sender != FACTORY) revert NotDeployer();
    if (templ != address(0)) revert AlreadyInitialized();
    if (_templ == address(0)) revert InvalidAddress();
    templ = _templ;
    emit TemplSet(_templ);
  }

  // ============ Views ============

  /// @inheritdoc ITreasury
  function getClaimableRewards(
    address member
  ) external view override returns (uint256) {
    if (!ITempl(templ).isMember(member)) return 0;
    uint256 snapshot = rewardSnapshot[member];
    return
      cumulativeMemberRewards > snapshot
        ? cumulativeMemberRewards - snapshot
        : 0;
  }

  // ============ Templ Actions ============

  /// @inheritdoc ITreasury
  /// @dev Distributes the entry fee in six steps: compute splits (burn, pool,
  ///      protocol, treasury), carve referral from the pool if valid, distribute
  ///      the remaining pool across existing members via cumulative-snapshot
  ///      accounting, set the new member's reward snapshot, update balance
  ///      trackers, and transfer burn/protocol/referral tokens out.
  function onJoin(
    uint256 fee,
    address member,
    address referral,
    uint256 existingMemberCount
  ) external override onlyTempl nonReentrant {
    // 1. Compute splits (treasury absorbs rounding dust)
    uint256 burnAmt = (fee * burnBps) / BPS;
    uint256 memberPoolAmt = (fee * memberPoolBps) / BPS;
    uint256 protocolAmt = (fee * PROTOCOL_BPS) / BPS;
    uint256 treasuryAmt = fee - burnAmt - memberPoolAmt - protocolAmt;

    // 2. Referral (takes from member pool)
    uint256 referralAmt;
    address referralTarget;
    if (referral != address(0) && referral != member && referralShareBps > 0) {
      if (ITempl(templ).isMember(referral)) {
        referralAmt = (memberPoolAmt * referralShareBps) / BPS;
        referralTarget = referral;
      }
    }

    uint256 distributablePool = memberPoolAmt - referralAmt;

    // 3. Distribute rewards to existing members
    if (existingMemberCount > 0) {
      uint256 totalRewards = distributablePool + memberRewardRemainder;
      uint256 perMember = totalRewards / existingMemberCount;
      memberRewardRemainder = totalRewards % existingMemberCount;
      cumulativeMemberRewards += perMember;
    }

    // 4. Set new member's snapshot (they don't earn from their own join)
    rewardSnapshot[member] = cumulativeMemberRewards;

    // 5. Update balances
    memberPoolBalance += distributablePool;
    if (burnAmt > 0) totalBurned += burnAmt;

    // 6. Transfer burn, protocol, referral
    if (burnAmt > 0) {
      SafeTransferLib.safeTransfer(TOKEN, burnAddress, burnAmt);
    }
    if (protocolAmt > 0) {
      SafeTransferLib.safeTransfer(
        TOKEN, IFactory(FACTORY).protocolFeeRecipient(), protocolAmt
      );
    }
    if (referralAmt > 0) {
      SafeTransferLib.safeTransfer(TOKEN, referralTarget, referralAmt);
      emit ReferralRewardPaid(templ, referralTarget, member, referralAmt);
    }

    emit FeesDistributed(
      templ,
      fee,
      burnAmt,
      treasuryAmt,
      memberPoolAmt,
      protocolAmt,
      referralTarget,
      referralAmt
    );
  }

  // ============ Member Actions ============

  /// @inheritdoc ITreasury
  /// @dev Anyone can trigger a claim on behalf of a member. Tokens always go
  ///      to the member address, never the caller.
  function claimRewards(
    address member
  ) external override nonReentrant {
    if (!ITempl(templ).isMember(member)) revert NotMember();

    uint256 snapshot = rewardSnapshot[member];
    uint256 claimable =
      cumulativeMemberRewards > snapshot
      ? cumulativeMemberRewards - snapshot
      : 0;
    if (claimable == 0) revert NoRewardsToClaim();

    uint256 distributable = memberPoolBalance - memberRewardRemainder;
    if (distributable < claimable) revert InsufficientPoolBalance();

    rewardSnapshot[member] = cumulativeMemberRewards;
    memberPoolClaims[member] += claimable;
    memberPoolBalance -= claimable;

    SafeTransferLib.safeTransfer(TOKEN, member, claimable);

    emit MemberRewardsClaimed(templ, member, claimable);
  }

  // ============ Governance ============

  /// @inheritdoc ITreasury
  /// @dev Withdraws `amount` from non-member-pool funds. The `available` check
  ///      guarantees the member pool is never touched within a single call:
  ///      after the transfer, remaining balance >= memberPoolBalance.
  ///      Caveat: negative-rebasing tokens shrink the real balance independently
  ///      of this contract's accounting, so memberPoolBalance can drift above the
  ///      actual token balance over time. Standard ERC-20 tokens are unaffected.
  function withdraw(
    address recipient,
    uint256 amount
  ) external override onlyGovernance nonReentrant {
    if (recipient == address(0)) revert InvalidAddress();
    if (amount == 0) revert AmountZero();
    uint256 available = _availableTreasury();
    if (amount > available) revert InsufficientTreasuryBalance();

    SafeTransferLib.safeTransfer(TOKEN, recipient, amount);

    emit TreasuryWithdrawn(templ, recipient, amount);
  }

  /// @inheritdoc ITreasury
  /// @dev Moves all non-member-pool funds into the member pool, distributing
  ///      equally among all members via cumulative-snapshot accounting.
  ///      After this call: _tokenBalance() == memberPoolBalance.
  function dissolve() external override onlyGovernance nonReentrant {
    uint256 activeMemberCount = ITempl(templ).memberCount();
    if (activeMemberCount == 0) revert AmountZero();

    uint256 available = _availableTreasury();
    if (available == 0) revert InsufficientTreasuryBalance();

    memberPoolBalance += available;

    uint256 totalRewards = available + memberRewardRemainder;
    uint256 perMember = totalRewards / activeMemberCount;
    memberRewardRemainder = totalRewards % activeMemberCount;
    cumulativeMemberRewards += perMember;

    emit TreasuryDissolved(
      templ, available, perMember, activeMemberCount, memberRewardRemainder
    );
  }

  /// @inheritdoc ITreasury
  function setFeeSplit(
    uint256 _burnBps,
    uint256 _treasuryBps,
    uint256 _memberPoolBps
  ) external override {
    // Factory calls this once during creation to emit the initial
    // FeeSplitUpdated event after TemplCreated. Governance can call
    // it later to change splits.
    if (msg.sender != FACTORY) _checkGovernance();
    _setFeeSplit(_burnBps, _treasuryBps, _memberPoolBps);
  }

  /// @inheritdoc ITreasury
  function setBurnAddress(
    address _burnAddress
  ) external override onlyGovernance {
    if (_burnAddress == address(0)) revert InvalidAddress();
    burnAddress = _burnAddress;
    emit BurnAddressUpdated(templ, _burnAddress);
  }

  /// @inheritdoc ITreasury
  function setReferralShareBps(
    uint256 _bps
  ) external override onlyGovernance {
    if (_bps > BPS) revert InvalidSplit();
    referralShareBps = _bps;
    emit ReferralShareBpsUpdated(templ, _bps);
  }

  /// @inheritdoc ITreasury
  /// @dev Sends dust left from integer division in reward distribution.
  ///      Useful for recovering small amounts that can't be evenly split.
  function sweepRemainder(
    address recipient
  ) external override onlyGovernance nonReentrant {
    if (recipient == address(0)) revert InvalidAddress();
    uint256 remainder = memberRewardRemainder;
    if (remainder == 0) revert NoRewardsToClaim();
    if (remainder > memberPoolBalance) revert InsufficientPoolBalance();

    memberRewardRemainder = 0;
    memberPoolBalance -= remainder;

    SafeTransferLib.safeTransfer(TOKEN, recipient, remainder);

    emit MemberPoolRemainderSwept(templ, recipient, remainder);
  }

  /// @inheritdoc ITreasury
  function treasuryBalance() external view override returns (uint256) {
    return _availableTreasury();
  }

  // ============ Internal ============

  function _availableTreasury() internal view returns (uint256) {
    uint256 balance = _tokenBalance();
    return balance > memberPoolBalance ? balance - memberPoolBalance : 0;
  }

  function _setFeeSplit(
    uint256 _burnBps,
    uint256 _treasuryBps,
    uint256 _memberPoolBps
  ) internal {
    if (_burnBps + _treasuryBps + _memberPoolBps + PROTOCOL_BPS != BPS) {
      revert InvalidSplit();
    }
    burnBps = _burnBps;
    treasuryBps = _treasuryBps;
    memberPoolBps = _memberPoolBps;
    emit FeeSplitUpdated(templ, _burnBps, _treasuryBps, _memberPoolBps);
  }

  function _checkTempl() internal view {
    if (msg.sender != templ) revert NotTempl();
  }

  function _checkGovernance() internal view {
    if (msg.sender != ITempl(templ).governance()) revert NotGovernance();
  }

  function _tokenBalance() internal view returns (uint256) {
    return SafeTransferLib.balanceOf(TOKEN, address(this));
  }
}
