// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITempl } from "../interfaces/ITempl.sol";
import { IWETH } from "../interfaces/IWETH.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
// Transient storage variant - saves ~2,100 gas per guarded call on mainnet
import {
  ReentrancyGuardTransient
} from "solady/utils/ReentrancyGuardTransient.sol";

/// @title JoinWithNative
/// @notice Wraps native tokens (ETH/BNB/MATIC) and joins a Templ in one transaction.
/// @dev Users pay for Templ membership with native tokens. This contract wraps the
///      entry fee into WETH, approves the Templ contract, calls join, and refunds
///      any excess - including WETH left over when the fee drops between the
///      entryFee() read and join()'s transferFrom (TOCTOU race condition).
///      Without this, users holding only native tokens would need two separate
///      transactions (wrap, then approve+join). ReentrancyGuard protects the
///      refund's external call.
contract JoinWithNative is ReentrancyGuardTransient {
  // ============ Errors ============

  error TokenNotWrappedNative();
  error InsufficientValue();
  error InvalidWrappedNative();
  error RefundFailed();

  // ============ Immutables ============

  IWETH public immutable WRAPPED_NATIVE;

  // ============ Constructor ============

  /// @param _wrappedNative Address of the chain's wrapped native token (WETH, WBNB, WMATIC, etc.)
  constructor(
    address _wrappedNative
  ) {
    if (_wrappedNative == address(0)) revert InvalidWrappedNative();
    WRAPPED_NATIVE = IWETH(_wrappedNative);
  }

  // ============ Join ============

  /// @notice Wrap native tokens and join a Templ. Pass address(0) for no referral.
  /// @param templ Address of the Templ contract to join
  /// @param recipient Address that receives the membership
  /// @param referral Address credited as the referrer (address(0) if none)
  function joinWithNative(
    address templ,
    address recipient,
    address referral
  ) external payable nonReentrant {
    ITempl t = ITempl(templ);

    if (t.TOKEN() != address(WRAPPED_NATIVE)) {
      revert TokenNotWrappedNative();
    }

    uint256 fee = t.entryFee();
    if (msg.value < fee) revert InsufficientValue();

    // Wrap exactly the fee amount and approve the Templ to pull it via transferFrom
    WRAPPED_NATIVE.deposit{ value: fee }();
    SafeTransferLib.safeApprove(address(WRAPPED_NATIVE), templ, fee);

    t.join(recipient, referral);

    // The fee read from entryFee() can be stale - the fee can change between our
    // read and join()'s transferFrom (up from new joins, or down from governance).
    // Unwrap any WETH the Templ did not pull.
    // NOTE: Fee increase between read and join tracked in #181.
    uint256 wethBalance = WRAPPED_NATIVE.balanceOf(address(this));
    if (wethBalance > 0) {
      WRAPPED_NATIVE.withdraw(wethBalance);
    }

    // Refund everything: ETH overpayment from the caller + unwrapped WETH leftover.
    uint256 excess = address(this).balance;
    if (excess > 0) {
      (bool ok,) = msg.sender.call{ value: excess }("");
      if (!ok) revert RefundFailed();
    }
  }

  /// @dev Required so WRAPPED_NATIVE.withdraw() can return ETH to this contract.
  ///      joinWithNative is nonReentrant and drains the full ETH balance before
  ///      returning, so excess from rounding or fee changes is refunded. However,
  ///      ETH force-sent via selfdestruct or coinbase is not recoverable.
  // NOTE: Force-sent ETH recovery tracked in #175.
  receive() external payable { }
}
