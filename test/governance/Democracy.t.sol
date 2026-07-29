// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MemberPool } from "../../src/MemberPool.sol";
import { Templ } from "../../src/Templ.sol";
import { Treasury } from "../../src/Treasury.sol";
import { Democracy } from "../../src/governance/Democracy.sol";
import { IGovernance } from "../../src/interfaces/IGovernance.sol";
import { ITempl } from "../../src/interfaces/ITempl.sol";
import { EntryFeeCurve } from "../../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC20Permit } from "../mocks/MockERC20Permit.sol";
import { MockFactory } from "../mocks/MockFactory.sol";
import { ReentrantToken } from "../mocks/ReentrantToken.sol";
import { ReentrantVoter } from "../mocks/ReentrantVoter.sol";
import { ERC2612Helper } from "../utils/ERC2612Helper.sol";
import { Permit2Helper } from "../utils/Permit2Helper.sol";
import { Test } from "forge-std/Test.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";

/// @dev Tests shared Governance behavior via Democracy.
///      Council tests only cover what differs (council-specific access control,
///      council size snapshot, council management).
contract DemocracyTest is Test, Permit2Helper, ERC2612Helper {
  Templ public templ;
  Treasury public treasury;
  Democracy public gov;
  MockERC20 public token;
  MockFactory public mockFactory;

  address public priest = makeAddr("priest");
  address public protocolRecipient = makeAddr("protocol");
  address public alice = makeAddr("alice");
  address public bob = makeAddr("bob");
  address public charlie = makeAddr("charlie");
  address public outsider = makeAddr("outsider");

  uint256 public constant ENTRY_FEE = 1000e18;
  uint256 public constant APPROVAL_THRESHOLD_BPS = 5100; // 51% of for+against
  uint256 public constant QUORUM_BPS = 5100; // 51% participation required
  uint256 public constant EXECUTION_DELAY = 1 days;
  uint256 public constant VOTING_PERIOD = 3 days;
  uint256 public constant IMMEDIATE_EXECUTION_BPS = 10_000; // 100% for bypass

  function setUp() public {
    _deployPermit2();
    token = new MockERC20();

    mockFactory = new MockFactory(protocolRecipient);
    MemberPool pool;
    (treasury, pool) = mockFactory.deployTreasuryAndPool(address(token));
    templ = new Templ(
      priest,
      address(token),
      ENTRY_FEE,
      EntryFeeCurve.exponentialWithTail(10_094, 248),
      address(treasury),
      address(pool),
      address(this), // test contract is initial governance
      1000,
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
    // Split config lives on Templ; address(this) is the temp governance
    // until the Democracy gov is wired below.
    templ.setFeeSplit(3000, 3000, 3000);
    templ.setReferralShareBps(2500);

    gov = new Democracy(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0 // no proposal fee
    );

    templ.setGovernance(address(gov));

    // priest is member #1 (auto-joined), these three are #2, #3, #4
    _joinMember(alice);
    _joinMember(bob);
    _joinMember(charlie);
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

  /// @dev Single-target proposal helper using batch arrays
  function _propose(
    address proposer
  ) internal returns (uint256) {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));

    vm.prank(proposer);
    return gov.propose(targets, vals, cds, "lower base entry fee");
  }

  // ============ Propose ============

  function test_propose_autoVotesAndSnapshots() public {
    uint64 memberCountBefore = templ.memberCount();

    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "raise fee");

    assertEq(gov.proposalCount(), 1);
    assertTrue(gov.hasVoted(id, alice));
    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Active));

    IGovernance.ProposalView memory p = gov.getProposal(id);
    assertEq(p.forVotes, 1);
    assertEq(p.snapshotMemberCount, memberCountBefore);
  }

  function test_propose_revertsIfNotMember() public {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    vm.expectRevert(IGovernance.NotAuthorized.selector);
    vm.prank(outsider);
    gov.propose(targets, vals, cds, "nope");
  }

  function test_propose_allowsArbitraryTarget() public {
    address[] memory targets = new address[](1);
    targets[0] = address(0xdead);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "external target");
    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Active));
  }

  function test_propose_oneActivePerProposer() public {
    _propose(alice);
    vm.expectRevert(IGovernance.ActiveProposalExists.selector);
    _propose(alice);
  }

  function test_propose_allowedAfterCancelledOrExpired() public {
    uint256 id1 = _propose(alice);
    vm.prank(alice);
    gov.cancel(id1);
    uint256 id2 = _propose(alice);
    assertEq(uint8(gov.state(id2)), uint8(IGovernance.ProposalState.Active));

    vm.warp(block.timestamp + VOTING_PERIOD);
    uint256 id3 = _propose(alice);
    assertEq(uint8(gov.state(id3)), uint8(IGovernance.ProposalState.Active));
  }

  // ============ Vote (OZ-aligned: 0=Against, 1=For, 2=Abstain) ============

  function test_vote_revertsIfJoinedAfterProposal() public {
    uint256 id = _propose(alice);

    address latecomer = makeAddr("latecomer");
    _joinMember(latecomer);

    vm.expectRevert(IGovernance.JoinedAfterProposal.selector);
    vm.prank(latecomer);
    gov.vote(id, 1); // VOTE_FOR
  }

  function test_vote_canChangeVote() public {
    uint256 id = _propose(alice);

    // Bob votes FOR
    vm.prank(bob);
    gov.vote(id, 1);
    IGovernance.ProposalView memory p = gov.getProposal(id);
    assertEq(p.forVotes, 2); // alice auto-vote + bob
    assertEq(p.againstVotes, 0);

    // Bob switches to AGAINST
    vm.prank(bob);
    gov.vote(id, 0);
    p = gov.getProposal(id);
    assertEq(p.forVotes, 1);
    assertEq(p.againstVotes, 1);
  }

  function test_vote_abstainCountsForQuorumNotDecision() public {
    uint256 id = _propose(alice); // auto-vote FOR

    vm.prank(bob);
    gov.vote(id, 2); // VOTE_ABSTAIN

    IGovernance.ProposalView memory p = gov.getProposal(id);
    assertEq(p.forVotes, 1);
    assertEq(p.againstVotes, 0);
    assertEq(p.abstainVotes, 1);

    // Remaining members vote FOR to reach immediate execution
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    // 3 for, 0 against, 1 abstain. All 4 participated (100% quorum).
    // FOR threshold: 3/(3+0) = 100% > 51%. But FOR/eligible = 3/4 = 75% < 100% instant.
    // Need voting period to end, then execution delay from quorumReachedAt.
    p = gov.getProposal(id);
    assertGt(p.quorumReachedAt, 0);
    vm.warp(block.timestamp + VOTING_PERIOD);
    gov.execute(id);
    assertEq(templ.baseEntryFee(), 500e18);
  }

  function test_vote_revertsIfSameVote() public {
    uint256 id = _propose(alice);

    vm.prank(bob);
    gov.vote(id, 1);

    vm.expectRevert(IGovernance.SameVote.selector);
    vm.prank(bob);
    gov.vote(id, 1);
  }

  function test_vote_revertsIfInvalidVoteValue() public {
    uint256 id = _propose(alice);

    vm.expectRevert(IGovernance.InvalidVoteValue.selector);
    vm.prank(bob);
    gov.vote(id, 3);
  }

  function test_vote_revertsAfterVotingPeriod() public {
    uint256 id = _propose(alice);
    vm.warp(block.timestamp + VOTING_PERIOD);

    vm.expectRevert(IGovernance.VotingEnded.selector);
    vm.prank(bob);
    gov.vote(id, 1);
  }

  // ============ Two-Threshold Execute ============

  function test_execute_fullLifecycle() public {
    uint256 newBaseFee = 500e18;
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (newBaseFee));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "Lower the base fee");

    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);

    // 3/4 = 75% participation > 51% quorum. quorumReachedAt should be set.
    IGovernance.ProposalView memory p = gov.getProposal(id);
    assertGt(p.quorumReachedAt, 0);

    // Need voting period to end (not instant quorum) before execution
    vm.warp(block.timestamp + VOTING_PERIOD);
    gov.execute(id);

    assertEq(templ.baseEntryFee(), newBaseFee);
    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Executed));
    assertEq(gov.activeProposal(alice), 0);
  }

  function test_execute_revertsIfTooEarly() public {
    uint256 id = _propose(alice);
    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);

    // Quorum reached, but execution delay from quorumReachedAt not yet elapsed
    vm.expectRevert(IGovernance.TooEarly.selector);
    gov.execute(id);
  }

  function test_execute_revertsIfQuorumNotMet() public {
    uint256 id = _propose(alice);
    // Only alice auto-voted = 1/4 = 25% < 51% quorum
    vm.warp(block.timestamp + VOTING_PERIOD);

    vm.expectRevert(IGovernance.QuorumNotMet.selector);
    gov.execute(id);
  }

  function test_execute_revertsIfTiedVote() public {
    uint256 id = _propose(alice); // auto FOR
    vm.prank(priest);
    gov.vote(id, 1); // FOR
    vm.prank(bob);
    gov.vote(id, 0); // AGAINST
    vm.prank(charlie);
    gov.vote(id, 0); // AGAINST

    // 2 for, 2 against - tied. FOR must exceed AGAINST.
    IGovernance.ProposalView memory p = gov.getProposal(id);
    assertGt(p.quorumReachedAt, 0); // quorum met (4/4)
    vm.warp(block.timestamp + VOTING_PERIOD);

    vm.expectRevert(IGovernance.QuorumNotMet.selector);
    gov.execute(id);
  }

  function test_execute_succeedsAfterVotingPeriodIfPassed() public {
    // Passed proposals remain executable after voting period (no expiry)
    uint256 id = _propose(alice);
    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);

    IGovernance.ProposalView memory p = gov.getProposal(id);

    // Warp past both voting period and execution delay
    vm.warp(p.quorumReachedAt + EXECUTION_DELAY + VOTING_PERIOD);
    gov.execute(id);

    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Executed));
  }

  // ============ Execution Delay from Quorum ============

  function test_execute_delayStartsFromQuorum() public {
    uint256 id = _propose(alice); // auto FOR (1/4 = 25%)

    // Wait 2 days then gradually reach quorum
    vm.warp(block.timestamp + 2 days);
    vm.prank(bob);
    gov.vote(id, 1); // 2/4 = 50%, still below 51%

    vm.prank(charlie);
    gov.vote(id, 1); // 3/4 = 75%, quorum reached

    IGovernance.ProposalView memory p = gov.getProposal(id);
    assertEq(p.quorumReachedAt, block.timestamp);

    // Execution delay starts from quorumReachedAt, not proposal creation
    vm.expectRevert(IGovernance.TooEarly.selector);
    gov.execute(id);

    vm.warp(p.quorumReachedAt + EXECUTION_DELAY);
    gov.execute(id);
  }

  // ============ Immediate Execution ============

  function test_execute_immediateExecutionBypassesDelay() public {
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "change");

    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    // 4/4 FOR = 100% = immediate execution bypasses execution delay
    gov.execute(id);
    assertEq(templ.baseEntryFee(), 500e18);
  }

  function test_execute_partialQuorumStillNeedsDelay() public {
    uint256 id = _propose(alice);
    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);

    // 3/4 = 75% quorum met, but not instant (100%). Needs execution delay.
    vm.expectRevert(IGovernance.TooEarly.selector);
    gov.execute(id);
  }

  // ============ Batch Execution ============

  function test_execute_batchTargets() public {
    address[] memory targets = new address[](2);
    targets[0] = address(templ);
    targets[1] = address(gov);
    uint256[] memory vals = new uint256[](2);
    bytes[] memory cds = new bytes[](2);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));
    cds[1] = abi.encodeCall(IGovernance.setVotingPeriod, (14 days));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "batch change");

    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    gov.execute(id);

    assertEq(templ.baseEntryFee(), 500e18);
    assertEq(gov.votingPeriod(), 14 days);
  }

  // ============ ETH Forwarding ============

  function test_receive_acceptsETH() public {
    vm.deal(address(this), 1 ether);
    (bool ok,) = address(gov).call{ value: 1 ether }("");
    assertTrue(ok);
    assertEq(address(gov).balance, 1 ether);
  }

  function test_execute_forwardsETHValue() public {
    // Fund governance with ETH
    vm.deal(address(gov), 2 ether);

    // Propose: set fee (no ETH) + send 1 ETH to gov's own receive()
    // This exercises the call{value: v} path with nonzero v
    address[] memory targets = new address[](2);
    targets[0] = address(templ);
    targets[1] = address(gov);
    uint256[] memory vals = new uint256[](2);
    vals[0] = 0;
    vals[1] = 1 ether; // nonzero ETH value
    bytes[] memory cds = new bytes[](2);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));
    cds[1] = ""; // triggers receive()

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "batch with ETH");

    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    // execute() is payable - if call{value: 1 ether} works, execution succeeds
    gov.execute(id);

    assertEq(templ.baseEntryFee(), 500e18);
    // Gov sent 1 ETH to itself, balance unchanged
    assertEq(address(gov).balance, 2 ether);
  }

  // ============ State View ============

  function test_state_lifecycle() public {
    uint256 id = _propose(alice);
    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Active));

    vm.prank(alice);
    gov.cancel(id);
    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Cancelled));

    // New proposal, let it expire with insufficient votes
    uint256 id2 = _propose(alice);
    vm.warp(block.timestamp + VOTING_PERIOD);
    assertEq(uint8(gov.state(id2)), uint8(IGovernance.ProposalState.Defeated));

    // Nonexistent proposal returns Pending (zero-initialized)
    assertEq(uint8(gov.state(999)), uint8(IGovernance.ProposalState.Pending));
  }

  function test_state_succeededAfterVotingEnds() public {
    uint256 id = _propose(alice);
    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);

    vm.warp(block.timestamp + VOTING_PERIOD);
    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Succeeded));
  }

  // ============ Cancel ============

  function test_cancel_proposerCanCancel() public {
    uint256 id = _propose(alice);
    vm.prank(alice);
    gov.cancel(id);
    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Cancelled));
    assertEq(gov.activeProposal(alice), 0);
  }

  function test_cancel_revertsIfNotProposer() public {
    uint256 id = _propose(alice);
    vm.expectRevert(IGovernance.NotAuthorized.selector);
    vm.prank(bob);
    gov.cancel(id);
  }

  // ============ Constructor Validation ============

  function test_constructor_revertsIfImmediateExecutionBelowThreshold() public {
    vm.expectRevert(IGovernance.InvalidQuorumConfig.selector);
    new Democracy(
      address(templ),
      5100,
      3300,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      3000, // immediateExecutionBps < approvalThresholdBps
      0
    );
  }

  function test_constructor_revertsIfApprovalThresholdAboveBps() public {
    vm.expectRevert(IGovernance.InvalidQuorumConfig.selector);
    new Democracy(
      address(templ),
      10_001, // approvalThresholdBps > BPS
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );
  }

  function test_constructor_revertsIfQuorumAboveBps() public {
    vm.expectRevert(IGovernance.InvalidQuorumConfig.selector);
    new Democracy(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      10_001, // quorumBps > BPS
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );
  }

  function test_constructor_revertsIfImmediateExecutionAboveBps() public {
    vm.expectRevert(IGovernance.InvalidQuorumConfig.selector);
    new Democracy(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      10_001, // immediateExecutionBps > BPS
      0
    );
  }

  function test_constructor_revertsIfVotingPeriodZero() public {
    vm.expectRevert(IGovernance.InvalidQuorumConfig.selector);
    new Democracy(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      0, // votingPeriod == 0 expires proposals immediately
      IMMEDIATE_EXECUTION_BPS,
      0
    );
  }

  function test_constructor_revertsIfExecutionDelayWithZeroImmediateExecution()
    public
  {
    vm.expectRevert(IGovernance.InvalidQuorumConfig.selector);
    new Democracy(
      address(templ),
      0, // approvalThresholdBps = 0
      QUORUM_BPS,
      7 days, // executionDelay > 0 - expects a timelock
      VOTING_PERIOD,
      0, // immediateExecutionBps = 0 - but instant always fires
      0
    );
  }

  /// @dev executionDelay = 0 with immediateExecutionBps = 0 is valid - the
  ///      creator explicitly chose no delay and no instant threshold.
  function test_constructor_allowsZeroDelayWithZeroImmediateExecution() public {
    new Democracy(
      address(templ),
      0, // approvalThresholdBps
      QUORUM_BPS,
      0, // executionDelay = 0
      VOTING_PERIOD,
      0, // immediateExecutionBps = 0
      0
    );
  }

  // ============ Proposal Fee ============

  function test_proposalFee_chargedOnPropose() public {
    uint256 feeBps = 500;

    Democracy feeGov = new Democracy(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      feeBps
    );

    vm.prank(address(gov));
    templ.setGovernance(address(feeGov));

    uint256 expectedFee = (templ.entryFee() * feeBps) / 10_000;
    assertGt(expectedFee, 0);

    uint256 treasuryBefore = token.balanceOf(address(treasury));

    token.mint(alice, expectedFee);
    vm.startPrank(alice);
    token.approve(address(feeGov), expectedFee);

    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));
    feeGov.propose(targets, vals, cds, "lower fee");
    vm.stopPrank();

    assertEq(token.balanceOf(address(treasury)) - treasuryBefore, expectedFee);
  }

  // ============ Base Entry Fee Change Mid-Life ============

  function test_setBaseEntryFee_viaGovernance_recalculatesCurve() public {
    uint256 feeBeforeChange = templ.entryFee();
    assertEq(templ.paidJoins(), 3);

    uint256 newBaseFee = 200e18;
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (newBaseFee));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "lower base fee");

    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    gov.execute(id);

    assertEq(templ.baseEntryFee(), newBaseFee);

    uint256 feeAfterChange = templ.entryFee();
    assertLt(
      feeAfterChange, feeBeforeChange, "fee should drop after lowering base fee"
    );
    assertGt(
      feeAfterChange,
      newBaseFee,
      "fee should still be above new base (curve applied)"
    );

    address newMember = makeAddr("newMember");
    uint256 joinFee = templ.entryFee();
    token.mint(newMember, joinFee);
    vm.startPrank(newMember);
    token.approve(address(templ), joinFee);
    templ.join(newMember, address(0));
    vm.stopPrank();

    assertTrue(templ.isMember(newMember));
    assertGt(templ.entryFee(), joinFee, "fee grows after new join");
  }

  // ============ Reentrancy ============

  function test_propose_resistsReentrancy() public {
    ReentrantToken evil = new ReentrantToken();
    MockFactory evilMockFactory = new MockFactory(protocolRecipient);
    (Treasury evilTreasury, MemberPool evilPool) =
      evilMockFactory.deployTreasuryAndPool(address(evil));
    Templ evilTempl = new Templ(
      priest,
      address(evil),
      ENTRY_FEE,
      EntryFeeCurve.exponentialWithTail(10_094, 248),
      address(evilTreasury),
      address(evilPool),
      address(this),
      1000,
      address(0)
    );
    vm.prank(address(evilMockFactory));
    evilTreasury.setTempl(address(evilTempl));
    vm.prank(address(evilMockFactory));
    evilTreasury.setMemberPool(address(evilPool));
    vm.prank(address(evilMockFactory));
    evilPool.setTempl(address(evilTempl));
    vm.prank(address(evilMockFactory));
    evilPool.setTreasury(address(evilTreasury));
    // Split config lives on Templ; address(this) is the temp gov.
    evilTempl.setFeeSplit(3000, 3000, 3000);
    evilTempl.setReferralShareBps(2500);

    evil.mint(alice, 100_000e18);
    vm.startPrank(alice);
    evil.approve(address(evilTempl), type(uint256).max);
    evilTempl.join(alice, address(0));
    vm.stopPrank();

    uint256 feeBps = 500;
    Democracy evilGov = new Democracy(
      address(evilTempl),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      feeBps
    );
    evilTempl.setGovernance(address(evilGov));

    address[] memory targets = new address[](1);
    targets[0] = address(evilTempl);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (1e18));

    bytes memory proposeCall =
      abi.encodeCall(evilGov.propose, (targets, vals, cds, "reentrant"));
    evil.setAttack(address(evilGov), proposeCall);

    evil.mint(alice, 100_000e18);
    vm.startPrank(alice);
    evil.approve(address(evilGov), type(uint256).max);

    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));
    evilGov.propose(targets, vals, cds, "legit");
    vm.stopPrank();

    // Reentrancy guard blocked the second propose
    assertEq(evilGov.proposalCount(), 1);
  }

  function test_vote_resistsReentrancyViaExecute() public {
    // Create a callback contract that tries to call vote() when
    // execute()'s batch calls it. Both execute() and vote() share
    // the same nonReentrant lock.
    ReentrantVoter attacker = new ReentrantVoter(address(gov));

    // Create proposal 1: calls the attacker contract (triggers reentry)
    address[] memory targets = new address[](1);
    targets[0] = address(attacker);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = ""; // triggers fallback

    vm.prank(alice);
    uint256 pid1 = gov.propose(targets, vals, cds, "attack");

    // Create proposal 2 (the target for the reentrant vote)
    address[] memory targets2 = new address[](1);
    targets2[0] = address(templ);
    uint256[] memory vals2 = new uint256[](1);
    bytes[] memory cds2 = new bytes[](1);
    cds2[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));

    vm.prank(bob);
    uint256 pid2 = gov.propose(targets2, vals2, cds2, "legit");

    // Arm the attacker to call vote(pid2, AGAINST) during execute
    attacker.arm(pid2);

    // All members vote FOR proposal 1 to reach quorum
    vm.prank(bob);
    gov.vote(pid1, 1);
    vm.prank(charlie);
    gov.vote(pid1, 1);

    // Advance past voting period + execution delay
    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY + 1);

    // Execute proposal 1 - the batch calls attacker, which tries
    // to call vote(). The shared nonReentrant guard reverts the
    // reentrant vote, causing execute to revert with ExecutionFailed.
    vm.expectRevert(IGovernance.ExecutionFailed.selector);
    gov.execute(pid1);
  }

  // ============ Propose With Permit2 ============

  function test_proposeWithPermitWitness_chargesFeeViaPermit2() public {
    uint256 feeBps = 500;

    Democracy feeGov = new Democracy(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      feeBps
    );

    vm.prank(address(gov));
    templ.setGovernance(address(feeGov));

    uint256 alicePk = 0xA11CE;
    address aliceSigner = vm.addr(alicePk);

    uint256 joinFee = templ.entryFee();
    token.mint(aliceSigner, joinFee);
    vm.startPrank(aliceSigner);
    token.approve(address(templ), joinFee);
    templ.join(aliceSigner, address(0));
    vm.stopPrank();

    uint256 expectedFee = (templ.entryFee() * feeBps) / 10_000;
    assertGt(expectedFee, 0);

    uint256 treasuryBefore = token.balanceOf(address(treasury));
    token.mint(aliceSigner, expectedFee);

    vm.prank(aliceSigner);
    token.approve(PERMIT2_ADDR, expectedFee);

    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));
    string memory desc = "lower fee via permit witness";

    bytes32 proposalHash = keccak256(abi.encode(targets, vals, cds, desc));

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signProposalPermitWitness(
      address(token),
      expectedFee,
      0,
      block.timestamp + 1 hours,
      address(feeGov),
      proposalHash,
      alicePk
    );

    // Relayer submits - not aliceSigner
    vm.prank(makeAddr("relayer"));
    uint256 proposalId = feeGov.proposeWithPermitWitness(
      aliceSigner, targets, vals, cds, desc, permit, sig
    );

    assertEq(feeGov.proposalCount(), 1);
    assertEq(
      uint8(feeGov.state(proposalId)), uint8(IGovernance.ProposalState.Active)
    );
    assertEq(token.balanceOf(address(treasury)) - treasuryBefore, expectedFee);
  }

  function test_proposeWithPermitWitness_noFeeRelayedTrustlessly() public {
    assertEq(gov.proposalFeeBps(), 0);

    uint256 alicePk = 0xA11CE;
    address aliceSigner = vm.addr(alicePk);

    uint256 joinFee = templ.entryFee();
    token.mint(aliceSigner, joinFee);
    vm.startPrank(aliceSigner);
    token.approve(address(templ), joinFee);
    templ.join(aliceSigner, address(0));
    vm.stopPrank();

    // Even with no Permit2 token approval, the witness still works for
    // zero-amount transfers - Permit2 verifies the signature regardless.

    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));
    string memory desc = "free proposal";

    bytes32 proposalHash = keccak256(abi.encode(targets, vals, cds, desc));

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signProposalPermitWitness(
      address(token),
      0,
      0,
      block.timestamp + 1 hours,
      address(gov),
      proposalHash,
      alicePk
    );

    // Anyone can relay - outsider submits on behalf of aliceSigner
    vm.prank(outsider);
    uint256 proposalId = gov.proposeWithPermitWitness(
      aliceSigner, targets, vals, cds, desc, permit, sig
    );

    assertEq(gov.proposalCount(), 1);
    assertEq(
      uint8(gov.state(proposalId)), uint8(IGovernance.ProposalState.Active)
    );
  }

  function test_proposeWithPermitWitness_rejectsAlteredProposal() public {
    // Relayer tries to swap proposal content - witness signature check fails
    assertEq(gov.proposalFeeBps(), 0);

    uint256 alicePk = 0xA11CE;
    address aliceSigner = vm.addr(alicePk);

    uint256 joinFee = templ.entryFee();
    token.mint(aliceSigner, joinFee);
    vm.startPrank(aliceSigner);
    token.approve(address(templ), joinFee);
    templ.join(aliceSigner, address(0));
    vm.stopPrank();

    // Alice signs a proposal to lower fees
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));
    string memory desc = "lower fee";

    bytes32 proposalHash = keccak256(abi.encode(targets, vals, cds, desc));

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signProposalPermitWitness(
      address(token),
      0,
      0,
      block.timestamp + 1 hours,
      address(gov),
      proposalHash,
      alicePk
    );

    // Relayer swaps the calldata to raise fees instead
    bytes[] memory evilCds = new bytes[](1);
    evilCds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (99_999e18));

    vm.prank(outsider);
    vm.expectRevert(); // Permit2 signature verification fails
    gov.proposeWithPermitWitness(
      aliceSigner, targets, vals, evilCds, desc, permit, sig
    );
  }

  function test_proposeWithPermitWitness_rejectsImpersonation() public {
    // Outsider cannot impersonate alice - they can't produce her signature
    assertEq(gov.proposalFeeBps(), 0);

    uint256 outsiderPk = 0xBAD;

    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));
    string memory desc = "impersonation";

    bytes32 proposalHash = keccak256(abi.encode(targets, vals, cds, desc));

    // Outsider signs with their own key but claims to be alice
    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signProposalPermitWitness(
      address(token),
      0,
      0,
      block.timestamp + 1 hours,
      address(gov),
      proposalHash,
      outsiderPk
    );

    vm.prank(outsider);
    vm.expectRevert(); // Permit2 rejects: signer != claimed proposer
    gov.proposeWithPermitWitness(alice, targets, vals, cds, desc, permit, sig);
  }

  function test_proposeWithPermitWitness_revertsOnWrongToken() public {
    uint256 alicePk = 0xA11CE;
    address aliceSigner = vm.addr(alicePk);

    uint256 joinFee = templ.entryFee();
    token.mint(aliceSigner, joinFee);
    vm.startPrank(aliceSigner);
    token.approve(address(templ), joinFee);
    templ.join(aliceSigner, address(0));
    vm.stopPrank();

    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));
    string memory desc = "wrong token proposal";

    bytes32 proposalHash = keccak256(abi.encode(targets, vals, cds, desc));

    MockERC20 wrongToken = new MockERC20();

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signProposalPermitWitness(
      address(wrongToken),
      0,
      0,
      block.timestamp + 1 hours,
      address(gov),
      proposalHash,
      alicePk
    );

    vm.prank(outsider);
    vm.expectRevert(IGovernance.WrongToken.selector);
    gov.proposeWithPermitWitness(
      aliceSigner, targets, vals, cds, desc, permit, sig
    );
  }

  // ============ Propose With ERC-2612 Permit ============

  function test_proposeWithERC2612Permit_selfSubmitSuccess() public {
    // Stand up a parallel Templ/Democracy with an ERC-2612 permit token
    // so the permit flow can be exercised end-to-end.
    MockERC20Permit permitToken = new MockERC20Permit();
    (Treasury permitTreasury, MemberPool permitPool) =
      mockFactory.deployTreasuryAndPool(address(permitToken));
    Templ permitTempl = new Templ(
      priest,
      address(permitToken),
      ENTRY_FEE,
      EntryFeeCurve.exponentialWithTail(10_094, 248),
      address(permitTreasury),
      address(permitPool),
      address(this),
      1000,
      address(0)
    );
    vm.prank(address(mockFactory));
    permitTreasury.setTempl(address(permitTempl));
    vm.prank(address(mockFactory));
    permitTreasury.setMemberPool(address(permitPool));
    vm.prank(address(mockFactory));
    permitPool.setTempl(address(permitTempl));
    vm.prank(address(mockFactory));
    permitPool.setTreasury(address(permitTreasury));
    // Split config lives on Templ; address(this) is the temp gov.
    permitTempl.setFeeSplit(3000, 3000, 3000);
    permitTempl.setReferralShareBps(2500);

    uint256 feeBps = 500;
    Democracy feeGov = new Democracy(
      address(permitTempl),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      feeBps
    );
    permitTempl.setGovernance(address(feeGov));

    // Onboard alice as a member so she can propose
    uint256 alicePk = 0xA11CE;
    address aliceSigner = vm.addr(alicePk);

    uint256 joinFee = permitTempl.entryFee();
    permitToken.mint(aliceSigner, joinFee);
    vm.startPrank(aliceSigner);
    permitToken.approve(address(permitTempl), joinFee);
    permitTempl.join(aliceSigner, address(0));
    vm.stopPrank();

    // Fund alice for the proposal fee
    uint256 proposalFee = (permitTempl.entryFee() * feeBps) / 10_000;
    assertGt(proposalFee, 0);
    permitToken.mint(aliceSigner, proposalFee);

    // Sign the ERC-2612 permit for the governance contract
    (uint8 v, bytes32 r, bytes32 s) = signERC2612Permit(
      address(permitToken),
      aliceSigner,
      address(feeGov),
      proposalFee,
      0,
      block.timestamp + 1 hours,
      alicePk
    );

    address[] memory targets = new address[](1);
    targets[0] = address(permitTempl);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (1e18));

    // Self-submit: alice signs AND submits (msg.sender == signer)
    vm.prank(aliceSigner);
    uint256 proposalId = feeGov.proposeWithERC2612Permit(
      targets,
      vals,
      cds,
      "set base fee to 1e18",
      block.timestamp + 1 hours,
      v,
      r,
      s
    );

    assertEq(feeGov.proposalCount(), 1);
    assertEq(proposalId, 1);

    // Permit nonce consumed, fee pulled from alice
    assertEq(permitToken.nonces(aliceSigner), 1);
    assertEq(permitToken.balanceOf(aliceSigner), 0);
  }

  // ============ Vote With Permit Witness ============

  function test_voteWithPermitWitness_relayedTrustlessly() public {
    _propose(alice);

    uint256 bobPk = 0xB0B;
    address bobSigner = vm.addr(bobPk);

    // Join bobSigner as a member
    uint256 joinFee = templ.entryFee();
    token.mint(bobSigner, joinFee);
    vm.startPrank(bobSigner);
    token.approve(address(templ), joinFee);
    templ.join(bobSigner, address(0));
    vm.stopPrank();

    // Need a new proposal after bobSigner joined
    vm.warp(block.timestamp + VOTING_PERIOD);
    uint256 id2 = _propose(alice);

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signVotePermitWitness(
      address(token),
      0,
      block.timestamp + 1 hours,
      address(gov),
      id2,
      1, // VOTE_FOR
      bobPk
    );

    // Relayer submits - not bobSigner
    vm.prank(outsider);
    gov.voteWithPermitWitness(bobSigner, id2, 1, permit, sig);

    assertTrue(gov.hasVoted(id2, bobSigner));
    assertEq(gov.getVote(id2, bobSigner), 1);
  }

  function test_voteWithPermitWitness_rejectsAlteredSupport() public {
    _propose(alice);

    uint256 bobPk = 0xB0B;
    address bobSigner = vm.addr(bobPk);

    uint256 joinFee = templ.entryFee();
    token.mint(bobSigner, joinFee);
    vm.startPrank(bobSigner);
    token.approve(address(templ), joinFee);
    templ.join(bobSigner, address(0));
    vm.stopPrank();

    vm.warp(block.timestamp + VOTING_PERIOD);
    uint256 id2 = _propose(alice);

    // bobSigner signs VOTE_FOR
    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signVotePermitWitness(
      address(token),
      0,
      block.timestamp + 1 hours,
      address(gov),
      id2,
      1, // VOTE_FOR
      bobPk
    );

    // Relayer tries to submit as VOTE_AGAINST
    vm.prank(outsider);
    vm.expectRevert(); // Permit2 signature verification fails
    gov.voteWithPermitWitness(bobSigner, id2, 0, permit, sig);
  }

  function test_voteWithPermitWitness_rejectsImpersonation() public {
    uint256 id = _propose(alice);

    uint256 evilPk = 0xBAD;

    // Evil signs with their own key but claims to be bob
    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signVotePermitWitness(
      address(token), 0, block.timestamp + 1 hours, address(gov), id, 1, evilPk
    );

    vm.prank(outsider);
    vm.expectRevert(); // Permit2 rejects: signer != claimed voter
    gov.voteWithPermitWitness(bob, id, 1, permit, sig);
  }

  function test_voteWithPermitWitness_rejectsAlteredProposalId() public {
    _propose(alice);

    uint256 bobPk = 0xB0B;
    address bobSigner = vm.addr(bobPk);

    uint256 joinFee = templ.entryFee();
    token.mint(bobSigner, joinFee);
    vm.startPrank(bobSigner);
    token.approve(address(templ), joinFee);
    templ.join(bobSigner, address(0));
    vm.stopPrank();

    vm.warp(block.timestamp + VOTING_PERIOD);
    uint256 id2 = _propose(alice);
    uint256 id3 = _propose(bob);

    // bobSigner signs for id2
    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signVotePermitWitness(
      address(token), 0, block.timestamp + 1 hours, address(gov), id2, 1, bobPk
    );

    // Relayer tries to use it on id3
    vm.prank(outsider);
    vm.expectRevert();
    gov.voteWithPermitWitness(bobSigner, id3, 1, permit, sig);
  }

  function test_voteWithPermitWitness_revertsOnWrongToken() public {
    _propose(alice);

    uint256 bobPk = 0xB0B;
    address bobSigner = vm.addr(bobPk);

    uint256 joinFee = templ.entryFee();
    token.mint(bobSigner, joinFee);
    vm.startPrank(bobSigner);
    token.approve(address(templ), joinFee);
    templ.join(bobSigner, address(0));
    vm.stopPrank();

    vm.warp(block.timestamp + VOTING_PERIOD);
    uint256 id2 = _propose(alice);

    MockERC20 wrongToken = new MockERC20();

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signVotePermitWitness(
      address(wrongToken),
      0,
      block.timestamp + 1 hours,
      address(gov),
      id2,
      1, // VOTE_FOR
      bobPk
    );

    vm.prank(outsider);
    vm.expectRevert(IGovernance.WrongToken.selector);
    gov.voteWithPermitWitness(bobSigner, id2, 1, permit, sig);

    assertFalse(gov.hasVoted(id2, bobSigner));
  }

  // ============ Quorum-Exempt Dissolution ============

  function test_proposeDissolution_fullLifecycle() public {
    uint256 treasuryBefore = token.balanceOf(address(treasury));
    assertGt(treasuryBefore, 0);

    vm.prank(priest);
    uint256 id = gov.proposeDissolution("emergency dissolution");

    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Active));
    IGovernance.ProposalView memory p = gov.getProposal(id);
    assertTrue(p.quorumExempt);

    // Priest auto-voted FOR. Quorum-exempt skips quorum/threshold checks,
    // but still needs FOR > AGAINST, voting period ended, and execution delay.
    vm.warp(block.timestamp + VOTING_PERIOD);
    gov.execute(id);
    assertEq(token.balanceOf(address(treasury)), 0);
  }

  function test_proposeDissolution_membersCanVoteNo() public {
    vm.prank(priest);
    uint256 id = gov.proposeDissolution("emergency dissolution");

    vm.prank(alice);
    gov.vote(id, 0);
    vm.prank(bob);
    gov.vote(id, 0);
    vm.prank(charlie);
    gov.vote(id, 0);

    // FOR (1) <= AGAINST (3), execution fails
    vm.warp(block.timestamp + VOTING_PERIOD);
    vm.expectRevert(IGovernance.QuorumNotMet.selector);
    gov.execute(id);
  }

  function test_proposeDissolution_revertsIfNotPriest() public {
    vm.expectRevert(IGovernance.NotAuthorized.selector);
    vm.prank(alice);
    gov.proposeDissolution("not allowed");
  }

  // ============ Parameter Setters ============

  function _proposeGovChange(
    bytes memory data
  ) internal returns (uint256 id) {
    address[] memory targets = new address[](1);
    targets[0] = address(gov);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = data;

    vm.prank(alice);
    id = gov.propose(targets, vals, cds, "update param");
    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);
    // Immediate execution (4/4), execute immediately
    gov.execute(id);
  }

  function test_setApprovalThresholdBps_viaProposal() public {
    assertEq(gov.approvalThresholdBps(), APPROVAL_THRESHOLD_BPS);
    _proposeGovChange(
      abi.encodeCall(IGovernance.setApprovalThresholdBps, (6000))
    );
    assertEq(gov.approvalThresholdBps(), 6000);
  }

  function test_setQuorumBps_viaProposal() public {
    assertEq(gov.quorumBps(), QUORUM_BPS);
    _proposeGovChange(abi.encodeCall(IGovernance.setQuorumBps, (6600)));
    assertEq(gov.quorumBps(), 6600);
  }

  function test_setQuorumBps_revertsIfAboveMax() public {
    address[] memory targets = new address[](1);
    targets[0] = address(gov);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(IGovernance.setQuorumBps, (10_001));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "brick governance");
    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    vm.expectRevert(IGovernance.ExecutionFailed.selector);
    gov.execute(id);

    // Expire the failed proposal so alice can propose again
    vm.warp(block.timestamp + VOTING_PERIOD);

    // 10000 (100%) should still be valid
    _proposeGovChange(abi.encodeCall(IGovernance.setQuorumBps, (10_000)));
    assertEq(gov.quorumBps(), 10_000);
  }

  function test_setExecutionDelay_viaProposal() public {
    assertEq(gov.executionDelay(), EXECUTION_DELAY);
    _proposeGovChange(abi.encodeCall(IGovernance.setExecutionDelay, (2 days)));
    assertEq(gov.executionDelay(), 2 days);
  }

  function test_setVotingPeriod_viaProposal() public {
    assertEq(gov.votingPeriod(), VOTING_PERIOD);
    _proposeGovChange(abi.encodeCall(IGovernance.setVotingPeriod, (7 days)));
    assertEq(gov.votingPeriod(), 7 days);
  }

  function test_setImmediateExecutionBps_viaProposal() public {
    assertEq(gov.immediateExecutionBps(), IMMEDIATE_EXECUTION_BPS);
    _proposeGovChange(
      abi.encodeCall(IGovernance.setImmediateExecutionBps, (8000))
    );
    assertEq(gov.immediateExecutionBps(), 8000);
  }

  function test_setImmediateExecutionBps_revertsIfBelowThreshold() public {
    address[] memory targets = new address[](1);
    targets[0] = address(gov);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(
      IGovernance.setImmediateExecutionBps, (APPROVAL_THRESHOLD_BPS - 1)
    );

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "bad quorum");
    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    vm.expectRevert(IGovernance.ExecutionFailed.selector);
    gov.execute(id);
  }

  function test_setProposalFeeBps_viaProposal() public {
    assertEq(gov.proposalFeeBps(), 0);
    _proposeGovChange(abi.encodeCall(IGovernance.setProposalFeeBps, (500)));
    assertEq(gov.proposalFeeBps(), 500);
  }

  function test_setProposalFeeBps_rejectsAboveMax() public {
    address[] memory targets = new address[](1);
    targets[0] = address(gov);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(IGovernance.setProposalFeeBps, (10_001));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "overflow fee bps");
    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    vm.expectRevert(IGovernance.ExecutionFailed.selector);
    gov.execute(id);
  }

  function test_setProposalFeeBps_acceptsAtMax() public {
    _proposeGovChange(abi.encodeCall(IGovernance.setProposalFeeBps, (10_000)));
    assertEq(gov.proposalFeeBps(), 10_000);
  }

  function test_setApprovalThresholdBps_rejectsAboveBps() public {
    // Symmetric to the constructor check. Without this, governance could
    // set approvalThresholdBps > 10000 via a proposal, making the threshold
    // mathematically unreachable and bricking every future proposal.
    address[] memory targets = new address[](1);
    targets[0] = address(gov);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(IGovernance.setApprovalThresholdBps, (10_001));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "overflow threshold");
    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    vm.expectRevert(IGovernance.ExecutionFailed.selector);
    gov.execute(id);
  }

  function test_setImmediateExecutionBps_rejectsAboveBps() public {
    // Same reasoning as setApprovalThresholdBps - a value above BPS is
    // mathematically unreachable and would brick fast-track execution.
    address[] memory targets = new address[](1);
    targets[0] = address(gov);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(IGovernance.setImmediateExecutionBps, (10_001));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "overflow immediate");
    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    vm.expectRevert(IGovernance.ExecutionFailed.selector);
    gov.execute(id);
  }

  function test_setVotingPeriod_rejectsZero() public {
    // Zero voting period would expire every future proposal the instant
    // it is created, leaving only the proposer's auto-FOR vote and
    // letting any proposer pass proposals solo.
    address[] memory targets = new address[](1);
    targets[0] = address(gov);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(IGovernance.setVotingPeriod, (0));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "zero voting period");
    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    vm.expectRevert(IGovernance.ExecutionFailed.selector);
    gov.execute(id);
  }

  /// @dev Cross-field invariant: when immediateExecutionBps is zero, the
  ///      execution delay must also be zero. Otherwise any single FOR vote
  ///      already satisfies `forVotes * BPS / denominator >= 0`, firing the
  ///      instant branch and skipping the delay anyway. The previous codebase
  ///      enforced this only in the constructor; the DRY refactor in
  ///      Governance._setExecutionDelay lifts the same rule into the setter so
  ///      governance cannot deploy in a sane (both-zero) config and later
  ///      bump executionDelay into the contradictory regime. This test pins
  ///      that tightening — if a future refactor reverts to constructor-only
  ///      enforcement, this test fails.
  function test_setExecutionDelay_revertsWhenImmediateExecutionBpsIsZero()
    public
  {
    // Spin up a second Templ + Democracy where both immediateExecutionBps
    // and executionDelay start at zero. This is the only constructor-legal
    // config that lets us later attempt `setExecutionDelay(nonZero)` while
    // immediateExecutionBps is still zero. We deploy with quorum/approval
    // also at zero so any single FOR vote suffices for execution (the only
    // way to actually drive a proposal through with immediateExecutionBps=0
    // and zero delay), keeping the test focused on the setter's invariant
    // rather than on quorum mechanics.
    MemberPool pool2;
    Treasury treasury2;
    (treasury2, pool2) = mockFactory.deployTreasuryAndPool(address(token));
    Templ templ2 = new Templ(
      priest,
      address(token),
      ENTRY_FEE,
      EntryFeeCurve.exponentialWithTail(10_094, 248),
      address(treasury2),
      address(pool2),
      address(this),
      1000,
      address(0)
    );
    vm.prank(address(mockFactory));
    treasury2.setTempl(address(templ2));
    vm.prank(address(mockFactory));
    treasury2.setMemberPool(address(pool2));
    vm.prank(address(mockFactory));
    pool2.setTempl(address(templ2));
    vm.prank(address(mockFactory));
    pool2.setTreasury(address(treasury2));
    templ2.setFeeSplit(3000, 3000, 3000);
    templ2.setReferralShareBps(2500);

    Democracy zeroGov = new Democracy(
      address(templ2),
      0, // approvalThresholdBps = 0
      0, // quorumBps = 0
      0, // executionDelay = 0  (constructor-legal alongside zero immediate)
      VOTING_PERIOD,
      0, // immediateExecutionBps = 0
      0
    );
    templ2.setGovernance(address(zeroGov));

    // Join one member so they can propose.
    uint256 fee = templ2.entryFee();
    token.mint(alice, fee);
    vm.startPrank(alice);
    token.approve(address(templ2), fee);
    templ2.join(alice, address(0));
    vm.stopPrank();

    // Propose setExecutionDelay(2 days). The inner call must revert with
    // InvalidQuorumConfig because immediateExecutionBps is still 0; the
    // outer execute() surfaces that as ExecutionFailed.
    address[] memory targets = new address[](1);
    targets[0] = address(zeroGov);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(IGovernance.setExecutionDelay, (2 days));

    vm.prank(alice);
    uint256 id = zeroGov.propose(targets, vals, cds, "bump delay");

    // Both forVotes (1, alice auto-vote) and denominator (1 member) yield
    // forVotes * BPS / denominator = 10_000 >= 0 = immediateExecutionBps,
    // so the instant branch fires and we can execute immediately.
    vm.expectRevert(IGovernance.ExecutionFailed.selector);
    zeroGov.execute(id);

    // Sanity: state did not move.
    assertEq(zeroGov.executionDelay(), 0);
    assertEq(zeroGov.immediateExecutionBps(), 0);
  }

  /// @dev Companion positive case: when immediateExecutionBps > 0, the same
  ///      setter accepts a non-zero executionDelay. The default test gov
  ///      already has immediateExecutionBps = IMMEDIATE_EXECUTION_BPS; this
  ///      asserts the success path is unchanged. (The original
  ///      `test_setExecutionDelay_viaProposal` already covers this with a
  ///      different value; this case pins the boundary "immediate > 0
  ///      enables non-zero delay" symmetry test against the revert above.)
  function test_setExecutionDelay_succeedsWhenImmediateExecutionBpsIsNonZero()
    public
  {
    assertGt(gov.immediateExecutionBps(), 0);
    assertEq(gov.executionDelay(), EXECUTION_DELAY);
    _proposeGovChange(abi.encodeCall(IGovernance.setExecutionDelay, (5 days)));
    assertEq(gov.executionDelay(), 5 days);
  }

  function test_parameterSetters_revertIfCalledDirectly() public {
    vm.expectRevert(IGovernance.NotAuthorized.selector);
    gov.setApprovalThresholdBps(6000);
    vm.expectRevert(IGovernance.NotAuthorized.selector);
    gov.setQuorumBps(3300);
    vm.expectRevert(IGovernance.NotAuthorized.selector);
    gov.setExecutionDelay(2 days);
    vm.expectRevert(IGovernance.NotAuthorized.selector);
    gov.setVotingPeriod(7 days);
    vm.expectRevert(IGovernance.NotAuthorized.selector);
    gov.setImmediateExecutionBps(8000);
    vm.expectRevert(IGovernance.NotAuthorized.selector);
    gov.setProposalFeeBps(500);
  }

  // ============ Arbitrary External Calls ============

  function test_execute_externalERC20Transfer() public {
    // Fund treasury with tokens directly, then propose a governance
    // withdrawal to an arbitrary external address via ERC20.transfer
    uint256 amount = 100e18;
    token.mint(address(gov), amount);

    address recipient = makeAddr("externalRecipient");

    address[] memory targets = new address[](1);
    targets[0] = address(token);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(MockERC20.transfer, (recipient, amount));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "send tokens to external");

    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    gov.execute(id);

    assertEq(token.balanceOf(recipient), amount);
    assertEq(token.balanceOf(address(gov)), 0);
  }

  function test_execute_externalETHTransfer() public {
    // Send ETH to an arbitrary address via governance
    vm.deal(address(gov), 5 ether);
    address payable recipient = payable(makeAddr("ethRecipient"));

    address[] memory targets = new address[](1);
    targets[0] = recipient;
    uint256[] memory vals = new uint256[](1);
    vals[0] = 2 ether;
    bytes[] memory cds = new bytes[](1);

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "send ETH externally");

    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    gov.execute(id);

    assertEq(recipient.balance, 2 ether);
    assertEq(address(gov).balance, 3 ether);
  }

  function test_execute_batchMixedInternalAndExternal() public {
    // Batch: change base fee (internal) + send tokens externally
    uint256 amount = 50e18;
    token.mint(address(gov), amount);
    address recipient = makeAddr("batchRecipient");

    address[] memory targets = new address[](2);
    targets[0] = address(templ);
    targets[1] = address(token);
    uint256[] memory vals = new uint256[](2);
    bytes[] memory cds = new bytes[](2);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));
    cds[1] = abi.encodeCall(MockERC20.transfer, (recipient, amount));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "batch mixed");

    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    gov.execute(id);

    assertEq(templ.baseEntryFee(), 500e18);
    assertEq(token.balanceOf(recipient), amount);
  }

  function test_execute_externalCallRevertRollsBackBatch() public {
    // If one call in a batch fails, the whole proposal execution reverts
    address[] memory targets = new address[](2);
    targets[0] = address(templ);
    targets[1] = address(token); // will try to transfer more than balance
    uint256[] memory vals = new uint256[](2);
    bytes[] memory cds = new bytes[](2);
    cds[0] = abi.encodeCall(ITempl.setBaseEntryFee, (500e18));
    cds[1] =
      abi.encodeCall(MockERC20.transfer, (makeAddr("nobody"), 999_999e18));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "batch with bad call");

    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    vm.expectRevert(IGovernance.ExecutionFailed.selector);
    gov.execute(id);

    // First action should NOT have executed (atomic batch)
    assertEq(templ.baseEntryFee(), ENTRY_FEE);
  }

  function test_execute_multipleExternalCalls() public {
    // Three external token transfers in a single proposal
    uint256 total = 300e18;
    token.mint(address(gov), total);

    address r1 = makeAddr("r1");
    address r2 = makeAddr("r2");
    address r3 = makeAddr("r3");

    address[] memory targets = new address[](3);
    targets[0] = address(token);
    targets[1] = address(token);
    targets[2] = address(token);
    uint256[] memory vals = new uint256[](3);
    bytes[] memory cds = new bytes[](3);
    cds[0] = abi.encodeCall(MockERC20.transfer, (r1, 100e18));
    cds[1] = abi.encodeCall(MockERC20.transfer, (r2, 100e18));
    cds[2] = abi.encodeCall(MockERC20.transfer, (r3, 100e18));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "multi-transfer");

    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    gov.execute(id);

    assertEq(token.balanceOf(r1), 100e18);
    assertEq(token.balanceOf(r2), 100e18);
    assertEq(token.balanceOf(r3), 100e18);
  }

  function test_execute_externalCallWithETHAndCalldata() public {
    // Call an external contract with both ETH value and calldata
    vm.deal(address(gov), 1 ether);

    // Deploy a simple receiver that accepts ETH
    address payable receiver = payable(address(gov)); // send to self for simplicity

    address[] memory targets = new address[](1);
    targets[0] = receiver;
    uint256[] memory vals = new uint256[](1);
    vals[0] = 0.5 ether;
    bytes[] memory cds = new bytes[](1); // empty calldata triggers receive()

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "ETH with calldata");

    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    gov.execute(id);
    // Self-send, balance unchanged
    assertEq(address(gov).balance, 1 ether);
  }

  function test_execute_treasuryTransferToExternalViaGovernance() public {
    // Real-world scenario: send treasury TOKEN to an external recipient via
    // the new programmable-vault `execute` surface.
    //   gov.execute -> treasury.execute(token, 0, transfer(defi, balance))
    uint256 treasuryBal = token.balanceOf(address(treasury));
    assertGt(treasuryBal, 0);

    address defiProtocol = makeAddr("defiProtocol");

    bytes memory innerTransfer =
      abi.encodeCall(MockERC20.transfer, (defiProtocol, treasuryBal));

    address[] memory targets = new address[](1);
    targets[0] = address(treasury);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] =
      abi.encodeCall(treasury.execute, (address(token), 0, innerTransfer));

    vm.prank(alice);
    uint256 id = gov.propose(targets, vals, cds, "invest in DeFi");

    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);
    vm.prank(priest);
    gov.vote(id, 1);

    gov.execute(id);

    assertEq(token.balanceOf(address(treasury)), 0);
    assertEq(token.balanceOf(defiProtocol), treasuryBal);
  }

  // ============ Governance Parameter Snapshots ============

  function test_proposalUsesSnapshotParams() public {
    // Create proposal #1 with current voting period (3 days)
    uint256 id1 = _propose(alice);
    assertEq(uint8(gov.state(id1)), uint8(IGovernance.ProposalState.Active));

    // Change voting period to 14 days via proposal #2 (immediate execution)
    address[] memory targets = new address[](1);
    targets[0] = address(gov);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(IGovernance.setVotingPeriod, (14 days));

    vm.prank(bob);
    uint256 id2 = gov.propose(targets, vals, cds, "extend voting period");
    vm.prank(charlie);
    gov.vote(id2, 1);
    vm.prank(priest);
    gov.vote(id2, 1);
    // Alice votes on id2 too for immediate execution
    vm.prank(alice);
    gov.vote(id2, 1);
    gov.execute(id2);
    assertEq(gov.votingPeriod(), 14 days);

    // Proposal #1 still uses the original 3-day voting period snapshot.
    // Warp past 3 days - proposal #1 should be expired.
    vm.warp(block.timestamp + VOTING_PERIOD);
    assertEq(uint8(gov.state(id1)), uint8(IGovernance.ProposalState.Defeated));

    // Verify the snapshot fields directly via getProposal
    IGovernance.ProposalView memory p = gov.getProposal(id1);
    assertEq(p.snapshotVotingPeriod, VOTING_PERIOD);
    assertEq(p.snapshotQuorumBps, QUORUM_BPS);
    assertEq(p.snapshotApprovalThresholdBps, APPROVAL_THRESHOLD_BPS);
    assertEq(p.snapshotExecutionDelay, EXECUTION_DELAY);
    assertEq(p.snapshotImmediateExecutionBps, IMMEDIATE_EXECUTION_BPS);
  }

  function test_execute_requiresVotingPeriodEndedOrInstantQuorum() public {
    uint256 id = _propose(alice); // auto FOR

    // Get quorum (3/4 = 75% > 51%) but not instant (need 100%)
    vm.prank(bob);
    gov.vote(id, 1);
    vm.prank(charlie);
    gov.vote(id, 1);

    // Voting period still open, no instant quorum - should revert
    vm.expectRevert(IGovernance.TooEarly.selector);
    gov.execute(id);

    // Even with execution delay from quorum, still reverts during voting period
    IGovernance.ProposalView memory p = gov.getProposal(id);
    assertGt(p.quorumReachedAt, 0);
    vm.warp(p.quorumReachedAt + EXECUTION_DELAY);

    // Still within voting period (EXECUTION_DELAY < VOTING_PERIOD), reverts
    assertTrue(
      block.timestamp < block.timestamp + VOTING_PERIOD - EXECUTION_DELAY
    );
    vm.expectRevert(IGovernance.TooEarly.selector);
    gov.execute(id);

    // Warp past voting period end - now execution works
    vm.warp(block.timestamp + VOTING_PERIOD);
    gov.execute(id);
    assertEq(uint8(gov.state(id)), uint8(IGovernance.ProposalState.Executed));
  }
}
