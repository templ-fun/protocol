// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IWETH
/// @notice Minimal interface for Wrapped Native tokens (WETH, WBNB, WMATIC, etc.)
/// @dev All major wrapped native tokens implement this same interface
interface IWETH {
  /// @notice Wrap native tokens into the ERC20 wrapper
  function deposit() external payable;

  /// @notice Unwrap ERC20 tokens back to native tokens
  /// @param amount Amount to unwrap
  function withdraw(
    uint256 amount
  ) external;

  /// @notice Approve a spender to transfer tokens
  /// @param spender Address authorized to spend
  /// @param amount Maximum amount the spender can transfer
  function approve(
    address spender,
    uint256 amount
  ) external returns (bool);

  /// @notice Query token balance
  /// @param account Address to query
  function balanceOf(
    address account
  ) external view returns (uint256);

  /// @notice Transfer tokens to a recipient
  /// @param to Recipient address
  /// @param amount Amount to transfer
  function transfer(
    address to,
    uint256 amount
  ) external returns (bool);
}
