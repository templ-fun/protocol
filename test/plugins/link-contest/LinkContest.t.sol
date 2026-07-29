// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Treasury } from "../../../src/Treasury.sol";
import { ILinkContest } from "../../../src/interfaces/ILinkContest.sol";
import { LinkContest } from "../../../src/plugins/link-contest/LinkContest.sol";
import { FeeOnTransferERC20 } from "../../mocks/FeeOnTransferERC20.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockFactory } from "../../mocks/MockFactory.sol";
import { MockTempl } from "../../mocks/MockTempl.sol";
import { Test } from "forge-std/Test.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @dev Tests LinkContest. The contest pulls a submission fee, splits it 90/10
///      between the templ Treasury and the protocol recipient (reading the rate
///      and recipient from the Factory), records submissions per round, and
///      lets the owner rank a closed round. See the issue #447 spec.
contract LinkContestTest is Test {
  LinkContest public contest;
  MockFactory public factory;
  Treasury public treasury;
  MockTempl public templ;
  MockERC20 public token;

  address public owner = makeAddr("owner");
  address public protocolRecipient = makeAddr("protocol");
  address public alice = makeAddr("alice");
  address public bob = makeAddr("bob");

  uint256 public constant FEE = 1000e18;
  uint256 public constant ROUND_DURATION = 7 days;
  uint256 public constant PROTOCOL_BPS = 1000;

  // Fixed start far enough in the future to exercise the pre-start guard, yet
  // warpable backwards from in tests that need an already-open round.
  uint256 public start;

  function setUp() public {
    token = new MockERC20();
    factory = new MockFactory(protocolRecipient);
    treasury = factory.deployTreasury(address(token));
    templ = new MockTempl(address(treasury));

    // Anchor round 0 to the current time so existing flows behave as before.
    start = block.timestamp;
    contest = new LinkContest(
      address(templ), address(token), FEE, ROUND_DURATION, start, owner
    );

    token.mint(alice, 1_000_000e18);
    token.mint(bob, 1_000_000e18);
  }

  // Submits the same string as both raw and normalized. Tests that care about
  // the raw-vs-normalized distinction call `contest.submit(...)` directly.
  function _submit(
    address who,
    string memory link
  ) internal {
    vm.startPrank(who);
    token.approve(address(contest), FEE);
    contest.submit(link, link);
    vm.stopPrank();
  }

  // ============ Constructor ============

  function test_constructor_derivesAddressesAndConfig() public view {
    assertEq(contest.TEMPL(), address(templ));
    assertEq(contest.token(), address(token));
    assertEq(contest.TREASURY(), address(treasury));
    assertEq(contest.FACTORY(), address(factory));
    assertEq(contest.submissionFee(), FEE);
    assertEq(contest.ROUND_DURATION(), ROUND_DURATION);
    assertEq(contest.firstRoundStart(), start);
    assertEq(contest.paused(), false);
    assertEq(contest.owner(), owner);
  }

  function test_constructor_revertsOnZeroTempl() public {
    vm.expectRevert(ILinkContest.ZeroAddress.selector);
    new LinkContest(
      address(0), address(token), FEE, ROUND_DURATION, start, owner
    );
  }

  function test_constructor_revertsOnZeroToken() public {
    vm.expectRevert(ILinkContest.ZeroAddress.selector);
    new LinkContest(
      address(templ), address(0), FEE, ROUND_DURATION, start, owner
    );
  }

  function test_constructor_revertsOnZeroDuration() public {
    vm.expectRevert(ILinkContest.ZeroDuration.selector);
    new LinkContest(address(templ), address(token), FEE, 0, start, owner);
  }

  // ============ Split math ============

  function test_submit_splits90TreasuryAnd10Protocol() public {
    _submit(alice, "https://x.com/a");

    uint256 protocolAmt = (FEE * PROTOCOL_BPS) / 10_000;
    assertEq(token.balanceOf(protocolRecipient), protocolAmt);
    assertEq(token.balanceOf(address(treasury)), FEE - protocolAmt);
    assertEq(token.balanceOf(address(contest)), 0);
  }

  function test_submit_dustGoesToTreasury() public {
    // A fee that does not divide evenly by the protocol BPS leaves dust that
    // must land in the treasury slice (remainder = fee - protocolAmt).
    uint256 oddFee = 1001;
    LinkContest oddContest = new LinkContest(
      address(templ), address(token), oddFee, ROUND_DURATION, start, owner
    );

    vm.startPrank(alice);
    token.approve(address(oddContest), oddFee);
    oddContest.submit("https://x.com/dust", "https://x.com/dust");
    vm.stopPrank();

    uint256 protocolAmt = (oddFee * PROTOCOL_BPS) / 10_000; // 100
    assertEq(token.balanceOf(protocolRecipient), protocolAmt);
    assertEq(token.balanceOf(address(treasury)), oddFee - protocolAmt); // 901
  }

  function test_submit_recordsSubmitterAndIncrementsId() public {
    _submit(alice, "https://x.com/a");
    _submit(bob, "https://x.com/b");

    uint256 round = contest.currentRound();
    assertEq(contest.submissionCount(round), 2);
    assertEq(contest.submitterOf(round, 1), alice);
    assertEq(contest.submitterOf(round, 2), bob);
  }

  function test_submit_emitsSubmitted() public {
    uint256 round = contest.currentRound();
    string memory rawLink = "https://X.com/a/";
    string memory normalizedLink = "https://x.com/a";
    uint256 protocolAmt = (FEE * PROTOCOL_BPS) / 10_000;
    vm.startPrank(alice);
    token.approve(address(contest), FEE);
    vm.expectEmit(true, true, true, true);
    emit ILinkContest.Submitted(
      round,
      1,
      alice,
      rawLink,
      normalizedLink,
      keccak256(bytes(normalizedLink)),
      FEE,
      FEE - protocolAmt
    );
    contest.submit(rawLink, normalizedLink);
    vm.stopPrank();
  }

  // ============ Fee-on-transfer rejection ============

  function test_submit_revertsOnFeeOnTransferToken() public {
    FeeOnTransferERC20 fotToken = new FeeOnTransferERC20(500); // 5% tax
    fotToken.mint(alice, 1_000_000e18);

    LinkContest fotContest = new LinkContest(
      address(templ), address(fotToken), FEE, ROUND_DURATION, start, owner
    );

    vm.startPrank(alice);
    fotToken.approve(address(fotContest), FEE);
    vm.expectRevert(ILinkContest.FeeTokenMismatch.selector);
    fotContest.submit("https://x.com/fot", "https://x.com/fot");
    vm.stopPrank();
  }

  // ============ Round boundary math ============

  function test_currentRound_advancesAtBoundary() public {
    assertEq(contest.currentRound(), 0);

    vm.warp(block.timestamp + ROUND_DURATION - 1);
    assertEq(contest.currentRound(), 0);

    vm.warp(block.timestamp + 1);
    assertEq(contest.currentRound(), 1);
  }

  function test_roundEndsAt_matchesDuration() public view {
    assertEq(contest.roundEndsAt(0), contest.firstRoundStart() + ROUND_DURATION);
    assertEq(
      contest.roundEndsAt(2), contest.firstRoundStart() + 3 * ROUND_DURATION
    );
  }

  function test_submit_landsInOpenRound() public {
    _submit(alice, "https://x.com/r0");
    vm.warp(block.timestamp + ROUND_DURATION);
    _submit(bob, "https://x.com/r1");

    assertEq(contest.submitterOf(0, 1), alice);
    assertEq(contest.submitterOf(1, 1), bob);
    assertEq(contest.submissionCount(0), 1);
    assertEq(contest.submissionCount(1), 1);
  }

  // ============ Duplicate links ============

  function test_submit_revertsOnDuplicateNormalizedLink() public {
    // First entry normalizes to "https://x.com/a".
    vm.startPrank(alice);
    token.approve(address(contest), FEE);
    contest.submit("https://X.com/a/", "https://x.com/a");
    vm.stopPrank();

    // A different raw link that normalizes to the same string is a duplicate:
    // dedup keys on the normalized form, not the raw input.
    vm.startPrank(bob);
    token.approve(address(contest), FEE);
    vm.expectRevert(ILinkContest.DuplicateLink.selector);
    contest.submit("https://www.x.com/a#top", "https://x.com/a");
    vm.stopPrank();
  }

  function test_submit_duplicateDoesNotPullFee() public {
    _submit(alice, "https://x.com/a");

    uint256 balanceBefore = token.balanceOf(bob);

    vm.startPrank(bob);
    token.approve(address(contest), FEE);
    vm.expectRevert(ILinkContest.DuplicateLink.selector);
    contest.submit("https://x.com/a", "https://x.com/a");
    vm.stopPrank();

    // The revert precedes the transfer, so the submitter keeps the fee and the
    // contest never holds tokens.
    assertEq(token.balanceOf(bob), balanceBefore);
    assertEq(token.balanceOf(address(contest)), 0);
  }

  function test_submit_allowsDistinctLinks() public {
    _submit(alice, "https://x.com/a");
    _submit(bob, "https://x.com/b");

    assertEq(contest.submissionCount(0), 2);
  }

  function test_submit_dedupIsGlobalAcrossRounds() public {
    _submit(alice, "https://x.com/a");

    vm.warp(block.timestamp + ROUND_DURATION);
    assertEq(contest.currentRound(), 1);

    vm.startPrank(bob);
    token.approve(address(contest), FEE);
    vm.expectRevert(ILinkContest.DuplicateLink.selector);
    contest.submit("https://x.com/a", "https://x.com/a");
    vm.stopPrank();
  }

  function test_isSubmitted_falseBeforeTrueAfter() public {
    assertEq(contest.isSubmitted("https://x.com/a"), false);

    _submit(alice, "https://x.com/a");

    assertEq(contest.isSubmitted("https://x.com/a"), true);
    assertEq(contest.isSubmitted("https://x.com/b"), false);
  }

  // ============ setWinners ============

  function test_setWinners_ownerOnlyAfterClose() public {
    _submit(alice, "https://x.com/a");
    _submit(bob, "https://x.com/b");
    _submit(alice, "https://x.com/c");

    vm.warp(contest.roundEndsAt(0));

    vm.expectEmit(true, false, false, true);
    emit ILinkContest.WinnersSet(0, 1, 2, 3);
    vm.prank(owner);
    contest.setWinners(0, 1, 2, 3);
  }

  function test_setWinners_revertsForNonOwner() public {
    _submit(alice, "https://x.com/a");
    _submit(bob, "https://x.com/b");
    _submit(alice, "https://x.com/c");
    vm.warp(contest.roundEndsAt(0));

    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(alice);
    contest.setWinners(0, 1, 2, 3);
  }

  function test_setWinners_revertsBeforeClose() public {
    _submit(alice, "https://x.com/a");
    _submit(bob, "https://x.com/b");
    _submit(alice, "https://x.com/c");

    vm.expectRevert(ILinkContest.RoundNotClosed.selector);
    vm.prank(owner);
    contest.setWinners(0, 1, 2, 3);
  }

  function test_setWinners_revertsOnZeroFirst() public {
    _submit(alice, "https://x.com/a");
    vm.warp(contest.roundEndsAt(0));

    // 1st place is required; a zero first id is always invalid.
    vm.expectRevert(ILinkContest.InvalidSubmission.selector);
    vm.prank(owner);
    contest.setWinners(0, 0, 1, 0);
  }

  function test_setWinners_revertsOnOutOfRangeId() public {
    _submit(alice, "https://x.com/a");
    _submit(bob, "https://x.com/b");
    vm.warp(contest.roundEndsAt(0));

    vm.expectRevert(ILinkContest.InvalidSubmission.selector);
    vm.prank(owner);
    contest.setWinners(0, 1, 2, 3); // only 2 submissions exist
  }

  function test_setWinners_singleEntrantOnlyFirst() public {
    _submit(alice, "https://x.com/a");
    vm.warp(contest.roundEndsAt(0));

    // A round with one entrant is finalizable with just 1st place set.
    vm.expectEmit(true, false, false, true);
    emit ILinkContest.WinnersSet(0, 1, 0, 0);
    vm.prank(owner);
    contest.setWinners(0, 1, 0, 0);
  }

  function test_setWinners_twoEntrantsFirstAndSecond() public {
    _submit(alice, "https://x.com/a");
    _submit(bob, "https://x.com/b");
    vm.warp(contest.roundEndsAt(0));

    vm.expectEmit(true, false, false, true);
    emit ILinkContest.WinnersSet(0, 2, 1, 0);
    vm.prank(owner);
    contest.setWinners(0, 2, 1, 0);
  }

  function test_setWinners_revertsOnThirdWithoutSecond() public {
    _submit(alice, "https://x.com/a");
    _submit(bob, "https://x.com/b");
    _submit(alice, "https://x.com/c");
    vm.warp(contest.roundEndsAt(0));

    // 3rd set without a 2nd is a gap and must revert.
    vm.expectRevert(ILinkContest.InvalidSubmission.selector);
    vm.prank(owner);
    contest.setWinners(0, 1, 0, 3);
  }

  function test_setWinners_revertsOnDuplicateIds() public {
    _submit(alice, "https://x.com/a");
    _submit(bob, "https://x.com/b");
    vm.warp(contest.roundEndsAt(0));

    vm.expectRevert(ILinkContest.InvalidSubmission.selector);
    vm.prank(owner);
    contest.setWinners(0, 1, 1, 0); // second duplicates first
  }

  function test_setWinners_revertsOnSecondOutOfRange() public {
    _submit(alice, "https://x.com/a");
    vm.warp(contest.roundEndsAt(0));

    vm.expectRevert(ILinkContest.InvalidSubmission.selector);
    vm.prank(owner);
    contest.setWinners(0, 1, 2, 0); // only 1 submission exists
  }

  // ============ firstRoundStart anchoring ============

  function test_constructor_anchorsStartTime() public {
    uint256 future = block.timestamp + 30 days;
    LinkContest anchored = new LinkContest(
      address(templ), address(token), FEE, ROUND_DURATION, future, owner
    );

    assertEq(anchored.firstRoundStart(), future);
  }

  function test_currentRound_returnsZeroBeforeStart() public {
    uint256 future = block.timestamp + 30 days;
    LinkContest anchored = new LinkContest(
      address(templ), address(token), FEE, ROUND_DURATION, future, owner
    );

    // Read the anchor back from the contest so the warp targets do not depend
    // on reusing a local across cheatcode calls.
    uint256 anchor = anchored.firstRoundStart();

    // Before firstRoundStart the round clamps to 0 instead of underflowing.
    assertEq(anchored.currentRound(), 0);

    vm.warp(anchor);
    assertEq(anchored.currentRound(), 0);

    vm.warp(anchor + ROUND_DURATION - 1);
    assertEq(anchored.currentRound(), 0);

    vm.warp(anchor + ROUND_DURATION);
    assertEq(anchored.currentRound(), 1);

    vm.warp(anchor + 3 * ROUND_DURATION);
    assertEq(anchored.currentRound(), 3);
  }

  function test_submit_revertsBeforeStart() public {
    uint256 future = block.timestamp + 30 days;
    LinkContest anchored = new LinkContest(
      address(templ), address(token), FEE, ROUND_DURATION, future, owner
    );

    vm.startPrank(alice);
    token.approve(address(anchored), FEE);
    vm.expectRevert(ILinkContest.ContestNotStarted.selector);
    anchored.submit("https://x.com/early", "https://x.com/early");
    vm.stopPrank();
  }

  function test_submit_succeedsAtStart() public {
    uint256 future = block.timestamp + 30 days;
    LinkContest anchored = new LinkContest(
      address(templ), address(token), FEE, ROUND_DURATION, future, owner
    );

    vm.warp(future);
    vm.startPrank(alice);
    token.approve(address(anchored), FEE);
    anchored.submit("https://x.com/onstart", "https://x.com/onstart");
    vm.stopPrank();

    assertEq(anchored.submitterOf(0, 1), alice);
  }

  // ============ Protocol recipient propagation ============

  function test_submit_picksUpProtocolRecipientChange() public {
    address newRecipient = makeAddr("newProtocol");
    _submit(alice, "https://x.com/before");

    uint256 protocolAmt = (FEE * PROTOCOL_BPS) / 10_000;
    assertEq(token.balanceOf(protocolRecipient), protocolAmt);

    factory.setProtocolFeeRecipient(newRecipient);
    _submit(bob, "https://x.com/after");

    // The first recipient is unchanged; the next submission routes to the new
    // recipient, proving the contest reads the Factory at submission time.
    assertEq(token.balanceOf(protocolRecipient), protocolAmt);
    assertEq(token.balanceOf(newRecipient), protocolAmt);
  }

  // ============ setToken ============

  function test_setToken_updatesAndEmits() public {
    MockERC20 newToken = new MockERC20();

    vm.expectEmit(false, false, false, true);
    emit ILinkContest.TokenUpdated(address(newToken));
    vm.prank(owner);
    contest.setToken(address(newToken));

    assertEq(contest.token(), address(newToken));
  }

  function test_setToken_chargesNewTokenOnSubmit() public {
    MockERC20 newToken = new MockERC20();
    newToken.mint(alice, 1_000_000e18);

    vm.prank(owner);
    contest.setToken(address(newToken));

    vm.startPrank(alice);
    newToken.approve(address(contest), FEE);
    contest.submit("https://x.com/newtoken", "https://x.com/newtoken");
    vm.stopPrank();

    uint256 protocolAmt = (FEE * PROTOCOL_BPS) / 10_000;
    assertEq(newToken.balanceOf(protocolRecipient), protocolAmt);
    assertEq(newToken.balanceOf(address(treasury)), FEE - protocolAmt);
  }

  function test_setToken_revertsOnZeroAddress() public {
    vm.expectRevert(ILinkContest.ZeroAddress.selector);
    vm.prank(owner);
    contest.setToken(address(0));
  }

  function test_setToken_revertsForNonOwner() public {
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(alice);
    contest.setToken(address(token));
  }

  // ============ setSubmissionFee ============

  function test_setSubmissionFee_updatesAndEmits() public {
    uint256 newFee = 42e18;

    vm.expectEmit(false, false, false, true);
    emit ILinkContest.SubmissionFeeUpdated(newFee);
    vm.prank(owner);
    contest.setSubmissionFee(newFee);

    assertEq(contest.submissionFee(), newFee);
  }

  function test_setSubmissionFee_chargesNewFeeOnSubmit() public {
    uint256 newFee = 42e18;
    vm.prank(owner);
    contest.setSubmissionFee(newFee);

    vm.startPrank(alice);
    token.approve(address(contest), newFee);
    contest.submit("https://x.com/newfee", "https://x.com/newfee");
    vm.stopPrank();

    uint256 protocolAmt = (newFee * PROTOCOL_BPS) / 10_000;
    assertEq(token.balanceOf(protocolRecipient), protocolAmt);
    assertEq(token.balanceOf(address(treasury)), newFee - protocolAmt);
  }

  function test_setSubmissionFee_revertsForNonOwner() public {
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(alice);
    contest.setSubmissionFee(1);
  }

  // ============ setFirstRoundStart ============

  function test_setFirstRoundStart_updatesAndEmits() public {
    uint256 future = block.timestamp + 60 days;
    LinkContest pending = new LinkContest(
      address(templ),
      address(token),
      FEE,
      ROUND_DURATION,
      block.timestamp + 30 days,
      owner
    );

    vm.expectEmit(false, false, false, true);
    emit ILinkContest.FirstRoundStartUpdated(future);
    vm.prank(owner);
    pending.setFirstRoundStart(future);

    assertEq(pending.firstRoundStart(), future);
  }

  function test_setFirstRoundStart_revertsAfterStart() public {
    // The default contest anchors round 0 to deployment time, so it has
    // already started and the start is locked.
    vm.expectRevert(ILinkContest.ContestAlreadyStarted.selector);
    vm.prank(owner);
    contest.setFirstRoundStart(block.timestamp + 30 days);
  }

  function test_setFirstRoundStart_revertsOnNonFutureStart() public {
    LinkContest pending = new LinkContest(
      address(templ),
      address(token),
      FEE,
      ROUND_DURATION,
      block.timestamp + 30 days,
      owner
    );

    vm.expectRevert(ILinkContest.InvalidStart.selector);
    vm.prank(owner);
    pending.setFirstRoundStart(block.timestamp);
  }

  function test_setFirstRoundStart_revertsForNonOwner() public {
    LinkContest pending = new LinkContest(
      address(templ),
      address(token),
      FEE,
      ROUND_DURATION,
      block.timestamp + 30 days,
      owner
    );

    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(alice);
    pending.setFirstRoundStart(block.timestamp + 60 days);
  }

  // ============ setPaused ============

  function test_setPaused_updatesAndEmits() public {
    vm.expectEmit(false, false, false, true);
    emit ILinkContest.PausedUpdated(true);
    vm.prank(owner);
    contest.setPaused(true);

    assertEq(contest.paused(), true);
  }

  function test_submit_revertsWhenPaused() public {
    vm.prank(owner);
    contest.setPaused(true);

    vm.startPrank(alice);
    token.approve(address(contest), FEE);
    vm.expectRevert(ILinkContest.ContestPaused.selector);
    contest.submit("https://x.com/paused", "https://x.com/paused");
    vm.stopPrank();
  }

  function test_submit_succeedsAfterUnpause() public {
    vm.prank(owner);
    contest.setPaused(true);
    vm.prank(owner);
    contest.setPaused(false);

    _submit(alice, "https://x.com/unpaused");
    assertEq(contest.submitterOf(0, 1), alice);
  }

  function test_setPaused_revertsForNonOwner() public {
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(alice);
    contest.setPaused(true);
  }

  // ============ setFeeExempt ============

  function test_setFeeExempt_setsFlagAndEmits() public {
    address[] memory accounts = new address[](1);
    accounts[0] = alice;

    assertEq(contest.feeExempt(alice), false);

    vm.expectEmit(true, false, false, true);
    emit ILinkContest.FeeExemptUpdated(alice, true);
    vm.prank(owner);
    contest.setFeeExempt(accounts, true);

    assertEq(contest.feeExempt(alice), true);
  }

  function test_setFeeExempt_revertsForNonOwner() public {
    address[] memory accounts = new address[](1);
    accounts[0] = alice;

    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(alice);
    contest.setFeeExempt(accounts, true);
  }

  function test_submit_exemptSubmitterPaysNothing() public {
    address[] memory accounts = new address[](1);
    accounts[0] = alice;
    vm.prank(owner);
    contest.setFeeExempt(accounts, true);

    uint256 aliceBefore = token.balanceOf(alice);

    // An exempt submitter does not need an approval and is never charged.
    vm.prank(alice);
    contest.submit("https://x.com/free", "https://x.com/free");

    assertEq(token.balanceOf(alice), aliceBefore);
    assertEq(token.balanceOf(address(treasury)), 0);
    assertEq(token.balanceOf(protocolRecipient), 0);
    assertEq(token.balanceOf(address(contest)), 0);

    // The submission is still recorded and counts toward the round.
    assertEq(contest.submissionCount(0), 1);
    assertEq(contest.submitterOf(0, 1), alice);
  }

  function test_submit_exemptStillDedups() public {
    address[] memory accounts = new address[](1);
    accounts[0] = alice;
    vm.prank(owner);
    contest.setFeeExempt(accounts, true);

    vm.prank(alice);
    contest.submit("https://x.com/free", "https://x.com/free");

    // Dedup runs before the fee branch, so an exempt wallet cannot reuse a link.
    vm.expectRevert(ILinkContest.DuplicateLink.selector);
    vm.prank(alice);
    contest.submit("https://x.com/free", "https://x.com/free");
  }

  function test_submit_exemptEmitsZeroFee() public {
    address[] memory accounts = new address[](1);
    accounts[0] = alice;
    vm.prank(owner);
    contest.setFeeExempt(accounts, true);

    string memory link = "https://x.com/free";
    vm.expectEmit(true, true, true, true);
    emit ILinkContest.Submitted(
      0, 1, alice, link, link, keccak256(bytes(link)), 0, 0
    );
    vm.prank(alice);
    contest.submit(link, link);
  }

  function test_submit_nonExemptEmitsFeeAccounting() public {
    string memory link = "https://x.com/paid";
    uint256 protocolAmt = (FEE * PROTOCOL_BPS) / 10_000;

    vm.startPrank(alice);
    token.approve(address(contest), FEE);
    vm.expectEmit(true, true, true, true);
    emit ILinkContest.Submitted(
      0, 1, alice, link, link, keccak256(bytes(link)), FEE, FEE - protocolAmt
    );
    contest.submit(link, link);
    vm.stopPrank();
  }

  function test_setFeeExempt_removalChargesAgain() public {
    address[] memory accounts = new address[](1);
    accounts[0] = alice;

    vm.prank(owner);
    contest.setFeeExempt(accounts, true);

    vm.prank(alice);
    contest.submit("https://x.com/one", "https://x.com/one");

    // Removing the exemption makes the same address pay on the next submit.
    vm.prank(owner);
    contest.setFeeExempt(accounts, false);
    assertEq(contest.feeExempt(alice), false);

    vm.startPrank(alice);
    token.approve(address(contest), FEE);
    contest.submit("https://x.com/two", "https://x.com/two");
    vm.stopPrank();

    uint256 protocolAmt = (FEE * PROTOCOL_BPS) / 10_000;
    assertEq(token.balanceOf(protocolRecipient), protocolAmt);
    assertEq(token.balanceOf(address(treasury)), FEE - protocolAmt);
  }
}
