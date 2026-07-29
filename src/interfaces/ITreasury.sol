// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IExecutable } from "./IExecutable.sol";

/// @title ITreasury
/// @notice Passive vault holding the treasury slice of every paid join.
/// @dev Treasury keeps custody of its slice, the FACTORY/TOKEN immutables, the
///      one-shot Templ / MemberPool wiring used at deploy, and the
///      governance-only `dissolve` escape hatch that forwards the entire
///      balance to MemberPool. The protocol's splitting rules live on Templ.
///
///      The programmable-vault surface (`execute`, `onERC721Received`, the
///      `Executed` event, `ExecuteFailed`/`NotGovernance` errors, and native
///      ETH `receive`) is inherited from `IExecutable`. Treasury's runtime ABI
///      includes those entries via inheritance; Solidity tests reach the
///      selectors through `IExecutable`.
interface ITreasury is IExecutable {
  // ============ Events ============

  /// @notice Emitted when governance sends the full Treasury balance to
  ///         MemberPool. The pool re-measures and folds the delta on the
  ///         next paid join.
  event TreasuryDissolved(address indexed templ, uint256 amount);

  event TemplSet(address indexed templ);
  event MemberPoolSet(address indexed memberPool);

  // ============ Errors ============

  error NotDeployer();
  error AlreadyInitialized();
  error NotInitialized();
  /// @notice `setTempl` was called with the zero address.
  error ZeroTempl();
  /// @notice `setMemberPool` was called with the zero address.
  error ZeroMemberPool();
  /// @notice `dissolve()` reverts with this when there is nothing to forward.
  error EmptyTreasury();

  // ============ Views ============
  // SCREAMING_SNAKE_CASE marks "morally immutable" storage: TOKEN/FACTORY have
  // no setter, TEMPL/MEMBER_POOL each have a one-shot initializer that reverts
  // after first call. See Treasury.sol storage block for the full rationale.

  /// @notice ERC20 token used for all fee operations
  function TOKEN() external view returns (address);

  /// @notice The Factory that deployed this Treasury
  function FACTORY() external view returns (address);

  /// @notice The linked Templ membership contract
  function TEMPL() external view returns (address);

  /// @notice The linked MemberPool contract (where dissolve forwards funds)
  function MEMBER_POOL() external view returns (address);

  // ============ Init ============

  /// @notice One-time: connect to the Templ contract
  /// @param _templ Address of the Templ membership contract
  function setTempl(
    address _templ
  ) external;

  /// @notice One-time: connect to the MemberPool contract
  /// @param _memberPool Address of the MemberPool contract
  function setMemberPool(
    address _memberPool
  ) external;

  // ============ Governance ============

  /// @notice Send the entire Treasury TOKEN balance to MemberPool. The pool's
  ///         next paid join folds the delta into that round's distribution.
  function dissolve() external;
}
