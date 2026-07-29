// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "solady/tokens/ERC20.sol";

/// @dev ERC-20 mock with ERC-2612 permit support (via Solady).
///      Not for production use.
contract MockERC20Permit is ERC20 {
  function name() public pure override returns (string memory) {
    return "Mock Permit Token";
  }

  function symbol() public pure override returns (string memory) {
    return "MOCKP";
  }

  function mint(
    address to,
    uint256 amount
  ) external {
    _mint(to, amount);
  }
}
