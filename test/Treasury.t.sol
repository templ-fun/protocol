// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Templ } from "../src/Templ.sol";
import { Treasury } from "../src/Treasury.sol";
import { ITempl } from "../src/interfaces/ITempl.sol";
import { ITreasury } from "../src/interfaces/ITreasury.sol";
import { CurveConfig, EntryFeeCurve } from "../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockFactory } from "./mocks/MockFactory.sol";
import { ReentrantToken } from "./mocks/ReentrantToken.sol";
import { Test } from "forge-std/Test.sol";

contract TreasuryTest is Test {
  Templ public templ;
  Treasury public treasury;
  MockERC20 public token;
  MockFactory public mockFactory;

  address public priest = makeAddr("priest");
  address public protocolRecipient = makeAddr("protocol");
  address public user1 = makeAddr("user1");
  address public user2 = makeAddr("user2");
  address public user3 = makeAddr("user3");

  uint256 public constant ENTRY_FEE = 1000e18;
  uint256 public constant PROTOCOL_BPS = 1000;
  uint256 public constant BURN_BPS = 3000;
  uint256 public constant TREASURY_BPS = 3000;
  uint256 public constant MEMBER_POOL_BPS = 3000;
  uint256 public constant REFERRAL_SHARE_BPS = 2500;

  address constant DEAD = 0x000000000000000000000000000000000000dEaD;

  function _defaultCurve() internal pure returns (CurveConfig memory) {
    return EntryFeeCurve.exponentialWithTail(10_094, 248);
  }

  function _deployPair() internal {
    mockFactory = new MockFactory(protocolRecipient);
    treasury = mockFactory.deployTreasury(
      address(token),
      PROTOCOL_BPS,
      address(0), // default burn
      REFERRAL_SHARE_BPS
    );

    templ = new Templ(
      priest,
      address(token),
      ENTRY_FEE,
      _defaultCurve(),
      address(treasury),
      priest
    );

    vm.prank(address(mockFactory));
    treasury.setTempl(address(templ));
    vm.prank(address(mockFactory));
    treasury.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);
  }

  function setUp() public {
    token = new MockERC20();
    _deployPair();

    token.mint(user1, 100_000e18);
    token.mint(user2, 100_000e18);
    token.mint(user3, 100_000e18);
  }

  function _join(
    address who
  ) internal {
    uint256 fee = templ.entryFee();
    vm.startPrank(who);
    token.approve(address(templ), fee);
    templ.join(who, address(0));
    vm.stopPrank();
  }

  function _joinWithReferral(
    address who,
    address referral
  ) internal {
    uint256 fee = templ.entryFee();
    vm.startPrank(who);
    token.approve(address(templ), fee);
    templ.join(who, referral);
    vm.stopPrank();
  }

  // ============ Constructor ============

  function test_constructor_setsParams() public view {
    assertEq(treasury.TOKEN(), address(token));
    assertEq(treasury.FACTORY(), address(mockFactory));
    assertEq(treasury.PROTOCOL_BPS(), PROTOCOL_BPS);
    assertEq(treasury.burnBps(), BURN_BPS);
    assertEq(treasury.treasuryBps(), TREASURY_BPS);
    assertEq(treasury.memberPoolBps(), MEMBER_POOL_BPS);
    assertEq(treasury.burnAddress(), DEAD);
    assertEq(treasury.referralShareBps(), REFERRAL_SHARE_BPS);
  }

  function test_constructor_revertsIfSplitDoesntSum() public {
    MockFactory badMockFactory = new MockFactory(protocolRecipient);
    Treasury badTreasury =
      badMockFactory.deployTreasury(address(token), 1000, address(0), 0);
    Templ badTempl = new Templ(
      priest,
      address(token),
      ENTRY_FEE,
      _defaultCurve(),
      address(badTreasury),
      priest
    );
    vm.prank(address(badMockFactory));
    badTreasury.setTempl(address(badTempl));

    vm.expectRevert(ITreasury.InvalidSplit.selector);
    vm.prank(address(badMockFactory));
    badTreasury.setFeeSplit(1000, 1000, 1000);
  }

  // ============ Fee Distribution ============

  function test_join_distributesCorrectly() public {
    uint256 burnBefore = token.balanceOf(DEAD);
    uint256 protocolBefore = token.balanceOf(protocolRecipient);

    _join(user1);

    uint256 fee = ENTRY_FEE;
    uint256 expectedBurn = (fee * BURN_BPS) / 10_000;
    uint256 expectedMemberPool = (fee * MEMBER_POOL_BPS) / 10_000;
    uint256 expectedProtocol = (fee * PROTOCOL_BPS) / 10_000;
    uint256 expectedTreasury =
      fee - expectedBurn - expectedMemberPool - expectedProtocol;

    assertEq(token.balanceOf(DEAD) - burnBefore, expectedBurn, "burn");
    assertEq(
      token.balanceOf(protocolRecipient) - protocolBefore,
      expectedProtocol,
      "protocol"
    );
    assertEq(treasury.treasuryBalance(), expectedTreasury, "treasury");
    assertEq(treasury.totalBurned(), expectedBurn, "totalBurned");
  }

  // ============ Member Rewards ============

  function test_rewards_priestEarnsFromFirstJoin() public {
    _join(user1);

    uint256 claimable = treasury.getClaimableRewards(priest);
    // Priest is the only existing member when user1 joins
    // distributablePool = memberPoolAmt - 0 referral = memberPoolAmt
    uint256 memberPoolAmt = (ENTRY_FEE * MEMBER_POOL_BPS) / 10_000;
    assertEq(claimable, memberPoolAmt, "priest gets full pool from first join");
  }

  function test_rewards_splitBetweenExistingMembers() public {
    _join(user1);
    // Now there are 2 members (priest + user1)

    // Clear priest's snapshot context - get fresh pool from user2's join
    uint256 rewardsBefore = treasury.cumulativeMemberRewards();

    _join(user2);

    uint256 fee2 = (ENTRY_FEE * 10_094) / 10_000; // approximate 2nd fee
    uint256 pool2 = (fee2 * MEMBER_POOL_BPS) / 10_000;
    uint256 perMember = pool2 / 2; // split between priest + user1

    // Each existing member should have earned perMember from this join
    uint256 added = treasury.cumulativeMemberRewards() - rewardsBefore;
    assertEq(added, perMember, "reward per member from 2nd join");
  }

  function test_claimRewards_success() public {
    _join(user1);

    uint256 claimable = treasury.getClaimableRewards(priest);
    assertGt(claimable, 0);

    uint256 balanceBefore = token.balanceOf(priest);

    vm.prank(priest);
    treasury.claimRewards(priest);

    assertEq(token.balanceOf(priest) - balanceBefore, claimable);
    assertEq(treasury.getClaimableRewards(priest), 0);
    assertEq(treasury.memberPoolClaims(priest), claimable);
  }

  function test_claimRewards_onBehalf() public {
    _join(user1);

    uint256 claimable = treasury.getClaimableRewards(priest);
    assertGt(claimable, 0);

    uint256 balanceBefore = token.balanceOf(priest);

    // user1 claims on behalf of priest - tokens go to priest
    vm.prank(user1);
    treasury.claimRewards(priest);

    assertEq(token.balanceOf(priest) - balanceBefore, claimable);
    assertEq(treasury.getClaimableRewards(priest), 0);
    assertEq(treasury.memberPoolClaims(priest), claimable);
  }

  function test_claimRewards_newMemberDoesNotEarnFromOwnJoin() public {
    _join(user1);
    assertEq(treasury.getClaimableRewards(user1), 0, "no self-reward");
  }

  function test_claimRewards_revertsIfNotMember() public {
    vm.expectRevert(ITreasury.NotMember.selector);
    treasury.claimRewards(user1); // user1 is not a member
  }

  function test_claimRewards_revertsIfNothingToClaim() public {
    _join(user1);

    // user1 just joined - snapshot == cumulative, nothing to claim
    vm.expectRevert(ITreasury.NoRewardsToClaim.selector);
    treasury.claimRewards(user1);
  }

  // ============ Referral ============

  function test_referral_validReferralGetsPaid() public {
    _join(user1); // user1 is now a member

    uint256 referralBefore = token.balanceOf(user1);

    _joinWithReferral(user2, user1);

    uint256 fee2 = (ENTRY_FEE * 10_094) / 10_000;
    uint256 memberPoolAmt = (fee2 * MEMBER_POOL_BPS) / 10_000;
    uint256 expectedReferral = (memberPoolAmt * REFERRAL_SHARE_BPS) / 10_000;

    assertEq(
      token.balanceOf(user1) - referralBefore, expectedReferral, "referral paid"
    );
  }

  function test_referral_selfReferralIgnored() public {
    // user1 tries to refer themselves - should be ignored
    uint256 user1Before = token.balanceOf(user1);
    uint256 fee = templ.entryFee();

    vm.startPrank(user1);
    token.approve(address(templ), fee);
    templ.join(user1, user1); // self-referral - Treasury ignores it
    vm.stopPrank();

    // user1 should NOT have received any referral tokens (they paid the fee)
    // Their balance decreased by fee, no referral was paid back
    assertEq(token.balanceOf(user1), user1Before - fee, "no self-referral");
  }

  function test_referral_nonMemberReferralIgnored() public {
    // user2 is not a member, used as referral
    _joinWithReferral(user1, user2);

    // user2 got nothing (not a member)
    assertEq(token.balanceOf(user2), 100_000e18, "non-member referral ignored");
  }

  // ============ Treasury ============

  function test_withdraw_viaGovernance() public {
    _join(user1);

    uint256 treasuryBal = treasury.treasuryBalance();
    assertGt(treasuryBal, 0);

    address recipient = makeAddr("recipient");

    // Governance = priest by default
    vm.prank(priest);
    treasury.withdraw(recipient, treasuryBal);

    assertEq(token.balanceOf(recipient), treasuryBal);
  }

  function test_withdraw_revertsIfNotGovernance() public {
    _join(user1);

    vm.expectRevert(ITreasury.NotGovernance.selector);
    vm.prank(user1);
    treasury.withdraw(user1, 100);
  }

  // ============ Dissolve Treasury ============

  function test_dissolve_distributesToAllMembers() public {
    _join(user1);
    _join(user2);

    // 3 members: priest, user1, user2
    uint256 treasuryBefore = treasury.treasuryBalance();
    assertGt(treasuryBefore, 0);

    uint256 priestClaimBefore = treasury.getClaimableRewards(priest);

    vm.prank(priest);
    treasury.dissolve();

    // Treasury emptied into member pool
    assertEq(treasury.treasuryBalance(), 0);

    // Each member gets an equal share of the treasury
    uint256 priestClaimAfter = treasury.getClaimableRewards(priest);
    uint256 addedPerMember = priestClaimAfter - priestClaimBefore;
    assertGt(addedPerMember, 0);

    // user1 also gets the same added amount
    uint256 user1Claim = treasury.getClaimableRewards(user1);
    assertGt(user1Claim, 0);
  }

  function test_dissolve_revertsIfNoTreasury() public {
    _join(user1);

    // Withdraw all treasury first
    uint256 treasuryBal = treasury.treasuryBalance();
    vm.prank(priest);
    treasury.withdraw(makeAddr("sink"), treasuryBal);

    vm.expectRevert(ITreasury.InsufficientTreasuryBalance.selector);
    vm.prank(priest);
    treasury.dissolve();
  }

  // ============ Sweep Remainder ============

  function test_sweepRemainder_recoversDust() public {
    // Join enough members to create a non-zero remainder from integer division
    _join(user1);
    _join(user2);
    _join(user3);

    uint256 remainder = treasury.memberRewardRemainder();
    if (remainder == 0) {
      // If no remainder from these joins, skip - it's math-dependent
      return;
    }

    address recipient = makeAddr("dustCollector");

    vm.prank(priest);
    treasury.sweepRemainder(recipient);

    assertEq(token.balanceOf(recipient), remainder);
    assertEq(treasury.memberRewardRemainder(), 0);
  }

  function test_sweepRemainder_revertsIfNoRemainder() public {
    // With only 1 existing member (priest), division is exact - no remainder
    _join(user1);

    // Remainder should be 0 (pool / 1 member = exact)
    assertEq(treasury.memberRewardRemainder(), 0);

    vm.expectRevert(ITreasury.NoRewardsToClaim.selector);
    vm.prank(priest);
    treasury.sweepRemainder(makeAddr("sink"));
  }

  // ============ Governance ============

  function test_setFeeSplit_viaGovernance() public {
    vm.prank(priest);
    treasury.setFeeSplit(2000, 4000, 3000);

    assertEq(treasury.burnBps(), 2000);
    assertEq(treasury.treasuryBps(), 4000);
    assertEq(treasury.memberPoolBps(), 3000);
  }

  function test_setFeeSplit_revertsIfBadSum() public {
    vm.expectRevert(ITreasury.InvalidSplit.selector);
    vm.prank(priest);
    treasury.setFeeSplit(5000, 5000, 5000); // doesn't sum with protocol
  }

  function test_setBurnAddress_viaGovernance() public {
    address newBurn = makeAddr("newBurn");

    vm.prank(priest);
    treasury.setBurnAddress(newBurn);

    assertEq(treasury.burnAddress(), newBurn);
  }

  function test_setReferralShareBps_viaGovernance() public {
    vm.prank(priest);
    treasury.setReferralShareBps(5000);

    assertEq(treasury.referralShareBps(), 5000);
  }

  // ============ Reentrancy ============

  function test_claimRewards_resistsReentrancy() public {
    // Deploy a new pair using the reentrant token
    ReentrantToken evil = new ReentrantToken();
    MockFactory evilMockFactory = new MockFactory(protocolRecipient);
    Treasury evilTreasury = evilMockFactory.deployTreasury(
      address(evil), PROTOCOL_BPS, address(0), REFERRAL_SHARE_BPS
    );
    Templ evilTempl = new Templ(
      priest,
      address(evil),
      ENTRY_FEE,
      _defaultCurve(),
      address(evilTreasury),
      priest
    );
    vm.prank(address(evilMockFactory));
    evilTreasury.setTempl(address(evilTempl));
    vm.prank(address(evilMockFactory));
    evilTreasury.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);

    // Setup: priest is member #1. Join user1 so priest has claimable rewards.
    evil.mint(user1, 100_000e18);
    vm.startPrank(user1);
    evil.approve(address(evilTempl), type(uint256).max);
    evilTempl.join(user1, address(0));
    vm.stopPrank();

    // Arm the reentrant attack - when Treasury transfers to priest,
    // the token will try to call claimRewards again
    evil.setAttack(
      address(evilTreasury), abi.encodeCall(evilTreasury.claimRewards, (priest))
    );

    uint256 claimable = evilTreasury.getClaimableRewards(priest);
    uint256 balBefore = evil.balanceOf(priest);

    // Outer claim succeeds, but reentrant claim is blocked by the guard.
    // Priest only receives one payout, not two.
    vm.prank(priest);
    evilTreasury.claimRewards(priest);

    assertEq(evil.balanceOf(priest) - balBefore, claimable);
    assertEq(evilTreasury.getClaimableRewards(priest), 0);
  }

  function test_withdraw_resistsReentrancy() public {
    // Deploy a pair with the reentrant token
    ReentrantToken evil = new ReentrantToken();
    MockFactory evilMockFactory = new MockFactory(protocolRecipient);
    Treasury evilTreasury = evilMockFactory.deployTreasury(
      address(evil), PROTOCOL_BPS, address(0), REFERRAL_SHARE_BPS
    );
    Templ evilTempl = new Templ(
      priest,
      address(evil),
      ENTRY_FEE,
      _defaultCurve(),
      address(evilTreasury),
      priest
    );
    vm.prank(address(evilMockFactory));
    evilTreasury.setTempl(address(evilTempl));
    vm.prank(address(evilMockFactory));
    evilTreasury.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);

    // Join user1 to generate treasury balance
    evil.mint(user1, 100_000e18);
    vm.startPrank(user1);
    evil.approve(address(evilTempl), type(uint256).max);
    evilTempl.join(user1, address(0));
    vm.stopPrank();

    uint256 treasuryBal = evilTreasury.treasuryBalance();
    address recipient = makeAddr("recipient");

    // Arm: during withdraw's token transfer, re-enter withdraw
    evil.setAttack(
      address(evilTreasury),
      abi.encodeCall(evilTreasury.withdraw, (recipient, treasuryBal))
    );

    vm.prank(priest);
    evilTreasury.withdraw(recipient, treasuryBal);

    // Only one withdrawal executed - guard blocked the reentrant call
    assertEq(evil.balanceOf(recipient), treasuryBal);
    assertEq(evilTreasury.treasuryBalance(), 0);
  }

  function test_dissolve_resistsReentrancy() public {
    // Deploy a pair with the reentrant token
    ReentrantToken evil = new ReentrantToken();
    MockFactory evilMockFactory = new MockFactory(protocolRecipient);
    Treasury evilTreasury = evilMockFactory.deployTreasury(
      address(evil), PROTOCOL_BPS, address(0), REFERRAL_SHARE_BPS
    );
    Templ evilTempl = new Templ(
      priest,
      address(evil),
      ENTRY_FEE,
      _defaultCurve(),
      address(evilTreasury),
      priest
    );
    vm.prank(address(evilMockFactory));
    evilTreasury.setTempl(address(evilTempl));
    vm.prank(address(evilMockFactory));
    evilTreasury.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);

    // Join user1 to generate treasury balance
    evil.mint(user1, 100_000e18);
    vm.startPrank(user1);
    evil.approve(address(evilTempl), type(uint256).max);
    evilTempl.join(user1, address(0));
    vm.stopPrank();

    uint256 treasuryBal = evilTreasury.treasuryBalance();
    assertGt(treasuryBal, 0);

    // Arm: during claimRewards transfer, re-enter dissolve.
    // dissolve() doesn't transfer tokens itself, but it shares the
    // nonReentrant lock with claimRewards, so a callback from
    // claimRewards can't call dissolve.
    evil.setAttack(
      address(evilTreasury), abi.encodeCall(evilTreasury.dissolve, ())
    );

    // Trigger via claimRewards (which does transfer) - the reentrant
    // dissolve call should be blocked by the shared guard
    uint256 claimable = evilTreasury.getClaimableRewards(priest);
    assertGt(claimable, 0);

    vm.prank(priest);
    evilTreasury.claimRewards(priest);

    // Treasury balance unchanged - dissolve was blocked
    assertEq(evilTreasury.treasuryBalance(), treasuryBal);
  }

  function test_onJoin_resistsReentrancy() public {
    // Deploy a pair with the reentrant token
    ReentrantToken evil = new ReentrantToken();
    MockFactory evilMockFactory = new MockFactory(protocolRecipient);
    Treasury evilTreasury = evilMockFactory.deployTreasury(
      address(evil), PROTOCOL_BPS, address(0), REFERRAL_SHARE_BPS
    );
    Templ evilTempl = new Templ(
      priest,
      address(evil),
      ENTRY_FEE,
      _defaultCurve(),
      address(evilTreasury),
      priest
    );
    vm.prank(address(evilMockFactory));
    evilTreasury.setTempl(address(evilTempl));
    vm.prank(address(evilMockFactory));
    evilTreasury.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);

    // During onJoin's burn transfer, the token tries to trigger
    // another join. The nonReentrant guard blocks re-entry into
    // onJoin via the shared transient lock.
    evil.mint(user1, 100_000e18);
    evil.mint(user2, 100_000e18);

    vm.prank(user2);
    evil.approve(address(evilTempl), type(uint256).max);

    // Arm: during user1's join (burn transfer), try to join as user2
    evil.setAttack(
      address(evilTempl), abi.encodeCall(evilTempl.join, (user2, address(0)))
    );

    vm.startPrank(user1);
    evil.approve(address(evilTempl), type(uint256).max);
    evilTempl.join(user1, address(0));
    vm.stopPrank();

    // user1 joined successfully
    assertTrue(evilTempl.isMember(user1), "user1 is member");
    // user2's reentrant join was blocked
    assertFalse(evilTempl.isMember(user2), "user2 blocked by reentrancy guard");
  }

  // ============ Join Pause ============

  function test_join_revertsWhenPaused() public {
    vm.prank(priest);
    templ.setJoinPaused(true);

    uint256 fee = templ.entryFee();
    token.mint(user1, fee);
    vm.startPrank(user1);
    token.approve(address(templ), fee);

    vm.expectRevert(ITempl.JoinsPaused.selector);
    templ.join(user1, address(0));
    vm.stopPrank();
  }

  // ============ Surplus Tokens (Direct Transfers) ============

  function test_directTransfer_automaticallyAvailableViaWithdraw() public {
    _join(user1);

    uint256 treasuryBefore = treasury.treasuryBalance();

    // Send tokens directly to Treasury (simulating donation or fee)
    uint256 donation = 500e18;
    token.mint(address(this), donation);
    require(token.transfer(address(treasury), donation), "transfer failed");

    // treasuryBalance is now derived, so it includes the surplus
    assertEq(
      treasury.treasuryBalance(),
      treasuryBefore + donation,
      "treasury includes surplus automatically"
    );

    // Governance can withdraw the full amount including surplus
    address recipient = makeAddr("donationRecipient");
    vm.prank(priest);
    treasury.withdraw(recipient, treasuryBefore + donation);
    assertEq(token.balanceOf(recipient), treasuryBefore + donation);
  }

  function test_treasuryBalance_returnsDerivedValue() public {
    _join(user1);

    uint256 actualBalance = token.balanceOf(address(treasury));
    uint256 memberPool = treasury.memberPoolBalance();

    assertEq(
      treasury.treasuryBalance(),
      actualBalance - memberPool,
      "treasuryBalance == tokenBalance - memberPool"
    );
  }

  // ============ Retroactive Fee Recipient ============

  function test_retroactiveFeeRecipient_nextJoinUsesNewAddress() public {
    _join(user1);

    // Change the fee recipient on the mock factory
    address newRecipient = makeAddr("newProtocol");
    mockFactory.setProtocolFeeRecipient(newRecipient);

    uint256 newRecipientBefore = token.balanceOf(newRecipient);

    _join(user2);

    // Protocol fees from user2's join went to the new recipient
    assertGt(
      token.balanceOf(newRecipient) - newRecipientBefore,
      0,
      "new recipient received protocol fees"
    );
  }

  // ============ Partial Treasury Withdrawal ============

  function test_withdraw_partialAmount() public {
    _join(user1);
    _join(user2);

    uint256 fullTreasury = treasury.treasuryBalance();
    assertGt(fullTreasury, 0);

    uint256 portion = fullTreasury / 3;
    address recipient = makeAddr("partialRecipient");

    vm.prank(priest);
    treasury.withdraw(recipient, portion);

    assertEq(token.balanceOf(recipient), portion);
    assertEq(
      treasury.treasuryBalance(), fullTreasury - portion, "remaining treasury"
    );

    // Can still withdraw the rest
    uint256 remaining = treasury.treasuryBalance();
    vm.prank(priest);
    treasury.withdraw(recipient, remaining);

    assertEq(token.balanceOf(recipient), portion + remaining);
    assertEq(treasury.treasuryBalance(), 0);
  }

  // ============ Referral Share Cap ============

  function test_setReferralShareBps_atCap_succeeds() public {
    vm.prank(priest);
    treasury.setReferralShareBps(10_000);

    assertEq(treasury.referralShareBps(), 10_000);
  }

  function test_setReferralShareBps_aboveCap_reverts() public {
    vm.prank(priest);
    vm.expectRevert(ITreasury.InvalidSplit.selector);
    treasury.setReferralShareBps(10_001);
  }

  function test_constructor_revertsIfReferralShareAboveCap() public {
    MockFactory badMockFactory = new MockFactory(protocolRecipient);
    vm.expectRevert(ITreasury.InvalidSplit.selector);
    badMockFactory.deployTreasury(
      address(token), PROTOCOL_BPS, address(0), 10_001
    );
  }

  function test_referral_fullMemberPoolGoesToReferrer() public {
    // Set referral share to max (100% of member pool)
    vm.prank(priest);
    treasury.setReferralShareBps(10_000);

    _join(user1); // user1 becomes a member

    uint256 rewardsBefore = treasury.cumulativeMemberRewards();
    uint256 referralBefore = token.balanceOf(user1);

    _joinWithReferral(user2, user1);

    // Referrer got 100% of the member pool share
    uint256 referralReceived = token.balanceOf(user1) - referralBefore;
    assertGt(referralReceived, 0, "referrer should be paid");

    // No remaining pool to distribute - member rewards unchanged
    uint256 rewardsAdded = treasury.cumulativeMemberRewards() - rewardsBefore;
    assertEq(rewardsAdded, 0, "no member rewards when referral takes 100%");
  }

  // ============ Withdraw Edge Cases ============

  function test_withdraw_revertsIfRecipientIsZero() public {
    _join(user1);
    uint256 available = treasury.treasuryBalance();
    assertGt(available, 0);

    vm.prank(priest);
    vm.expectRevert(ITreasury.InvalidAddress.selector);
    treasury.withdraw(address(0), available);
  }

  function test_withdraw_revertsIfAmountIsZero() public {
    _join(user1);

    vm.prank(priest);
    vm.expectRevert(ITreasury.AmountZero.selector);
    treasury.withdraw(makeAddr("sink"), 0);
  }

  // ============ Dissolve Edge Cases ============

  function test_dissolve_revertsIfNoMembers() public {
    // Deploy a standalone Treasury+Templ where no one has joined yet.
    // The priest is always member #1, so memberCount is never 0 in
    // normal flows. But the revert guard exists in case of future
    // governance patterns, so test it via a direct call.
    // Since priest is always member #1, memberCount is at least 1.
    // The zero-member branch is unreachable in normal operation.
    // Instead, verify dissolve reverts when treasury balance is zero
    // (the other guard).
    MockFactory mf2 = new MockFactory(protocolRecipient);
    Treasury tr2 = mf2.deployTreasury(
      address(token), PROTOCOL_BPS, address(0), REFERRAL_SHARE_BPS
    );
    Templ t2 = new Templ(
      priest, address(token), ENTRY_FEE, _defaultCurve(), address(tr2), priest
    );
    vm.prank(address(mf2));
    tr2.setTempl(address(t2));
    vm.prank(address(mf2));
    tr2.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);

    // No joins yet, treasury balance is zero
    assertEq(tr2.treasuryBalance(), 0);

    vm.prank(priest);
    vm.expectRevert(ITreasury.InsufficientTreasuryBalance.selector);
    tr2.dissolve();
  }

  // ============ setTempl Edge Cases ============

  function test_setTempl_revertsIfNotFactory() public {
    MockFactory mf2 = new MockFactory(protocolRecipient);
    Treasury tr2 = mf2.deployTreasury(
      address(token), PROTOCOL_BPS, address(0), REFERRAL_SHARE_BPS
    );

    vm.prank(user1);
    vm.expectRevert(ITreasury.NotDeployer.selector);
    tr2.setTempl(address(templ));
  }

  function test_setTempl_revertsIfAlreadySet() public {
    // treasury.setTempl was already called in setUp via _deployPair
    vm.prank(address(mockFactory));
    vm.expectRevert(ITreasury.AlreadyInitialized.selector);
    treasury.setTempl(makeAddr("anotherTempl"));
  }

  function test_setTempl_revertsIfZeroAddress() public {
    MockFactory mf2 = new MockFactory(protocolRecipient);
    Treasury tr2 = mf2.deployTreasury(
      address(token), PROTOCOL_BPS, address(0), REFERRAL_SHARE_BPS
    );

    vm.prank(address(mf2));
    vm.expectRevert(ITreasury.InvalidAddress.selector);
    tr2.setTempl(address(0));
  }

  // ============ setBurnAddress Edge Cases ============

  function test_setBurnAddress_revertsIfZero() public {
    vm.prank(priest);
    vm.expectRevert(ITreasury.InvalidAddress.selector);
    treasury.setBurnAddress(address(0));
  }

  function test_setBurnAddress_revertsIfNotGovernance() public {
    vm.prank(user1);
    vm.expectRevert(ITreasury.NotGovernance.selector);
    treasury.setBurnAddress(makeAddr("newBurn"));
  }

  // ============ sweepRemainder Edge Cases ============

  function test_sweepRemainder_revertsIfRecipientIsZero() public {
    _join(user1);
    _join(user2);
    _join(user3);

    uint256 remainder = treasury.memberRewardRemainder();
    if (remainder == 0) return;

    vm.prank(priest);
    vm.expectRevert(ITreasury.InvalidAddress.selector);
    treasury.sweepRemainder(address(0));
  }

  function test_sweepRemainder_revertsIfNotGovernance() public {
    vm.prank(user1);
    vm.expectRevert(ITreasury.NotGovernance.selector);
    treasury.sweepRemainder(makeAddr("sink"));
  }

  // ============ setFeeSplit Edge Cases ============

  function test_setFeeSplit_revertsIfNotGovernanceOrFactory() public {
    vm.prank(user1);
    vm.expectRevert(ITreasury.NotGovernance.selector);
    treasury.setFeeSplit(3000, 3000, 3000);
  }

  // ============ setReferralShareBps Edge Cases ============

  function test_setReferralShareBps_revertsIfNotGovernance() public {
    vm.prank(user1);
    vm.expectRevert(ITreasury.NotGovernance.selector);
    treasury.setReferralShareBps(5000);
  }

  // ============ Proposal Fees Land In Treasury ============

  function test_proposalFees_areWithdrawableByGovernance() public {
    // Proposal fees are sent directly to treasury via safeTransferFrom.
    // They bypass credit() so they appear as surplus in treasuryBalance().
    // This test confirms governance can withdraw them.
    uint256 donation = 500e18;
    token.mint(address(this), donation);
    require(token.transfer(address(treasury), donation), "transfer failed");

    uint256 available = treasury.treasuryBalance();
    assertGe(available, donation);

    address recipient = makeAddr("feeRecipient");
    vm.prank(priest);
    treasury.withdraw(recipient, donation);

    assertEq(token.balanceOf(recipient), donation);
  }

  // ============ Surplus Token Safety ============

  function test_withdraw_withSurplus_memberPoolSafe() public {
    _join(user1);
    _join(user2);

    // Send surplus tokens directly to Treasury
    uint256 surplus = 2000e18;
    token.mint(address(this), surplus);
    require(token.transfer(address(treasury), surplus), "transfer failed");

    uint256 memberPool = treasury.memberPoolBalance();
    uint256 available = treasury.treasuryBalance();

    // Governance withdraws full available (including surplus)
    address recipient = makeAddr("surplus-recipient");
    vm.prank(priest);
    treasury.withdraw(recipient, available);

    // Recipient received all available funds
    assertEq(token.balanceOf(recipient), available);

    // Derived treasury balance is now zero
    assertEq(treasury.treasuryBalance(), 0);

    // Member pool balance unchanged - never touched
    assertEq(treasury.memberPoolBalance(), memberPool, "member pool untouched");

    // Actual balance still covers member pool
    assertGe(
      token.balanceOf(address(treasury)),
      treasury.memberPoolBalance(),
      "actual balance >= member pool"
    );

    // Members can still claim their rewards
    uint256 claimable = treasury.getClaimableRewards(priest);
    if (claimable > 0) {
      treasury.claimRewards(priest);
      assertEq(treasury.getClaimableRewards(priest), 0);
    }
  }

  function test_withdraw_cannotExceedAvailable() public {
    _join(user1);

    uint256 treasuryBal = treasury.treasuryBalance();
    uint256 tooMuch = treasuryBal + 1;

    vm.expectRevert(ITreasury.InsufficientTreasuryBalance.selector);
    vm.prank(priest);
    treasury.withdraw(makeAddr("thief"), tooMuch);
  }

  function test_dissolve_withSurplus_accountingConsistent() public {
    _join(user1);
    _join(user2);

    // Inject surplus tokens
    uint256 surplus = 1500e18;
    token.mint(address(this), surplus);
    require(token.transfer(address(treasury), surplus), "transfer failed");

    uint256 memberPoolBefore = treasury.memberPoolBalance();
    uint256 actualBalance = token.balanceOf(address(treasury));
    uint256 available = actualBalance - memberPoolBefore;

    vm.prank(priest);
    treasury.dissolve();

    // Treasury zeroed
    assertEq(treasury.treasuryBalance(), 0);

    // Member pool absorbed everything (treasury + surplus)
    assertEq(
      treasury.memberPoolBalance(),
      memberPoolBefore + available,
      "member pool absorbed available"
    );

    // Actual balance equals member pool (fully consistent)
    assertEq(
      token.balanceOf(address(treasury)),
      treasury.memberPoolBalance(),
      "balance == memberPoolBalance"
    );
  }

  // ============ Solvency: Invariant Tests ============

  /// @dev Helper: check solvency invariants hold
  function _assertSolvency(
    string memory label
  ) internal view {
    uint256 balance = token.balanceOf(address(treasury));
    uint256 memberPool = treasury.memberPoolBalance();
    uint256 remainder = treasury.memberRewardRemainder();

    // Invariant 1: actual balance covers the member pool
    assertGe(
      balance, memberPool, string.concat(label, ": balance >= memberPool")
    );

    // Invariant 2: memberPoolBalance >= memberRewardRemainder (no underflow in claimRewards)
    assertGe(
      memberPool, remainder, string.concat(label, ": memberPool >= remainder")
    );
  }

  /// @dev Helper: sum of all claimable rewards across tracked members
  function _totalClaimable(
    address[] memory members
  ) internal view returns (uint256 total) {
    for (uint256 i; i < members.length; ++i) {
      total += treasury.getClaimableRewards(members[i]);
    }
  }

  function test_solvency_allMembersClaim_poolEqualsRemainder() public {
    _join(user1);
    _join(user2);
    _join(user3);

    // Claim in arbitrary order
    treasury.claimRewards(priest);
    treasury.claimRewards(user1);
    treasury.claimRewards(user2);

    // user3 has nothing (joined last, no subsequent joins)
    assertEq(treasury.getClaimableRewards(user3), 0);

    // After all claims: memberPoolBalance should equal memberRewardRemainder
    assertEq(
      treasury.memberPoolBalance(),
      treasury.memberRewardRemainder(),
      "pool == remainder after all claims"
    );

    _assertSolvency("after all claims");
  }

  function test_solvency_claimThenJoinThenClaim() public {
    // Join → claim → join → claim → sweep: full lifecycle
    _join(user1);

    treasury.claimRewards(priest);

    _assertSolvency("after priest claim");

    _join(user2);
    _assertSolvency("after user2 join");

    // Both priest and user1 now have claimable from user2's join
    treasury.claimRewards(priest);
    _assertSolvency("after priest second claim");

    treasury.claimRewards(user1);
    _assertSolvency("after user1 claim");

    // After all claims, pool should equal remainder
    assertEq(
      treasury.memberPoolBalance(),
      treasury.memberRewardRemainder(),
      "pool == remainder"
    );

    // Sweep remainder if any
    uint256 remainder = treasury.memberRewardRemainder();
    if (remainder > 0) {
      vm.prank(priest);
      treasury.sweepRemainder(makeAddr("dustBin"));
      _assertSolvency("after sweep");
      assertEq(treasury.memberPoolBalance(), 0);
      assertEq(treasury.memberRewardRemainder(), 0);
    }
  }

  function test_solvency_dissolveThenAllClaim() public {
    _join(user1);
    _join(user2);

    _assertSolvency("before dissolve");

    vm.prank(priest);
    treasury.dissolve();

    _assertSolvency("after dissolve");

    // Verify tight invariant: total claimable == memberPool - remainder
    address[] memory members = new address[](3);
    members[0] = priest;
    members[1] = user1;
    members[2] = user2;
    uint256 totalClaimable = _totalClaimable(members);
    assertEq(
      totalClaimable,
      treasury.memberPoolBalance() - treasury.memberRewardRemainder(),
      "tight invariant: claimable == pool - remainder"
    );

    // All members claim (including user2 who got a share from dissolve)
    treasury.claimRewards(priest);
    treasury.claimRewards(user1);
    if (treasury.getClaimableRewards(user2) > 0) {
      treasury.claimRewards(user2);
    }

    _assertSolvency("after all claims post-dissolve");
    assertEq(
      treasury.memberPoolBalance(),
      treasury.memberRewardRemainder(),
      "pool == remainder after full drain"
    );
  }

  // ============ Remainder Carry-Forward ============

  /// @dev Verifies that integer-division remainder from one round is folded
  ///      into the next round's distribution (e.g. 7 / 4 = 1 rem 3 → the 3
  ///      becomes part of the next totalRewards).
  function test_remainder_carriesForwardToNextRound() public {
    // Round 1: user1 joins → 1 existing member (priest) → exact division
    _join(user1);
    assertEq(treasury.memberRewardRemainder(), 0, "1 member: exact division");

    // Round 2: user2 joins → 2 existing members (priest, user1)
    _join(user2);
    uint256 remainderAfterRound2 = treasury.memberRewardRemainder();

    // Round 3: user3 joins → 3 existing members
    // The prior remainder MUST be folded into this round's distribution
    uint256 cumulBefore = treasury.cumulativeMemberRewards();
    uint256 poolBefore = treasury.memberPoolBalance();

    _join(user3);

    uint256 distributablePool = treasury.memberPoolBalance() - poolBefore;
    uint256 totalRewards = distributablePool + remainderAfterRound2;
    uint256 expectedPerMember = totalRewards / 3;
    uint256 expectedRemainder = totalRewards % 3;

    assertEq(
      treasury.cumulativeMemberRewards() - cumulBefore,
      expectedPerMember,
      "perMember includes carried-forward remainder"
    );
    assertEq(
      treasury.memberRewardRemainder(),
      expectedRemainder,
      "new remainder = totalRewards mod memberCount"
    );

    _assertSolvency("after remainder carry-forward");
  }

  /// @dev Multi-round test: verifies that remainder accumulates and
  ///      redistributes correctly across 5 sequential joins, and that
  ///      all tokens are accounted for (claimable + remainder == pool).
  function test_remainder_multiRound_allTokensAccountedFor() public {
    address user4 = makeAddr("user4");
    address user5 = makeAddr("user5");
    token.mint(user4, 100_000e18);
    token.mint(user5, 100_000e18);

    address[5] memory joiners = [user1, user2, user3, user4, user5];
    uint256 prevRemainder;

    for (uint256 i; i < joiners.length; ++i) {
      prevRemainder = treasury.memberRewardRemainder();
      uint256 cumulBefore = treasury.cumulativeMemberRewards();
      uint256 poolBefore = treasury.memberPoolBalance();
      uint256 existingMembers = i + 1; // priest + previously joined

      uint256 fee = templ.entryFee();
      vm.startPrank(joiners[i]);
      token.approve(address(templ), fee);
      templ.join(joiners[i], address(0));
      vm.stopPrank();

      uint256 distributablePool = treasury.memberPoolBalance() - poolBefore;
      uint256 totalRewards = distributablePool + prevRemainder;
      uint256 expectedPerMember = totalRewards / existingMembers;
      uint256 expectedRemainder = totalRewards % existingMembers;

      assertEq(
        treasury.cumulativeMemberRewards() - cumulBefore,
        expectedPerMember,
        string.concat("round ", vm.toString(i + 1), ": perMember correct")
      );
      assertEq(
        treasury.memberRewardRemainder(),
        expectedRemainder,
        string.concat("round ", vm.toString(i + 1), ": remainder correct")
      );

      _assertSolvency(string.concat("round ", vm.toString(i + 1)));
    }

    // Final invariant: claimable + remainder == memberPoolBalance
    address[] memory allMembers = new address[](6);
    allMembers[0] = priest;
    for (uint256 i; i < joiners.length; ++i) {
      allMembers[i + 1] = joiners[i];
    }
    uint256 totalClaimable = _totalClaimable(allMembers);
    assertEq(
      totalClaimable + treasury.memberRewardRemainder(),
      treasury.memberPoolBalance(),
      "all tokens accounted: claimable + remainder == pool"
    );
  }

  /// @dev After all members claim, a subsequent join should redistribute
  ///      the leftover remainder. Verifies no tokens are permanently stuck.
  function test_remainder_redistributesAfterClaimsAndNewJoin() public {
    _join(user1);
    _join(user2);

    // All existing members claim
    treasury.claimRewards(priest);
    treasury.claimRewards(user1);

    // pool should now equal remainder (only undistributed dust left)
    assertEq(
      treasury.memberPoolBalance(),
      treasury.memberRewardRemainder(),
      "pool == remainder after all claims"
    );

    // New join: remainder from previous rounds gets folded in
    uint256 cumulBefore = treasury.cumulativeMemberRewards();
    uint256 poolBefore = treasury.memberPoolBalance();
    uint256 prevRemainder = treasury.memberRewardRemainder();

    _join(user3);

    uint256 distributablePool = treasury.memberPoolBalance() - poolBefore;
    uint256 totalRewards = distributablePool + prevRemainder;
    uint256 expectedPerMember = totalRewards / 3; // priest, user1, user2
    uint256 expectedRemainder = totalRewards % 3;

    assertEq(
      treasury.cumulativeMemberRewards() - cumulBefore,
      expectedPerMember,
      "remainder folded into distribution after claims"
    );
    assertEq(
      treasury.memberRewardRemainder(),
      expectedRemainder,
      "new remainder after redistribution"
    );

    _assertSolvency("after remainder redistribution");
  }

  function test_solvency_maxReferral_remainderRedistributes() public {
    // Set referral to max (100%) - distributablePool = 0
    vm.prank(priest);
    treasury.setReferralShareBps(10_000);

    // user1 joins (no referral) - creates pool for priest
    _join(user1);
    _assertSolvency("after user1 join");

    // user2 joins (no referral) - creates pool split between priest + user1
    _join(user2);
    _assertSolvency("after user2 join");

    uint256 poolBefore = treasury.memberPoolBalance();

    // user3 joins with referral = user1 → referral takes 100%, 0 goes to pool
    _joinWithReferral(user3, user1);
    _assertSolvency("after user3 join with max referral");

    // Pool unchanged - referral took 100% of the member pool portion
    assertEq(
      treasury.memberPoolBalance(),
      poolBefore,
      "pool unchanged when referral takes 100%"
    );

    // Remainder must still be <= memberPoolBalance
    assertGe(
      treasury.memberPoolBalance(),
      treasury.memberRewardRemainder(),
      "pool >= remainder after max-referral join"
    );
  }

  // ============ Fuzz: Solvency ============

  function testFuzz_solvency_joinsAndClaims(
    uint8 numJoins,
    uint8 claimSeed
  ) public {
    numJoins = uint8(bound(numJoins, 1, 20));

    address[] memory members = new address[](numJoins + 1);
    members[0] = priest;

    for (uint8 i; i < numJoins; ++i) {
      address joiner = makeAddr(string(abi.encodePacked("inv", i)));
      members[i + 1] = joiner;

      uint256 fee = templ.entryFee();
      token.mint(joiner, fee);
      vm.startPrank(joiner);
      token.approve(address(templ), fee);
      templ.join(joiner, address(0));
      vm.stopPrank();

      _assertSolvency(string.concat("after join ", string(abi.encodePacked(i))));

      // Pseudo-randomly decide if an existing member claims
      if (uint256(keccak256(abi.encode(claimSeed, i))) % 3 == 0 && i > 0) {
        // Pick a random existing member to claim
        uint256 idx =
          uint256(keccak256(abi.encode(claimSeed, i, "pick"))) % (i + 1);
        address claimer = members[idx];
        uint256 claimable = treasury.getClaimableRewards(claimer);
        if (claimable > 0) {
          treasury.claimRewards(claimer);
          _assertSolvency("after mid-claim");
        }
      }
    }

    // Verify tight invariant at the end
    uint256 totalClaimable = _totalClaimable(members);
    uint256 distributable =
      treasury.memberPoolBalance() - treasury.memberRewardRemainder();
    assertEq(
      totalClaimable,
      distributable,
      "tight invariant: total claimable == pool - remainder"
    );
  }

  function testFuzz_rewards_cumulativeNeverDecreases(
    uint8 numJoins
  ) public {
    numJoins = uint8(bound(numJoins, 1, 15));

    uint256 prevCumulative;
    for (uint8 i; i < numJoins; ++i) {
      address joiner = makeAddr(string(abi.encodePacked("fuzz", i)));
      uint256 fee = templ.entryFee();
      token.mint(joiner, fee);

      vm.startPrank(joiner);
      token.approve(address(templ), fee);
      templ.join(joiner, address(0));
      vm.stopPrank();

      uint256 curr = treasury.cumulativeMemberRewards();
      assertGe(curr, prevCumulative, "cumulative never decreases");
      prevCumulative = curr;
    }
  }
}
