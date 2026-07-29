// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MemberPool } from "../src/MemberPool.sol";
import { Templ } from "../src/Templ.sol";
import { Treasury } from "../src/Treasury.sol";
import { IExecutable } from "../src/interfaces/IExecutable.sol";
import { ITempl } from "../src/interfaces/ITempl.sol";
import {
  CurveConfig,
  CurveSegment,
  CurveStyle,
  EntryFeeCurve
} from "../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC20Permit } from "./mocks/MockERC20Permit.sol";
import { MockFactory } from "./mocks/MockFactory.sol";
import { ReentrantGovernance } from "./mocks/ReentrantGovernance.sol";
import {
  TreasuryDrainingGovernance
} from "./mocks/TreasuryDrainingGovernance.sol";
import { ERC2612Helper } from "./utils/ERC2612Helper.sol";
import { Permit2Helper } from "./utils/Permit2Helper.sol";
import { Test } from "forge-std/Test.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";

interface IERC20 {
  function transfer(
    address to,
    uint256 amount
  ) external returns (bool);
}

contract TemplTest is Test, Permit2Helper, ERC2612Helper {
  Templ public templ;
  Treasury public treasury;
  MemberPool public pool;
  MockERC20 public token;
  MockERC20Permit public permitToken;

  address public priest = makeAddr("priest");
  address public protocolRecipient = makeAddr("protocol");
  address public user1 = makeAddr("user1");
  address public user2 = makeAddr("user2");

  uint256 public constant ENTRY_FEE = 1000e18;
  uint256 public constant PROTOCOL_FEE_BPS = 1000;

  uint32 constant DEFAULT_RATE_BPS = 10_094;
  uint32 constant DEFAULT_LENGTH = 248;

  function _defaultCurve() internal pure returns (CurveConfig memory) {
    return EntryFeeCurve.exponentialWithTail(DEFAULT_RATE_BPS, DEFAULT_LENGTH);
  }

  function _staticCurve() internal pure returns (CurveConfig memory config) {
    config.primary =
      CurveSegment({ style: CurveStyle.Static, rateBps: 0, length: 0 });
  }

  function _deployPair(
    CurveConfig memory curve,
    uint256 entryFee
  ) internal returns (Templ t, Treasury tr) {
    MockFactory mf = new MockFactory(protocolRecipient);
    MemberPool p;
    (tr, p) = mf.deployTreasuryAndPool(address(token));
    t = new Templ(
      priest,
      address(token),
      entryFee,
      curve,
      address(tr),
      address(p),
      priest,
      PROTOCOL_FEE_BPS,
      address(0)
    );
    vm.prank(address(mf));
    tr.setTempl(address(t));
    vm.prank(address(mf));
    tr.setMemberPool(address(p));
    vm.prank(address(mf));
    p.setTempl(address(t));
    vm.prank(address(mf));
    p.setTreasury(address(tr));
    // Bootstrap split config (priest doubles as governance in this fixture).
    vm.prank(priest);
    t.setFeeSplit(3000, 3000, 3000);
    vm.prank(priest);
    t.setReferralShareBps(2500);
  }

  function _deployTrio(
    CurveConfig memory curve,
    uint256 entryFee
  ) internal returns (Templ t, Treasury tr, MemberPool p) {
    MockFactory mf = new MockFactory(protocolRecipient);
    (tr, p) = mf.deployTreasuryAndPool(address(token));
    t = new Templ(
      priest,
      address(token),
      entryFee,
      curve,
      address(tr),
      address(p),
      priest,
      PROTOCOL_FEE_BPS,
      address(0)
    );
    vm.prank(address(mf));
    tr.setTempl(address(t));
    vm.prank(address(mf));
    tr.setMemberPool(address(p));
    vm.prank(address(mf));
    p.setTempl(address(t));
    vm.prank(address(mf));
    p.setTreasury(address(tr));
    // Bootstrap split config.
    vm.prank(priest);
    t.setFeeSplit(3000, 3000, 3000);
    vm.prank(priest);
    t.setReferralShareBps(2500);
  }

  function _deployPermitPair(
    CurveConfig memory curve,
    uint256 entryFee
  ) internal returns (Templ t, Treasury tr) {
    MockFactory mf = new MockFactory(protocolRecipient);
    MemberPool p;
    (tr, p) = mf.deployTreasuryAndPool(address(permitToken));
    t = new Templ(
      priest,
      address(permitToken),
      entryFee,
      curve,
      address(tr),
      address(p),
      priest,
      PROTOCOL_FEE_BPS,
      address(0)
    );
    vm.prank(address(mf));
    tr.setTempl(address(t));
    vm.prank(address(mf));
    tr.setMemberPool(address(p));
    vm.prank(address(mf));
    p.setTempl(address(t));
    vm.prank(address(mf));
    p.setTreasury(address(tr));
    // Bootstrap split config.
    vm.prank(priest);
    t.setFeeSplit(3000, 3000, 3000);
    vm.prank(priest);
    t.setReferralShareBps(2500);
  }

  function setUp() public {
    _deployPermit2();
    token = new MockERC20();
    permitToken = new MockERC20Permit();
    (templ, treasury, pool) = _deployTrio(_defaultCurve(), ENTRY_FEE);

    token.mint(user1, 100_000e18);
    token.mint(user2, 100_000e18);
  }

  // ============ Constructor ============

  function test_constructor_setsImmutables() public view {
    assertEq(templ.priest(), priest);
    assertEq(templ.TOKEN(), address(token));
    assertEq(templ.entryFee(), ENTRY_FEE);
    assertEq(templ.baseEntryFee(), ENTRY_FEE);
    assertEq(templ.paidJoins(), 0);
    assertEq(templ.governance(), priest);
    assertEq(address(templ.TREASURY()), address(treasury));
  }

  function test_constructor_priestIsMember() public view {
    assertTrue(templ.isMember(priest));
    assertEq(templ.memberCount(), 1);

    (uint64 priestId,) = templ.members(priest);
    assertEq(priestId, 1);
  }

  // ============ Join ============

  function test_join_success() public {
    uint256 protocolBefore = token.balanceOf(protocolRecipient);

    vm.startPrank(user1);
    token.approve(address(templ), ENTRY_FEE);

    vm.expectEmit(true, true, false, true);
    emit ITempl.MemberJoined(user1, user1, ENTRY_FEE, block.timestamp);
    templ.join(user1, address(0));
    vm.stopPrank();

    // Membership checks
    assertTrue(templ.isMember(user1));
    assertEq(templ.memberCount(), 2);
    assertEq(templ.paidJoins(), 1);
    (uint64 id,) = templ.members(user1);
    assertEq(id, 2);

    // Fee distribution checks
    uint256 expectedProtocol = (ENTRY_FEE * PROTOCOL_FEE_BPS) / 10_000;
    assertEq(
      token.balanceOf(protocolRecipient) - protocolBefore, expectedProtocol
    );
    assertGt(token.balanceOf(address(treasury)), 0);
  }

  function test_join_forSomeoneElse() public {
    vm.startPrank(user1);
    token.approve(address(templ), ENTRY_FEE);
    templ.join(user2, address(0));
    vm.stopPrank();

    assertTrue(templ.isMember(user2));
    assertFalse(templ.isMember(user1));
  }

  function test_join_revertsOnInvalidInput() public {
    vm.startPrank(user1);
    token.approve(address(templ), ENTRY_FEE * 2);

    // Recipient required
    vm.expectRevert(ITempl.RecipientIsRequired.selector);
    templ.join(address(0), address(0));

    // First join succeeds
    templ.join(user1, address(0));

    // Already member
    vm.expectRevert(ITempl.AlreadyMember.selector);
    templ.join(user1, address(0));
    vm.stopPrank();
  }

  // ============ Entry Fee Curve Integration ============

  function test_join_entryFeeIncreasesAfterJoin() public {
    uint256 feeBefore = templ.entryFee();

    vm.startPrank(user1);
    token.approve(address(templ), ENTRY_FEE);
    templ.join(user1, address(0));
    vm.stopPrank();

    uint256 feeAfter = templ.entryFee();
    assertGt(feeAfter, feeBefore, "fee should increase after join");

    uint256 expected = EntryFeeCurve.normalize(
      EntryFeeCurve.priceAtJoin(ENTRY_FEE, _defaultCurve(), 1)
    );
    assertEq(feeAfter, expected, "fee should match curve");
  }

  function test_join_multipleJoins_feeProgression() public {
    CurveConfig memory curve = _defaultCurve();
    address[5] memory joiners;
    for (uint256 i; i < 5; ++i) {
      joiners[i] = makeAddr(string(abi.encodePacked("joiner", i)));
      token.mint(joiners[i], 10_000e18);
    }

    uint256 prevFee = templ.entryFee();
    for (uint256 i; i < 5; ++i) {
      uint256 fee = templ.entryFee();

      vm.startPrank(joiners[i]);
      token.approve(address(templ), fee);
      templ.join(joiners[i], address(0));
      vm.stopPrank();

      uint256 nextFee = templ.entryFee();
      assertGt(nextFee, prevFee, "fee must increase each join");

      uint256 expected = EntryFeeCurve.normalize(
        EntryFeeCurve.priceAtJoin(ENTRY_FEE, curve, i + 1)
      );
      assertEq(nextFee, expected, "fee must match curve at each step");
      prevFee = nextFee;
    }

    assertEq(templ.paidJoins(), 5);
  }

  function test_entryFee_updatesAndEmits() public {
    // Test join emits EntryFeeUpdated
    uint256 expectedNewFee = EntryFeeCurve.normalize(
      EntryFeeCurve.priceAtJoin(ENTRY_FEE, _defaultCurve(), 1)
    );

    vm.startPrank(user1);
    token.approve(address(templ), ENTRY_FEE);
    vm.expectEmit(true, false, false, true);
    emit ITempl.EntryFeeUpdated(address(templ), expectedNewFee);
    templ.join(user1, address(0));
    vm.stopPrank();

    // Test setBaseEntryFee recalculates and emits BaseEntryFeeUpdated then EntryFeeUpdated
    uint256 newBase = 2000e18;
    uint256 expectedFeeAfterBaseChange = EntryFeeCurve.normalize(
      EntryFeeCurve.priceAtJoin(newBase, _defaultCurve(), templ.paidJoins())
    );

    vm.prank(priest);
    vm.expectEmit(true, false, false, true);
    emit ITempl.BaseEntryFeeUpdated(address(templ), newBase);
    vm.expectEmit(true, false, false, true);
    emit ITempl.EntryFeeUpdated(address(templ), expectedFeeAfterBaseChange);
    templ.setBaseEntryFee(newBase);

    assertEq(templ.baseEntryFee(), newBase);
    assertEq(templ.entryFee(), expectedFeeAfterBaseChange);
  }

  function test_join_staticCurve_feeNeverChanges() public {
    (Templ staticTempl,) = _deployPair(_staticCurve(), ENTRY_FEE);

    vm.startPrank(user1);
    token.approve(address(staticTempl), ENTRY_FEE);
    staticTempl.join(user1, address(0));
    vm.stopPrank();

    assertEq(staticTempl.entryFee(), ENTRY_FEE, "static curve: fee stays flat");

    vm.startPrank(user2);
    token.approve(address(staticTempl), ENTRY_FEE);
    staticTempl.join(user2, address(0));
    vm.stopPrank();

    assertEq(staticTempl.entryFee(), ENTRY_FEE, "static curve: still flat");
  }

  // ============ Priest Functions ============

  function test_execute_treasuryTransferToken() public {
    vm.startPrank(user1);
    token.approve(address(templ), ENTRY_FEE);
    templ.join(user1, address(0));
    vm.stopPrank();

    uint256 treasuryBal = token.balanceOf(address(treasury));
    address recipient = makeAddr("recipient");

    vm.prank(priest);
    treasury.execute(
      address(token),
      0,
      abi.encodeCall(IERC20.transfer, (recipient, treasuryBal))
    );

    assertEq(token.balanceOf(recipient), treasuryBal);
  }

  function test_execute_revertsIfNotGovernance() public {
    vm.expectRevert(IExecutable.NotGovernance.selector);
    vm.prank(user1);
    treasury.execute(
      address(token), 0, abi.encodeCall(IERC20.transfer, (user1, 100))
    );
  }

  function test_transferPriest_success() public {
    vm.startPrank(user1);
    token.approve(address(templ), ENTRY_FEE);
    templ.join(user1, address(0));
    vm.stopPrank();

    vm.prank(priest);
    templ.transferPriest(user1);

    assertEq(templ.priest(), user1);
  }

  function test_transferPriest_revertsIfNotMember() public {
    vm.prank(priest);
    vm.expectRevert(ITempl.NotMember.selector);
    templ.transferPriest(user1);
  }

  // ============ Fuzz ============

  function testFuzz_join_anyValidEntryFee(
    uint256 _entryFee
  ) public {
    _entryFee = bound(_entryFee, 100, 1_000_000e18);

    (Templ fuzzTempl,) = _deployPair(_defaultCurve(), _entryFee);

    token.mint(user1, _entryFee);

    vm.startPrank(user1);
    token.approve(address(fuzzTempl), _entryFee);
    fuzzTempl.join(user1, address(0));
    vm.stopPrank();

    assertTrue(fuzzTempl.isMember(user1));
    assertEq(fuzzTempl.paidJoins(), 1);
  }

  function testFuzz_join_feeNeverDecreases(
    uint8 numJoins
  ) public {
    numJoins = uint8(bound(numJoins, 2, 20));

    (Templ fuzzTempl,) = _deployPair(_defaultCurve(), ENTRY_FEE);

    uint256 prevFee = fuzzTempl.entryFee();

    for (uint8 i; i < numJoins; ++i) {
      address joiner = makeAddr(string(abi.encodePacked("fuzzJoiner", i)));
      uint256 fee = fuzzTempl.entryFee();
      token.mint(joiner, fee);

      vm.startPrank(joiner);
      token.approve(address(fuzzTempl), fee);
      fuzzTempl.join(joiner, address(0));
      vm.stopPrank();

      uint256 newFee = fuzzTempl.entryFee();
      assertGe(newFee, prevFee, "fee must never decrease");
      prevFee = newFee;
    }
  }

  // ============ Join Pause ============

  function test_setJoinPaused_blocksJoins() public {
    vm.prank(priest);
    templ.setJoinPaused(true);

    address who = makeAddr("paused");
    token.mint(who, 100_000e18);
    vm.startPrank(who);
    token.approve(address(templ), type(uint256).max);

    vm.expectRevert(ITempl.JoinsPaused.selector);
    templ.join(who, address(0));
    vm.stopPrank();

    // Unpause
    vm.prank(priest);
    templ.setJoinPaused(false);

    // Now join works
    vm.prank(who);
    templ.join(who, address(0));
    assertTrue(templ.isMember(who));
  }

  // ============ Join With ERC-2612 Permit ============

  function test_joinWithERC2612Permit_success() public {
    uint256 signerPk = 0xA11CE;
    address signer = vm.addr(signerPk);

    (Templ pt,) = _deployPermitPair(_staticCurve(), ENTRY_FEE);
    permitToken.mint(signer, ENTRY_FEE);

    (uint8 v, bytes32 r, bytes32 s) = signERC2612Permit(
      address(permitToken),
      signer,
      address(pt),
      ENTRY_FEE,
      0,
      block.timestamp + 1 hours,
      signerPk
    );

    vm.prank(signer);
    pt.joinWithERC2612Permit(
      signer, address(0), block.timestamp + 1 hours, v, r, s
    );

    assertTrue(pt.isMember(signer));
    assertEq(pt.memberCount(), 2);
    // Allowance is fully consumed - no residual approval
    assertEq(permitToken.allowance(signer, address(pt)), 0);
  }

  function test_joinWithERC2612Permit_referralAndGifting() public {
    (Templ pt,) = _deployPermitPair(_staticCurve(), ENTRY_FEE);

    // Setup: user1 joins as referrer
    permitToken.mint(user1, ENTRY_FEE);
    vm.startPrank(user1);
    permitToken.approve(address(pt), ENTRY_FEE);
    pt.join(user1, address(0));
    vm.stopPrank();

    uint256 user1Before = permitToken.balanceOf(user1);

    // Test: signer pays for recipient, with user1 as referral
    uint256 signerPk = 0xBEEF;
    address signer = vm.addr(signerPk);
    address recipient = makeAddr("giftedMember");
    permitToken.mint(signer, ENTRY_FEE);

    (uint8 v, bytes32 r, bytes32 s) = signERC2612Permit(
      address(permitToken),
      signer,
      address(pt),
      ENTRY_FEE,
      0,
      block.timestamp + 1 hours,
      signerPk
    );

    vm.prank(signer);
    pt.joinWithERC2612Permit(
      recipient, user1, block.timestamp + 1 hours, v, r, s
    );

    // Recipient is member, signer is not, referrer got paid
    assertTrue(pt.isMember(recipient));
    assertFalse(pt.isMember(signer));
    assertGt(permitToken.balanceOf(user1), user1Before);
  }

  function test_joinWithERC2612Permit_revertsIfExpired() public {
    (Templ pt,) = _deployPermitPair(_staticCurve(), ENTRY_FEE);
    uint256 signerPk = 0xC0DE;
    address signer = vm.addr(signerPk);
    permitToken.mint(signer, ENTRY_FEE);

    (uint8 v, bytes32 r, bytes32 s) = signERC2612Permit(
      address(permitToken),
      signer,
      address(pt),
      ENTRY_FEE,
      0,
      block.timestamp - 1,
      signerPk
    );
    vm.prank(signer);
    vm.expectRevert();
    pt.joinWithERC2612Permit(signer, address(0), block.timestamp - 1, v, r, s);
  }

  function test_joinWithERC2612Permit_revertsIfAlreadyMember() public {
    (Templ pt,) = _deployPermitPair(_staticCurve(), ENTRY_FEE);
    uint256 signerPk = 0xA11CE;
    address signer = vm.addr(signerPk);
    permitToken.mint(signer, ENTRY_FEE * 2);

    // First join succeeds
    (uint8 v1, bytes32 r1, bytes32 s1) = signERC2612Permit(
      address(permitToken),
      signer,
      address(pt),
      ENTRY_FEE,
      0,
      block.timestamp + 1 hours,
      signerPk
    );
    vm.prank(signer);
    pt.joinWithERC2612Permit(
      signer, address(0), block.timestamp + 1 hours, v1, r1, s1
    );

    // Second join reverts
    (uint8 v2, bytes32 r2, bytes32 s2) = signERC2612Permit(
      address(permitToken),
      signer,
      address(pt),
      ENTRY_FEE,
      1,
      block.timestamp + 1 hours,
      signerPk
    );
    vm.prank(signer);
    vm.expectRevert(ITempl.AlreadyMember.selector);
    pt.joinWithERC2612Permit(
      signer, address(0), block.timestamp + 1 hours, v2, r2, s2
    );
  }

  // ============ Join With Permit2 (Uniswap) ============

  function test_joinWithPermit2_success() public {
    uint256 signerPk = 0xA11CE;
    address signer = vm.addr(signerPk);
    uint256 fee = templ.entryFee();

    token.mint(signer, fee);
    vm.prank(signer);
    token.approve(PERMIT2_ADDR, fee);

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signPermit(
      address(token),
      fee,
      0,
      block.timestamp + 1 hours,
      address(templ),
      signerPk
    );

    vm.prank(signer);
    templ.joinWithPermit2(signer, address(0), permit, sig);

    assertTrue(templ.isMember(signer));
    assertEq(templ.memberCount(), 2);
  }

  function test_joinWithPermit2_referralAndGifting() public {
    // Setup: user1 joins as referrer
    vm.startPrank(user1);
    token.approve(address(templ), ENTRY_FEE);
    templ.join(user1, address(0));
    vm.stopPrank();

    uint256 user1Before = token.balanceOf(user1);

    // Test: signer pays for recipient, with user1 as referral
    uint256 signerPk = 0xBEEF;
    address signer = vm.addr(signerPk);
    address recipient = makeAddr("giftedMember");
    uint256 fee = templ.entryFee();

    token.mint(signer, fee);
    vm.prank(signer);
    token.approve(PERMIT2_ADDR, fee);

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signPermit(
      address(token),
      fee,
      0,
      block.timestamp + 1 hours,
      address(templ),
      signerPk
    );

    vm.prank(signer);
    templ.joinWithPermit2(recipient, user1, permit, sig);

    // Recipient is member, signer is not, referrer got paid
    assertTrue(templ.isMember(recipient));
    assertFalse(templ.isMember(signer));
    assertGt(token.balanceOf(user1), user1Before);
  }

  function test_joinWithPermit2_revertsOnInvalidPermit() public {
    uint256 signerPk = 0xC0DE;
    address signer = vm.addr(signerPk);
    uint256 fee = templ.entryFee();

    token.mint(signer, fee);
    vm.prank(signer);
    token.approve(PERMIT2_ADDR, fee);

    // Expired permit
    (ISignatureTransfer.PermitTransferFrom memory permit1, bytes memory sig1) = _signPermit(
      address(token), fee, 0, block.timestamp - 1, address(templ), signerPk
    );
    vm.prank(signer);
    vm.expectRevert();
    templ.joinWithPermit2(signer, address(0), permit1, sig1);

    // Wrong amount
    (ISignatureTransfer.PermitTransferFrom memory permit2, bytes memory sig2) = _signPermit(
      address(token),
      fee / 2,
      0,
      block.timestamp + 1 hours,
      address(templ),
      signerPk
    );
    vm.prank(signer);
    vm.expectRevert();
    templ.joinWithPermit2(signer, address(0), permit2, sig2);
  }

  function test_joinWithPermit2_revertsOnWrongToken() public {
    uint256 signerPk = 0xC0DE;
    address signer = vm.addr(signerPk);
    uint256 fee = templ.entryFee();

    MockERC20 wrongToken = new MockERC20();
    wrongToken.mint(signer, fee);
    vm.prank(signer);
    wrongToken.approve(PERMIT2_ADDR, fee);

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signPermit(
      address(wrongToken),
      fee,
      0,
      block.timestamp + 1 hours,
      address(templ),
      signerPk
    );

    vm.prank(signer);
    vm.expectRevert(ITempl.WrongToken.selector);
    templ.joinWithPermit2(signer, address(0), permit, sig);

    assertFalse(templ.isMember(signer));
  }

  // ============ Join With Permit2 Witness ============

  function test_joinWithPermit2Witness_success() public {
    uint256 signerPk = 0xA11CE;
    address signer = vm.addr(signerPk);
    uint256 fee = templ.entryFee();

    token.mint(signer, fee);
    vm.prank(signer);
    token.approve(PERMIT2_ADDR, fee);

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signPermitWitness(
      WitnessPermitParams({
        token: address(token),
        amount: fee,
        nonce: 0,
        deadline: block.timestamp + 1 hours,
        spender: address(templ),
        recipient: signer,
        referral: address(0),
        relayerTip: 0,
        signerPrivateKey: signerPk
      })
    );

    ITempl.JoinIntent memory intent = ITempl.JoinIntent({
      recipient: signer, referral: address(0), relayerTip: 0
    });

    vm.prank(signer);
    templ.joinWithPermit2Witness(signer, permit, sig, intent);

    assertTrue(templ.isMember(signer));
    assertEq(templ.memberCount(), 2);
  }

  function test_joinWithPermit2Witness_referralGiftingAndRelayerTip() public {
    // Setup: user1 joins as referrer
    vm.startPrank(user1);
    token.approve(address(templ), ENTRY_FEE);
    templ.join(user1, address(0));
    vm.stopPrank();

    uint256 user1Before = token.balanceOf(user1);

    // Test: signer pays for recipient + relayer tip, with user1 as referral
    uint256 signerPk = 0xBEEF;
    address signer = vm.addr(signerPk);
    address recipient = makeAddr("giftedMember");
    address relayer = makeAddr("relayer");
    uint256 fee = templ.entryFee();
    uint256 tip = 50e18;
    uint256 totalAmount = fee + tip;

    token.mint(signer, totalAmount);
    vm.prank(signer);
    token.approve(PERMIT2_ADDR, totalAmount);

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signPermitWitness(
      WitnessPermitParams({
        token: address(token),
        amount: totalAmount,
        nonce: 0,
        deadline: block.timestamp + 1 hours,
        spender: address(templ),
        recipient: recipient,
        referral: user1,
        relayerTip: tip,
        signerPrivateKey: signerPk
      })
    );

    ITempl.JoinIntent memory intent = ITempl.JoinIntent({
      recipient: recipient, referral: user1, relayerTip: tip
    });

    vm.prank(relayer);
    templ.joinWithPermit2Witness(signer, permit, sig, intent);

    // Recipient is member, signer is not, referrer got paid, relayer got tip
    assertTrue(templ.isMember(recipient));
    assertFalse(templ.isMember(signer));
    assertGt(token.balanceOf(user1), user1Before);
    assertEq(token.balanceOf(relayer), tip);
  }

  function test_joinWithPermit2Witness_revertsIfExpired() public {
    uint256 signerPk = 0xC0DE;
    address signer = vm.addr(signerPk);
    uint256 fee = templ.entryFee();

    token.mint(signer, fee);
    vm.prank(signer);
    token.approve(PERMIT2_ADDR, fee);

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signPermitWitness(
      WitnessPermitParams({
        token: address(token),
        amount: fee,
        nonce: 0,
        deadline: block.timestamp - 1,
        spender: address(templ),
        recipient: signer,
        referral: address(0),
        relayerTip: 0,
        signerPrivateKey: signerPk
      })
    );

    vm.prank(signer);
    vm.expectRevert();
    templ.joinWithPermit2Witness(
      signer, permit, sig, ITempl.JoinIntent(signer, address(0), 0)
    );
  }

  function test_joinWithPermit2Witness_revertsIfWrongRecipientInIntent()
    public
  {
    uint256 signerPk = 0xBEEF;
    address signer = vm.addr(signerPk);
    uint256 fee = templ.entryFee();

    token.mint(signer, fee);
    vm.prank(signer);
    token.approve(PERMIT2_ADDR, fee);

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signPermitWitness(
      WitnessPermitParams({
        token: address(token),
        amount: fee,
        nonce: 0,
        deadline: block.timestamp + 1 hours,
        spender: address(templ),
        recipient: signer,
        referral: address(0),
        relayerTip: 0,
        signerPrivateKey: signerPk
      })
    );

    vm.prank(signer);
    vm.expectRevert();
    templ.joinWithPermit2Witness(
      signer, permit, sig, ITempl.JoinIntent(makeAddr("wrong"), address(0), 0)
    );
  }

  function test_joinWithPermit2Witness_revertsOnWrongToken() public {
    uint256 signerPk = 0xC0DE;
    address signer = vm.addr(signerPk);
    uint256 fee = templ.entryFee();

    MockERC20 wrongToken = new MockERC20();
    wrongToken.mint(signer, fee);
    vm.prank(signer);
    wrongToken.approve(PERMIT2_ADDR, fee);

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signPermitWitness(
      WitnessPermitParams({
        token: address(wrongToken),
        amount: fee,
        nonce: 0,
        deadline: block.timestamp + 1 hours,
        spender: address(templ),
        recipient: signer,
        referral: address(0),
        relayerTip: 0,
        signerPrivateKey: signerPk
      })
    );

    vm.prank(signer);
    vm.expectRevert(ITempl.WrongToken.selector);
    templ.joinWithPermit2Witness(
      signer, permit, sig, ITempl.JoinIntent(signer, address(0), 0)
    );

    assertFalse(templ.isMember(signer));
  }

  function test_joinWithPermit2Witness_revertsIfAlreadyMember() public {
    uint256 signerPk = 0xA11CE;
    address signer = vm.addr(signerPk);
    uint256 fee = templ.entryFee();

    token.mint(signer, fee * 2);
    vm.prank(signer);
    token.approve(PERMIT2_ADDR, fee * 2);

    // First join succeeds
    (ISignatureTransfer.PermitTransferFrom memory permit1, bytes memory sig1) = _signPermitWitness(
      WitnessPermitParams({
        token: address(token),
        amount: fee,
        nonce: 0,
        deadline: block.timestamp + 1 hours,
        spender: address(templ),
        recipient: signer,
        referral: address(0),
        relayerTip: 0,
        signerPrivateKey: signerPk
      })
    );
    vm.prank(signer);
    templ.joinWithPermit2Witness(
      signer, permit1, sig1, ITempl.JoinIntent(signer, address(0), 0)
    );

    // Second join reverts
    (ISignatureTransfer.PermitTransferFrom memory permit2, bytes memory sig2) = _signPermitWitness(
      WitnessPermitParams({
        token: address(token),
        amount: fee,
        nonce: 1,
        deadline: block.timestamp + 1 hours,
        spender: address(templ),
        recipient: signer,
        referral: address(0),
        relayerTip: 0,
        signerPrivateKey: signerPk
      })
    );
    vm.prank(signer);
    vm.expectRevert(ITempl.AlreadyMember.selector);
    templ.joinWithPermit2Witness(
      signer, permit2, sig2, ITempl.JoinIntent(signer, address(0), 0)
    );
  }

  // ============ Zero Fee (Free Join) ============
  // When entryFee is zero, the three permit-based join methods skip the
  // signature/permit logic entirely and behave like plain join(). These tests
  // pass deliberately zeroed permit data to confirm the guard is in place:
  // any wiring that runs the permit call or token check outside the fee guard
  // would fail these tests because the calls revert on the zeroed signature.

  function test_joinWithERC2612Permit_zeroFee_skipsPermit() public {
    (Templ free,) = _deployPermitPair(_staticCurve(), 0);

    address caller = makeAddr("caller");
    address recipient = makeAddr("recipient");

    // Caller holds no tokens and passes zeroed v/r/s. With a non-zero fee the
    // call would revert at permit() (invalid signature) or safeTransferFrom
    // (no balance). With fee=0 the guard skips both.
    vm.prank(caller);
    free.joinWithERC2612Permit(
      recipient, address(0), 0, 0, bytes32(0), bytes32(0)
    );

    assertTrue(free.isMember(recipient));
    assertEq(free.memberCount(), 2);
    // No permit() happened - allowance and nonce are untouched
    assertEq(permitToken.allowance(caller, address(free)), 0);
    assertEq(permitToken.nonces(caller), 0);
    // No transfer happened - treasury holds nothing
    assertEq(permitToken.balanceOf(address(free.TREASURY())), 0);
  }

  function test_joinWithPermit2_zeroFee_skipsPermit() public {
    (Templ free,) = _deployPair(_staticCurve(), 0);

    address caller = makeAddr("caller");
    address recipient = makeAddr("recipient");

    // Garbage permit: wrong token (not free.TOKEN()) and empty signature.
    // With a non-zero fee the WrongToken check would fire, or Permit2 would
    // reject the signature. With fee=0 the guard skips the whole block.
    ISignatureTransfer.PermitTransferFrom memory garbage =
      ISignatureTransfer.PermitTransferFrom({
        permitted: ISignatureTransfer.TokenPermissions({
          token: address(0xdead), amount: 0
        }),
        nonce: 0,
        deadline: 0
      });

    vm.prank(caller);
    free.joinWithPermit2(recipient, address(0), garbage, bytes(""));

    assertTrue(free.isMember(recipient));
    assertEq(free.memberCount(), 2);
    assertEq(token.balanceOf(address(free.TREASURY())), 0);
  }

  function test_joinWithPermit2Witness_zeroFeeAndZeroTip_skipsPermit() public {
    (Templ free,) = _deployPair(_staticCurve(), 0);

    address caller = makeAddr("caller");
    address recipient = makeAddr("recipient");

    // Garbage permit + empty signature. With fee=0 AND relayerTip=0 the
    // outer `fee > 0 || intent.relayerTip > 0` guard is false, so neither
    // the WrongToken check nor the witness verification runs.
    ISignatureTransfer.PermitTransferFrom memory garbage =
      ISignatureTransfer.PermitTransferFrom({
        permitted: ISignatureTransfer.TokenPermissions({
          token: address(0xdead), amount: 0
        }),
        nonce: 0,
        deadline: 0
      });

    ITempl.JoinIntent memory intent = ITempl.JoinIntent({
      recipient: recipient, referral: address(0), relayerTip: 0
    });

    vm.prank(caller);
    free.joinWithPermit2Witness(caller, garbage, bytes(""), intent);

    assertTrue(free.isMember(recipient));
    assertEq(free.memberCount(), 2);
    assertEq(token.balanceOf(address(free.TREASURY())), 0);
    // Relayer (caller) got nothing since tip is 0
    assertEq(token.balanceOf(caller), 0);
  }

  // ============ Reentrancy ============

  function test_setGovernance_resistsReentrancyViaEmitConfig() public {
    // Deploy a malicious governance that re-enters setGovernance
    // during the emitConfig() callback
    ReentrantGovernance malicious = new ReentrantGovernance(address(templ));
    address benign = makeAddr("benign");

    // Arm the mock: when emitConfig() is called, it will try to
    // call templ.setGovernance(benign) - a reentrant call
    malicious.arm(benign);

    // Priest is initial governance. Transfer governance to the
    // malicious contract. The nonReentrant guard should cause the
    // reentrant setGovernance call inside emitConfig() to revert,
    // which bubbles up and reverts the outer call too.
    vm.prank(priest);
    vm.expectRevert();
    templ.setGovernance(address(malicious));

    // Governance unchanged - attack was blocked
    assertEq(templ.governance(), priest);
  }

  /// @dev A malicious governance contract must not be able to drain the
  ///      treasury during its own emitConfig() callback. Templ updates its
  ///      governance pointer AFTER the emitConfig() call so Treasury's
  ///      _checkGovernance resolves to the prior (trusted) address during the
  ///      callback, making Treasury.execute() revert.
  function test_setGovernance_cannotDrainTreasuryViaEmitConfig() public {
    // Seed the treasury by having two real members join.
    vm.startPrank(user1);
    token.approve(address(templ), ENTRY_FEE);
    templ.join(user1, address(0));
    vm.stopPrank();

    vm.startPrank(user2);
    token.approve(address(templ), templ.entryFee());
    templ.join(user2, address(0));
    vm.stopPrank();

    uint256 availableBefore = token.balanceOf(address(treasury));
    assertGt(availableBefore, 0, "treasury should hold withdrawable funds");

    // Deploy a malicious governance that will drain the treasury to `attacker`
    // during its emitConfig() callback.
    address attacker = makeAddr("attacker");
    TreasuryDrainingGovernance malicious =
      new TreasuryDrainingGovernance(address(templ), attacker);

    uint256 attackerBalanceBefore = token.balanceOf(attacker);

    // Priest is the initial governance. It calls setGovernance(malicious).
    // The emitConfig() callback runs while Templ.governance() still points at
    // the priest, so Treasury.execute() reverts with NotGovernance and the
    // whole setGovernance call reverts.
    vm.prank(priest);
    vm.expectRevert();
    templ.setGovernance(address(malicious));

    // Governance must not have changed.
    assertEq(templ.governance(), priest);

    // Treasury must still hold the full amount.
    assertEq(token.balanceOf(address(treasury)), availableBefore);
    assertEq(token.balanceOf(attacker), attackerBalanceBefore);
  }

  // ============ Templ programmable vault: execute / receive / onERC721 ============

  function test_templ_execute_revertsIfNotGovernance() public {
    vm.prank(user1);
    vm.expectRevert(IExecutable.NotGovernance.selector);
    templ.execute(
      address(token), 0, abi.encodeCall(IERC20.transfer, (user1, 1))
    );
  }

  function test_templ_execute_transfersTokenViaGovernance() public {
    // Donate tokens directly to Templ so it has something to move.
    uint256 donation = 500e18;
    token.mint(address(this), donation);
    require(token.transfer(address(templ), donation), "donate");

    address recipient = makeAddr("recipient");
    vm.prank(priest);
    templ.execute(
      address(token), 0, abi.encodeCall(IERC20.transfer, (recipient, donation))
    );

    assertEq(token.balanceOf(recipient), donation);
    assertEq(token.balanceOf(address(templ)), 0);
  }

  function test_templ_execute_emitsExecuted() public {
    uint256 donation = 100e18;
    token.mint(address(this), donation);
    require(token.transfer(address(templ), donation), "donate");

    address recipient = makeAddr("recipient");
    bytes memory data = abi.encodeCall(IERC20.transfer, (recipient, donation));

    vm.expectEmit(true, false, false, true, address(templ));
    emit IExecutable.Executed(address(token), 0, data);

    vm.prank(priest);
    templ.execute(address(token), 0, data);
  }

  function test_templ_execute_canSendNativeETH() public {
    vm.deal(address(this), 1 ether);
    (bool sent,) = address(templ).call{ value: 1 ether }("");
    assertTrue(sent);
    assertEq(address(templ).balance, 1 ether);

    address payable recipient = payable(makeAddr("eth-recipient"));
    uint256 before = recipient.balance;

    vm.prank(priest);
    templ.execute(recipient, 1 ether, "");

    assertEq(recipient.balance - before, 1 ether);
    assertEq(address(templ).balance, 0);
  }

  function test_templ_receive_acceptsETH() public {
    vm.deal(address(this), 2 ether);
    uint256 before = address(templ).balance;
    (bool sent,) = address(templ).call{ value: 2 ether }("");
    assertTrue(sent);
    assertEq(address(templ).balance - before, 2 ether);
  }

  function test_templ_onERC721Received_returnsMagicValue() public view {
    bytes4 magic = templ.onERC721Received(address(0), address(0), 0, "");
    assertEq(magic, bytes4(0x150b7a02));
  }
}
