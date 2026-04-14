// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CouncilDeployer } from "../../src/CouncilDeployer.sol";
import { DemocracyDeployer } from "../../src/DemocracyDeployer.sol";
import { GovernanceDeployer } from "../../src/GovernanceDeployer.sol";
import { Templ } from "../../src/Templ.sol";
import { Treasury } from "../../src/Treasury.sol";
import { Council } from "../../src/governance/Council.sol";
import { Democracy } from "../../src/governance/Democracy.sol";
import { GovMode, GovernanceConfig } from "../../src/interfaces/IFactory.sol";
import { IGovernance } from "../../src/interfaces/IGovernance.sol";
import { ITempl } from "../../src/interfaces/ITempl.sol";
import { EntryFeeCurve } from "../../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockFactory } from "../mocks/MockFactory.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Tests governance type flipping between Democracy and Council
///      via GovernanceDeployer, verifying the new governance is fully
///      operational after each swap.
contract GovernanceFlipTest is Test {
  Templ public templ;
  Treasury public treasury;
  Democracy public democracyGov;
  GovernanceDeployer public govDeployer;
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

    DemocracyDeployer dd = new DemocracyDeployer();
    CouncilDeployer cd = new CouncilDeployer();
    govDeployer = new GovernanceDeployer(address(dd), address(cd));
    cd.setGovernanceDeployer(address(govDeployer));
    dd.setGovernanceDeployer(address(govDeployer));
    // Lock factory to this test contract so deploy() calls succeed
    govDeployer.setFactory(address(this));

    treasury = mf.deployTreasury(address(token), 1000, address(0), 2500);
    templ = new Templ(
      priest,
      address(token),
      ENTRY_FEE,
      EntryFeeCurve.exponentialWithTail(10_094, 248),
      address(treasury),
      address(this) // test contract acts as initial governance
    );
    vm.prank(address(mf));
    treasury.setTempl(address(templ));
    vm.prank(address(mf));
    treasury.setFeeSplit(3000, 3000, 3000);

    democracyGov = new Democracy(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );

    templ.setGovernance(address(democracyGov));

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

  function _deployCouncil(
    address[] memory council
  ) internal returns (address) {
    GovernanceConfig memory config = GovernanceConfig({
      mode: GovMode.Council,
      approvalThresholdBps: APPROVAL_THRESHOLD_BPS,
      quorumBps: QUORUM_BPS,
      votingPeriod: VOTING_PERIOD,
      executionDelay: EXECUTION_DELAY,
      immediateExecutionBps: IMMEDIATE_EXECUTION_BPS,
      proposalFeeBps: 0,
      council: council
    });

    return govDeployer.deploy(
      address(templ),
      config,
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      VOTING_PERIOD,
      EXECUTION_DELAY,
      IMMEDIATE_EXECUTION_BPS,
      0
    );
  }

  function _deployDemocracy() internal returns (address) {
    GovernanceConfig memory config = GovernanceConfig({
      mode: GovMode.Democracy,
      approvalThresholdBps: APPROVAL_THRESHOLD_BPS,
      quorumBps: QUORUM_BPS,
      votingPeriod: VOTING_PERIOD,
      executionDelay: EXECUTION_DELAY,
      immediateExecutionBps: IMMEDIATE_EXECUTION_BPS,
      proposalFeeBps: 0,
      council: new address[](0)
    });

    return govDeployer.deploy(
      address(templ),
      config,
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      VOTING_PERIOD,
      EXECUTION_DELAY,
      IMMEDIATE_EXECUTION_BPS,
      0
    );
  }

  /// @dev Propose a single-target action through Democracy with majority vote
  function _proposeAndExecuteDemocracy(
    address target,
    bytes memory data,
    string memory description
  ) internal {
    address[] memory targets = new address[](1);
    targets[0] = target;
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = data;

    vm.prank(alice);
    uint256 pid = democracyGov.propose(targets, vals, cds, description);
    vm.prank(bob);
    democracyGov.vote(pid, 1);
    vm.prank(charlie);
    democracyGov.vote(pid, 1);

    // 3 of 4 members (75%) - not enough for immediate execution
    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);
    democracyGov.execute(pid);
  }

  // ============ Democracy -> Council ============

  function test_flipDemocracyToCouncil() public {
    address[] memory council = new address[](2);
    council[0] = alice;
    council[1] = bob;
    address newGovAddr = _deployCouncil(council);

    // Propose the governance swap through the current Democracy
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setGovernance, (newGovAddr));

    vm.prank(alice);
    uint256 proposalId =
      democracyGov.propose(targets, vals, cds, "switch to council");

    vm.prank(bob);
    democracyGov.vote(proposalId, 1);
    vm.prank(charlie);
    democracyGov.vote(proposalId, 1);

    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);

    // Indexer-critical event sequence during setGovernance:
    // 1. GovernanceUpdated from Templ (registers the contract in indexer)
    // 2. GovernanceInitialized (sets governanceType)
    // 3. Config parameter events (populate Templ entity fields)
    // 4. CouncilInitialized (Council-specific, sets councilSize)
    vm.expectEmit(true, false, false, true, address(templ));
    emit ITempl.GovernanceUpdated(newGovAddr);

    vm.expectEmit(true, false, false, true, newGovAddr);
    emit IGovernance.GovernanceInitialized(address(templ), "council");

    vm.expectEmit(true, false, false, true, newGovAddr);
    emit Council.CouncilInitialized(address(templ), 2);

    democracyGov.execute(proposalId);

    assertEq(templ.governance(), newGovAddr);

    // Verify the Council is operational
    Council councilGov = Council(payable(newGovAddr));

    address[] memory targets2 = new address[](1);
    targets2[0] = address(templ);
    uint256[] memory vals2 = new uint256[](1);
    bytes[] memory cds2 = new bytes[](1);
    cds2[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2000e18));

    vm.prank(alice);
    uint256 councilProposalId =
      councilGov.propose(targets2, vals2, cds2, "raise fee");

    // 2/2 council = 100% -> immediate execution
    vm.prank(bob);
    councilGov.vote(councilProposalId, 1);

    councilGov.execute(councilProposalId);
    assertEq(templ.baseEntryFee(), 2000e18);
  }

  // ============ Council -> Democracy ============

  function test_flipCouncilToDemocracy() public {
    // First, flip to Council
    address[] memory council = new address[](2);
    council[0] = alice;
    council[1] = bob;
    address councilAddr = _deployCouncil(council);

    _proposeAndExecuteDemocracy(
      address(templ),
      abi.encodeCall(ITempl.setGovernance, (councilAddr)),
      "to council"
    );

    assertEq(templ.governance(), councilAddr);
    Council councilGov = Council(payable(councilAddr));

    // Deploy a new Democracy and propose the swap through Council
    address newDemocracyAddr = _deployDemocracy();

    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setGovernance, (newDemocracyAddr));

    vm.prank(alice);
    uint256 pid = councilGov.propose(targets, vals, cds, "back to democracy");

    // 2/2 council = 100% -> immediate execution
    vm.prank(bob);
    councilGov.vote(pid, 1);

    vm.expectEmit(true, false, false, true, address(templ));
    emit ITempl.GovernanceUpdated(newDemocracyAddr);

    vm.expectEmit(true, false, false, true, newDemocracyAddr);
    emit IGovernance.GovernanceInitialized(address(templ), "democracy");

    councilGov.execute(pid);

    assertEq(templ.governance(), newDemocracyAddr);

    // charlie could not vote in the Council but can propose in Democracy
    Democracy newDemocracy = Democracy(payable(newDemocracyAddr));

    address[] memory targets2 = new address[](1);
    targets2[0] = address(templ);
    uint256[] memory vals2 = new uint256[](1);
    bytes[] memory cds2 = new bytes[](1);
    cds2[0] = abi.encodeCall(ITempl.setBaseEntryFee, (3000e18));

    vm.prank(charlie);
    uint256 pid2 =
      newDemocracy.propose(targets2, vals2, cds2, "charlie proposes");

    vm.prank(alice);
    newDemocracy.vote(pid2, 1);
    vm.prank(bob);
    newDemocracy.vote(pid2, 1);

    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);
    newDemocracy.execute(pid2);

    assertEq(templ.baseEntryFee(), 3000e18);
  }
}
