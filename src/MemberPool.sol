// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IMemberPool } from "./interfaces/IMemberPool.sol";
import { ITempl } from "./interfaces/ITempl.sol";
// Transient storage variant - saves ~2,100 gas per guarded call vs regular
// ReentrancyGuard on networks that support EIP-1153 (Cancun+).
import {
  ReentrancyGuardTransient
} from "solady/utils/ReentrancyGuardTransient.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @title MemberPool
/// @notice Holds the user-claimable share of every paid join.
/// @dev Topology guarantee: this contract never holds non-pool funds and has no
///      governance-callable function. The only TOKEN outflow is `claimRewards`,
///      callable by anyone but always paying the member. There is no
///      `withdraw`, no `delegatecall`, no `fallback`, no `receive`. Stranded
///      ETH and non-TOKEN ERC-20 sent here are stuck forever by design - the
///      no-admin guarantee is the structural safety property the contract
///      exists for. Pool dust accumulating in `rewardRemainder` on
///      terminal-state templs (no future paid joins) is also stranded by the
///      same property: stranding is the price of having no admin.
///
///      Solvency invariant (defense in depth): every state transition preserves
///      `IERC20(TOKEN).balanceOf(this) >= totalDeposited - totalClaimed`. Direct
///      transfers (donations, Treasury.dissolve) only push the inequality
///      strictly above; the next paid join's `onJoin` re-measures balance and
///      folds the delta into that round's distribution.
contract MemberPool is IMemberPool, ReentrancyGuardTransient {
  // ============ Set once in constructor / one-shot init ============
  // Not marked `immutable` so all instances share identical runtime bytecode,
  // enabling auto-verification on Etherscan/Sourcify after a single verified
  // deployment.
  //
  // TOKEN and FACTORY have no setter and are effectively immutable. TEMPL and
  // TREASURY each have a one-shot initializer callable only by FACTORY
  // (reverts after first call via AlreadyInitialized) and are also effectively
  // immutable once wired. SCREAMING_SNAKE_CASE signals that intent at the call
  // site. The lint exemption is scoped to this block alone.

  // forge-lint: disable-start(mixed-case-variable)
  address public override TOKEN;
  address public override FACTORY;
  address public override TEMPL;
  address public override TREASURY;
  // forge-lint: disable-end(mixed-case-variable)

  // ============ State: snapshot accounting ============

  uint256 public override cumulativeRewards;
  uint256 public override rewardRemainder;
  uint256 public override totalDeposited;
  uint256 public override totalClaimed;

  mapping(address => uint256) public override rewardSnapshot;
  mapping(address => uint256) public override claims;

  // ============ Modifiers ============

  modifier onlyTempl() {
    if (msg.sender != TEMPL) revert NotTempl();
    _;
  }

  // ============ Constructor ============

  /// @param _token ERC20 token used for member rewards
  constructor(
    address _token
  ) {
    if (_token == address(0)) revert ZeroToken();
    FACTORY = msg.sender;
    TOKEN = _token;
  }

  // ============ Init ============

  /// @inheritdoc IMemberPool
  function setTempl(
    address _templ
  ) external override {
    if (msg.sender != FACTORY) revert NotDeployer();
    if (TEMPL != address(0)) revert AlreadyInitialized();
    if (_templ == address(0)) revert ZeroTempl();
    TEMPL = _templ;
    emit TemplSet(_templ);
  }

  /// @inheritdoc IMemberPool
  function setTreasury(
    address _treasury
  ) external override {
    if (msg.sender != FACTORY) revert NotDeployer();
    if (TREASURY != address(0)) revert AlreadyInitialized();
    if (_treasury == address(0)) revert ZeroTreasury();
    TREASURY = _treasury;
    emit TreasurySet(_treasury);
  }

  // ============ Views ============

  /// @inheritdoc IMemberPool
  function getClaimableRewards(
    address member
  ) external view override returns (uint256) {
    if (!ITempl(TEMPL).isMember(member)) return 0;
    uint256 snapshot = rewardSnapshot[member];
    return cumulativeRewards > snapshot ? cumulativeRewards - snapshot : 0;
  }

  // ============ Templ Actions ============

  /// @inheritdoc IMemberPool
  /// @dev Templ has already transferred `deliveredAmount` into this contract
  ///      before calling. Re-measure balance to detect any unaccounted delta
  ///      (e.g. a direct transfer from Treasury.dissolve) and fold it into this
  ///      round's distribution.
  function onJoin(
    uint256 deliveredAmount,
    address newMember,
    uint256 existingMemberCount
  ) external override onlyTempl nonReentrant {
    _accrue(deliveredAmount, existingMemberCount);

    // Snapshot the new member AFTER distribution. They earn from the next
    // paid join, not their own.
    rewardSnapshot[newMember] = cumulativeRewards;

    emit MemberJoined(TEMPL, newMember, deliveredAmount, existingMemberCount);
  }

  /// @inheritdoc IMemberPool
  function accrue() external override nonReentrant {
    uint256 memberCount = ITempl(TEMPL).memberCount();
    uint256 absorbed = _accrue(0, memberCount);
    emit RewardsAccrued(TEMPL, absorbed, memberCount);
  }

  // ============ Internal ============

  /// @dev Re-measures balance, treats any excess over the accounted state plus
  ///      the just-arrived `deliveredAmount` as an absorbed delta, and folds
  ///      `deliveredAmount + absorbed + rewardRemainder` into a per-member
  ///      increment of `cumulativeRewards`. Dust from integer division carries
  ///      forward in `rewardRemainder`. Reverts if `denominator == 0` (priest
  ///      is always member 1, so this is unreachable in practice and documents
  ///      the invariant) or if balance is below the accounted state plus
  ///      delivery (fee-on-transfer guard).
  function _accrue(
    uint256 deliveredAmount,
    uint256 denominator
  ) internal returns (uint256 absorbed) {
    if (denominator == 0) revert NoExistingMembers();

    uint256 actual = SafeTransferLib.balanceOf(TOKEN, address(this));
    uint256 expectedAfter = totalDeposited - totalClaimed + deliveredAmount;
    if (actual < expectedAfter) revert AmountMismatch();
    absorbed = actual - expectedAfter;

    uint256 effective = deliveredAmount + absorbed;
    uint256 totalRewards = effective + rewardRemainder;
    uint256 perMember = totalRewards / denominator;
    cumulativeRewards += perMember;
    rewardRemainder = totalRewards - (perMember * denominator);
    totalDeposited += effective;
  }

  // ============ Member Actions ============

  /// @inheritdoc IMemberPool
  /// @dev Permissionless: anyone can trigger a claim on behalf of a member.
  ///      Tokens always go to `member`, never the caller. CEI ordering plus
  ///      nonReentrant plus a local copy of `cumulativeRewards` block reentrancy
  ///      and double-spend.
  function claimRewards(
    address member
  ) external override nonReentrant {
    if (!ITempl(TEMPL).isMember(member)) revert NotMember();

    uint256 cumulative = cumulativeRewards;
    uint256 snapshot = rewardSnapshot[member];
    if (snapshot >= cumulative) revert NoRewardsToClaim();

    uint256 amount = cumulative - snapshot;

    // CEI: writes before transfer.
    rewardSnapshot[member] = cumulative;
    claims[member] += amount;
    totalClaimed += amount;

    SafeTransferLib.safeTransfer(TOKEN, member, amount);

    emit MemberRewardsClaimed(TEMPL, member, amount);
  }
}
