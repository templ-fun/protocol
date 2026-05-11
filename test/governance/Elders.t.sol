// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MemberPool } from "../../src/MemberPool.sol";
import { Templ } from "../../src/Templ.sol";
import { Treasury } from "../../src/Treasury.sol";
import { Elders } from "../../src/governance/Elders.sol";
import { IGovernance } from "../../src/interfaces/IGovernance.sol";
import { ITempl } from "../../src/interfaces/ITempl.sol";
import { EntryFeeCurve } from "../../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockFactory } from "../mocks/MockFactory.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Tests the Elders governance type where only the first N members
///      (by join order) can vote.
contract EldersTest is Test {
  Templ public templ;
  Treasury public treasury;
  Elders public gov;
  MockERC20 public token;
  MockFactory public mf;

  address public priest = makeAddr("priest");
  address public protocolRecipient = makeAddr("protocol");

  // Elders (join first, within threshold)
  address public elder1 = makeAddr("elder1");
  address public elder2 = makeAddr("elder2");

  // Late joiners (outside threshold, cannot vote)
  address public latecomer = makeAddr("latecomer");

  uint256 public constant ENTRY_FEE = 1000e18;
  uint256 public constant APPROVAL_THRESHOLD_BPS = 5100;
  uint256 public constant QUORUM_BPS = 5100;
  uint256 public constant EXECUTION_DELAY = 1 days;
  uint256 public constant VOTING_PERIOD = 3 days;
  uint256 public constant IMMEDIATE_EXECUTION_BPS = 10_000;

  // priest = member #1, elder1 = #2, elder2 = #3, latecomer = #4
  // Threshold of 3 means members #1-#3 are elders
  uint64 public constant ELDER_THRESHOLD = 3;

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
    // until the Elders gov is wired below.
    templ.setFeeSplit(3000, 3000, 3000);
    templ.setReferralShareBps(2500);

    _joinMember(elder1);
    _joinMember(elder2);
    _joinMember(latecomer);

    gov = new Elders(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      ELDER_THRESHOLD
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

  // ============ Constructor ============

  function test_constructor() public view {
    assertEq(gov.elderThreshold(), ELDER_THRESHOLD);
  }

  function test_constructor_revertsIfZeroThreshold() public {
    vm.expectRevert(Elders.InvalidElderThreshold.selector);
    new Elders(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      0 // invalid
    );
  }

  // ============ emitConfig ============

  function test_emitConfig_emitsEldersInitialized() public {
    Elders newGov = new Elders(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      ELDER_THRESHOLD
    );

    // setGovernance calls emitConfig which triggers _afterEmitConfig
    vm.expectEmit(true, false, false, true, address(newGov));
    emit Elders.EldersInitialized(address(templ), ELDER_THRESHOLD);

    vm.prank(address(gov));
    templ.setGovernance(address(newGov));
  }

  // ============ Propose: any member ============

  function test_propose_anyMemberCanPropose() public {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    // latecomer (member #4) can propose even though they can't vote
    vm.prank(latecomer);
    uint256 id = gov.propose(targets, vals, cds, "raise fee");

    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Active));

    // latecomer cannot vote so no auto-vote
    assertFalse(gov.hasVoted(id, latecomer));
  }

  // ============ Vote: only elders ============

  function test_vote_elderCanVote() public {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    vm.prank(elder1);
    uint256 id = gov.propose(targets, vals, cds, "raise fee");

    // elder1 auto-voted FOR (member #2 <= threshold 3)
    assertTrue(gov.hasVoted(id, elder1));

    vm.prank(elder2);
    gov.vote(id, 1);
    assertTrue(gov.hasVoted(id, elder2));
  }

  function test_vote_revertsIfLatecomer() public {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    vm.prank(elder1);
    uint256 id = gov.propose(targets, vals, cds, "raise fee");

    vm.expectRevert(IGovernance.NotAuthorized.selector);
    vm.prank(latecomer);
    gov.vote(id, 1);
  }

  // ============ Execute: full lifecycle ============

  function test_execute_fullLifecycle() public {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    // elder1 proposes (auto-votes FOR, member #2)
    vm.prank(elder1);
    uint256 id = gov.propose(targets, vals, cds, "raise fee");

    // elder2 votes FOR (member #3)
    vm.prank(elder2);
    gov.vote(id, 1);

    // 2 of 3 elders = 67% > 51% quorum and 100% approval
    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);
    gov.execute(id);

    assertEq(templ.baseEntryFee(), 2000e18);
  }

  function test_execute_priestIsElder() public {
    // priest is member #1, within threshold
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));

    vm.prank(priest);
    uint256 id = gov.propose(targets, vals, cds, "lower fee");

    // priest auto-voted. elder1 and elder2 vote FOR -> 3/3 = 100%
    vm.prank(elder1);
    gov.vote(id, 1);
    vm.prank(elder2);
    gov.vote(id, 1);

    // 100% FOR -> immediate execution
    gov.execute(id);
    assertEq(templ.baseEntryFee(), 500e18);
  }

  // ============ Quorum: elder count as denominator ============

  function test_quorum_usesElderCountNotTotalMembers() public {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    vm.prank(elder1);
    uint256 id = gov.propose(targets, vals, cds, "raise fee");

    // Only elder1 voted FOR (1 of 3 elders = 33% < 51% quorum)
    vm.warp(block.timestamp + VOTING_PERIOD);

    vm.expectRevert(IGovernance.QuorumNotMet.selector);
    gov.execute(id);
  }
}
