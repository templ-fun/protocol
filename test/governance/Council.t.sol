// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Templ } from "../../src/Templ.sol";
import { Treasury } from "../../src/Treasury.sol";
import { Council } from "../../src/governance/Council.sol";
import { IGovernance } from "../../src/interfaces/IGovernance.sol";
import { ITempl } from "../../src/interfaces/ITempl.sol";
import { EntryFeeCurve } from "../../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockFactory } from "../mocks/MockFactory.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Tests only Council-specific behavior.
///      Shared Governance logic is covered in Democracy.t.sol.
contract CouncilTest is Test {
  Templ public templ;
  Treasury public treasury;
  Council public gov;
  MockERC20 public token;

  address public priest = makeAddr("priest");
  address public protocolRecipient = makeAddr("protocol");
  address public councilA = makeAddr("councilA");
  address public councilB = makeAddr("councilB");
  address public councilC = makeAddr("councilC");
  address public member = makeAddr("member");
  address public outsider = makeAddr("outsider");

  uint256 public constant ENTRY_FEE = 1000e18;
  uint256 public constant APPROVAL_THRESHOLD_BPS = 5100;
  uint256 public constant QUORUM_BPS = 6700; // 67% (2 of 3)
  uint256 public constant EXECUTION_DELAY = 12 hours;
  uint256 public constant VOTING_PERIOD = 3 days;
  uint256 public constant IMMEDIATE_EXECUTION_BPS = 10_000;

  MockFactory public mockFactory;

  function setUp() public {
    token = new MockERC20();

    mockFactory = new MockFactory(protocolRecipient);
    treasury =
      mockFactory.deployTreasury(address(token), 1000, address(0), 2500);
    templ = new Templ(
      priest,
      address(token),
      ENTRY_FEE,
      EntryFeeCurve.exponentialWithTail(10_094, 248),
      address(treasury),
      address(this)
    );
    vm.prank(address(mockFactory));
    treasury.setTempl(address(templ));
    vm.prank(address(mockFactory));
    treasury.setFeeSplit(3000, 3000, 3000);

    _joinMember(councilA);
    _joinMember(councilB);
    _joinMember(councilC);
    _joinMember(member);

    address[] memory council = new address[](3);
    council[0] = councilA;
    council[1] = councilB;
    council[2] = councilC;

    gov = new Council(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0, // no proposal fee
      council
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

  /// @dev Helper: propose, vote with full council, execute
  function _proposeVoteExecute(
    address proposer,
    address target,
    bytes memory data
  ) internal returns (uint256 id) {
    address[] memory targets = new address[](1);
    targets[0] = target;
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = data;

    vm.prank(proposer);
    id = gov.propose(targets, vals, cds, "proposal");

    // Vote FOR with council members that aren't the proposer (proposer auto-votes)
    if (proposer != councilA) {
      vm.prank(councilA);
      gov.vote(id, 1);
    }
    if (proposer != councilB) {
      vm.prank(councilB);
      gov.vote(id, 1);
    }
    if (proposer != councilC) {
      vm.prank(councilC);
      gov.vote(id, 1);
    }

    vm.warp(block.timestamp + EXECUTION_DELAY);
    gov.execute(id);
  }

  // ============ Constructor ============

  function test_constructor() public view {
    assertEq(gov.councilSize(), 3);
    assertTrue(gov.isCouncilMember(councilA));
    assertTrue(gov.isCouncilMember(councilB));
    assertFalse(gov.isCouncilMember(member));
  }

  function test_constructor_revertsIfInvalid() public {
    address[] memory empty = new address[](0);
    vm.expectRevert(Council.EmptyCouncil.selector);
    new Council(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      empty
    );

    address[] memory dups = new address[](2);
    dups[0] = councilA;
    dups[1] = councilA;
    vm.expectRevert(Council.AlreadyCouncilMember.selector);
    new Council(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      dups
    );
  }

  // ============ Propose: any member can propose ============

  function test_propose_anyMemberCanPropose() public {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    vm.prank(member);
    uint256 id = gov.propose(targets, vals, cds, "raise fee");

    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Active));

    // Non-council proposer does NOT auto-vote
    assertFalse(gov.hasVoted(id, member));
    IGovernance.ProposalView memory p = gov.getProposal(id);
    assertEq(p.forVotes, 0);
  }

  function test_propose_councilMemberAutoVotesFor() public {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    vm.prank(councilA);
    uint256 id = gov.propose(targets, vals, cds, "raise fee");

    assertTrue(gov.hasVoted(id, councilA));
    IGovernance.ProposalView memory p = gov.getProposal(id);
    assertEq(p.forVotes, 1);
  }

  // ============ Vote: only council votes ============

  function test_vote_revertsIfNotCouncilMember() public {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    vm.prank(councilA);
    uint256 id = gov.propose(targets, vals, cds, "raise fee");

    vm.expectRevert(IGovernance.NotAuthorized.selector);
    vm.prank(member);
    gov.vote(id, 1);
  }

  // ============ Execute: council quorum ============

  function test_execute_fullLifecycle() public {
    uint256 newBaseFee = 500e18;
    _proposeVoteExecute(
      councilA,
      address(templ),
      abi.encodeCall(ITempl.setBaseEntryFee, (newBaseFee))
    );
    assertEq(templ.baseEntryFee(), newBaseFee);
  }

  function test_execute_revertsIfOnlyOneCouncilVotes() public {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));

    vm.prank(councilA);
    uint256 id = gov.propose(targets, vals, cds, "change");

    // Only councilA auto-voted (1/3 = 33% < 67%)
    vm.warp(block.timestamp + VOTING_PERIOD);

    vm.expectRevert(IGovernance.QuorumNotMet.selector);
    gov.execute(id);
  }

  // ============ Council Size Snapshot ============

  function test_councilSizeSnapshotAtCreation() public {
    // Snapshot council size = 3 at proposal creation
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));

    vm.prank(councilA);
    uint256 id = gov.propose(targets, vals, cds, "change");

    assertEq(gov.snapshotCouncilSize(id), 3);

    // Add a 4th council member via a separate proposal (use councilB to avoid ActiveProposalExists)
    _proposeVoteExecute(
      councilB, address(gov), abi.encodeCall(Council.addCouncilMember, (member))
    );
    assertEq(gov.councilSize(), 4);

    // Original proposal still uses snapshot of 3
    assertEq(gov.snapshotCouncilSize(id), 3);
  }

  // ============ Immediate Execution: single-member council ============

  function test_execute_singleCouncilImmediateExecution() public {
    address[] memory solo = new address[](1);
    solo[0] = priest;

    Council soloGov = new Council(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      solo
    );
    vm.prank(address(gov));
    templ.setGovernance(address(soloGov));

    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (777e18));

    vm.prank(priest);
    uint256 id = soloGov.propose(targets, vals, cds, "instant");

    // 1/1 = 100% immediate execution
    soloGov.execute(id);
    assertEq(templ.baseEntryFee(), 777e18);
  }

  // ============ Council Management ============

  function test_addCouncilMember_viaProposal() public {
    assertFalse(gov.isCouncilMember(member));
    assertEq(gov.councilSize(), 3);

    _proposeVoteExecute(
      councilA, address(gov), abi.encodeCall(Council.addCouncilMember, (member))
    );

    assertTrue(gov.isCouncilMember(member));
    assertEq(gov.councilSize(), 4);
  }

  function test_removeCouncilMember_viaProposal() public {
    assertTrue(gov.isCouncilMember(councilC));

    _proposeVoteExecute(
      councilA,
      address(gov),
      abi.encodeCall(Council.removeCouncilMember, (councilC))
    );

    assertFalse(gov.isCouncilMember(councilC));
    assertEq(gov.councilSize(), 2);
  }

  function test_removeCouncilMember_revertsIfWouldEmptyCouncil() public {
    // Remove B (3 -> 2)
    _proposeVoteExecute(
      councilA,
      address(gov),
      abi.encodeCall(Council.removeCouncilMember, (councilB))
    );

    // Remove C (2 -> 1)
    address[] memory targets = new address[](1);
    targets[0] = address(gov);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(Council.removeCouncilMember, (councilC));

    vm.prank(councilA);
    uint256 id2 = gov.propose(targets, vals, cds, "remove C");
    vm.prank(councilC);
    gov.vote(id2, 1);
    vm.warp(block.timestamp + EXECUTION_DELAY);
    gov.execute(id2);
    assertEq(gov.councilSize(), 1);

    // Try to remove last member (1 -> 0)
    cds[0] = abi.encodeCall(Council.removeCouncilMember, (councilA));
    vm.prank(councilA);
    uint256 id3 = gov.propose(targets, vals, cds, "remove self");
    vm.warp(block.timestamp + EXECUTION_DELAY);

    vm.expectRevert(IGovernance.ExecutionFailed.selector);
    gov.execute(id3);
  }

  function test_councilManagement_cannotCallDirectly() public {
    vm.expectRevert(Council.OnlyGovernance.selector);
    gov.addCouncilMember(member);

    vm.expectRevert(Council.OnlyGovernance.selector);
    gov.removeCouncilMember(councilA);
  }

  // ============ Quorum-Exempt Dissolution ============

  function test_proposeDissolution_councilMemberCanPropose() public {
    uint256 treasuryBefore = treasury.treasuryBalance();
    assertGt(treasuryBefore, 0);

    vm.prank(councilA);
    uint256 id = gov.proposeDissolution("emergency dissolution");

    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Active));
    IGovernance.ProposalView memory p = gov.getProposal(id);
    assertTrue(p.quorumExempt);

    // councilA auto-voted FOR. Quorum-exempt skips quorum/threshold checks.
    // Still needs voting period to end and execution delay.
    vm.warp(block.timestamp + VOTING_PERIOD);
    gov.execute(id);
    assertEq(treasury.treasuryBalance(), 0);
  }

  function test_proposeDissolution_priestCanPropose() public {
    vm.prank(priest);
    uint256 id = gov.proposeDissolution("priest dissolution");

    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Active));
    IGovernance.ProposalView memory p = gov.getProposal(id);
    assertTrue(p.quorumExempt);
  }

  function test_proposeDissolution_revertsIfNotPriestOrCouncil() public {
    vm.expectRevert(IGovernance.NotAuthorized.selector);
    vm.prank(member);
    gov.proposeDissolution("not allowed");
  }

  // ============ Proposal Fee Exemption ============

  function test_councilMember_proposesForFree() public {
    // Deploy a new Council with a proposal fee to test the exemption
    uint256 proposalFeeBps = 2500;

    address[] memory council = new address[](3);
    council[0] = councilA;
    council[1] = councilB;
    council[2] = councilC;

    Council feeGov = new Council(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      proposalFeeBps,
      council
    );
    vm.prank(address(gov));
    templ.setGovernance(address(feeGov));

    // Council member should pay nothing
    uint256 balanceBefore = token.balanceOf(councilA);

    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    vm.prank(councilA);
    feeGov.propose(targets, vals, cds, "free proposal");

    assertEq(token.balanceOf(councilA), balanceBefore);
  }

  function test_nonCouncilMember_paysProposalFee() public {
    // Deploy a new Council with a proposal fee
    uint256 proposalFeeBps = 2500;

    address[] memory council = new address[](3);
    council[0] = councilA;
    council[1] = councilB;
    council[2] = councilC;

    Council feeGov = new Council(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      proposalFeeBps,
      council
    );
    vm.prank(address(gov));
    templ.setGovernance(address(feeGov));

    // Non-council member (regular member) must pay the fee
    uint256 fee = (templ.entryFee() * proposalFeeBps) / 10_000;
    token.mint(member, fee);

    uint256 balanceBefore = token.balanceOf(member);

    vm.startPrank(member);
    token.approve(address(feeGov), fee);

    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    feeGov.propose(targets, vals, cds, "paid proposal");
    vm.stopPrank();

    assertEq(token.balanceOf(member), balanceBefore - fee);
  }
}
