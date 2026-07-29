// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IExecutable
/// @notice Programmable-vault surface: a governance-only `execute` plus the
///         native-asset receivers needed to custody ETH and ERC-721s.
/// @dev Shared by every contract that mixes in `abstracts/Executable.sol`.
///      Concrete interfaces (e.g. ITreasury, ITempl) extend this so the event
///      and error remain reachable as `IConcrete.Executed` / `IConcrete.ExecuteFailed`
///      from off-chain consumers and tests, while the base contract owns the
///      single implementation.
interface IExecutable {
  /// @notice Emitted on every successful `execute` call. `data` is the raw
  ///         calldata governance forwarded; consumers decode it client-side.
  event Executed(address indexed target, uint256 value, bytes data);

  /// @notice `execute()` reverts with the target's raw return data on failure.
  error ExecuteFailed(bytes returnData);
  /// @notice Reverts when the caller is not the configured governance address.
  error NotGovernance();

  /// @notice Run an arbitrary call from this contract's context.
  /// @param target Address to call
  /// @param value Native ETH to attach
  /// @param data Encoded call data
  /// @return result Raw return data from the target call
  function execute(
    address target,
    uint256 value,
    bytes calldata data
  ) external returns (bytes memory result);

  /// @notice ERC-721 receiver hook so safeTransferFrom into this contract
  ///         succeeds. Returns the magic value defined by ERC-721.
  function onERC721Received(
    address operator,
    address from,
    uint256 tokenId,
    bytes calldata data
  ) external returns (bytes4);
}
