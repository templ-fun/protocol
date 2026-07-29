// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMemberPool
/// @notice Holds the user-claimable share of every paid join. Templ transfers
///         the member-pool slice in and immediately calls onJoin for accounting.
///         Members claim accumulated rewards via cumulative-snapshot accounting.
///         No governance-callable function exists: the only TOKEN outflow is
///         `claimRewards(member)`. Stranded ETH and non-TOKEN ERC-20 sent here
///         are stuck by design, and so is the rounding-dust `rewardRemainder`
///         on terminal-state templs - the no-admin invariant is the safety
///         property the contract exists for.
interface IMemberPool {
  // ============ Events ============

  /// @notice Emitted on every onJoin notification from Templ
  /// @param templ The linked Templ contract (immutable per pool)
  /// @param member The address that just joined
  /// @param deliveredAmount Tokens that arrived at the pool for this join
  /// @param existingMemberCount Members before this join (used for division)
  event MemberJoined(
    address indexed templ,
    address indexed member,
    uint256 deliveredAmount,
    uint256 existingMemberCount
  );

  /// @notice Emitted when a member claims their accumulated rewards
  event MemberRewardsClaimed(
    address indexed templ, address indexed member, uint256 amount
  );

  /// @notice Emitted on every accrue() call.
  /// @param templ The linked Templ contract (immutable per pool)
  /// @param absorbed Tokens picked up from the balance delta (donations,
  ///        Treasury.dissolve, etc.). May be zero when only `rewardRemainder`
  ///        is being folded forward.
  /// @param memberCount Members at the moment of distribution
  event RewardsAccrued(
    address indexed templ, uint256 absorbed, uint256 memberCount
  );

  /// @notice Emitted once when FACTORY links the pool to its Templ + Treasury
  event TemplSet(address indexed templ);
  event TreasurySet(address indexed treasury);

  // ============ Errors ============

  error NotTempl();
  error NotDeployer();
  error AlreadyInitialized();
  /// @notice Constructor was called with the zero address as TOKEN.
  error ZeroToken();
  /// @notice `setTempl` was called with the zero address.
  error ZeroTempl();
  /// @notice `setTreasury` was called with the zero address.
  error ZeroTreasury();
  error NotMember();
  error NoRewardsToClaim();
  error NoExistingMembers();
  error AmountMismatch();

  // ============ Views ============
  // SCREAMING_SNAKE_CASE marks "morally immutable" storage: TOKEN/FACTORY have
  // no setter, TEMPL/TREASURY each have a one-shot initializer that reverts
  // after first call. See MemberPool.sol storage block for the full rationale.

  /// @notice ERC20 token used for member rewards (same as Templ.TOKEN)
  function TOKEN() external view returns (address);

  /// @notice Factory that deployed this pool
  function FACTORY() external view returns (address);

  /// @notice The linked Templ membership contract
  function TEMPL() external view returns (address);

  /// @notice The linked Treasury contract (referenced for symmetry; pool does
  ///         not pull from Treasury directly - dissolve is a plain
  ///         ERC20.transfer).
  function TREASURY() external view returns (address);

  /// @notice Cumulative per-member reward counter used for snapshot accounting.
  ///         Monotonically non-decreasing.
  function cumulativeRewards() external view returns (uint256);

  /// @notice Leftover wei from integer division, carried into the next round
  function rewardRemainder() external view returns (uint256);

  /// @notice Running sum of every onJoin amount delivered to this pool.
  ///         Includes deltas folded in from direct transfers (e.g. dissolve).
  function totalDeposited() external view returns (uint256);

  /// @notice Running sum of every claim payout
  function totalClaimed() external view returns (uint256);

  /// @notice Snapshot of cumulativeRewards at the time a member joined or last claimed
  function rewardSnapshot(
    address member
  ) external view returns (uint256);

  /// @notice Total tokens a member has claimed over their lifetime
  function claims(
    address member
  ) external view returns (uint256);

  /// @notice Unclaimed reward balance for a member (returns 0 if not a member)
  function getClaimableRewards(
    address member
  ) external view returns (uint256);

  // ============ Init ============

  /// @notice One-time: connect the pool to its Templ contract
  /// @param _templ Address of the Templ membership contract
  function setTempl(
    address _templ
  ) external;

  /// @notice One-time: connect the pool to its Treasury contract
  /// @param _treasury Address of the Treasury contract
  function setTreasury(
    address _treasury
  ) external;

  // ============ Templ Actions ============

  /// @notice Called by Templ on every paid join, after the member-pool slice has
  ///         already been transferred into this contract.
  /// @dev Re-measures balanceOf(this) and folds any unaccounted delta (e.g. a
  ///      direct transfer from Treasury.dissolve) into the round's distribution.
  ///      Reverts if existingMemberCount == 0; the priest is always member 1 by
  ///      the time anyone else joins, so the zero branch is unreachable in
  ///      practice and the revert documents the invariant.
  /// @param deliveredAmount Member-pool slice that Templ transferred in just now
  /// @param newMember Address that just joined (snapshot is set after distribution)
  /// @param existingMemberCount Members before this join
  function onJoin(
    uint256 deliveredAmount,
    address newMember,
    uint256 existingMemberCount
  ) external;

  /// @notice Permissionless trigger that folds any unaccounted TOKEN balance
  ///         delta (e.g. tokens sent here by `Treasury.dissolve`) plus any
  ///         carried `rewardRemainder` into a per-member distribution among
  ///         the current Templ membership. Idempotent: a call with no delta
  ///         and no remainder leaves state unchanged.
  function accrue() external;

  // ============ Member Actions ============

  /// @notice Claim accumulated rewards for `member`. Anyone can trigger; tokens
  ///         always go to `member`, never the caller.
  function claimRewards(
    address member
  ) external;
}
