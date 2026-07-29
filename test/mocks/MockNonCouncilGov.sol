// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Governance stand-in that does NOT expose `isCouncilMember`, so the
///      factory's try/catch falls through to the deny branch. The absence of
///      that selector is the behaviour under test.
contract MockNonCouncilGov { }
