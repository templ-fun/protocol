// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CouncilDeployer } from "../../src/CouncilDeployer.sol";
import { DemocracyDeployer } from "../../src/DemocracyDeployer.sol";
import { GovernanceDeployer } from "../../src/GovernanceDeployer.sol";
import { MemberPool } from "../../src/MemberPool.sol";
import { Templ } from "../../src/Templ.sol";
import { Treasury } from "../../src/Treasury.sol";
import { Council } from "../../src/governance/Council.sol";
import { Democracy } from "../../src/governance/Democracy.sol";
import { GovMode, GovernanceConfig } from "../../src/interfaces/IFactory.sol";
import { ITempl } from "../../src/interfaces/ITempl.sol";
import { EntryFeeCurve } from "../../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockFactory } from "../mocks/MockFactory.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Tests the `deployFor` + nonce-salt switch path on each sub-deployer.
///      Covers happy-path switching in both directions, repeated switching,
///      wrong-caller revert, bad-config revert, and CREATE2 address prediction.
contract SwitchGovernanceTest is Test {
  Templ public templ;
  Treasury public treasury;
  Democracy public genesisGov;
  DemocracyDeployer public democracyDeployer;
  CouncilDeployer public councilDeployer;
  GovernanceDeployer public govDeployer;
  MockERC20 public token;
  MockFactory public mf;

  /// @dev This test contract acts as the Factory from the deployers'
  ///      perspective (`govDeployer.setFactory(address(this))` in setUp).
  ///      The new `deployFor` paths verify `IFactory(factory).isTempl(templ)`
  ///      to refuse spoofed-templ inputs. Tests register their real templ
  ///      in this map and the view below answers truthfully.
  mapping(address => bool) public isTempl;

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

    democracyDeployer = new DemocracyDeployer(address(this));
    councilDeployer = new CouncilDeployer(address(this));
    govDeployer = new GovernanceDeployer(
      address(democracyDeployer), address(councilDeployer), address(this)
    );
    councilDeployer.setGovernanceDeployer(address(govDeployer));
    democracyDeployer.setGovernanceDeployer(address(govDeployer));
    govDeployer.setFactory(address(this));

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
    templ.setFeeSplit(3000, 3000, 3000);
    templ.setReferralShareBps(2500);

    genesisGov = new Democracy(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );

    templ.setGovernance(address(genesisGov));

    // Mark the real templ as factory-registered so `deployFor`'s isTempl
    // guard passes. Fake-templ tests intentionally skip this step.
    isTempl[address(templ)] = true;

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

  function _councilOfTwo() internal view returns (address[] memory council) {
    council = new address[](2);
    council[0] = alice;
    council[1] = bob;
  }

  // ============ Genesis salt is preserved ============

  function test_genesisSalt_unchanged() public {
    // Spin up a second templ purely to confirm the genesis path still uses
    // the templ-address salt and ignores the switchNonce mapping.
    MemberPool pool;
    (Treasury t2, MemberPool p2) = mf.deployTreasuryAndPool(address(token));
    pool = p2;
    Templ templ2 = new Templ(
      priest,
      address(token),
      ENTRY_FEE,
      EntryFeeCurve.exponentialWithTail(10_094, 248),
      address(t2),
      address(pool),
      address(this),
      1000,
      address(0)
    );
    vm.prank(address(mf));
    t2.setTempl(address(templ2));
    vm.prank(address(mf));
    t2.setMemberPool(address(pool));
    vm.prank(address(mf));
    pool.setTempl(address(templ2));
    vm.prank(address(mf));
    pool.setTreasury(address(t2));
    templ2.setFeeSplit(3000, 3000, 3000);

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

    address gov = govDeployer.deploy(
      address(templ2),
      config,
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      VOTING_PERIOD,
      EXECUTION_DELAY,
      IMMEDIATE_EXECUTION_BPS,
      0
    );

    // Recompute genesis address from the templ-address salt and initcode.
    bytes32 salt = bytes32(uint256(uint160(address(templ2))));
    bytes32 initCodeHash = keccak256(
      abi.encodePacked(
        type(Democracy).creationCode,
        abi.encode(
          address(templ2),
          APPROVAL_THRESHOLD_BPS,
          QUORUM_BPS,
          EXECUTION_DELAY,
          VOTING_PERIOD,
          IMMEDIATE_EXECUTION_BPS,
          uint256(0)
        )
      )
    );
    address expected = address(
      uint160(
        uint256(
          keccak256(
            abi.encodePacked(
              bytes1(0xff), address(democracyDeployer), salt, initCodeHash
            )
          )
        )
      )
    );

    assertEq(gov, expected);
    assertEq(democracyDeployer.switchNonce(address(templ2)), 0);
  }

  // ============ deployFor authorisation ============

  function test_deployFor_democracy_revertsWhenCallerIsNotGovernance() public {
    vm.prank(alice);
    vm.expectRevert(DemocracyDeployer.NotAuthorized.selector);
    democracyDeployer.deployFor(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );
  }

  function test_deployFor_council_revertsWhenCallerIsNotGovernance() public {
    address[] memory council = _councilOfTwo();
    vm.prank(alice);
    vm.expectRevert(CouncilDeployer.NotAuthorized.selector);
    councilDeployer.deployFor(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council
    );
  }

  function test_deployFor_revertsWhenCallerIsGenesisDeployer() public {
    // The genesis `deploy` path is gated to governanceDeployer. `deployFor`
    // is gated to the templ's governance contract. Crossing the wires must
    // revert.
    vm.prank(address(govDeployer));
    vm.expectRevert(DemocracyDeployer.NotAuthorized.selector);
    democracyDeployer.deployFor(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );
  }

  // ============ Bad config reverts ============

  function test_deployFor_democracy_revertsOnInvalidConfig() public {
    // approvalThresholdBps > BPS reverts inside Democracy's constructor.
    vm.prank(address(genesisGov));
    vm.expectRevert();
    democracyDeployer.deployFor(
      address(templ),
      20_000, // > 10_000
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );
  }

  function test_deployFor_council_revertsOnEmptyCouncil() public {
    address[] memory empty = new address[](0);
    vm.prank(address(genesisGov));
    vm.expectRevert(Council.EmptyCouncil.selector);
    councilDeployer.deployFor(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      empty
    );
  }

  // ============ Address prediction ============

  function test_predictDeployForAddress_democracy_matchesActual() public {
    address predicted = democracyDeployer.predictDeployForAddress(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );

    vm.prank(address(genesisGov));
    address actual = democracyDeployer.deployFor(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );

    assertEq(predicted, actual);
    assertEq(democracyDeployer.switchNonce(address(templ)), 1);
  }

  function test_predictDeployForAddress_council_matchesActual() public {
    address[] memory council = _councilOfTwo();
    address predicted = councilDeployer.predictDeployForAddress(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council
    );

    vm.prank(address(genesisGov));
    address actual = councilDeployer.deployFor(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council
    );

    assertEq(predicted, actual);
    assertEq(councilDeployer.switchNonce(address(templ)), 1);
  }

  // ============ End-to-end switch via proposal ============

  /// @dev Drive a 2-call proposal through the current governance:
  ///        1. XDeployer.deployFor(...)
  ///        2. Templ.setGovernance(predicted)
  ///      and assert the templ ends up wired to the predicted address.
  function _switchToCouncilViaProposal(
    Democracy currentGov,
    address[] memory council
  ) internal returns (address newGov) {
    address predicted = councilDeployer.predictDeployForAddress(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council
    );

    address[] memory targets = new address[](2);
    targets[0] = address(councilDeployer);
    targets[1] = address(templ);
    uint256[] memory vals = new uint256[](2);
    bytes[] memory cds = new bytes[](2);
    cds[0] = abi.encodeCall(
      CouncilDeployer.deployFor,
      (
        address(templ),
        APPROVAL_THRESHOLD_BPS,
        QUORUM_BPS,
        EXECUTION_DELAY,
        VOTING_PERIOD,
        IMMEDIATE_EXECUTION_BPS,
        0,
        council
      )
    );
    cds[1] = abi.encodeCall(ITempl.setGovernance, (predicted));

    vm.prank(alice);
    uint256 pid = currentGov.propose(targets, vals, cds, "to council");
    vm.prank(bob);
    currentGov.vote(pid, 1);
    vm.prank(charlie);
    currentGov.vote(pid, 1);
    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);
    currentGov.execute(pid);

    assertEq(templ.governance(), predicted);
    return predicted;
  }

  function _switchToDemocracyViaProposal(
    Council currentGov,
    address secondVoter
  ) internal returns (address newGov) {
    address predicted = democracyDeployer.predictDeployForAddress(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );

    address[] memory targets = new address[](2);
    targets[0] = address(democracyDeployer);
    targets[1] = address(templ);
    uint256[] memory vals = new uint256[](2);
    bytes[] memory cds = new bytes[](2);
    cds[0] = abi.encodeCall(
      DemocracyDeployer.deployFor,
      (
        address(templ),
        APPROVAL_THRESHOLD_BPS,
        QUORUM_BPS,
        EXECUTION_DELAY,
        VOTING_PERIOD,
        IMMEDIATE_EXECUTION_BPS,
        0
      )
    );
    cds[1] = abi.encodeCall(ITempl.setGovernance, (predicted));

    vm.prank(alice);
    uint256 pid = currentGov.propose(targets, vals, cds, "to democracy");
    // 2/2 council = 100% -> immediate execution
    vm.prank(secondVoter);
    currentGov.vote(pid, 1);
    currentGov.execute(pid);

    assertEq(templ.governance(), predicted);
    return predicted;
  }

  /// @dev democracy -> council -> democracy -> council. Verifies the nonce
  ///      keyspace prevents collisions and each new governance is fully
  ///      operational after the swap.
  function test_repeatedSwitching_democracyCouncilDemocracyCouncil() public {
    address[] memory council = _councilOfTwo();

    // 1. democracy -> council
    address councilAddr1 = _switchToCouncilViaProposal(genesisGov, council);
    assertEq(councilDeployer.switchNonce(address(templ)), 1);

    // 2. council -> democracy. Council = [alice, bob], bob seconds the vote.
    address democracyAddr1 =
      _switchToDemocracyViaProposal(Council(payable(councilAddr1)), bob);
    assertEq(democracyDeployer.switchNonce(address(templ)), 1);

    // 3. democracy -> council (different params so init code differs from
    //    the first council deploy too)
    address[] memory council2 = new address[](2);
    council2[0] = alice;
    council2[1] = charlie;
    address predictedCouncil2 = councilDeployer.predictDeployForAddress(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council2
    );

    Democracy newDemocracy = Democracy(payable(democracyAddr1));
    address[] memory targets = new address[](2);
    targets[0] = address(councilDeployer);
    targets[1] = address(templ);
    uint256[] memory vals = new uint256[](2);
    bytes[] memory cds = new bytes[](2);
    cds[0] = abi.encodeCall(
      CouncilDeployer.deployFor,
      (
        address(templ),
        APPROVAL_THRESHOLD_BPS,
        QUORUM_BPS,
        EXECUTION_DELAY,
        VOTING_PERIOD,
        IMMEDIATE_EXECUTION_BPS,
        0,
        council2
      )
    );
    cds[1] = abi.encodeCall(ITempl.setGovernance, (predictedCouncil2));

    vm.prank(alice);
    uint256 pid = newDemocracy.propose(targets, vals, cds, "to council 2");
    vm.prank(bob);
    newDemocracy.vote(pid, 1);
    vm.prank(charlie);
    newDemocracy.vote(pid, 1);
    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);
    newDemocracy.execute(pid);

    assertEq(templ.governance(), predictedCouncil2);
    assertTrue(predictedCouncil2 != councilAddr1);
    assertEq(councilDeployer.switchNonce(address(templ)), 2);

    // 4. council -> democracy. Council = [alice, charlie], charlie seconds.
    //    Confirms the next democracy switch uses nonce = 2 and lands at a
    //    brand-new address.
    Council councilGov2 = Council(payable(predictedCouncil2));
    address democracyAddr2 = _switchToDemocracyViaProposal(councilGov2, charlie);
    assertEq(democracyDeployer.switchNonce(address(templ)), 2);
    assertTrue(democracyAddr2 != democracyAddr1);

    // The newly-installed Democracy is operational: members can propose,
    // vote, and execute through it.
    Democracy democracyGov2 = Democracy(payable(democracyAddr2));
    address[] memory targets2 = new address[](1);
    targets2[0] = address(templ);
    uint256[] memory vals2 = new uint256[](1);
    bytes[] memory cds2 = new bytes[](1);
    cds2[0] = abi.encodeCall(ITempl.setBaseEntryFee, (2500e18));

    vm.prank(alice);
    uint256 pid2 = democracyGov2.propose(targets2, vals2, cds2, "raise fee");
    vm.prank(bob);
    democracyGov2.vote(pid2, 1);
    vm.prank(charlie);
    democracyGov2.vote(pid2, 1);
    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);
    democracyGov2.execute(pid2);

    assertEq(templ.baseEntryFee(), 2500e18);
  }

  // ============ Fake-templ guard ============

  /// @dev Spoof-templ that returns `address(this)` as its governance so the
  ///      first authorisation check in `deployFor` (`msg.sender == templ.governance()`)
  ///      passes. The second guard - `factory.isTempl(templ)` - is the one we
  ///      rely on to refuse this caller.
  function _deployFakeTempl() internal returns (FakeTempl fake) {
    fake = new FakeTempl();
  }

  function test_deployFor_democracy_revertsOnFakeTempl() public {
    FakeTempl fake = _deployFakeTempl();
    // Fake templ reports itself as its own governance, so this call passes
    // the first check (`msg.sender == ITempl(fake).governance()`). The
    // factory.isTempl guard must catch it.
    vm.prank(address(fake));
    vm.expectRevert(DemocracyDeployer.NotAuthorized.selector);
    democracyDeployer.deployFor(
      address(fake),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );
    // Nonce must not advance for an unregistered templ.
    assertEq(democracyDeployer.switchNonce(address(fake)), 0);
  }

  function test_deployFor_council_revertsOnFakeTempl() public {
    FakeTempl fake = _deployFakeTempl();
    address[] memory council = _councilOfTwo();
    vm.prank(address(fake));
    vm.expectRevert(CouncilDeployer.NotAuthorized.selector);
    councilDeployer.deployFor(
      address(fake),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council
    );
    assertEq(councilDeployer.switchNonce(address(fake)), 0);
  }

  // ============ Council constructor guards exercised via deployFor ============

  function test_deployFor_council_revertsOnZeroAddressMember() public {
    address[] memory council = new address[](2);
    council[0] = alice;
    council[1] = address(0);
    vm.prank(address(genesisGov));
    vm.expectRevert(Council.ZeroAddress.selector);
    councilDeployer.deployFor(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council
    );
    // Failed CREATE2 reverts before the nonce write commits.
    assertEq(councilDeployer.switchNonce(address(templ)), 0);
  }

  function test_deployFor_council_revertsOnDuplicateMember() public {
    address[] memory council = new address[](2);
    council[0] = alice;
    council[1] = alice;
    vm.prank(address(genesisGov));
    vm.expectRevert(Council.AlreadyCouncilMember.selector);
    councilDeployer.deployFor(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council
    );
    assertEq(councilDeployer.switchNonce(address(templ)), 0);
  }

  // ============ Same-mode switching with new params/members ============

  /// @dev democracy -> democracy with stricter parameters. Confirms a templ
  ///      can re-deploy the same governance type to update its tuning, and
  ///      that the nonce-salt namespacing produces a distinct address.
  function test_switchDemocracyToDemocracy_withDifferentParams() public {
    // Tighten the parameters compared to genesisGov.
    uint256 newApproval = 6000;
    uint256 newQuorum = 6000;
    uint256 newVotingPeriod = VOTING_PERIOD + 1 days;

    address predicted = democracyDeployer.predictDeployForAddress(
      address(templ),
      newApproval,
      newQuorum,
      EXECUTION_DELAY,
      newVotingPeriod,
      IMMEDIATE_EXECUTION_BPS,
      0
    );

    address[] memory targets = new address[](2);
    targets[0] = address(democracyDeployer);
    targets[1] = address(templ);
    uint256[] memory vals = new uint256[](2);
    bytes[] memory cds = new bytes[](2);
    cds[0] = abi.encodeCall(
      DemocracyDeployer.deployFor,
      (
        address(templ),
        newApproval,
        newQuorum,
        EXECUTION_DELAY,
        newVotingPeriod,
        IMMEDIATE_EXECUTION_BPS,
        0
      )
    );
    cds[1] = abi.encodeCall(ITempl.setGovernance, (predicted));

    vm.prank(alice);
    uint256 pid = genesisGov.propose(targets, vals, cds, "retune democracy");
    vm.prank(bob);
    genesisGov.vote(pid, 1);
    vm.prank(charlie);
    genesisGov.vote(pid, 1);
    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);
    genesisGov.execute(pid);

    assertEq(templ.governance(), predicted);
    assertTrue(predicted != address(genesisGov));
    assertEq(democracyDeployer.switchNonce(address(templ)), 1);

    // Sanity: new democracy honours the tighter params.
    Democracy newGov = Democracy(payable(predicted));
    assertEq(newGov.approvalThresholdBps(), newApproval);
    assertEq(newGov.quorumBps(), newQuorum);
    assertEq(newGov.votingPeriod(), newVotingPeriod);
  }

  /// @dev council -> council with a different member set. Confirms a templ
  ///      can rotate its entire council in one proposal.
  function test_switchCouncilToCouncil_withDifferentMembers() public {
    // First switch democracy -> council (alice + bob) so we start at a council.
    address[] memory council1 = _councilOfTwo();
    address councilAddr1 = _switchToCouncilViaProposal(genesisGov, council1);
    Council council1Gov = Council(payable(councilAddr1));

    // Now council -> council with a different roster (alice + charlie).
    address[] memory council2 = new address[](2);
    council2[0] = alice;
    council2[1] = charlie;
    address predicted = councilDeployer.predictDeployForAddress(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council2
    );

    address[] memory targets = new address[](2);
    targets[0] = address(councilDeployer);
    targets[1] = address(templ);
    uint256[] memory vals = new uint256[](2);
    bytes[] memory cds = new bytes[](2);
    cds[0] = abi.encodeCall(
      CouncilDeployer.deployFor,
      (
        address(templ),
        APPROVAL_THRESHOLD_BPS,
        QUORUM_BPS,
        EXECUTION_DELAY,
        VOTING_PERIOD,
        IMMEDIATE_EXECUTION_BPS,
        0,
        council2
      )
    );
    cds[1] = abi.encodeCall(ITempl.setGovernance, (predicted));

    vm.prank(alice);
    uint256 pid = council1Gov.propose(targets, vals, cds, "rotate council");
    vm.prank(bob); // second council member; 2/2 = 100% -> immediate execute
    council1Gov.vote(pid, 1);
    council1Gov.execute(pid);

    assertEq(templ.governance(), predicted);
    assertTrue(predicted != councilAddr1);
    assertEq(councilDeployer.switchNonce(address(templ)), 2);

    // The new council has the new roster.
    Council council2Gov = Council(payable(predicted));
    assertTrue(council2Gov.isCouncilMember(alice));
    assertTrue(council2Gov.isCouncilMember(charlie));
    assertFalse(council2Gov.isCouncilMember(bob));
    assertEq(council2Gov.councilSize(), 2);
  }

  /// @dev Five consecutive switches (D->C->D->C->D). Verifies nonce growth,
  ///      address uniqueness across the full sequence, and that the final
  ///      governance is fully operational.
  function test_fiveSwitches_DCDCD() public {
    address[] memory addrs = new address[](5);
    address[] memory councilA = _councilOfTwo();

    // 1: D->C
    addrs[0] = _switchToCouncilViaProposal(genesisGov, councilA);
    assertEq(councilDeployer.switchNonce(address(templ)), 1);

    // 2: C->D
    addrs[1] = _switchToDemocracyViaProposal(Council(payable(addrs[0])), bob);
    assertEq(democracyDeployer.switchNonce(address(templ)), 1);

    // 3: D->C (different roster)
    address[] memory councilB = new address[](2);
    councilB[0] = alice;
    councilB[1] = charlie;
    addrs[2] =
      _switchToCouncilViaProposal(Democracy(payable(addrs[1])), councilB);
    assertEq(councilDeployer.switchNonce(address(templ)), 2);

    // 4: C->D
    addrs[3] =
      _switchToDemocracyViaProposal(Council(payable(addrs[2])), charlie);
    assertEq(democracyDeployer.switchNonce(address(templ)), 2);

    // 5: D->C (yet another roster)
    address[] memory councilC = new address[](3);
    councilC[0] = alice;
    councilC[1] = bob;
    councilC[2] = charlie;
    addrs[4] =
      _switchToCouncilViaProposal(Democracy(payable(addrs[3])), councilC);
    assertEq(councilDeployer.switchNonce(address(templ)), 3);

    // All five governance addresses are pairwise distinct.
    for (uint256 i; i < addrs.length; ++i) {
      assertTrue(addrs[i] != address(genesisGov));
      for (uint256 j = i + 1; j < addrs.length; ++j) {
        assertTrue(addrs[i] != addrs[j]);
      }
    }

    // The final governance (a Council with all three as members) is wired up.
    assertEq(templ.governance(), addrs[4]);
    Council finalGov = Council(payable(addrs[4]));
    assertEq(finalGov.councilSize(), 3);
    assertTrue(finalGov.isCouncilMember(alice));
    assertTrue(finalGov.isCouncilMember(bob));
    assertTrue(finalGov.isCouncilMember(charlie));
  }

  // ============ Old governance loses authority post-switch ============

  /// @dev After a switch, the previous governance address must no longer
  ///      be able to invoke `deployFor` - it is no longer `templ.governance()`.
  function test_oldGovernance_revertsAfterSwap() public {
    address[] memory council = _councilOfTwo();
    address councilAddr = _switchToCouncilViaProposal(genesisGov, council);
    assertEq(templ.governance(), councilAddr);

    // genesisGov is no longer the active governance. Calling deployFor as
    // the old governance must revert.
    vm.prank(address(genesisGov));
    vm.expectRevert(CouncilDeployer.NotAuthorized.selector);
    councilDeployer.deployFor(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council
    );

    vm.prank(address(genesisGov));
    vm.expectRevert(DemocracyDeployer.NotAuthorized.selector);
    democracyDeployer.deployFor(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );

    // Failed deployFor calls must not leak nonce state.
    assertEq(councilDeployer.switchNonce(address(templ)), 1);
    assertEq(democracyDeployer.switchNonce(address(templ)), 0);
  }

  // ============ Proposal atomicity: revert rolls back the whole batch ============

  /// @dev If the second call in a switch proposal (`Templ.setGovernance(...)`)
  ///      reverts, the entire batch including the `deployFor` side-effect must
  ///      roll back. Confirms `switchNonce` does not creep forward when a
  ///      proposal fails to execute end-to-end.
  function test_proposalAtomicity_revertsBoth_whenSetGovernanceReverts()
    public
  {
    address predicted = democracyDeployer.predictDeployForAddress(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0
    );

    address[] memory targets = new address[](2);
    targets[0] = address(democracyDeployer);
    targets[1] = address(templ);
    uint256[] memory vals = new uint256[](2);
    bytes[] memory cds = new bytes[](2);
    cds[0] = abi.encodeCall(
      DemocracyDeployer.deployFor,
      (
        address(templ),
        APPROVAL_THRESHOLD_BPS,
        QUORUM_BPS,
        EXECUTION_DELAY,
        VOTING_PERIOD,
        IMMEDIATE_EXECUTION_BPS,
        0
      )
    );
    // setGovernance(0) reverts inside Templ. The whole batch must roll back.
    cds[1] = abi.encodeCall(ITempl.setGovernance, (address(0)));

    vm.prank(alice);
    uint256 pid = genesisGov.propose(targets, vals, cds, "broken switch");
    vm.prank(bob);
    genesisGov.vote(pid, 1);
    vm.prank(charlie);
    genesisGov.vote(pid, 1);
    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);

    vm.expectRevert();
    genesisGov.execute(pid);

    // Governance pointer untouched. Predicted address has no code (CREATE2
    // was rolled back). Nonce did not increment.
    assertEq(templ.governance(), address(genesisGov));
    assertEq(predicted.code.length, 0);
    assertEq(democracyDeployer.switchNonce(address(templ)), 0);
  }
}

/// @dev Minimal contract that satisfies the ITempl.governance() call surface
///      used by the deployers' first authorisation check, while *not* being
///      registered with the factory. Used to prove that the `isTempl` guard
///      blocks spoofed-templ inputs.
contract FakeTempl {
  function governance() external view returns (address) {
    return address(this);
  }
}
