// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MemberPool } from "../../src/MemberPool.sol";
import { Templ } from "../../src/Templ.sol";
import { Treasury } from "../../src/Treasury.sol";
import { Quadratic } from "../../src/governance/Quadratic.sol";
import { IGovernance } from "../../src/interfaces/IGovernance.sol";
import { ITempl } from "../../src/interfaces/ITempl.sol";
import { EntryFeeCurve } from "../../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockFactory } from "../mocks/MockFactory.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Tests the Quadratic governance type where quorum denominator is
///      sqrt(memberCount) instead of memberCount.
contract QuadraticTest is Test {
  Templ public templ;
  Treasury public treasury;
  Quadratic public gov;
  MockERC20 public token;
  MockFactory public mf;

  address public priest = makeAddr("priest");
  address public protocolRecipient = makeAddr("protocol");

  address public alice = makeAddr("alice");
  address public bob = makeAddr("bob");
  address public charlie = makeAddr("charlie");

  uint256 public constant ENTRY_FEE = 1000e18;
  uint256 public constant APPROVAL_THRESHOLD_BPS = 5100;
  uint256 public constant QUORUM_BPS = 5100;
  uint256 public constant EXECUTION_DELAY = 1 days;
  uint256 public constant VOTING_PERIOD = 3 days;
  uint256 public constant IMMEDIATE_EXECUTION_BPS = 10_000;

  function setUp() public {
    token = new MockERC20();
    mf = new MockFactory(protocolRecipient);

    MemberPool pool;
    (treasury, pool) = mf.deployTreasuryAndPool(address(token));
    templ = new Templ(
      priest,
      address(token),
      ENTRY_FEE,
      EntryFeeCurve.exponentialWithTail(10_094, 248),
      address(treasury),
      address(pool),
      address(this),
      1000,
      address(0)
    );
    vm.prank(address(mf));
    treasury.setTempl(address(templ));
    vm.prank(address(mf));
    treasury.setMemberPool(address(pool));
    vm.prank(address(mf));
    pool.setTempl(address(templ));
    vm.prank(address(mf));
    pool.setTreasury(address(treasury));
    // Split config lives on Templ; address(this) is the temp governance
    // until the Quadratic gov is wired below.
    templ.setFeeSplit(3000, 3000, 3000);
    templ.setReferralShareBps(2500);

    _joinMember(alice);
    _joinMember(bob);
    _joinMember(charlie);

    // 4 members total: priest(#1), alice(#2), bob(#3), charlie(#4)
    // sqrt(4) = 2, so quorum denominator = 2

    gov = new Quadratic(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );

    templ.setGovernance(address(gov));
  }

  function _joinMember(
    address who
  ) internal {
    uint256 fee = templ.entryFee();
    token.mint(who, fee);
    vm.startPrank(who);
    token.approve(address(templ), fee);
    templ.join(who, address(0));
    vm.stopPrank();
  }

  function _propose(
    address proposer,
    bytes memory data
  ) internal returns (uint256) {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = data;

    vm.prank(proposer);
    return gov.propose(targets, vals, cds, "test proposal");
  }

  // ============ emitConfig ============

  function test_emitConfig_governanceType() public {
    Quadratic newGov = new Quadratic(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );

    vm.expectEmit(true, false, false, true, address(newGov));
    emit IGovernance.GovernanceInitialized(address(templ), "quadratic");

    vm.prank(address(gov));
    templ.setGovernance(address(newGov));
  }

  // ============ Access: any member can propose and vote ============

  function test_propose_anyMemberCanPropose() public {
    uint256 id =
      _propose(charlie, abi.encodeCall(ITempl.setBaseEntryFee, (2000e18)));
    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Active));
  }

  function test_vote_anyMemberCanVote() public {
    uint256 id =
      _propose(alice, abi.encodeCall(ITempl.setBaseEntryFee, (2000e18)));

    vm.prank(bob);
    gov.vote(id, 1);
    assertTrue(gov.hasVoted(id, bob));

    vm.prank(charlie);
    gov.vote(id, 1);
    assertTrue(gov.hasVoted(id, charlie));
  }

  // ============ Quorum: sqrt-based denominator ============

  function test_quorum_sqrtDenominator_singleVoteInsufficient() public {
    // 4 members -> sqrt(4) = 2 -> quorum = 51% of 2 = 2 voters needed
    // alice proposes (auto-votes FOR), so 1 of 2 = 50% < 51%
    uint256 id =
      _propose(alice, abi.encodeCall(ITempl.setBaseEntryFee, (2000e18)));

    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);

    // 1 vote out of denominator 2 = 50% < 51% quorum -> fails
    vm.expectRevert(IGovernance.QuorumNotMet.selector);
    gov.execute(id);
  }

  function test_quorum_sqrtDenominator_twoVotesPass() public {
    // 4 members -> sqrt(4) = 2 -> 51% of 2 = 2 voters needed
    uint256 id =
      _propose(alice, abi.encodeCall(ITempl.setBaseEntryFee, (2000e18)));

    // alice auto-voted FOR (1), bob votes FOR (2) -> 2/2 = 100%
    vm.prank(bob);
    gov.vote(id, 1);

    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);
    gov.execute(id);

    assertEq(templ.baseEntryFee(), 2000e18);
  }

  // ============ Scaling: quorum stays manageable as membership grows ============

  function test_quorum_scalesSublinearly() public {
    // Add 5 more members (total = 9). sqrt(9) = 3.
    // With 51% quorumBps: 2 of 3 = 67% >= 51% (passes).
    // Without quadratic: 51% of 9 = 5 voters needed.
    for (uint256 i; i < 5; ++i) {
      address member = makeAddr(string(abi.encodePacked("extra", i)));
      _joinMember(member);
    }

    assertEq(templ.memberCount(), 9);

    uint256 id =
      _propose(alice, abi.encodeCall(ITempl.setBaseEntryFee, (3000e18)));

    // alice auto-voted FOR (1), bob votes FOR (2)
    vm.prank(bob);
    gov.vote(id, 1);

    // 2 of sqrt(9)=3 = 67% > 51% -> passes
    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);
    gov.execute(id);

    assertEq(templ.baseEntryFee(), 3000e18);
  }

  // ============ Full lifecycle ============

  function test_execute_fullLifecycle() public {
    uint256 id =
      _propose(alice, abi.encodeCall(ITempl.setBaseEntryFee, (5000e18)));

    vm.prank(bob);
    gov.vote(id, 1);

    // Immediate execution: 2/2 = 100% of sqrt denominator
    gov.execute(id);

    assertEq(templ.baseEntryFee(), 5000e18);
    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Executed));
  }

  function test_execute_revertsIfDefeated() public {
    uint256 id =
      _propose(alice, abi.encodeCall(ITempl.setBaseEntryFee, (2000e18)));

    // bob votes AGAINST
    vm.prank(bob);
    gov.vote(id, 0);

    // 1 FOR, 1 AGAINST -> FOR does not exceed AGAINST
    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);

    vm.expectRevert(IGovernance.QuorumNotMet.selector);
    gov.execute(id);
  }
}
