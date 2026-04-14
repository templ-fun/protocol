// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC2612
/// @notice Minimal interface for ERC-2612 permit (EIP-2612).
///         Tokens implementing this allow gasless approvals via off-chain signatures.
interface IERC2612 {
  function permit(
    address owner,
    address spender,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external;

  function nonces(
    address owner
  ) external view returns (uint256);

  // solhint-disable-next-line func-name-mixedcase
  function DOMAIN_SEPARATOR() external view returns (bytes32);
}
