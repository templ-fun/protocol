// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Council } from "./governance/Council.sol";

/// @title CouncilDeployer
/// @notice Deploys Council governance contracts via CREATE2.
///         Split from GovernanceDeployer to stay under 24KB (EIP-170).
contract CouncilDeployer {
  error NotAuthorized();
  error AlreadyInitialized();
  error ZeroAddress();

  address public governanceDeployer;

  /// @notice One-shot setter - locks the GovernanceDeployer address permanently.
  function setGovernanceDeployer(
    address _governanceDeployer
  ) external {
    if (governanceDeployer != address(0)) revert AlreadyInitialized();
    if (_governanceDeployer == address(0)) revert ZeroAddress();
    governanceDeployer = _governanceDeployer;
  }

  function deploy(
    address templ,
    uint256 approvalThresholdBps,
    uint256 quorumBps,
    uint256 executionDelay,
    uint256 votingPeriod,
    uint256 immediateExecutionBps,
    uint256 proposalFeeBps,
    address[] calldata council
  ) external returns (address) {
    if (msg.sender != governanceDeployer) revert NotAuthorized();

    bytes32 salt = bytes32(uint256(uint160(templ)));
    return address(
      new Council{
        salt: salt
      }(
        templ,
        approvalThresholdBps,
        quorumBps,
        executionDelay,
        votingPeriod,
        immediateExecutionBps,
        proposalFeeBps,
        council
      )
    );
  }
}
