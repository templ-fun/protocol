// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IExecutable } from "../interfaces/IExecutable.sol";
import {
  ReentrancyGuardTransient
} from "solady/utils/ReentrancyGuardTransient.sol";

/// @title Executable
/// @notice Programmable-vault primitive: governance can forward an arbitrary
///         call from this contract's address. Subclasses provide the
///         governance check by overriding `_checkGovernance`.
/// @dev Combines the executor surface with native-asset receivers so any
///      contract that mixes this in can custody and move ETH, ERC-20, and
///      ERC-721 assets through governance proposals. The event, errors, and
///      function signatures live on `IExecutable`; concrete interfaces extend
///      it so the runtime ABI on Treasury and Templ keeps `Executed`,
///      `ExecuteFailed`, `execute`, `onERC721Received`, and `receive` without
///      duplicating their declarations.
abstract contract Executable is IExecutable, ReentrancyGuardTransient {
  modifier onlyGovernance() {
    _checkGovernance();
    _;
  }

  /// @inheritdoc IExecutable
  /// @dev Runs in this contract's context, so positions taken sit in this
  ///      contract's name. Reverts surface the target's revert data via
  ///      `ExecuteFailed(returnData)` for off-chain decoding.
  function execute(
    address target,
    uint256 value,
    bytes calldata data
  ) external onlyGovernance nonReentrant returns (bytes memory result) {
    bool ok;
    (ok, result) = target.call{ value: value }(data);
    if (!ok) revert ExecuteFailed(result);
    emit Executed(target, value, data);
  }

  /// @notice Accept native ETH so governance can later move it via `execute`.
  receive() external payable { }

  /// @inheritdoc IExecutable
  /// @dev Pure since it neither reads nor writes state. Magic value:
  ///      bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")).
  function onERC721Received(
    address,
    address,
    uint256,
    bytes calldata
  ) external pure returns (bytes4) {
    return 0x150b7a02;
  }

  /// @dev Subclass-supplied governance check. Must revert if msg.sender is
  ///      not authorized, otherwise return.
  function _checkGovernance() internal view virtual;
}
