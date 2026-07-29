// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal Council stand-in that exposes `isCouncilMember(address)`,
///      the selector LinkContestFactory probes via try/catch.
contract MockCouncil {
  mapping(address => bool) public isCouncilMember;

  function setCouncilMember(
    address account,
    bool member
  ) external {
    isCouncilMember[account] = member;
  }
}
