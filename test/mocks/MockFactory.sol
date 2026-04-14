// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Treasury } from "../../src/Treasury.sol";

/// @dev Minimal mock that deploys a Treasury and exposes protocolFeeRecipient().
///      Treasury reads protocolFeeRecipient from its FACTORY (msg.sender at
///      construction time), so the deployer must implement this view.
contract MockFactory {
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
    address _token,
    uint256 _protocolBps,
    address _burnAddress,
    uint256 _referralShareBps
  ) external returns (Treasury) {
    return new Treasury(_token, _protocolBps, _burnAddress, _referralShareBps);
  }
}
