// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Templ } from "../src/Templ.sol";
import { Treasury } from "../src/Treasury.sol";
import { ITempl } from "../src/interfaces/ITempl.sol";
import { CurveConfig, EntryFeeCurve } from "../src/libraries/EntryFeeCurve.sol";
import { JoinWithNative } from "../src/utils/JoinWithNative.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockFactory } from "./mocks/MockFactory.sol";
import { Test } from "forge-std/Test.sol";
import { WETH } from "solady/tokens/WETH.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @dev Simulates the fee TOCTOU race condition. entryFee() returns one value
///      but join() pulls a lower amount, as if governance lowered the fee
///      between the read and the transferFrom.
contract MockTOCTOUTempl {
  address public TOKEN;
  uint256 public entryFee;
  uint256 public actualFee;

  constructor(
    address _token,
    uint256 _entryFee,
    uint256 _actualFee
  ) {
    TOKEN = _token;
    entryFee = _entryFee;
    actualFee = _actualFee;
  }

  function join(
    address,
    address
  ) external {
    SafeTransferLib.safeTransferFrom(
      TOKEN, msg.sender, address(this), actualFee
    );
  }
}

contract RejectingReceiver {
  JoinWithNative public router;

  constructor(
    JoinWithNative _router
  ) {
    router = _router;
  }

  function joinWithNative(
    address templ,
    address recipient
  ) external payable {
    router.joinWithNative{ value: msg.value }(templ, recipient, address(0));
  }
}

