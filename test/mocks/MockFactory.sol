// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MemberPool } from "../../src/MemberPool.sol";
import { Treasury } from "../../src/Treasury.sol";

/// @dev Minimal mock that deploys Treasury + MemberPool and exposes
///      protocolFeeRecipient(). Treasury and MemberPool read FACTORY = msg.sender
///      at construction time, so the deployer must implement this view.
///
///      The protocol-fee BPS and burn destination live on Templ, so this mock
///      does not forward them into Treasury. Tests pass those values directly
///      into the Templ constructor.
contract MockFactory {
  // forge-lint: disable-next-line(screaming-snake-case-const)
  uint256 public constant PROTOCOL_FEE_BPS = 1000;
  address public protocolFeeRecipient;

  constructor(
    address _protocolFeeRecipient
  ) {
    protocolFeeRecipient = _protocolFeeRecipient;
  }

  function setProtocolFeeRecipient(
    address _recipient
  ) external {
    protocolFeeRecipient = _recipient;
  }

  function deployTreasury(
    address _token
  ) external returns (Treasury) {
    return new Treasury(_token);
  }

  function deployMemberPool(
    address _token
  ) external returns (MemberPool) {
    return new MemberPool(_token);
  }

  /// @dev Deploys Treasury + MemberPool as a wired pair (FACTORY = address(this)).
  ///      Convenience helper for tests that need both contracts. Caller must
  ///      still call setTempl on each after deploying the Templ contract.
  function deployTreasuryAndPool(
    address _token
  ) external returns (Treasury treasury, MemberPool pool) {
    treasury = new Treasury(_token);
    pool = new MemberPool(_token);
  }
}
