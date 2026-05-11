// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CouncilDeployer } from "../../src/CouncilDeployer.sol";
import { DemocracyDeployer } from "../../src/DemocracyDeployer.sol";
import { GovernanceDeployer } from "../../src/GovernanceDeployer.sol";
import { MemberPool } from "../../src/MemberPool.sol";
import { Templ } from "../../src/Templ.sol";
import { Treasury } from "../../src/Treasury.sol";
import { Council } from "../../src/governance/Council.sol";
import { IGovernance } from "../../src/interfaces/IGovernance.sol";
import { ITempl } from "../../src/interfaces/ITempl.sol";
import { EntryFeeCurve } from "../../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockFactory } from "../mocks/MockFactory.sol";
import { Test, Vm } from "forge-std/Test.sol";

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
    MemberPool pool;
    (treasury, pool) = mockFactory.deployTreasuryAndPool(address(token));
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
    vm.prank(address(mockFactory));
    treasury.setTempl(address(templ));
    vm.prank(address(mockFactory));
    treasury.setMemberPool(address(pool));
    vm.prank(address(mockFactory));
    pool.setTempl(address(templ));
    vm.prank(address(mockFactory));
    pool.setTreasury(address(treasury));
    // Split config lives on Templ; address(this) is the temp governance
    // until the Council is deployed and wired below.
    templ.setFeeSplit(3000, 3000, 3000);
    templ.setReferralShareBps(2500);

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

  /// @dev The genesis roster is carried in a single `CouncilInitialized` event
  ///      with the full member array. Envio backfills same-block events on
  ///      contracts dynamically registered via `Templ.GovernanceUpdated`, so
  ///      this constructor-time event is captured by the indexer and replayed
  ///      as one `CouncilMember` row per member.
  function test_constructor_emitsCouncilInitializedWithMembers() public {
    address[] memory council = new address[](3);
    council[0] = councilA;
    council[1] = councilB;
    council[2] = councilC;

    vm.recordLogs();

    Council fresh = new Council(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council
    );

    _assertCouncilInitialized(
      vm.getRecordedLogs(), address(fresh), address(templ), council
    );
  }

  /// @dev Same property as the constructor test but routed through the
  ///      `CouncilDeployer.deployFor` switch path, so the deploy-path Council
  ///      is observationally identical to a direct `new Council(...)`.
  function test_deployFor_emitsCouncilInitializedWithMembers() public {
    // Stand up a deployer harness that treats this test contract as both the
    // Factory (for isTempl) and the deployer-EOA seed. Mirrors SwitchGovernanceTest.
    CouncilDeployer councilDeployer = new CouncilDeployer(address(this));
    DemocracyDeployer democracyDeployer = new DemocracyDeployer(address(this));
    GovernanceDeployer govDeployer = new GovernanceDeployer(
      address(democracyDeployer), address(councilDeployer), address(this)
    );
    councilDeployer.setGovernanceDeployer(address(govDeployer));
    democracyDeployer.setGovernanceDeployer(address(govDeployer));
    govDeployer.setFactory(address(this));

    address[] memory council = new address[](3);
    council[0] = councilA;
    council[1] = councilB;
    council[2] = councilC;

    // Caller must be the templ's current governance. setUp's `gov` is it.
    vm.recordLogs();

    vm.prank(address(gov));
    address fresh = councilDeployer.deployFor(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council
    );

    _assertCouncilInitialized(
      vm.getRecordedLogs(), fresh, address(templ), council
    );
  }

  /// @dev Required by CouncilDeployer.deployFor for the isTempl guard. The
  ///      test contract poses as the Factory in this harness.
  function isTempl(
    address what
  ) external view returns (bool) {
    return what == address(templ);
  }

  /// @dev Walks the recorded log entries emitted by `gov_` and asserts exactly
  ///      one `CouncilInitialized(templ_, expected)` event with the full
  ///      member array decoded from event data. Logs from other contracts
  ///      (Templ, deployers) are ignored.
  function _assertCouncilInitialized(
    Vm.Log[] memory entries,
    address gov_,
    address templ_,
    address[] memory expected
  ) internal pure {
    bytes32 sigInit = keccak256("CouncilInitialized(address,address[])");

    uint256 initCount;
    address[] memory members;
    for (uint256 i; i < entries.length; ++i) {
      Vm.Log memory e = entries[i];
      if (e.emitter != gov_) continue;
      if (e.topics[0] != sigInit) continue;
      ++initCount;
      assertEq(
        address(uint160(uint256(e.topics[1]))),
        templ_,
        "CouncilInitialized: wrong templ"
      );
      members = abi.decode(e.data, (address[]));
    }

    assertEq(initCount, 1, "CouncilInitialized: not emitted exactly once");
    assertEq(
      members.length, expected.length, "CouncilInitialized: wrong member count"
    );
    for (uint256 i; i < expected.length; ++i) {
      assertEq(members[i], expected[i], "CouncilInitialized: wrong member");
    }
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
    uint256 treasuryBefore = token.balanceOf(address(treasury));
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
    assertEq(token.balanceOf(address(treasury)), 0);
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