contract JoinWithNativeTest is Test {
  JoinWithNative public router;
  WETH public weth;
  MockERC20 public otherToken;
  Templ public templ;
  Templ public otherTempl;

  address public priest = makeAddr("priest");
  address public protocolRecipient = makeAddr("protocol");
  address public user1 = makeAddr("user1");

  uint256 public constant ENTRY_FEE = 1 ether;
  uint256 public constant PROTOCOL_FEE_BPS = 1000;

  function _defaultCurve() internal pure returns (CurveConfig memory) {
    return EntryFeeCurve.exponentialWithTail(10_094, 248);
  }

  function _deployPair(
    address tokenAddr
  ) internal returns (Templ t, Treasury tr) {
    MockFactory mf = new MockFactory(protocolRecipient);
    tr = mf.deployTreasury(tokenAddr, PROTOCOL_FEE_BPS, address(0), 2500);
    t = new Templ(
      priest, tokenAddr, ENTRY_FEE, _defaultCurve(), address(tr), address(this)
    );
    vm.prank(address(mf));
    tr.setTempl(address(t));
    vm.prank(address(mf));
    tr.setFeeSplit(3000, 3000, 3000);
  }

  function setUp() public {
    weth = new WETH();
    otherToken = new MockERC20();
    router = new JoinWithNative(address(weth));

    (templ,) = _deployPair(address(weth));
    (otherTempl,) = _deployPair(address(otherToken));

    vm.deal(user1, 10 ether);
  }

  // ============ Happy Path ============

  function test_joinWithNative_success() public {
    vm.prank(user1);
    router.joinWithNative{ value: ENTRY_FEE }(address(templ), user1, address(0));

    assertTrue(templ.isMember(user1));
    assertEq(address(router).balance, 0);
    assertEq(weth.balanceOf(address(router)), 0);
  }

  function test_joinWithNative_refundsExcess() public {
    uint256 balanceBefore = user1.balance;

    vm.prank(user1);
    router.joinWithNative{
      value: ENTRY_FEE + 0.5 ether
    }(address(templ), user1, address(0));

    assertTrue(templ.isMember(user1));
    assertEq(user1.balance, balanceBefore - ENTRY_FEE);
  }

  function test_joinWithNative_referral() public {
    // Join user1 first so there's a valid member-referrer
    vm.prank(user1);
    router.joinWithNative{ value: ENTRY_FEE }(address(templ), user1, address(0));

    uint256 user1Before = weth.balanceOf(user1);
    address user2 = makeAddr("user2");
    vm.deal(user2, 10 ether);

    uint256 fee = templ.entryFee();
    vm.prank(user2);
    router.joinWithNative{ value: fee }(address(templ), user2, user1);

    assertTrue(templ.isMember(user2));
    assertGt(weth.balanceOf(user1), user1Before, "referrer should receive WETH");
  }

  // ============ Reverts ============

  function test_constructor_revertsIfZeroAddress() public {
    vm.expectRevert(JoinWithNative.InvalidWrappedNative.selector);
    new JoinWithNative(address(0));
  }

  function test_joinWithNative_revertsIfNotWrappedNative() public {
    vm.prank(user1);
    vm.expectRevert(JoinWithNative.TokenNotWrappedNative.selector);
    router.joinWithNative{
      value: ENTRY_FEE
    }(address(otherTempl), user1, address(0));
  }

  function test_joinWithNative_revertsIfInsufficientValue() public {
    vm.prank(user1);
    vm.expectRevert(JoinWithNative.InsufficientValue.selector);
    router.joinWithNative{
      value: ENTRY_FEE - 1
    }(address(templ), user1, address(0));
  }

  function test_joinWithNative_revertsIfRefundFails() public {
    RejectingReceiver rejector = new RejectingReceiver(router);
    vm.deal(address(rejector), 10 ether);

    vm.expectRevert(JoinWithNative.RefundFailed.selector);
    rejector.joinWithNative{
      value: ENTRY_FEE + 0.5 ether
    }(address(templ), address(rejector));
  }

  function test_joinWithNative_revertsIfAlreadyMember() public {
    vm.prank(user1);
    router.joinWithNative{ value: ENTRY_FEE }(address(templ), user1, address(0));

    uint256 currentFee = templ.entryFee();
    vm.prank(user1);
    vm.expectRevert(ITempl.AlreadyMember.selector);
    router.joinWithNative{
      value: currentFee
    }(address(templ), user1, address(0));
  }

  // ============ Fuzz ============

  function testFuzz_joinWithNative_anyValidFee(
    uint256 _entryFee
  ) public {
    _entryFee = bound(_entryFee, 100, 100 ether);

    MockFactory fuzzMf = new MockFactory(protocolRecipient);
    Treasury fuzzTreasury = fuzzMf.deployTreasury(
      address(weth), PROTOCOL_FEE_BPS, address(0), 2500
    );
    Templ fuzzTempl = new Templ(
      priest,
      address(weth),
      _entryFee,
      _defaultCurve(),
      address(fuzzTreasury),
      address(this)
    );
    vm.prank(address(fuzzMf));
    fuzzTreasury.setTempl(address(fuzzTempl));
    vm.prank(address(fuzzMf));
    fuzzTreasury.setFeeSplit(3000, 3000, 3000);

    vm.deal(user1, _entryFee);
    vm.prank(user1);
    router.joinWithNative{
      value: _entryFee
    }(address(fuzzTempl), user1, address(0));

    assertTrue(fuzzTempl.isMember(user1));
  }

  function testFuzz_joinWithNative_refundsCorrectly(
    uint256 _excess
  ) public {
    _excess = bound(_excess, 1, 10 ether);

    vm.deal(user1, ENTRY_FEE + _excess);
    uint256 balanceBefore = user1.balance;

    vm.prank(user1);
    router.joinWithNative{
      value: ENTRY_FEE + _excess
    }(address(templ), user1, address(0));

    assertEq(user1.balance, balanceBefore - ENTRY_FEE);
  }

  // ============ TOCTOU Refund ============

  function test_joinWithNative_refundsWethLeftoverOnFeeDrop() public {
    // Fee drops from 1 ETH to 0.6 ETH between entryFee() read and join()
    uint256 reportedFee = 1 ether;
    uint256 actualFee = 0.6 ether;
    MockTOCTOUTempl mock =
      new MockTOCTOUTempl(address(weth), reportedFee, actualFee);

    uint256 balanceBefore = user1.balance;

    vm.prank(user1);
    router.joinWithNative{
      value: reportedFee
    }(address(mock), user1, address(0));

    // User only pays the actual fee; leftover WETH is unwrapped and refunded
    assertEq(user1.balance, balanceBefore - actualFee);
    assertEq(address(router).balance, 0, "no ETH stranded in router");
    assertEq(weth.balanceOf(address(router)), 0, "no WETH stranded in router");
  }

  function test_joinWithNative_refundsWethLeftoverPlusEthOverpayment() public {
    // Fee drops from 1 ETH to 0.7 ETH, and user also overpays by 0.5 ETH
    uint256 reportedFee = 1 ether;
    uint256 actualFee = 0.7 ether;
    uint256 overpayment = 0.5 ether;
    MockTOCTOUTempl mock =
      new MockTOCTOUTempl(address(weth), reportedFee, actualFee);

    uint256 balanceBefore = user1.balance;

    vm.prank(user1);
    router.joinWithNative{
      value: reportedFee + overpayment
    }(address(mock), user1, address(0));

    // User pays only the actual fee; both WETH leftover and ETH overpayment refunded
    assertEq(user1.balance, balanceBefore - actualFee);
    assertEq(address(router).balance, 0, "no ETH stranded in router");
    assertEq(weth.balanceOf(address(router)), 0, "no WETH stranded in router");
  }
}
