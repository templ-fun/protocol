// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Treasury } from "../../../src/Treasury.sol";
import { LinkContest } from "../../../src/plugins/link-contest/LinkContest.sol";
import {
  LinkContestFactory
} from "../../../src/plugins/link-contest/LinkContestFactory.sol";
import { MockCouncil } from "../../mocks/MockCouncil.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockFactory } from "../../mocks/MockFactory.sol";
import { MockNonCouncilGov } from "../../mocks/MockNonCouncilGov.sol";
import { MockTempl } from "../../mocks/MockTempl.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Tests LinkContestFactory: emits `LinkContestCreated` (the indexer
///      discovery hook), produces a working contest, and enforces the
///      priest / council deploy gate.
contract LinkContestFactoryTest is Test {
  LinkContestFactory public deployer;
  MockFactory public protocolFactory;
  Treasury public treasury;
  MockTempl public templ;
  MockERC20 public token;

  address public owner = makeAddr("owner");
  address public protocolRecipient = makeAddr("protocol");
  address public alice = makeAddr("alice");
  address public priest = makeAddr("priest");
  address public councilMember = makeAddr("councilMember");
  address public stranger = makeAddr("stranger");

  uint256 public constant FEE = 1000e18;
  uint256 public constant ROUND_DURATION = 7 days;

  uint256 public start;

  event LinkContestCreated(
    address indexed contest,
    address indexed templ,
    address token,
    uint256 submissionFee,
    uint256 roundDuration,
    uint256 firstRoundStart
  );

  function setUp() public {
    token = new MockERC20();
    protocolFactory = new MockFactory(protocolRecipient);
    treasury = protocolFactory.deployTreasury(address(token));
    templ = new MockTempl(address(treasury));
    templ.setPriest(priest);
    deployer = new LinkContestFactory();
    start = block.timestamp;

    token.mint(alice, 1_000_000e18);
  }

  function _createContest() internal returns (address) {
    return deployer.createContest(
      address(templ), address(token), FEE, ROUND_DURATION, start, owner
    );
  }

  function test_createContest_emitsCreationEvent() public {
    // The contest address is not known ahead of the call, so match the
    // unindexed payload and the templ topic, not the contest topic.
    vm.expectEmit(false, true, false, true);
    emit LinkContestCreated(
      address(0), address(templ), address(token), FEE, ROUND_DURATION, start
    );
    vm.prank(priest);
    _createContest();
  }

  function test_createContest_deploysWorkingContest() public {
    vm.prank(priest);
    address contestAddr = _createContest();
    LinkContest contest = LinkContest(contestAddr);

    assertEq(contest.TEMPL(), address(templ));
    assertEq(contest.submissionFee(), FEE);
    assertEq(contest.firstRoundStart(), start);
    assertEq(contest.owner(), owner);

    vm.startPrank(alice);
    token.approve(contestAddr, FEE);
    contest.submit("https://x.com/a", "https://x.com/a");
    vm.stopPrank();

    uint256 round = contest.currentRound();
    assertEq(contest.submitterOf(round, 1), alice);
  }

  function test_createContest_revertsWhenStranger() public {
    vm.prank(stranger);
    vm.expectRevert(LinkContestFactory.NotAuthorized.selector);
    _createContest();
  }

  function test_createContest_priestCanDeployOnCouncilTempl() public {
    MockCouncil council = new MockCouncil();
    templ.setGovernance(address(council));

    vm.prank(priest);
    address contestAddr = _createContest();
    assertEq(LinkContest(contestAddr).TEMPL(), address(templ));
  }

  function test_createContest_priestCanDeployOnDemocracyTempl() public {
    MockNonCouncilGov gov = new MockNonCouncilGov();
    templ.setGovernance(address(gov));

    vm.prank(priest);
    address contestAddr = _createContest();
    assertEq(LinkContest(contestAddr).TEMPL(), address(templ));
  }

  function test_createContest_councilMemberCanDeploy() public {
    MockCouncil council = new MockCouncil();
    council.setCouncilMember(councilMember, true);
    templ.setGovernance(address(council));

    vm.prank(councilMember);
    address contestAddr = _createContest();
    assertEq(LinkContest(contestAddr).TEMPL(), address(templ));
  }

  function test_createContest_nonPriestMemberOnDemocracyCannotDeploy() public {
    MockNonCouncilGov gov = new MockNonCouncilGov();
    templ.setGovernance(address(gov));
    // Plain member status does not grant deploy rights on a non-council templ.
    templ.setMember(alice, true);

    vm.prank(alice);
    vm.expectRevert(LinkContestFactory.NotAuthorized.selector);
    _createContest();
  }

  function test_createContest_nonCouncilMemberOnCouncilTemplCannotDeploy()
    public
  {
    MockCouncil council = new MockCouncil();
    templ.setGovernance(address(council));

    vm.prank(alice);
    vm.expectRevert(LinkContestFactory.NotAuthorized.selector);
    _createContest();
  }

  function test_createContest_oldPriestCannotDeployAfterTransfer() public {
    address newPriest = makeAddr("newPriest");
    templ.setPriest(newPriest);

    vm.prank(priest);
    vm.expectRevert(LinkContestFactory.NotAuthorized.selector);
    _createContest();

    vm.prank(newPriest);
    address contestAddr = _createContest();
    assertEq(LinkContest(contestAddr).TEMPL(), address(templ));
  }

  function test_createContest_removedCouncilMemberCannotDeploy() public {
    MockCouncil council = new MockCouncil();
    council.setCouncilMember(councilMember, true);
    templ.setGovernance(address(council));

    vm.prank(councilMember);
    address first = _createContest();
    assertEq(LinkContest(first).TEMPL(), address(templ));

    council.setCouncilMember(councilMember, false);

    vm.prank(councilMember);
    vm.expectRevert(LinkContestFactory.NotAuthorized.selector);
    _createContest();
  }
}
