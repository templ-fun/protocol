// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CouncilDeployer } from "./CouncilDeployer.sol";
import { DemocracyDeployer } from "./DemocracyDeployer.sol";
import { GovMode, GovernanceConfig } from "./interfaces/IFactory.sol";

/// @title GovernanceDeployer
/// @notice Routes governance deployment to DemocracyDeployer or CouncilDeployer.
///         Each sub-deployer holds its own bytecode, keeping all contracts under
///         the 24KB limit (EIP-170).
contract GovernanceDeployer {
  error InvalidCouncil();
  error NotAuthorized();
  error AlreadyInitialized();
  error ZeroAddress();

  DemocracyDeployer public immutable DEMOCRACY_DEPLOYER;
  CouncilDeployer public immutable COUNCIL_DEPLOYER;

  /// @notice EOA that deployed the infrastructure - only address allowed to
  ///         call setFactory. Prevents front-running on chains with public
  ///         mempools.
  address public immutable DEPLOYER_EOA;

  address public factory;

  constructor(
    address _democracyDeployer,
    address _councilDeployer,
    address _deployerEoa
  ) {
    if (_deployerEoa == address(0)) revert ZeroAddress();
    DEMOCRACY_DEPLOYER = DemocracyDeployer(_democracyDeployer);
    COUNCIL_DEPLOYER = CouncilDeployer(_councilDeployer);
    DEPLOYER_EOA = _deployerEoa;
  }

  /// @notice One-shot setter - locks the Factory address permanently.
  ///         Restricted to DEPLOYER_EOA to prevent front-running between
  ///         deployment and initialization.
  function setFactory(
    address _factory
  ) external {
    if (msg.sender != DEPLOYER_EOA) revert NotAuthorized();
    if (factory != address(0)) revert AlreadyInitialized();
    if (_factory == address(0)) revert ZeroAddress();
    factory = _factory;
  }

  /// @notice Deploy a governance contract for a templ
  function deploy(
    address templ,
    GovernanceConfig calldata govConfig,
    uint256 approvalThresholdBps,
    uint256 quorumBps,
    uint256 votingPeriod,
    uint256 executionDelay,
    uint256 immediateExecutionBps,
    uint256 proposalFeeBps
  ) external returns (address governance) {
    if (msg.sender != factory) revert NotAuthorized();

    if (govConfig.mode == GovMode.Council) {
      if (govConfig.council.length == 0) revert InvalidCouncil();
      governance = COUNCIL_DEPLOYER.deploy(
        templ,
        approvalThresholdBps,
        quorumBps,
        executionDelay,
        votingPeriod,
        immediateExecutionBps,
        proposalFeeBps,
        govConfig.council
      );
    } else {
      governance = DEMOCRACY_DEPLOYER.deploy(
        templ,
        approvalThresholdBps,
        quorumBps,
        executionDelay,
        votingPeriod,
        immediateExecutionBps,
        proposalFeeBps
      );
    }
  }
}
