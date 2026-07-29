// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MemberPool } from "../src/MemberPool.sol";
import { Templ } from "../src/Templ.sol";
import { Treasury } from "../src/Treasury.sol";
import { ITempl } from "../src/interfaces/ITempl.sol";
import {
  CurveConfig,
  CurveSegment,
  CurveStyle
} from "../src/libraries/EntryFeeCurve.sol";
import { FeeOnTransferERC20 } from "./mocks/FeeOnTransferERC20.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockFactory } from "./mocks/MockFactory.sol";
import { Permit2Helper } from "./utils/Permit2Helper.sol";
import { Test } from "forge-std/Test.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";

/// @dev Verifies that fee-on-transfer tokens are rejected at the join gate.
///      Delta accounting detects the tax and reverts with FeeTokenMismatch.
contract TemplFoTTest is Test, Permit2Helper {
  Templ public templ;
  Treasury public treasury;
  FeeOnTransferERC20 public fotToken;
  MockERC20 public standardToken;

  address public priest = makeAddr("priest");
  address public protocolRecipient = makeAddr("protocol");

  uint256 public constant ENTRY_FEE = 1000e18;
  uint256 public constant PROTOCOL_FEE_BPS = 0;
  uint256 public constant BURN_BPS = 0;
  uint256 public constant TREASURY_BPS = 0;
  uint256 public constant MEMBER_POOL_BPS = 10_000;
  uint256 public constant FOT_TAX_BPS = 100; // 1% tax on every transfer

  function _staticCurve() internal pure returns (CurveConfig memory config) {
    config.primary =
      CurveSegment({ style: CurveStyle.Static, rateBps: 0, length: 0 });
  }

  function _deployPair(
    address token,
    uint256 entryFee
  ) internal returns (Templ t, Treasury tr) {
    MockFactory mf = new MockFactory(protocolRecipient);
    MemberPool p;
    (tr, p) = mf.deployTreasuryAndPool(token);
    t = new Templ(
      priest,
      token,
      entryFee,
      _staticCurve(),
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
    // Split config lives on Templ; priest doubles as governance.
    vm.prank(priest);
    t.setFeeSplit(BURN_BPS, TREASURY_BPS, MEMBER_POOL_BPS);
    vm.prank(priest);
    t.setReferralShareBps(2500);
  }

  function setUp() public {
    _deployPermit2();
    fotToken = new FeeOnTransferERC20(FOT_TAX_BPS);
    standardToken = new MockERC20();
    (templ, treasury) = _deployPair(address(fotToken), ENTRY_FEE);
  }

  // ============ FoT tokens are rejected ============

  function test_join_revertsWithFoTToken() public {
    address member = makeAddr("fotMember");
    fotToken.mint(member, ENTRY_FEE * 2);

    vm.startPrank(member);
    fotToken.approve(address(templ), ENTRY_FEE);
    vm.expectRevert(ITempl.FeeTokenMismatch.selector);
    templ.join(member, address(0));
    vm.stopPrank();
  }

  /// @dev Separate test because the witness path has two transfer hops:
  ///      Permit2 first pulls payer -> Templ, then Templ fans out to the burn
  ///      address, Treasury, MemberPool, and protocol fee recipient. Each hop
  ///      is taxed independently by the FoT token, so the delivered amount at
  ///      Templ is below the entry fee and the join must revert.
  function test_joinWithPermit2Witness_revertsWithFoTToken() public {
    uint256 payerPk = 0xCAFE;
    address payer = vm.addr(payerPk);
    address relayer = makeAddr("relayer");
    uint256 tip = 50e18;
    uint256 totalAmount = ENTRY_FEE + tip;

    fotToken.mint(payer, totalAmount * 2);
    vm.prank(payer);
    fotToken.approve(PERMIT2_ADDR, type(uint256).max);

    (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) = _signPermitWitness(
      WitnessPermitParams({
        token: address(fotToken),
        amount: totalAmount,
        nonce: 0,
        deadline: block.timestamp + 1 hours,
        spender: address(templ),
        recipient: payer,
        referral: address(0),
        relayerTip: tip,
        signerPrivateKey: payerPk
      })
    );

    ITempl.JoinIntent memory intent = ITempl.JoinIntent({
      recipient: payer, referral: address(0), relayerTip: tip
    });

    vm.prank(relayer);
    vm.expectRevert(ITempl.FeeTokenMismatch.selector);
    templ.joinWithPermit2Witness(payer, permit, sig, intent);
  }

  // ============ Standard tokens still work ============

  function test_join_succeedsWithStandardToken() public {
    (Templ stdTempl,) = _deployPair(address(standardToken), ENTRY_FEE);

    address member = makeAddr("stdMember");
    standardToken.mint(member, ENTRY_FEE * 2);

    vm.startPrank(member);
    standardToken.approve(address(stdTempl), ENTRY_FEE);
    stdTempl.join(member, address(0));
    vm.stopPrank();

    (uint64 id,) = stdTempl.members(member);
    assertEq(id, 2); // priest is #1, first paid join is #2
  }

  /// @dev Deploys with a FoT token to prove the check does not false-positive
  ///      when fee is 0. No transfer happens, so both values are 0.
  function test_join_succeedsWithZeroFee() public {
    (Templ freeTempl,) = _deployPair(address(fotToken), 0);

    address member = makeAddr("freeMember");
    freeTempl.join(member, address(0));

    (uint64 id,) = freeTempl.members(member);
    assertEq(id, 2);
  }
}
