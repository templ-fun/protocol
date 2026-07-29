// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { GovernanceDeployer } from "./GovernanceDeployer.sol";
import { Council } from "./governance/Council.sol";
import { IFactory } from "./interfaces/IFactory.sol";
import { ITempl } from "./interfaces/ITempl.sol";

/// @title CouncilDeployer
/// @notice Deploys Council governance contracts via CREATE2.
///         Split from GovernanceDeployer to stay under 24KB (EIP-170).
///
///         Two entry points:
///         - `deploy` (genesis): callable by GovernanceDeployer during Factory.createTempl.
///           Salt = bytes32(uint160(templ)); fires exactly once per templ.
///         - `deployFor` (switch): callable by the templ's current governance through
///           a passing proposal. Salt is namespaced by a per-templ nonce so successive
///           switches never collide.
contract CouncilDeployer {
  error NotAuthorized();
  error AlreadyInitialized();
  error ZeroAddress();

  /// @notice EOA that deployed the infrastructure - only address allowed to
  ///         call setGovernanceDeployer. Prevents front-running on chains
  ///         with public mempools.
  address public immutable DEPLOYER_EOA;

  address public governanceDeployer;

  /// @notice Per-templ counter used as the salt seed for `deployFor`.
  ///         Increments before each new deployment, so the nth switch
  ///         for a given templ uses nonce n. Lives in its own keyspace
  ///         (keccak256(templ, nonce)) and never collides with the
  ///         genesis salt (bytes32(uint160(templ))).
  mapping(address templ => uint256) public switchNonce;

  constructor(
    address _deployerEoa
  ) {
    if (_deployerEoa == address(0)) revert ZeroAddress();
    DEPLOYER_EOA = _deployerEoa;
  }

  /// @notice One-shot setter - locks the GovernanceDeployer address permanently.
  ///         Restricted to DEPLOYER_EOA to prevent front-running between
  ///         deployment and initialization.
  function setGovernanceDeployer(
    address _governanceDeployer
  ) external {
    if (msg.sender != DEPLOYER_EOA) revert NotAuthorized();
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
      new Council{ salt: salt }(
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

  /// @notice Deploy a new Council for an existing templ via a passing governance
  ///         proposal. Gated to the templ's current governance contract, so only
  ///         a proposal that has reached quorum and approval can trigger it.
  /// @dev    Uses a per-templ nonce salt (keccak256(templ, ++switchNonce[templ])),
  ///         disjoint from the genesis salt space. Successive switches never
  ///         collide, and the genesis deployment for any templ is byte-identical
  ///         to the pre-switch behavior.
  /// @dev    Refuses to deploy for any address that is not a Factory-registered
  ///         templ. Without this guard, anyone could deploy a contract with a
  ///         spoofed `governance()` view and have `deployFor` succeed; the
  ///         resulting Council would be orphaned (can only act on the
  ///         attacker's fake templ, never a real one) but the attacker would
  ///         still pollute `switchNonce` for arbitrary addresses. Cheap to
  ///         close the surface here by reading the Factory pointer from
  ///         the locked-in GovernanceDeployer.
  function deployFor(
    address templ,
    uint256 approvalThresholdBps,
    uint256 quorumBps,
    uint256 executionDelay,
    uint256 votingPeriod,
    uint256 immediateExecutionBps,
    uint256 proposalFeeBps,
    address[] calldata council
  ) external returns (address) {
    if (msg.sender != ITempl(templ).governance()) revert NotAuthorized();
    if (!IFactory(GovernanceDeployer(governanceDeployer).factory())
        .isTempl(templ)) {
      revert NotAuthorized();
    }

    bytes32 salt = keccak256(abi.encode(templ, ++switchNonce[templ]));
    return address(
      new Council{ salt: salt }(
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

  /// @notice Predict the address `deployFor` will return on its next call for
  ///         this templ, given the supplied constructor args. Gas-free read,
  ///         used by the UI to encode `Templ.setGovernance(predicted)` in the
  ///         same proposal as the `deployFor` call.
  /// @dev    Reads `switchNonce[templ] + 1` to mirror the pre-increment in
  ///         `deployFor`. Any state-changing call to `deployFor` for this templ
  ///         between prediction and execution will invalidate the prediction,
  ///         but in practice both calls land in the same proposal batch, which
  ///         executes atomically.
  function predictDeployForAddress(
    address templ,
    uint256 approvalThresholdBps,
    uint256 quorumBps,
    uint256 executionDelay,
    uint256 votingPeriod,
    uint256 immediateExecutionBps,
    uint256 proposalFeeBps,
    address[] calldata council
  ) external view returns (address) {
    bytes32 salt = keccak256(abi.encode(templ, switchNonce[templ] + 1));
    bytes32 initCodeHash = keccak256(
      abi.encodePacked(
        type(Council).creationCode,
        abi.encode(
          templ,
          approvalThresholdBps,
          quorumBps,
          executionDelay,
          votingPeriod,
          immediateExecutionBps,
          proposalFeeBps,
          council
        )
      )
    );
    return address(
      uint160(
        uint256(
          keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)
          )
        )
      )
    );
  }
}
