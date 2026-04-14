// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "solady/tokens/ERC20.sol";

/// @dev Fee-on-transfer mock that burns a configurable tax on every
///      non-mint, non-burn transfer. Supports ERC-2612 permit via Solady's
///      ERC20 base so permit-based flows can be exercised.
///
///      Mirrors real FoT tokens: the sender is debited `amount`, the
///      recipient ends up with `amount - tax`, and the tax is burned to
///      `0xdead`. Not for production use.
contract FeeOnTransferERC20 is ERC20 {
  address internal constant _DEAD = 0x000000000000000000000000000000000000dEaD;

  uint256 public immutable TAX_BPS;
  bool private _taxing;

  constructor(
    uint256 _taxBps
  ) {
    require(_taxBps < 10_000, "tax too high");
    TAX_BPS = _taxBps;
  }

  function name() public pure override returns (string memory) {
    return "Fee On Transfer Mock";
  }

  function symbol() public pure override returns (string memory) {
    return "FOT";
  }

  function mint(
    address to,
    uint256 amount
  ) external {
    _mint(to, amount);
  }

  /// @dev After a normal transfer lands on `to`, immediately burn the tax
  ///      from `to`. Skips minting, burning, and reentrant calls from the
  ///      burn below so the tax is only applied once per user transfer.
  function _afterTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal override {
    if (_taxing) return;
    if (from == address(0) || to == address(0)) return;
    if (TAX_BPS == 0) return;

    uint256 tax = (amount * TAX_BPS) / 10_000;
    if (tax == 0) return;

    _taxing = true;
    _transfer(to, _DEAD, tax);
    _taxing = false;
  }
}
