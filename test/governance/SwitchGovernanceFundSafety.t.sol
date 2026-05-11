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
import { IExecutable } from "../../src/interfaces/IExecutable.sol";
import { IGovernance } from "../../src/interfaces/IGovernance.sol";
import { ITempl } from "../../src/interfaces/ITempl.sol";
import { EntryFeeCurve } from "../../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockFactory } from "../mocks/MockFactory.sol";
import {
  TreasuryDrainingGovernance
} from "../mocks/TreasuryDrainingGovernance.sol";
import { Test } from "forge-std/Test.sol";

interface IERC20Like {
  function balanceOf(
    address
  ) external view returns (uint256);
  function transfer(
    address,
    uint256
  ) external returns (bool);
}

/// @title SwitchGovernanceFundSafetyTest
/// @notice End-to-end fund-safety coverage across governance switches.
///         These tests are the load-bearing assurance that user money cannot
///         get bricked, stranded, or stolen across a governance transition.
///         Every test follows the same shape: fund the vault, drive a
///         governance switch via real proposal flow, then prove that the
///         current authority — and ONLY the current authority — can move
///         funds. Regressions in the pointer-flip ordering on Templ.setGovernance
///         or in Treasury._checkGovernance's dynamic read of Templ.governance()
///         will surface as failures here.
contract SwitchGovernanceFundSafetyTest is Test {
  Templ public templ;
  Treasury public treasury;
  MemberPool public pool;
  Democracy public genesisGov;
  DemocracyDeployer public democracyDeployer;
  CouncilDeployer public councilDeployer;
  GovernanceDeployer public govDeployer;
  MockERC20 public token;
  MockERC20 public extraToken; // distinct ERC20 to exercise multi-asset moves
  MockFactory public mf;

  /// @dev This test contract acts as the Factory from the deployers'
  ///      perspective (`govDeployer.setFactory(address(this))` in setUp),
  ///      mirroring SwitchGovernance.t.sol. The deployer's deployFor path
  ///      checks `IFactory(factory).isTempl(templ)`; tests register the real
  ///      templ in this map.
  mapping(address => bool) public isTempl;

  address public priest = makeAddr("priest");
  address public protocolRecipient = makeAddr("protocol");
  address public alice = makeAddr("alice");
  address public bob = makeAddr("bob");
  address public charlie = makeAddr("charlie");
  address public recipientA = makeAddr("recipientA");
  address public recipientB = makeAddr("recipientB");
  address public attacker = makeAddr("attacker");

  uint256 public constant ENTRY_FEE = 1000e18;
  uint256 public constant APPROVAL_THRESHOLD_BPS = 5100;
  uint256 public constant QUORUM_BPS = 5100;
  uint256 public constant EXECUTION_DELAY = 1 days;
  uint256 public constant VOTING_PERIOD = 3 days;
  uint256 public constant IMMEDIATE_EXECUTION_BPS = 10_000;

  uint256 public constant TREASURY_SEED_TOKEN = 500e18;
  uint256 public constant TREASURY_SEED_EXTRA = 700e18;
  uint256 public constant TREASURY_SEED_NATIVE = 3 ether;

  function setUp() public {
    token = new MockERC20();
    extraToken = new MockERC20();
    mf = new MockFactory(protocolRecipient);

    democracyDeployer = new DemocracyDeployer(address(this));
    councilDeployer = new CouncilDeployer(address(this));
    govDeployer = new GovernanceDeployer(
      address(democracyDeployer), address(councilDeployer), address(this)
    );
    councilDeployer.setGovernanceDeployer(address(govDeployer));
    democracyDeployer.setGovernanceDeployer(address(govDeployer));
    govDeployer.setFactory(address(this));

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

    // Register the real templ so deployFor's isTempl guard passes.
    isTempl[address(templ)] = true;

    _joinMember(alice);
    _joinMember(bob);
    _joinMember(charlie);
  }

  // ============ Funding helpers ============

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

  function _councilOf3() internal view returns (address[] memory members) {
    members = new address[](3);
    members[0] = alice;
    members[1] = bob;
    members[2] = charlie;
  }

  /// @dev Fund the treasury directly with token, extraToken, and native ETH.
  ///      We don't route through `join()` because the per-join treasury slice
  ///      is small and the test cares about ergonomic round-trip amounts.
  function _fundTreasury() internal {
    token.mint(address(treasury), TREASURY_SEED_TOKEN);
    extraToken.mint(address(treasury), TREASURY_SEED_EXTRA);
    vm.deal(address(this), TREASURY_SEED_NATIVE);
    (bool ok,) = address(treasury).call{ value: TREASURY_SEED_NATIVE }("");
    require(ok, "fund native");
  }

  // ============ Proposal helpers ============

  /// @dev Drive a democracy -> council switch through the current democracy
  ///      governance: deployFor(council params), then setGovernance(predicted).
  function _switchDemocracyToCouncil(
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
    uint256 pid = currentGov.propose(targets, vals, cds, "switch to council");
    vm.prank(bob);
    currentGov.vote(pid, 1);
    vm.prank(charlie);
    currentGov.vote(pid, 1);
    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);
    currentGov.execute(pid);

    assertEq(templ.governance(), predicted);
    return predicted;
  }

  /// @dev Drive a council -> democracy switch. The 3-member council reaches
  ///      100% with all votes, firing the instant branch and bypassing the
  ///      voting period entirely.
  function _switchCouncilToDemocracy(
    Council currentGov
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
    uint256 pid = currentGov.propose(targets, vals, cds, "switch to democracy");
    vm.prank(bob);
    currentGov.vote(pid, 1);
    vm.prank(charlie);
    currentGov.vote(pid, 1);
    // 3/3 council -> instant execution, no warp required.
    currentGov.execute(pid);

    assertEq(templ.governance(), predicted);
    return predicted;
  }

  /// @dev Build a 2-call proposal that drains `tokenAmt` of `tokenAddr` to
  ///      `to1` and `extraAmt` of `extraToken` to `to2`, then submit it via
  ///      `proposer` on `currentGov`, vote with alice/bob/charlie, and
  ///      execute. Caller is responsible for picking a proposer that the
  ///      current gov accepts (templ member for democracy, anyone for
  ///      council since council also requires templ membership for voting).
  function _proposeAndExecuteWithdrawDemocracy(
    Democracy currentGov,
    uint256 tokenAmt,
    address to1,
    uint256 extraAmt,
    address to2
  ) internal {
    address[] memory targets = new address[](2);
    targets[0] = address(treasury);
    targets[1] = address(treasury);
    uint256[] memory vals = new uint256[](2);
    bytes[] memory cds = new bytes[](2);
    cds[0] = abi.encodeCall(
      IExecutable.execute,
      (address(token), 0, abi.encodeCall(IERC20Like.transfer, (to1, tokenAmt)))
    );
    cds[1] = abi.encodeCall(
      IExecutable.execute,
      (
        address(extraToken),
        0,
        abi.encodeCall(IERC20Like.transfer, (to2, extraAmt))
      )
    );

    vm.prank(alice);
    uint256 pid = currentGov.propose(targets, vals, cds, "withdraw tokens");
    vm.prank(bob);
    currentGov.vote(pid, 1);
    vm.prank(charlie);
    currentGov.vote(pid, 1);
    vm.warp(block.timestamp + VOTING_PERIOD + EXECUTION_DELAY);
    currentGov.execute(pid);
  }

  function _proposeAndExecuteWithdrawCouncil(
    Council currentGov,
    uint256 tokenAmt,
    address to1,
    uint256 extraAmt,
    address to2
  ) internal {
    address[] memory targets = new address[](2);
    targets[0] = address(treasury);
    targets[1] = address(treasury);
    uint256[] memory vals = new uint256[](2);
    bytes[] memory cds = new bytes[](2);
    cds[0] = abi.encodeCall(
      IExecutable.execute,
      (address(token), 0, abi.encodeCall(IERC20Like.transfer, (to1, tokenAmt)))
    );
    cds[1] = abi.encodeCall(
      IExecutable.execute,
      (
        address(extraToken),
        0,
        abi.encodeCall(IERC20Like.transfer, (to2, extraAmt))
      )
    );

    vm.prank(alice);
    uint256 pid = currentGov.propose(targets, vals, cds, "withdraw tokens");
    vm.prank(bob);
    currentGov.vote(pid, 1);
    vm.prank(charlie);
    currentGov.vote(pid, 1);
    // 3/3 council -> instant.
    currentGov.execute(pid);
  }

  // ============ A. Treasury survives democracy -> council switch ============

  /// @dev Fund treasury, switch democracy -> council, then drive a treasury
  ///      withdrawal via the new council. Proves: the new authority can move
  ///      funds and the funds land at the intended recipients with the
  ///      treasury balance decreasing accordingly.
  function test_treasurySurvivesDemocracyToCouncilSwitch() public {
    _fundTreasury();

    // Treasury already holds protocol slices from the 3 setUp joins; the
    // seed helpers add to that. Capture the post-seed reality.
    uint256 tokenBefore = token.balanceOf(address(treasury));
    uint256 extraBefore = extraToken.balanceOf(address(treasury));
    uint256 nativeBefore = address(treasury).balance;
    assertGe(tokenBefore, TREASURY_SEED_TOKEN);
    assertEq(extraBefore, TREASURY_SEED_EXTRA);
    assertEq(nativeBefore, TREASURY_SEED_NATIVE);

    address[] memory council = _councilOf3();
    address councilAddr = _switchDemocracyToCouncil(genesisGov, council);
    Council newGov = Council(payable(councilAddr));

    // Withdraw a slice of each asset via the new council.
    uint256 tokenSlice = 200e18;
    uint256 extraSlice = 300e18;
    uint256 nativeSlice = 1 ether;

    address[] memory targets = new address[](3);
    targets[0] = address(treasury);
    targets[1] = address(treasury);
    targets[2] = address(treasury);
    uint256[] memory vals = new uint256[](3);
    bytes[] memory cds = new bytes[](3);
    cds[0] = abi.encodeCall(
      IExecutable.execute,
      (
        address(token),
        0,
        abi.encodeCall(IERC20Like.transfer, (recipientA, tokenSlice))
      )
    );
    cds[1] = abi.encodeCall(
      IExecutable.execute,
      (
        address(extraToken),
        0,
        abi.encodeCall(IERC20Like.transfer, (recipientB, extraSlice))
      )
    );
    cds[2] = abi.encodeCall(IExecutable.execute, (recipientA, nativeSlice, ""));

    vm.prank(alice);
    uint256 pid = newGov.propose(targets, vals, cds, "withdraw mixed assets");
    vm.prank(bob);
    newGov.vote(pid, 1);
    vm.prank(charlie);
    newGov.vote(pid, 1);
    // 3/3 council -> instant.
    newGov.execute(pid);

    // Recipients received the expected amounts.
    assertEq(token.balanceOf(recipientA), tokenSlice);
    assertEq(extraToken.balanceOf(recipientB), extraSlice);
    assertEq(recipientA.balance, nativeSlice);

    // Treasury balances decreased by exactly the withdrawn amount.
    assertEq(token.balanceOf(address(treasury)), tokenBefore - tokenSlice);
    assertEq(extraToken.balanceOf(address(treasury)), extraBefore - extraSlice);
    assertEq(address(treasury).balance, nativeBefore - nativeSlice);

    // No orphans: nothing landed in the old governance or the new governance
    // (Treasury.execute runs in Treasury's context — funds always go to the
    // recipient encoded in the call).
    assertEq(token.balanceOf(address(genesisGov)), 0);
    assertEq(token.balanceOf(address(newGov)), 0);
    assertEq(extraToken.balanceOf(address(genesisGov)), 0);
    assertEq(extraToken.balanceOf(address(newGov)), 0);
  }

  // ============ B. Treasury survives council -> democracy switch ============

  /// @dev Mirror of A in the opposite direction: start at democracy, hop to
  ///      a council, hop back to a democracy, then drive a withdrawal via
  ///      that final democracy. Funds must land cleanly.
  function test_treasurySurvivesCouncilToDemocracySwitch() public {
    _fundTreasury();

    uint256 tokenBefore = token.balanceOf(address(treasury));
    uint256 extraBefore = extraToken.balanceOf(address(treasury));

    address[] memory council = _councilOf3();
    address councilAddr = _switchDemocracyToCouncil(genesisGov, council);
    address democracyAddr =
      _switchCouncilToDemocracy(Council(payable(councilAddr)));
    Democracy newGov = Democracy(payable(democracyAddr));

    uint256 tokenSlice = 150e18;
    uint256 extraSlice = 250e18;

    _proposeAndExecuteWithdrawDemocracy(
      newGov, tokenSlice, recipientA, extraSlice, recipientB
    );

    assertEq(token.balanceOf(recipientA), tokenSlice);
    assertEq(extraToken.balanceOf(recipientB), extraSlice);
    assertEq(token.balanceOf(address(treasury)), tokenBefore - tokenSlice);
    assertEq(extraToken.balanceOf(address(treasury)), extraBefore - extraSlice);

    // No funds at any of the three governance addresses we ever installed.
    assertEq(token.balanceOf(address(genesisGov)), 0);
    assertEq(token.balanceOf(councilAddr), 0);
    assertEq(token.balanceOf(address(newGov)), 0);
  }

  // ============ C. Repeated switches with mid-flight withdrawals ============

  /// @dev Heavy stress: democracy -> council (withdraw) -> democracy
  ///      (withdraw) -> council (different roster, withdraw). Verifies that
  ///      every intermediate governance can drain its slice and that the
  ///      cumulative drain matches the cumulative seed minus the final
  ///      balance.
  function test_treasurySurvivesRepeatedSwitchesWithMidflightWithdrawals()
    public
  {
    _fundTreasury();
    uint256 tokenSeed = token.balanceOf(address(treasury));
    uint256 extraSeed = extraToken.balanceOf(address(treasury));

    address[] memory council = _councilOf3();

    // Switch 1: democracy -> council; withdraw slice 1.
    address councilAddr = _switchDemocracyToCouncil(genesisGov, council);
    Council council1 = Council(payable(councilAddr));
    uint256 t1 = 50e18;
    uint256 e1 = 70e18;
    _proposeAndExecuteWithdrawCouncil(council1, t1, recipientA, e1, recipientB);
    assertEq(token.balanceOf(address(treasury)), tokenSeed - t1);
    assertEq(extraToken.balanceOf(address(treasury)), extraSeed - e1);

    // Switch 2: council -> democracy; withdraw slice 2.
    address democracyAddr = _switchCouncilToDemocracy(council1);
    Democracy democracy2 = Democracy(payable(democracyAddr));
    uint256 t2 = 60e18;
    uint256 e2 = 80e18;
    _proposeAndExecuteWithdrawDemocracy(
      democracy2, t2, recipientA, e2, recipientB
    );
    assertEq(token.balanceOf(address(treasury)), tokenSeed - t1 - t2);
    assertEq(extraToken.balanceOf(address(treasury)), extraSeed - e1 - e2);

    // Switch 3: democracy -> council with different roster; withdraw slice 3.
    address[] memory council2 = new address[](3);
    council2[0] = alice;
    council2[1] = charlie;
    council2[2] = bob;
    address councilAddr2 = _switchDemocracyToCouncil(democracy2, council2);
    Council council3 = Council(payable(councilAddr2));
    uint256 t3 = 70e18;
    uint256 e3 = 90e18;
    _proposeAndExecuteWithdrawCouncil(council3, t3, recipientA, e3, recipientB);

    // Final accounting: every wei accounted for, nothing stranded at any
    // governance address.
    uint256 totalTokenWithdrawn = t1 + t2 + t3;
    uint256 totalExtraWithdrawn = e1 + e2 + e3;
    assertEq(token.balanceOf(recipientA), totalTokenWithdrawn);
    assertEq(extraToken.balanceOf(recipientB), totalExtraWithdrawn);
    assertEq(
      token.balanceOf(address(treasury)), tokenSeed - totalTokenWithdrawn
    );
    assertEq(
      extraToken.balanceOf(address(treasury)), extraSeed - totalExtraWithdrawn
    );
    assertEq(token.balanceOf(address(genesisGov)), 0);
    assertEq(token.balanceOf(councilAddr), 0);
    assertEq(token.balanceOf(democracyAddr), 0);
    assertEq(token.balanceOf(councilAddr2), 0);
    assertEq(extraToken.balanceOf(address(genesisGov)), 0);
    assertEq(extraToken.balanceOf(councilAddr), 0);
    assertEq(extraToken.balanceOf(democracyAddr), 0);
    assertEq(extraToken.balanceOf(councilAddr2), 0);
  }

  // ============ D. Old governance cannot drain after a switch ============

  /// @dev THE CRITICAL TEST. Build a fully-passed withdrawal proposal on
  ///      democracy, then switch governance to a council BEFORE executing
  ///      it. The withdrawal must revert because Treasury._checkGovernance
  ///      reads Templ.governance() dynamically — and that now returns the
  ///      new council, not the old democracy. If anyone ever caches the
  ///      governance pointer on Treasury (or removes the dynamic read), this
  ///      test fails and the treasury becomes drainable by stale proposals.
  function test_oldGovernanceCannotDrainTreasuryAfterSwitch() public {
    _fundTreasury();
    uint256 tokenBefore = token.balanceOf(address(treasury));
    uint256 extraBefore = extraToken.balanceOf(address(treasury));
    uint256 nativeBefore = address(treasury).balance;

    // Step 1: build a withdrawal proposal on the genesis democracy that
    // tries to drain the entire treasury to `attacker`. Vote it through to
    // an executable state but DO NOT execute yet.
    uint256 tokenAmt = tokenBefore;
    uint256 extraAmt = extraBefore;
    uint256 nativeAmt = nativeBefore;

    address[] memory targets = new address[](3);
    targets[0] = address(treasury);
    targets[1] = address(treasury);
    targets[2] = address(treasury);
    uint256[] memory vals = new uint256[](3);
    bytes[] memory cds = new bytes[](3);
    cds[0] = abi.encodeCall(
      IExecutable.execute,
      (
        address(token),
        0,
        abi.encodeCall(IERC20Like.transfer, (attacker, tokenAmt))
      )
    );
    cds[1] = abi.encodeCall(
      IExecutable.execute,
      (
        address(extraToken),
        0,
        abi.encodeCall(IERC20Like.transfer, (attacker, extraAmt))
      )
    );
    cds[2] = abi.encodeCall(IExecutable.execute, (attacker, nativeAmt, ""));

    vm.prank(alice);
    uint256 drainPid = genesisGov.propose(targets, vals, cds, "stale drain");
    vm.prank(bob);
    genesisGov.vote(drainPid, 1);
    vm.prank(charlie);
    genesisGov.vote(drainPid, 1);
    vm.prank(priest);
    genesisGov.vote(drainPid, 1);
    // 4/4 voters -> instant branch fires (forVotes * BPS / 4 = 10_000 >=
    // IMMEDIATE_EXECUTION_BPS = 10_000), so the drain proposal is ready to
    // execute right now without any further warp. Quorum and approval
    // thresholds are trivially satisfied.

    // Step 2: switch governance to a council via a SEPARATE proposal. Alice
    // cannot have two active proposals at once, so the switch proposal is
    // submitted by bob.
    address[] memory council = _councilOf3();
    address predictedCouncil = councilDeployer.predictDeployForAddress(
      address(templ),
      APPROVAL_THRESHOLD_BPS,
      QUORUM_BPS,
      EXECUTION_DELAY,
      VOTING_PERIOD,
      IMMEDIATE_EXECUTION_BPS,
      0,
      council
    );
    address[] memory switchTargets = new address[](2);
    switchTargets[0] = address(councilDeployer);
    switchTargets[1] = address(templ);
    uint256[] memory switchVals = new uint256[](2);
    bytes[] memory switchCds = new bytes[](2);
    switchCds[0] = abi.encodeCall(
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
    switchCds[1] = abi.encodeCall(ITempl.setGovernance, (predictedCouncil));

    vm.prank(bob);
    uint256 switchPid =
      genesisGov.propose(switchTargets, switchVals, switchCds, "switch out");
    vm.prank(alice);
    genesisGov.vote(switchPid, 1);
    vm.prank(charlie);
    genesisGov.vote(switchPid, 1);
    vm.prank(priest);
    genesisGov.vote(switchPid, 1);
    // 4/4 voters -> instant, execute immediately.
    genesisGov.execute(switchPid);

    // The templ now points at the new council; the genesis democracy is no
    // longer the authorized governance from Treasury's POV.
    assertEq(templ.governance(), predictedCouncil);

    // Step 3: try to execute the original drain proposal on the (now stale)
    // genesis democracy. It must revert at Treasury._checkGovernance:
    // Treasury.execute reverts with NotGovernance, which Governance.execute
    // surfaces as ExecutionFailed.
    vm.expectRevert(IGovernance.ExecutionFailed.selector);
    genesisGov.execute(drainPid);

    // Step 4: every wei is still in the treasury. Nothing leaked to the
    // attacker, nothing landed at the stale governance.
    assertEq(token.balanceOf(address(treasury)), tokenBefore);
    assertEq(extraToken.balanceOf(address(treasury)), extraBefore);
    assertEq(address(treasury).balance, nativeBefore);
    assertEq(token.balanceOf(attacker), 0);
    assertEq(extraToken.balanceOf(attacker), 0);
    assertEq(attacker.balance, 0);
    assertEq(token.balanceOf(address(genesisGov)), 0);
    assertEq(extraToken.balanceOf(address(genesisGov)), 0);
  }

  // ============ E. New malicious gov cannot reenter during setGovernance ===

  /// @dev When Templ.setGovernance(maliciousGov) calls maliciousGov.emitConfig(),
  ///      the storage write to `Templ.governance` is deferred until after the
  ///      callback returns. If a malicious new gov tries to call a
  ///      governance-only Treasury function from inside emitConfig, Treasury
  ///      resolves `Templ.governance()` to the OLD governance and reverts.
  ///      The whole setGovernance call bubbles up the revert.
  ///
  ///      Pinned by `test_setGovernance_cannotDrainTreasuryViaEmitConfig` in
  ///      Templ.t.sol against the direct-call path; this companion drives the
  ///      same attack through the switch-via-proposal path (a sitting
  ///      governance proposes setGovernance(malicious)) and confirms the
  ///      atomicity property: the proposal as a whole reverts and the
  ///      governance pointer never moves to the attacker.
  function test_maliciousNewGovernanceCannotDrainTreasuryDuringEmitConfig()
    public
  {
    _fundTreasury();
    uint256 tokenBefore = token.balanceOf(address(treasury));
    uint256 extraBefore = extraToken.balanceOf(address(treasury));

    TreasuryDrainingGovernance malicious =
      new TreasuryDrainingGovernance(address(templ), attacker);

    // Propose Templ.setGovernance(malicious) via the genesis democracy.
    address[] memory targets = new address[](1);
    targets[0] = address(templ);
    uint256[] memory vals = new uint256[](1);
    bytes[] memory cds = new bytes[](1);
    cds[0] = abi.encodeCall(ITempl.setGovernance, (address(malicious)));

    vm.prank(alice);
    uint256 pid = genesisGov.propose(targets, vals, cds, "malicious swap");
    vm.prank(bob);
    genesisGov.vote(pid, 1);
    vm.prank(charlie);
    genesisGov.vote(pid, 1);
    vm.prank(priest);
    genesisGov.vote(pid, 1);

    // The malicious emitConfig() tries to call Treasury.execute. Treasury
    // checks Templ.governance() which still resolves to genesisGov (the
    // pointer flip is deferred until after emitConfig returns), so the
    // execute call reverts with NotGovernance. That bubbles out of
    // setGovernance and out of Governance.execute as ExecutionFailed.
    vm.expectRevert(IGovernance.ExecutionFailed.selector);
    genesisGov.execute(pid);

    // Governance pointer untouched, treasury untouched, attacker got
    // nothing.
    assertEq(templ.governance(), address(genesisGov));
    assertEq(token.balanceOf(address(treasury)), tokenBefore);
    assertEq(extraToken.balanceOf(address(treasury)), extraBefore);
    assertEq(token.balanceOf(attacker), 0);
    assertEq(extraToken.balanceOf(attacker), 0);
  }

  // ============ F. MemberPool funds survive switches =====================

  /// @dev MemberPool exposes ZERO governance-callable functions: the only
  ///      TOKEN outflow is `claimRewards`, which is permissionless and pays
  ///      the member directly. There is no `withdraw`, no `dissolve`, no
  ///      governance-gated mover (see MemberPool.sol NatSpec). That means a
  ///      governance switch cannot affect MemberPool authority surfaces —
  ///      there are none. We assert that member claims continue to work
  ///      unchanged across a switch (a positive liveness property), and that
  ///      the new governance has no way to seize MemberPool funds.
  function test_memberPoolClaimsSurviveSwitchesAndGovernanceCannotSeize()
    public
  {
    // Drive a paid join so the pool accumulates real rewards.
    address newcomer = makeAddr("newcomer");
    _joinMember(newcomer);

    // After newcomer's paid join, alice/bob/charlie/priest have claimable
    // rewards on the pool. Snapshot one of them.
    uint256 aliceClaimableBefore = pool.getClaimableRewards(alice);
    assertGt(aliceClaimableBefore, 0, "alice should have claimable rewards");

    // Switch democracy -> council. Pool authority surface is unaffected.
    address[] memory council = _councilOf3();
    address councilAddr = _switchDemocracyToCouncil(genesisGov, council);

    // Same claimable amount post-switch (no state-of-the-pool corruption).
    assertEq(pool.getClaimableRewards(alice), aliceClaimableBefore);

    // The new council cannot move pool funds: there is no governance entry
    // point on MemberPool. Confirm by asserting the pool has no
    // `execute`-like surface — a generic execute on the pool address would
    // hit non-existent calldata. To pin the no-admin invariant we prove
    // that calling any plausible attacker-style function reverts. The pool
    // interface only exposes `setTempl`/`setTreasury` (factory-gated,
    // one-shot already-initialized), `onJoin` (templ-gated), `accrue`
    // (permissionless), `claimRewards` (pays member). None drain to the
    // governance.

    // setTempl as the new gov -> AlreadyInitialized (factory-gated AND
    // one-shot; we want to assert it reverts regardless of who calls).
    vm.prank(councilAddr);
    vm.expectRevert();
    pool.setTempl(councilAddr);

    // Claim still works for the member and pays the member.
    uint256 aliceTokenBefore = token.balanceOf(alice);
    pool.claimRewards(alice);
    uint256 paid = token.balanceOf(alice) - aliceTokenBefore;
    assertEq(paid, aliceClaimableBefore);

    // Cross-switch claim: switch council -> democracy, then claim for bob.
    uint256 bobClaimableBefore = pool.getClaimableRewards(bob);
    assertGt(bobClaimableBefore, 0);
    _switchCouncilToDemocracy(Council(payable(councilAddr)));
    assertEq(pool.getClaimableRewards(bob), bobClaimableBefore);
    uint256 bobTokenBefore = token.balanceOf(bob);
    pool.claimRewards(bob);
    assertEq(token.balanceOf(bob) - bobTokenBefore, bobClaimableBefore);
  }

  // ============ G. switchNonce does not affect Treasury ==================

  /// @dev Sanity: incrementing switchNonce by driving several switches must
  ///      have no effect on Treasury balances or its addressable state. This
  ///      pins the topology: switchNonce lives on the deployer contracts,
  ///      Treasury never reads it. If anyone wires nonce into Treasury by
  ///      accident, balances would change here.
  function test_switchNonceDoesNotAffectTreasury() public {
    _fundTreasury();
    uint256 tokenBefore = token.balanceOf(address(treasury));
    uint256 extraBefore = extraToken.balanceOf(address(treasury));
    uint256 nativeBefore = address(treasury).balance;
    address templBefore = treasury.TEMPL();
    address mpBefore = treasury.MEMBER_POOL();
    address tokenAddrBefore = treasury.TOKEN();

    // Drive 4 switches: D -> C -> D -> C -> D. Each one bumps a nonce on
    // either democracyDeployer or councilDeployer.
    address[] memory council = _councilOf3();
    address[] memory council2 = new address[](3);
    council2[0] = charlie;
    council2[1] = bob;
    council2[2] = alice;

    address c1 = _switchDemocracyToCouncil(genesisGov, council);
    address d1 = _switchCouncilToDemocracy(Council(payable(c1)));
    address c2 = _switchDemocracyToCouncil(Democracy(payable(d1)), council2);
    address d2 = _switchCouncilToDemocracy(Council(payable(c2)));

    // Nonces have advanced.
    assertEq(councilDeployer.switchNonce(address(templ)), 2);
    assertEq(democracyDeployer.switchNonce(address(templ)), 2);
    assertEq(templ.governance(), d2);

    // Treasury identity is untouched (no setters fire on switch).
    assertEq(treasury.TEMPL(), templBefore);
    assertEq(treasury.MEMBER_POOL(), mpBefore);
    assertEq(treasury.TOKEN(), tokenAddrBefore);

    // Treasury balances unchanged (we never withdrew).
    assertEq(token.balanceOf(address(treasury)), tokenBefore);
    assertEq(extraToken.balanceOf(address(treasury)), extraBefore);
    assertEq(address(treasury).balance, nativeBefore);
  }
}
