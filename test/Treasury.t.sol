// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MemberPool } from "../src/MemberPool.sol";
import { Templ } from "../src/Templ.sol";
import { Treasury } from "../src/Treasury.sol";
import { IExecutable } from "../src/interfaces/IExecutable.sol";
import { ITreasury } from "../src/interfaces/ITreasury.sol";
import { CurveConfig, EntryFeeCurve } from "../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockFactory } from "./mocks/MockFactory.sol";
import { ReentrantToken } from "./mocks/ReentrantToken.sol";
import { Test } from "forge-std/Test.sol";

interface IERC20Like {
  function transfer(
    address to,
    uint256 amount
  ) external returns (bool);
  function balanceOf(
    address
  ) external view returns (uint256);
}

/// @dev Tests Treasury. Treasury is a slim programmable vault:
///      TOKEN/FACTORY/templ/memberPool, the governance-only `dissolve` escape
///      hatch, and the `execute` / `receive` / `onERC721Received` surface
///      inherited from Executable. All fee-split knobs and `totalBurned`
///      live on Templ; see Templ.t.sol for those tests.
contract TreasuryTest is Test {
  Templ public templ;
  Treasury public treasury;
  MemberPool public pool;
  MockERC20 public token;
  MockFactory public mockFactory;

  address public priest = makeAddr("priest");
  address public protocolRecipient = makeAddr("protocol");
  address public user1 = makeAddr("user1");
  address public user2 = makeAddr("user2");
  address public user3 = makeAddr("user3");

  uint256 public constant ENTRY_FEE = 1000e18;
  uint256 public constant PROTOCOL_BPS = 1000;
  uint256 public constant BURN_BPS = 3000;
  uint256 public constant TREASURY_BPS = 3000;
  uint256 public constant MEMBER_POOL_BPS = 3000;
  uint256 public constant REFERRAL_SHARE_BPS = 2500;

  address constant DEAD = 0x000000000000000000000000000000000000dEaD;

  function _defaultCurve() internal pure returns (CurveConfig memory) {
    return EntryFeeCurve.exponentialWithTail(10_094, 248);
  }

  function _deployTrio() internal {
    mockFactory = new MockFactory(protocolRecipient);
    (treasury, pool) = mockFactory.deployTreasuryAndPool(address(token));

    templ = new Templ(
      priest,
      address(token),
      ENTRY_FEE,
      _defaultCurve(),
      address(treasury),
      address(pool),
      priest,
      PROTOCOL_BPS,
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

    // Bootstrap split config (priest doubles as governance in this fixture).
    vm.prank(priest);
    templ.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);
    vm.prank(priest);
    templ.setReferralShareBps(REFERRAL_SHARE_BPS);
  }

  function setUp() public {
    token = new MockERC20();
    _deployTrio();

    token.mint(user1, 100_000e18);
    token.mint(user2, 100_000e18);
    token.mint(user3, 100_000e18);
  }

  function _join(
    address who
  ) internal {
    uint256 fee = templ.entryFee();
    vm.startPrank(who);
    token.approve(address(templ), fee);
    templ.join(who, address(0));
    vm.stopPrank();
  }

  // ============ Constructor ============

  function test_constructor_setsParams() public view {
    assertEq(treasury.TOKEN(), address(token));
    assertEq(treasury.FACTORY(), address(mockFactory));
    assertEq(treasury.TEMPL(), address(templ));
    assertEq(treasury.MEMBER_POOL(), address(pool));
  }

  // ============ Templ Forwards Treasury Slice ============

  function test_join_treasuryReceivesItsSlice() public {
    uint256 burnBefore = token.balanceOf(DEAD);
    uint256 protocolBefore = token.balanceOf(protocolRecipient);

    _join(user1);

    uint256 fee = ENTRY_FEE;
    uint256 expectedBurn = (fee * BURN_BPS) / 10_000;
    uint256 expectedMemberPool = (fee * MEMBER_POOL_BPS) / 10_000;
    uint256 expectedProtocol = (fee * PROTOCOL_BPS) / 10_000;
    uint256 expectedTreasury =
      fee - expectedBurn - expectedMemberPool - expectedProtocol;

    assertEq(token.balanceOf(DEAD) - burnBefore, expectedBurn, "burn");
    assertEq(
      token.balanceOf(protocolRecipient) - protocolBefore,
      expectedProtocol,
      "protocol"
    );
    assertEq(
      token.balanceOf(address(treasury)), expectedTreasury, "treasury slice"
    );
    // totalBurned lives on Templ.
    assertEq(templ.totalBurned(), expectedBurn, "totalBurned");
  }

  function test_directTransfer_addsToTokenBalance() public {
    _join(user1);
    uint256 before = token.balanceOf(address(treasury));

    uint256 donation = 500e18;
    token.mint(address(this), donation);
    require(token.transfer(address(treasury), donation), "transfer failed");

    assertEq(token.balanceOf(address(treasury)), before + donation);
  }

  // ============ execute ============

  function test_execute_transferTokenViaGovernance() public {
    _join(user1);

    uint256 treasuryBal = token.balanceOf(address(treasury));
    assertGt(treasuryBal, 0);

    address recipient = makeAddr("recipient");
    vm.prank(priest);
    treasury.execute(
      address(token),
      0,
      abi.encodeCall(IERC20Like.transfer, (recipient, treasuryBal))
    );

    assertEq(token.balanceOf(recipient), treasuryBal);
    assertEq(token.balanceOf(address(treasury)), 0);
  }

  function test_execute_partialTransfer() public {
    _join(user1);
    _join(user2);

    uint256 fullTreasury = token.balanceOf(address(treasury));
    assertGt(fullTreasury, 0);

    uint256 portion = fullTreasury / 3;
    address recipient = makeAddr("partialRecipient");

    vm.prank(priest);
    treasury.execute(
      address(token),
      0,
      abi.encodeCall(IERC20Like.transfer, (recipient, portion))
    );

    assertEq(token.balanceOf(recipient), portion);
    assertEq(token.balanceOf(address(treasury)), fullTreasury - portion);
  }

  function test_execute_revertsIfNotGovernance() public {
    vm.expectRevert(IExecutable.NotGovernance.selector);
    vm.prank(user1);
    treasury.execute(
      address(token), 0, abi.encodeCall(IERC20Like.transfer, (user1, 100))
    );
  }

  function test_execute_revertsWithExecuteFailed_onTargetRevert() public {
    _join(user1);
    uint256 bal = token.balanceOf(address(treasury));

    // Try to transfer more than the treasury holds; the token reverts.
    vm.prank(priest);
    vm.expectRevert();
    treasury.execute(
      address(token),
      0,
      abi.encodeCall(IERC20Like.transfer, (makeAddr("thief"), bal + 1))
    );
  }

  function test_execute_emitsExecuted() public {
    _join(user1);
    uint256 bal = token.balanceOf(address(treasury));
    address recipient = makeAddr("recipient");
    bytes memory data = abi.encodeCall(IERC20Like.transfer, (recipient, bal));

    vm.expectEmit(true, false, false, true, address(treasury));
    emit IExecutable.Executed(address(token), 0, data);

    vm.prank(priest);
    treasury.execute(address(token), 0, data);
  }

  function test_execute_canSendNativeETH() public {
    // Seed treasury with ETH via receive()
    vm.deal(address(this), 1 ether);
    (bool sent,) = address(treasury).call{ value: 1 ether }("");
    assertTrue(sent);
    assertEq(address(treasury).balance, 1 ether);

    address payable recipient = payable(makeAddr("eth-recipient"));
    uint256 before = recipient.balance;

    vm.prank(priest);
    treasury.execute(recipient, 1 ether, "");

    assertEq(recipient.balance - before, 1 ether);
    assertEq(address(treasury).balance, 0);
  }

  function test_execute_resistsReentrancyViaToken() public {
    // Deploy a Treasury+Pool+Templ trio with the reentrant token
    ReentrantToken evil = new ReentrantToken();
    MockFactory evilFactory = new MockFactory(protocolRecipient);
    (Treasury evilTreasury, MemberPool evilPool) =
      evilFactory.deployTreasuryAndPool(address(evil));
    Templ evilTempl = new Templ(
      priest,
      address(evil),
      ENTRY_FEE,
      _defaultCurve(),
      address(evilTreasury),
      address(evilPool),
      priest,
      PROTOCOL_BPS,
      address(0)
    );
    vm.prank(address(evilFactory));
    evilTreasury.setTempl(address(evilTempl));
    vm.prank(address(evilFactory));
    evilTreasury.setMemberPool(address(evilPool));
    vm.prank(address(evilFactory));
    evilPool.setTempl(address(evilTempl));
    vm.prank(address(evilFactory));
    evilPool.setTreasury(address(evilTreasury));
    vm.prank(priest);
    evilTempl.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);

    evil.mint(user1, 100_000e18);
    vm.startPrank(user1);
    evil.approve(address(evilTempl), type(uint256).max);
    evilTempl.join(user1, address(0));
    vm.stopPrank();

    uint256 treasuryBal = evil.balanceOf(address(evilTreasury));
    address recipient = makeAddr("recipient");
    bytes memory transferData =
      abi.encodeCall(IERC20Like.transfer, (recipient, treasuryBal));

    // Arm the token to attempt a re-entry into Treasury.execute during
    // the transfer; the nonReentrant guard must block it.
    evil.setAttack(
      address(evilTreasury),
      abi.encodeCall(evilTreasury.execute, (address(evil), 0, transferData))
    );

    vm.prank(priest);
    evilTreasury.execute(address(evil), 0, transferData);

    assertEq(evil.balanceOf(recipient), treasuryBal);
    assertEq(evil.balanceOf(address(evilTreasury)), 0);
  }

  // ============ receive / onERC721Received ============

  function test_receive_acceptsETH() public {
    vm.deal(address(this), 1 ether);
    uint256 before = address(treasury).balance;
    (bool sent,) = address(treasury).call{ value: 1 ether }("");
    assertTrue(sent);
    assertEq(address(treasury).balance - before, 1 ether);
  }

  function test_onERC721Received_returnsMagicValue() public view {
    bytes4 magic = treasury.onERC721Received(address(0), address(0), 0, "");
    assertEq(magic, bytes4(0x150b7a02));
  }

  // ============ dissolve ============

  function test_dissolve_sendsBalanceToMemberPool() public {
    _join(user1);
    _join(user2);

    uint256 treasuryBefore = token.balanceOf(address(treasury));
    assertGt(treasuryBefore, 0);

    uint256 poolBefore = token.balanceOf(address(pool));

    vm.prank(priest);
    treasury.dissolve();

    assertEq(token.balanceOf(address(treasury)), 0, "treasury empty");
    assertEq(
      token.balanceOf(address(pool)),
      poolBefore + treasuryBefore,
      "pool received entire treasury"
    );
  }

  function test_dissolve_emitsEvent() public {
    _join(user1);
    uint256 treasuryBal = token.balanceOf(address(treasury));

    vm.expectEmit(true, false, false, true, address(treasury));
    emit ITreasury.TreasuryDissolved(address(templ), treasuryBal);

    vm.prank(priest);
    treasury.dissolve();
  }

  function test_dissolve_nextJoinFoldsAbsorbedDelta() public {
    // Seed pool via joins
    _join(user1);
    _join(user2);

    // Bump treasury via direct donation so dissolve has more to send
    uint256 donation = 5000e18;
    token.mint(address(this), donation);
    require(token.transfer(address(treasury), donation), "transfer failed");

    uint256 treasuryBal = token.balanceOf(address(treasury));

    vm.prank(priest);
    treasury.dissolve();

    // Treasury empty, pool got everything
    assertEq(token.balanceOf(address(treasury)), 0);

    // The next paid join folds the surplus into that round's distribution.
    // totalDeposited is the running deposit counter; before user3 joins it
    // captures only the per-join slices. After user3 joins, totalDeposited
    // gains both the round's normal slice and the absorbed surplus.
    uint256 totalDepositedBefore = pool.totalDeposited();

    _join(user3);

    uint256 totalDepositedAfter = pool.totalDeposited();
    uint256 delta = totalDepositedAfter - totalDepositedBefore;
    // The delta must be at least the dissolved amount (plus the round's slice)
    assertGe(delta, treasuryBal, "next join folds dissolved funds");
  }

  function test_dissolve_revertsIfNotGovernance() public {
    _join(user1);
    vm.prank(user1);
    vm.expectRevert(IExecutable.NotGovernance.selector);
    treasury.dissolve();
  }

  function test_dissolve_revertsIfBalanceZero() public {
    vm.prank(priest);
    vm.expectRevert(ITreasury.EmptyTreasury.selector);
    treasury.dissolve();
  }

  function test_dissolve_revertsIfMemberPoolNotInitialized() public {
    MockFactory mf = new MockFactory(protocolRecipient);
    Treasury tr = mf.deployTreasury(address(token));
    // Skip setMemberPool to leave it zero. Need a templ for governance check.
    MemberPool p = mf.deployMemberPool(address(token));
    Templ t = new Templ(
      priest,
      address(token),
      ENTRY_FEE,
      _defaultCurve(),
      address(tr),
      address(p),
      priest,
      PROTOCOL_BPS,
      address(0)
    );
    vm.prank(address(mf));
    tr.setTempl(address(t));

    // Send tokens directly so the balance>0 guard is satisfied
    token.mint(address(this), 100e18);
    require(token.transfer(address(tr), 100e18), "transfer failed");

    vm.prank(priest);
    vm.expectRevert(ITreasury.NotInitialized.selector);
    tr.dissolve();
  }

  // ============ setTempl ============

  function test_setTempl_revertsIfNotFactory() public {
    MockFactory mf = new MockFactory(protocolRecipient);
    Treasury tr = mf.deployTreasury(address(token));
    vm.prank(user1);
    vm.expectRevert(ITreasury.NotDeployer.selector);
    tr.setTempl(address(templ));
  }

  function test_setTempl_revertsIfAlreadySet() public {
    vm.prank(address(mockFactory));
    vm.expectRevert(ITreasury.AlreadyInitialized.selector);
    treasury.setTempl(makeAddr("anotherTempl"));
  }

  function test_setTempl_revertsIfZeroAddress() public {
    MockFactory mf = new MockFactory(protocolRecipient);
    Treasury tr = mf.deployTreasury(address(token));
    vm.prank(address(mf));
    vm.expectRevert(ITreasury.ZeroTempl.selector);
    tr.setTempl(address(0));
  }

  // ============ setMemberPool ============

  function test_setMemberPool_revertsIfNotFactory() public {
    MockFactory mf = new MockFactory(protocolRecipient);
    Treasury tr = mf.deployTreasury(address(token));
    vm.prank(user1);
    vm.expectRevert(ITreasury.NotDeployer.selector);
    tr.setMemberPool(address(pool));
  }

  function test_setMemberPool_revertsIfAlreadySet() public {
    vm.prank(address(mockFactory));
    vm.expectRevert(ITreasury.AlreadyInitialized.selector);
    treasury.setMemberPool(makeAddr("anotherPool"));
  }

  function test_setMemberPool_revertsIfZeroAddress() public {
    MockFactory mf = new MockFactory(protocolRecipient);
    Treasury tr = mf.deployTreasury(address(token));
    vm.prank(address(mf));
    vm.expectRevert(ITreasury.ZeroMemberPool.selector);
    tr.setMemberPool(address(0));
  }

  function test_setMemberPool_emitsEvent() public {
    MockFactory mf = new MockFactory(protocolRecipient);
    Treasury tr = mf.deployTreasury(address(token));
    address p = makeAddr("pool");

    vm.expectEmit(true, false, false, false, address(tr));
    emit ITreasury.MemberPoolSet(p);

    vm.prank(address(mf));
    tr.setMemberPool(p);
    assertEq(tr.MEMBER_POOL(), p);
  }
}
