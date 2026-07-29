// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MemberPool } from "../src/MemberPool.sol";
import { Templ } from "../src/Templ.sol";
import { Treasury } from "../src/Treasury.sol";
import { IMemberPool } from "../src/interfaces/IMemberPool.sol";
import { CurveConfig, EntryFeeCurve } from "../src/libraries/EntryFeeCurve.sol";
import { HookERC20 } from "./mocks/HookERC20.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockFactory } from "./mocks/MockFactory.sol";
import { OnJoinAttacker } from "./mocks/OnJoinAttacker.sol";
import {
  ReentrantReferralAttacker
} from "./mocks/ReentrantReferralAttacker.sol";
import { ReentrantToken } from "./mocks/ReentrantToken.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Coverage target: 95% line / 90% branch on MemberPool.sol. Tests the
///      cumulative-snapshot accounting, balance-delta absorption, claim flow,
///      reentrancy guard, and solvency invariants under fuzzing. There is no
///      governance path: pool dust is stranded by design.
contract MemberPoolTest is Test {
  Templ public templ;
  Treasury public treasury;
  MemberPool public pool;
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

  function _defaultCurve() internal pure returns (CurveConfig memory) {
    return EntryFeeCurve.exponentialWithTail(10_094, 248);
  }

  function _deployTrio() internal {
    mockFactory = new MockFactory(protocolRecipient);
    (treasury, pool) = mockFactory.deployTreasuryAndPool(address(token));

    templ = new Templ(
      priest,
      address(token),
      ENTRY_FEE,
      _defaultCurve(),
      address(treasury),
      address(pool),
      priest,
      PROTOCOL_BPS,
      address(0)
    );

    vm.prank(address(mockFactory));
    treasury.setTempl(address(templ));
    vm.prank(address(mockFactory));
    treasury.setMemberPool(address(pool));
    vm.prank(address(mockFactory));
    pool.setTempl(address(templ));
    vm.prank(address(mockFactory));
    pool.setTreasury(address(treasury));
    // Split config lives on Templ; priest doubles as governance.
    vm.prank(priest);
    templ.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);
    vm.prank(priest);
    templ.setReferralShareBps(REFERRAL_SHARE_BPS);
  }

  function setUp() public {
    token = new MockERC20();
    _deployTrio();

    token.mint(user1, 1_000_000e18);
    token.mint(user2, 1_000_000e18);
    token.mint(user3, 1_000_000e18);
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

  function _assertSolvency(
    string memory label
  ) internal view {
    uint256 balance = token.balanceOf(address(pool));
    uint256 owed = pool.totalDeposited() - pool.totalClaimed();
    assertGe(
      balance, owed, string.concat(label, ": balance >= deposited - claimed")
    );
  }

  // ============ Constructor / Init ============

  function test_constructor_setsImmutables() public view {
    assertEq(pool.TOKEN(), address(token));
    assertEq(pool.FACTORY(), address(mockFactory));
  }

  function test_constructor_revertsOnZeroToken() public {
    MockFactory mf = new MockFactory(protocolRecipient);
    vm.expectRevert(IMemberPool.ZeroToken.selector);
    mf.deployMemberPool(address(0));
  }

  function test_setTempl_onlyFactory() public {
    MockFactory mf = new MockFactory(protocolRecipient);
    MemberPool p = mf.deployMemberPool(address(token));
    vm.prank(user1);
    vm.expectRevert(IMemberPool.NotDeployer.selector);
    p.setTempl(address(templ));
  }

  function test_setTempl_oneShot() public {
    vm.prank(address(mockFactory));
    vm.expectRevert(IMemberPool.AlreadyInitialized.selector);
    pool.setTempl(makeAddr("other"));
  }

  function test_setTempl_revertsOnZero() public {
    MockFactory mf = new MockFactory(protocolRecipient);
    MemberPool p = mf.deployMemberPool(address(token));
    vm.prank(address(mf));
    vm.expectRevert(IMemberPool.ZeroTempl.selector);
    p.setTempl(address(0));
  }

  function test_setTreasury_onlyFactory() public {
    MockFactory mf = new MockFactory(protocolRecipient);
    MemberPool p = mf.deployMemberPool(address(token));
    vm.prank(user1);
    vm.expectRevert(IMemberPool.NotDeployer.selector);
    p.setTreasury(address(treasury));
  }

  function test_setTreasury_oneShot() public {
    vm.prank(address(mockFactory));
    vm.expectRevert(IMemberPool.AlreadyInitialized.selector);
    pool.setTreasury(makeAddr("other"));
  }

  function test_setTreasury_revertsOnZero() public {
    MockFactory mf = new MockFactory(protocolRecipient);
    MemberPool p = mf.deployMemberPool(address(token));
    vm.prank(address(mf));
    vm.expectRevert(IMemberPool.ZeroTreasury.selector);
    p.setTreasury(address(0));
  }

  // ============ onJoin (access control) ============

  function test_onJoin_revertsIfNotTempl() public {
    vm.prank(user1);
    vm.expectRevert(IMemberPool.NotTempl.selector);
    pool.onJoin(100, user1, 1);
  }

  function test_onJoin_revertsIfNoExistingMembers() public {
    // Direct call as templ to hit the existingMemberCount==0 branch.
    vm.prank(address(templ));
    vm.expectRevert(IMemberPool.NoExistingMembers.selector);
    pool.onJoin(100, user1, 0);
  }

  function test_onJoin_revertsOnAmountMismatch() public {
    // Tell pool we delivered 100 tokens, but transfer nothing - the balance
    // re-measurement detects the shortfall.
    vm.prank(address(templ));
    vm.expectRevert(IMemberPool.AmountMismatch.selector);
    pool.onJoin(100, user1, 1);
  }

  // ============ Reward distribution ============

  function test_priestEarnsFromFirstJoin() public {
    _join(user1);

    // Priest is the only existing member when user1 joins.
    uint256 expectedPool = (ENTRY_FEE * MEMBER_POOL_BPS) / 10_000;
    uint256 claimable = pool.getClaimableRewards(priest);
    assertEq(claimable, expectedPool, "priest gets full pool from first join");
  }

  function test_newMemberSnapshotEqualsCumulativeAfterJoin() public {
    _join(user1);
    // user1 joined this round; their snapshot should equal cumulative -> no claim
    assertEq(pool.getClaimableRewards(user1), 0);
    assertEq(pool.rewardSnapshot(user1), pool.cumulativeRewards());
  }

  function test_rewards_splitBetweenExistingMembers() public {
    _join(user1);
    uint256 cumulBefore = pool.cumulativeRewards();
    _join(user2);

    // 2 existing members (priest + user1) before user2 joined
    uint256 fee2 = (ENTRY_FEE * 10_094) / 10_000; // approximate 2nd fee
    uint256 pool2 = (fee2 * MEMBER_POOL_BPS) / 10_000;
    uint256 perMember = pool2 / 2;

    assertEq(pool.cumulativeRewards() - cumulBefore, perMember);
  }

  // ============ claimRewards ============

  function test_claim_success() public {
    _join(user1);
    uint256 claimable = pool.getClaimableRewards(priest);
    assertGt(claimable, 0);

    uint256 before = token.balanceOf(priest);
    vm.prank(priest);
    pool.claimRewards(priest);

    assertEq(token.balanceOf(priest) - before, claimable);
    assertEq(pool.getClaimableRewards(priest), 0);
    assertEq(pool.claims(priest), claimable);
    assertEq(pool.totalClaimed(), claimable);
  }

  function test_claim_onBehalf() public {
    _join(user1);
    uint256 claimable = pool.getClaimableRewards(priest);

    // user1 calls on behalf of priest - tokens go to priest
    uint256 before = token.balanceOf(priest);
    vm.prank(user1);
    pool.claimRewards(priest);

    assertEq(token.balanceOf(priest) - before, claimable);
    assertEq(
      token.balanceOf(user1), 1_000_000e18 - ENTRY_FEE, "user1 untouched"
    );
  }

  function test_claim_revertsIfNotMember() public {
    vm.expectRevert(IMemberPool.NotMember.selector);
    pool.claimRewards(user1); // user1 is not a member
  }

  function test_claim_revertsIfNothingToClaim() public {
    _join(user1);
    vm.expectRevert(IMemberPool.NoRewardsToClaim.selector);
    pool.claimRewards(user1); // user1 just joined - snapshot == cumulative
  }

  function test_getClaimableRewards_zeroForNonMember() public view {
    assertEq(pool.getClaimableRewards(user1), 0);
  }

  // ============ Absorption: dissolve / direct donation ============

  function test_onJoin_absorbsTreasuryDissolveDelta() public {
    _join(user1);
    _join(user2);

    // Donate funds directly to pool to mimic Treasury.dissolve transfer
    uint256 donation = 5000e18;
    token.mint(address(this), donation);
    require(token.transfer(address(pool), donation), "transfer failed");

    uint256 cumulBefore = pool.cumulativeRewards();
    uint256 totalDepositedBefore = pool.totalDeposited();

    // Trigger a paid join: the donation should be folded into THIS round
    _join(user3);

    // 3 existing members (priest, user1, user2). The round's distributable
    // pool plus the donation are split evenly.
    uint256 totalDepositedAfter = pool.totalDeposited();
    uint256 absorbed = totalDepositedAfter - totalDepositedBefore;
    assertGe(absorbed, donation, "round absorbed at least the donation");

    // cumulativeRewards strictly increased
    assertGt(pool.cumulativeRewards(), cumulBefore);
  }

  function test_onJoin_absorbsDirectDonation() public {
    _join(user1);
    uint256 donation = 1234e18;
    token.mint(address(this), donation);
    require(token.transfer(address(pool), donation), "transfer failed");

    // Solvency holds even before the next join (balance can only be >= owed)
    _assertSolvency("after donation");

    uint256 totalDepositedBefore = pool.totalDeposited();
    _join(user2);

    // The donation got folded into user2's round
    uint256 absorbed = pool.totalDeposited() - totalDepositedBefore;
    assertGe(absorbed, donation);
    _assertSolvency("after absorbing donation");
  }

  // ============ accrue() ============

  function test_accrue_distributesDirectDonation() public {
    _join(user1);
    _join(user2);

    uint256 cumulBefore = pool.cumulativeRewards();
    uint256 totalDepositedBefore = pool.totalDeposited();

    uint256 donation = 6000e18;
    token.mint(address(this), donation);
    require(token.transfer(address(pool), donation), "transfer failed");

    pool.accrue();

    // 3 members (priest + user1 + user2): perMember = 6000e18 / 3 = 2000e18.
    assertEq(
      pool.cumulativeRewards() - cumulBefore,
      donation / 3,
      "perMember increment"
    );
    assertEq(
      pool.totalDeposited() - totalDepositedBefore,
      donation,
      "totalDeposited grew by donation"
    );
    assertEq(pool.rewardRemainder(), 0, "no remainder for clean division");
    _assertSolvency("after accrue");
  }

  function test_accrue_afterDissolve_membersClaimImmediately() public {
    _join(user1);
    _join(user2);

    // Top up Treasury and dissolve. The dissolved amount = whatever Treasury
    // accumulated from the join splits + this top-up. Compute it from the
    // pool balance delta rather than hard-coding.
    token.mint(address(treasury), 9000e18);
    uint256 priestClaimableBefore = pool.getClaimableRewards(priest);
    uint256 cumulativeBefore = pool.cumulativeRewards();

    vm.prank(priest);
    treasury.dissolve();

    // The full dissolved amount sits at the pool but is not yet accounted.
    uint256 absorbed = token.balanceOf(address(pool))
      - (pool.totalDeposited() - pool.totalClaimed());

    pool.accrue();

    // 3 members. perMember = absorbed/3.
    uint256 perMember = absorbed / 3;
    assertEq(
      pool.cumulativeRewards() - cumulativeBefore,
      perMember,
      "cumulative bumped by perMember"
    );
    assertEq(
      pool.getClaimableRewards(priest) - priestClaimableBefore,
      perMember,
      "priest claimable up by perMember"
    );

    // Claim works end-to-end.
    uint256 priestBalBefore = token.balanceOf(priest);
    pool.claimRewards(priest);
    assertEq(
      token.balanceOf(priest) - priestBalBefore,
      priestClaimableBefore + perMember,
      "priest received full claim"
    );
    _assertSolvency("after dissolve+accrue+claim");
  }

  function test_accrue_idempotentNoOp() public {
    _join(user1);

    uint256 cumulBefore = pool.cumulativeRewards();
    uint256 depositedBefore = pool.totalDeposited();
    uint256 remainderBefore = pool.rewardRemainder();

    pool.accrue();

    assertEq(pool.cumulativeRewards(), cumulBefore, "cumulative unchanged");
    assertEq(pool.totalDeposited(), depositedBefore, "deposited unchanged");
    assertEq(pool.rewardRemainder(), remainderBefore, "remainder unchanged");
  }

  function test_accrue_emitsEvent() public {
    _join(user1);

    uint256 donation = 3000e18;
    token.mint(address(this), donation);
    require(token.transfer(address(pool), donation), "transfer failed");

    vm.expectEmit(true, false, false, true, address(pool));
    emit IMemberPool.RewardsAccrued(address(templ), donation, 2);
    pool.accrue();
  }

  function test_accrue_foldsLingeringRemainder() public {
    _join(user1);
    _join(user2);
    _join(user3);
    // Templ.memberCount() = 4 (priest + 3 users).

    // Donate 7 wei. accrue distributes 7/4 = 1 perMember, remainder = 3.
    token.mint(address(this), 7);
    require(token.transfer(address(pool), 7), "transfer failed");
    pool.accrue();
    assertEq(pool.rewardRemainder(), 3, "3 wei remainder");

    // Donate 1 wei: total = 3 + 1 = 4. Divides cleanly: 4/4 = 1 each.
    token.mint(address(this), 1);
    require(token.transfer(address(pool), 1), "transfer failed");
    pool.accrue();
    assertEq(pool.rewardRemainder(), 0, "remainder cleared");
  }

  // ============ Remainder accumulation (no sweep path) ============

  /// @dev Rounding dust accumulating in rewardRemainder is stranded by the
  ///      no-admin invariant. The next
  ///      paid join folds it back into that round's distribution; if no future
  ///      joins occur, the dust stays in the pool's balance forever.
  function test_remainder_isAbsorbedOnNextJoin() public {
    _join(user1); // priest, user1 are existing members (exact division)
    _join(user2); // priest, user1, user2 are existing members (exact division)

    // Force a non-zero remainder. Deliver 7 wei across 3 existing members:
    // perMember = 7 / 3 = 2, remainder = 7 - (2 * 3) = 1.
    // Mint 7 wei directly so the actual-vs-expected balance check passes.
    token.mint(address(pool), 7);
    vm.prank(address(templ));
    pool.onJoin(7, user3, 3);

    assertEq(pool.rewardRemainder(), 1, "expected 1 wei remainder");

    // Next paid join rolls the remainder into that round's distribution. With
    // priest + user1..user3 = 4 existing members and 11 wei delivered, total
    // = 11 + 1 = 12, perMember = 3, remainder = 0.
    token.mint(address(pool), 11);
    vm.prank(address(templ));
    pool.onJoin(11, makeAddr("user4"), 4);

    assertEq(pool.rewardRemainder(), 0, "remainder absorbed on next join");
    _assertSolvency("after remainder absorption");
  }

  // ============ Reentrancy ============

  function test_claim_resistsReentrancy() public {
    ReentrantToken evil = new ReentrantToken();
    MockFactory evilFactory = new MockFactory(protocolRecipient);
    (Treasury evilTreasury, MemberPool evilPool) =
      evilFactory.deployTreasuryAndPool(address(evil));
    Templ evilTempl = new Templ(
      priest,
      address(evil),
      ENTRY_FEE,
      _defaultCurve(),
      address(evilTreasury),
      address(evilPool),
      priest,
      PROTOCOL_BPS,
      address(0)
    );
    vm.prank(address(evilFactory));
    evilTreasury.setTempl(address(evilTempl));
    vm.prank(address(evilFactory));
    evilTreasury.setMemberPool(address(evilPool));
    vm.prank(address(evilFactory));
    evilPool.setTempl(address(evilTempl));
    vm.prank(address(evilFactory));
    evilPool.setTreasury(address(evilTreasury));
    // Split config lives on Templ; priest doubles as governance.
    vm.prank(priest);
    evilTempl.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);

    evil.mint(user1, 100_000e18);
    vm.startPrank(user1);
    evil.approve(address(evilTempl), type(uint256).max);
    evilTempl.join(user1, address(0));
    vm.stopPrank();

    evil.setAttack(
      address(evilPool), abi.encodeCall(evilPool.claimRewards, (priest))
    );

    uint256 claimable = evilPool.getClaimableRewards(priest);
    uint256 before = evil.balanceOf(priest);

    vm.prank(priest);
    evilPool.claimRewards(priest);

    // Single payout, reentrant call blocked by transient guard.
    assertEq(evil.balanceOf(priest) - before, claimable);
    assertEq(evilPool.getClaimableRewards(priest), 0);
  }

  // ============ Multi-round remainder ============

  function test_remainder_carriesForwardToNextRound() public {
    _join(user1); // 1 existing -> exact
    assertEq(pool.rewardRemainder(), 0);

    _join(user2); // 2 existing
    uint256 remainderRound2 = pool.rewardRemainder();

    uint256 cumulBefore = pool.cumulativeRewards();
    uint256 totalDepositedBefore = pool.totalDeposited();

    _join(user3); // 3 existing - prior remainder folded in

    uint256 distributable = pool.totalDeposited() - totalDepositedBefore;
    uint256 totalRewards = distributable + remainderRound2;
    uint256 expectedPerMember = totalRewards / 3;
    uint256 expectedRemainder = totalRewards % 3;

    assertEq(
      pool.cumulativeRewards() - cumulBefore,
      expectedPerMember,
      "perMember includes carried remainder"
    );
    assertEq(pool.rewardRemainder(), expectedRemainder);
    _assertSolvency("after remainder carry-forward");
  }

  // ============ Tight solvency invariant ============

  function test_solvency_allClaim_balanceEqualsRemainder() public {
    _join(user1);
    _join(user2);
    _join(user3);

    pool.claimRewards(priest);
    pool.claimRewards(user1);
    pool.claimRewards(user2);
    // user3 has nothing (joined last)

    assertEq(pool.getClaimableRewards(user3), 0);

    // Pool balance == rewardRemainder once everyone claimed.
    assertEq(
      token.balanceOf(address(pool)) - pool.rewardRemainder(),
      0,
      "balance == remainder after all claims"
    );
    _assertSolvency("after all claims");
  }

  // ============ Fuzz: solvency under random join+claim sequences ============

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

      _assertSolvency("after join");

      // Pseudo-randomly claim from a prior member
      if (uint256(keccak256(abi.encode(claimSeed, i))) % 3 == 0 && i > 0) {
        uint256 idx =
          uint256(keccak256(abi.encode(claimSeed, i, "pick"))) % (i + 1);
        address claimer = members[idx];
        uint256 claimable = pool.getClaimableRewards(claimer);
        if (claimable > 0) {
          pool.claimRewards(claimer);
          _assertSolvency("after mid-claim");
        }
      }
    }

    // Tight invariant: total claimable == totalDeposited - totalClaimed - remainder
    uint256 totalClaimable;
    for (uint256 i; i < members.length; ++i) {
      totalClaimable += pool.getClaimableRewards(members[i]);
    }
    uint256 owed = pool.totalDeposited() - pool.totalClaimed();
    assertEq(
      totalClaimable + pool.rewardRemainder(),
      owed,
      "total claimable + remainder == owed"
    );
  }

  function testFuzz_cumulativeNeverDecreases(
    uint8 numJoins
  ) public {
    numJoins = uint8(bound(numJoins, 1, 15));
    uint256 prev;

    for (uint8 i; i < numJoins; ++i) {
      address joiner = makeAddr(string(abi.encodePacked("fuzz", i)));
      uint256 fee = templ.entryFee();
      token.mint(joiner, fee);

      vm.startPrank(joiner);
      token.approve(address(templ), fee);
      templ.join(joiner, address(0));
      vm.stopPrank();

      uint256 curr = pool.cumulativeRewards();
      assertGe(curr, prev);
      prev = curr;
    }
  }

  // ============ Cross-contract reentrancy guard (security review) ============

  /// @dev Pins the snapshot-before-transfer ordering in
  ///      Templ._splitAndForward. With a hook-bearing TOKEN (modelled here by
  ///      HookERC20, an ERC777-style mock), an attacker who points `referral`
  ///      at a contract they control would otherwise reenter
  ///      MemberPool.claimRewards from inside the referral transfer while the
  ///      new member's snapshot was still 0, draining the entire
  ///      cumulativeRewards stream. To prevent this, Templ transfers to
  ///      MemberPool and calls onJoin BEFORE any other external transfer,
  ///      pinning rewardSnapshot[newMember] = cumulative. A later hook
  ///      reentering claimRewards on the new member sees snapshot >= cumulative
  ///      and reverts with NoRewardsToClaim.
  ///
  ///      Defense layers verified:
  ///      1. The attacker's reentrant claim attempt fires (the hook runs).
  ///      2. The attempt does NOT succeed (no token outflow).
  ///      3. cumulativeRewards is preserved.
  ///      4. The solvency invariant holds.
  function test_security_referralHookCannotDrainCumulativeRewards() public {
    // Trio with a hook-bearing TOKEN.
    HookERC20 hook = new HookERC20();
    MockFactory hookFactory = new MockFactory(protocolRecipient);
    (Treasury hookTreasury, MemberPool hookPool) =
      hookFactory.deployTreasuryAndPool(address(hook));
    Templ hookTempl = new Templ(
      priest,
      address(hook),
      ENTRY_FEE,
      _defaultCurve(),
      address(hookTreasury),
      address(hookPool),
      priest,
      PROTOCOL_BPS,
      address(0)
    );
    vm.startPrank(address(hookFactory));
    hookTreasury.setTempl(address(hookTempl));
    hookTreasury.setMemberPool(address(hookPool));
    hookPool.setTempl(address(hookTempl));
    hookPool.setTreasury(address(hookTreasury));
    vm.stopPrank();
    // Split config lives on Templ; priest doubles as governance.
    vm.startPrank(priest);
    hookTempl.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);
    hookTempl.setReferralShareBps(REFERRAL_SHARE_BPS);
    vm.stopPrank();

    // Deploy the attacker contract (will become a member via referral target).
    ReentrantReferralAttacker attacker =
      new ReentrantReferralAttacker(address(hookPool));
    hook.setHookEnabled(address(attacker), true);

    // Step 1: attacker contract joins legitimately so it qualifies as a
    // referral target (members[attacker].id != 0).
    hook.mint(address(attacker), ENTRY_FEE * 10);
    vm.startPrank(address(attacker));
    hook.approve(address(hookTempl), type(uint256).max);
    hookTempl.join(address(attacker), address(0));
    vm.stopPrank();

    // Step 2: another legitimate join so cumulativeRewards > 0 in the pool.
    hook.mint(user2, ENTRY_FEE * 10);
    vm.startPrank(user2);
    hook.approve(address(hookTempl), type(uint256).max);
    hookTempl.join(user2, address(0));
    vm.stopPrank();

    uint256 cumulativeBeforeAttack = hookPool.cumulativeRewards();
    assertGt(cumulativeBeforeAttack, 0, "cumulative must be non-zero");
    uint256 poolBalanceBefore = hook.balanceOf(address(hookPool));

    // Step 3: arm the attacker contract. When tokensReceived fires (during
    // Templ's referral payout to attacker), it tries to drain rewards for
    // user3 - the freshly-registered EOA.
    attacker.primeAttack(user3);

    // Step 4: user3 joins with referral = attacker contract. The hook fires
    // inside the referral transfer.
    hook.mint(user3, ENTRY_FEE * 10);
    uint256 user3BalanceBefore = hook.balanceOf(user3);
    uint256 user3JoinFee = hookTempl.entryFee();
    vm.startPrank(user3);
    hook.approve(address(hookTempl), type(uint256).max);
    hookTempl.join(user3, address(attacker));
    vm.stopPrank();

    // Defense check 1: the attack DID fire (hook ran, claim was attempted).
    //                  Without this assertion the test would silently pass
    //                  even if the attack path were bypassed entirely.
    assertTrue(attacker.attackFired(), "attack hook must have fired");

    // Defense check 2: the attack did NOT succeed.
    assertFalse(
      attacker.attackSucceeded(), "reentrant claim must not transfer any token"
    );

    // Defense check 3: user3's snapshot is pinned to current cumulative -
    //                  no rewards claimable from accumulated history.
    assertEq(
      hookPool.getClaimableRewards(user3),
      0,
      "new member must not be able to claim from accumulated cumulative"
    );

    // Defense check 4: user3 did NOT receive any out-of-band transfer. Their
    //                  balance dropped by exactly entryFee.
    uint256 user3BalanceAfter = hook.balanceOf(user3);
    assertEq(
      user3BalanceBefore - user3BalanceAfter,
      user3JoinFee,
      "attacker must lose exactly entryFee - no reward outflow"
    );

    // Defense check 5: pool balance grew by at least the member-pool slice
    //                  (it was not drained by the reentrant claim).
    assertGe(
      hook.balanceOf(address(hookPool)),
      poolBalanceBefore,
      "pool balance must not have decreased"
    );

    // Defense check 6: cumulativeRewards only grew - never consumed by claim.
    assertGe(
      hookPool.cumulativeRewards(),
      cumulativeBeforeAttack,
      "cumulative must not decrease via reentrancy"
    );

    // Defense check 7: solvency invariant holds.
    uint256 owed = hookPool.totalDeposited() - hookPool.totalClaimed();
    assertGe(
      hook.balanceOf(address(hookPool)),
      owed,
      "solvency invariant preserved post-attack"
    );
  }

  // ============ Direct reentrancy on onJoin ============

  /// @dev External callers cannot invoke onJoin: it carries the onlyTempl
  ///      modifier. The transient nonReentrant guard layered on top blocks
  ///      same-contract reentry. Verifies both gates explicitly.
  function test_onJoin_externalCallerReverts() public {
    // EOA cannot call onJoin.
    vm.prank(user1);
    vm.expectRevert(IMemberPool.NotTempl.selector);
    pool.onJoin(100, user2, 1);

    // Even another contract address cannot call - only `templ` may.
    vm.prank(address(treasury));
    vm.expectRevert(IMemberPool.NotTempl.selector);
    pool.onJoin(100, user2, 1);

    // address(this) (the test contract) cannot call.
    vm.expectRevert(IMemberPool.NotTempl.selector);
    pool.onJoin(100, user2, 1);
  }

  /// @dev When TOKEN has receive hooks, the splitter's per-slice transfers
  ///      could fire a synchronous callback. The callback cannot reenter
  ///      onJoin directly (onlyTempl reverts because msg.sender is the token
  ///      or attacker contract, not templ). Combined with Templ's per-call
  ///      nonReentrant guard, an attacker has no path to a second onJoin
  ///      within a single join. This test wires a hook-bearing token plus an
  ///      attacker contract that tries to call pool.onJoin from its
  ///      tokensReceived hook.
  function test_security_onJoin_directReentrancyBlocked() public {
    HookERC20 hook = new HookERC20();
    MockFactory hookFactory = new MockFactory(protocolRecipient);
    (Treasury hookTreasury, MemberPool hookPool) =
      hookFactory.deployTreasuryAndPool(address(hook));
    Templ hookTempl = new Templ(
      priest,
      address(hook),
      ENTRY_FEE,
      _defaultCurve(),
      address(hookTreasury),
      address(hookPool),
      priest,
      PROTOCOL_BPS,
      address(0)
    );
    vm.startPrank(address(hookFactory));
    hookTreasury.setTempl(address(hookTempl));
    hookTreasury.setMemberPool(address(hookPool));
    hookPool.setTempl(address(hookTempl));
    hookPool.setTreasury(address(hookTreasury));
    vm.stopPrank();
    // Split config lives on Templ; priest doubles as governance.
    vm.startPrank(priest);
    hookTempl.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);
    hookTempl.setReferralShareBps(REFERRAL_SHARE_BPS);
    vm.stopPrank();

    OnJoinAttacker attacker = new OnJoinAttacker(address(hookPool));
    hook.setHookEnabled(address(attacker), true);

    // attacker registers as a member so they can be a referral target.
    hook.mint(address(attacker), ENTRY_FEE * 10);
    vm.startPrank(address(attacker));
    hook.approve(address(hookTempl), type(uint256).max);
    hookTempl.join(address(attacker), address(0));
    vm.stopPrank();

    attacker.prime();

    // user2 joins with referral = attacker. Referral transfer fires the hook,
    // hook tries pool.onJoin(...) which reverts with NotTempl. The catch in
    // the attacker swallows the revert; outer join completes.
    hook.mint(user2, ENTRY_FEE * 10);
    vm.startPrank(user2);
    hook.approve(address(hookTempl), type(uint256).max);
    hookTempl.join(user2, address(attacker));
    vm.stopPrank();

    assertTrue(attacker.attackFired(), "attack hook must have fired");
    assertFalse(
      attacker.attackSucceeded(),
      "direct onJoin reentry must be blocked by onlyTempl"
    );
    assertTrue(hookTempl.isMember(user2));
    assertEq(hookPool.getClaimableRewards(user2), 0);
    uint256 owed = hookPool.totalDeposited() - hookPool.totalClaimed();
    assertGe(hook.balanceOf(address(hookPool)), owed);
  }

  // ============ Free-join with stranded remainder ============

  /// @dev Math gap: when a Templ has entryFee == 0 but a prior weighted join
  ///      left a non-zero rewardRemainder, the next free join folds the
  ///      stranded remainder into existing members and the new free joiner's
  ///      snapshot is set to the post-distribution cumulative. The free joiner
  ///      gets nothing from the absorption. Verified directly against onJoin
  ///      (Templ-side: _processJoin calls onJoin(0, ...) when fee == 0).
  function test_freeJoin_distributesStrandedRemainder() public {
    // Two paid joins create a baseline. Then force a non-zero remainder via
    // direct onJoin: 5 wei across 3 existing members -> perMember = 1, rem = 2.
    _join(user1); // priest, user1 are members
    _join(user2); // priest, user1, user2 are members

    token.mint(address(pool), 5);
    vm.prank(address(templ));
    pool.onJoin(5, user3, 3);
    assertEq(pool.rewardRemainder(), 2, "expected 2 wei stranded remainder");

    uint256 cumulativeBefore = pool.cumulativeRewards();
    uint256 totalDepositedBefore = pool.totalDeposited();

    // Free join: deliveredAmount == 0 with 4 existing members. Total to
    // distribute = 0 + 0 (absorbed) + 2 (carried remainder) = 2. perMember =
    // 2 / 4 = 0, new remainder = 2. So cumulative does NOT increase, the
    // stranded remainder stays put, and the free joiner gets nothing.
    address freeJoiner = makeAddr("freeJoiner");
    vm.prank(address(templ));
    pool.onJoin(0, freeJoiner, 4);

    assertEq(
      pool.cumulativeRewards() - cumulativeBefore,
      0,
      "free join with sub-count remainder must not advance cumulative"
    );
    assertEq(
      pool.rewardRemainder(),
      2,
      "remainder unchanged when totalRewards < memberCount"
    );
    assertEq(
      pool.totalDeposited() - totalDepositedBefore,
      0,
      "free join with no absorption must not bump totalDeposited"
    );
    assertEq(pool.rewardSnapshot(freeJoiner), pool.cumulativeRewards());

    // Now deliver another free join with smaller existingMemberCount = 2 so
    // the stranded 2 wei DOES distribute: total = 2, perMember = 1, rem = 0.
    address freeJoiner2 = makeAddr("freeJoiner2");
    uint256 cumulativeBefore2 = pool.cumulativeRewards();
    vm.prank(address(templ));
    pool.onJoin(0, freeJoiner2, 2);

    assertEq(
      pool.cumulativeRewards() - cumulativeBefore2,
      1,
      "free join distributes stranded remainder when count divides evenly"
    );
    assertEq(pool.rewardRemainder(), 0, "remainder fully absorbed");
    // freeJoiner2 still gets nothing for their own round.
    assertEq(pool.getClaimableRewards(freeJoiner2), 0);
    _assertSolvency("after free-join distributing stranded remainder");
  }

  // ============ referralShareBps == BPS (full carve) ============

  /// @dev Math gap: when referralShareBps == 10000 the referrer takes the
  ///      entire member-pool slice and distributablePool == 0. The
  ///      distribution math handles the zero correctly: no new per-member
  ///      reward is emitted, but the new member's snapshot still pins to the
  ///      current cumulativeRewards so they cannot claim accumulated history.
  function test_referralShareBps_fullCarve_skipsZeroTransferAndPinsSnapshot()
    public
  {
    // Set referralShareBps to BPS (10000). Lives on Templ.
    vm.prank(priest);
    templ.setReferralShareBps(10_000);

    // user1 joins (no referral, so full slice goes to pool, priest earns).
    _join(user1);
    uint256 cumulativeBefore = pool.cumulativeRewards();
    assertGt(cumulativeBefore, 0);
    uint256 priestClaimableBefore = pool.getClaimableRewards(priest);
    uint256 totalDepositedBefore = pool.totalDeposited();

    // user2 joins with user1 as referral. user1 takes the entire member-pool
    // slice; distributablePool = 0; pool's cumulative does not advance from
    // this round.
    uint256 user1BalanceBefore = token.balanceOf(user1);
    vm.startPrank(user2);
    token.approve(address(templ), templ.entryFee());
    templ.join(user2, user1);
    vm.stopPrank();

    // Verify the carve: user1's balance grew by the full member-pool slice.
    uint256 fee2 = (ENTRY_FEE * 10_094) / 10_000; // approximate 2nd fee
    uint256 expectedCarve = (fee2 * MEMBER_POOL_BPS) / 10_000;
    assertEq(
      token.balanceOf(user1) - user1BalanceBefore,
      expectedCarve,
      "referrer takes full member-pool slice"
    );

    // Verify cumulative did not advance and totalDeposited did not grow.
    assertEq(
      pool.cumulativeRewards(),
      cumulativeBefore,
      "cumulative unchanged when distributablePool == 0"
    );
    assertEq(
      pool.totalDeposited(),
      totalDepositedBefore,
      "totalDeposited unchanged when distributablePool == 0"
    );

    // Existing members' claims unaffected.
    assertEq(
      pool.getClaimableRewards(priest),
      priestClaimableBefore,
      "priest claimable unchanged - this round skipped distribution"
    );

    // Critical: user2's snapshot is still pinned to current cumulative even
    // though distribution was skipped. They cannot claim accumulated history.
    assertEq(
      pool.rewardSnapshot(user2),
      pool.cumulativeRewards(),
      "new member snapshot pinned even with zero distribution"
    );
    assertEq(
      pool.getClaimableRewards(user2),
      0,
      "new member cannot claim from prior cumulative when carve is full"
    );

    _assertSolvency("after full-carve referral");
  }
}
