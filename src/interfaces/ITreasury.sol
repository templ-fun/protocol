// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITreasury
/// @notice Handles entry fee distribution: burn, treasury, member pool, protocol, referral.
///         Referral is carved from the member pool when a valid referrer exists.
interface ITreasury {
  // ============ Events ============

  event FeesDistributed(
    address indexed templ,
    uint256 fee,
    uint256 burn,
    uint256 treasury,
    uint256 memberPool,
    uint256 protocol,
    address indexed referrer,
    uint256 referral
  );

  event ReferralRewardPaid(
    address indexed templ,
    address indexed referrer,
    address indexed member,
    uint256 amount
  );

  event MemberRewardsClaimed(
    address indexed templ, address indexed member, uint256 amount
  );

  event TreasuryWithdrawn(
    address indexed templ, address indexed recipient, uint256 amount
  );

  event TreasuryDissolved(
    address indexed templ,
    uint256 amount,
    uint256 perMember,
    uint256 memberCount,
    uint256 remainder
  );

  event FeeSplitUpdated(
    address indexed templ,
    uint256 burnBps,
    uint256 treasuryBps,
    uint256 memberPoolBps
  );

  event BurnAddressUpdated(address indexed templ, address indexed burnAddress);
  event ReferralShareBpsUpdated(address indexed templ, uint256 bps);
  event MemberPoolRemainderSwept(
    address indexed templ, address indexed recipient, uint256 amount
  );
  event TemplSet(address indexed templ);

  // ============ Errors ============

  error NotTempl();
  error NotGovernance();
  error NotMember();
  error NotDeployer();
  error AlreadyInitialized();
  error InvalidSplit();
  error InvalidAddress();
  error NoRewardsToClaim();
  error InsufficientPoolBalance();
  error InsufficientTreasuryBalance();
  error AmountZero();

  // ============ Views ============

  /// @notice The linked Templ membership contract
  function templ() external view returns (address);

  /// @notice ERC20 token used for all fee operations
  function TOKEN() external view returns (address);

  /// @notice The Factory that deployed this Treasury
  function FACTORY() external view returns (address);

  /// @notice Protocol fee share in basis points (set once in constructor)
  function PROTOCOL_BPS() external view returns (uint256);

  /// @notice Burn share in basis points
  function burnBps() external view returns (uint256);

  /// @notice Treasury share in basis points
  function treasuryBps() external view returns (uint256);

  /// @notice Member pool share in basis points
  function memberPoolBps() external view returns (uint256);

  /// @notice Destination address for burned tokens
  function burnAddress() external view returns (address);

  /// @notice Referral's cut of the member pool in basis points
  function referralShareBps() external view returns (uint256);

  /// @notice Computed treasury balance: token balance minus member pool.
  ///         Not stored - derived from actual token balance each call.
  function treasuryBalance() external view returns (uint256);

  /// @notice Tracked member pool balance (claimable by members)
  function memberPoolBalance() external view returns (uint256);

  /// @notice Cumulative tokens sent to the burn address
  function totalBurned() external view returns (uint256);

  /// @notice Cumulative per-member reward counter used for snapshot accounting
  function cumulativeMemberRewards() external view returns (uint256);

  /// @notice Leftover wei from integer division in reward distribution
  function memberRewardRemainder() external view returns (uint256);

  /// @notice Snapshot of cumulativeMemberRewards at the time a member last claimed or joined
  /// @param member Address to query
  function rewardSnapshot(
    address member
  ) external view returns (uint256);

  /// @notice Total rewards a member has claimed over their lifetime
  /// @param member Address to query
  function memberPoolClaims(
    address member
  ) external view returns (uint256);

  /// @notice Returns the unclaimed reward balance for a member (0 if not a member)
  /// @param member Address to query
  function getClaimableRewards(
    address member
  ) external view returns (uint256);

  // ============ Templ Actions ============

  /// @notice One-time: connect to the Templ contract
  /// @param _templ Address of the Templ membership contract
  function setTempl(
    address _templ
  ) external;

  /// @notice Called by Templ on each paid join
  /// @param fee Total entry fee to distribute
  /// @param member Address of the new member
  /// @param referral Referral address (address(0) if none)
  /// @param existingMemberCount Members before this join (used for per-member reward math)
  function onJoin(
    uint256 fee,
    address member,
    address referral,
    uint256 existingMemberCount
  ) external;

  /// @notice Withdraw treasury funds
  /// @param recipient Address to receive the withdrawn tokens
  /// @param amount Token amount to withdraw
  function withdraw(
    address recipient,
    uint256 amount
  ) external;

  /// @notice Distribute treasury into member pool
  function dissolve() external;

  /// @notice Update fee split (PROTOCOL_BPS is set once in constructor)
  /// @param _burnBps New burn share in basis points
  /// @param _treasuryBps New treasury share in basis points
  /// @param _memberPoolBps New member pool share in basis points
  function setFeeSplit(
    uint256 _burnBps,
    uint256 _treasuryBps,
    uint256 _memberPoolBps
  ) external;

  /// @notice Update the token burn destination address
  /// @param _burnAddress New burn address (must not be zero)
  function setBurnAddress(
    address _burnAddress
  ) external;

  /// @notice Update the referral's share of the member pool
  /// @param _bps New referral share in basis points (0 = no referral, 10000 = full pool)
  function setReferralShareBps(
    uint256 _bps
  ) external;

  /// @notice Send leftover integer-division dust to a recipient
  /// @param recipient Address to receive the remainder tokens
  function sweepRemainder(
    address recipient
  ) external;

  // ============ Member Actions ============

  /// @notice Claim accumulated member rewards for a given member
  /// @param member The member whose rewards are claimed (tokens sent to this address)
  function claimRewards(
    address member
  ) external;
}
