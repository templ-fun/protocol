// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";

/// @dev Sign ERC-2612 permits in Foundry tests.
///      Reconstructs the EIP-712 digest that a standard ERC-2612 token hashes
///      inside its `permit()` function, then signs it with vm.sign.
contract ERC2612Helper is CommonBase {
  bytes32 internal constant _PERMIT_TYPEHASH = keccak256(
    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
  );

  /// @dev Build and sign an ERC-2612 permit
  function signERC2612Permit(
    address token,
    address owner,
    address spender,
    uint256 value,
    uint256 nonce,
    uint256 deadline,
    uint256 signerPrivateKey
  ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
    // Fetch the token's domain separator
    // solhint-disable-next-line avoid-low-level-calls
    (bool ok, bytes memory data) =
      token.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
    require(ok, "ERC2612Helper: DOMAIN_SEPARATOR() failed");
    bytes32 domainSeparator = abi.decode(data, (bytes32));

    bytes32 structHash = keccak256(
      abi.encode(_PERMIT_TYPEHASH, owner, spender, value, nonce, deadline)
    );

    bytes32 digest =
      keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

    (v, r, s) = vm.sign(signerPrivateKey, digest);
  }
}
