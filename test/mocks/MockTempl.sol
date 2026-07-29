// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal Templ stand-in for plugin tests. Exposes only the views
///      plugins read: TREASURY, priest, governance, isMember. Not for
///      production use.
contract MockTempl {
  // forge-lint: disable-next-line(mixed-case-variable)
  address public TREASURY;

  address public priest;
  address public governance;
  mapping(address => bool) public isMember;

  constructor(
    address _treasury
  ) {
    TREASURY = _treasury;
  }

  function setPriest(
    address _priest
  ) external {
    priest = _priest;
  }

  function setGovernance(
    address _governance
  ) external {
    governance = _governance;
  }

  function setMember(
    address account,
    bool member
  ) external {
    isMember[account] = member;
  }
}
