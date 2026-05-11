// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Executable } from "./abstracts/Executable.sol";
import { ITempl } from "./interfaces/ITempl.sol";
import { ITreasury } from "./interfaces/ITreasury.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @title Treasury
/// @notice Programmable vault holding the treasury slice of every paid join.
/// @dev Treasury exposes a generic `execute(target, value, data)` surface that
///      governance uses to move TOKEN, ETH, ERC-721s, or any other asset that
///      lands here, including DeFi positions taken in Treasury's own name. It
///      also accepts ETH via `receive()` and NFTs via `onERC721Received`, so
///      anything that can be sent to an address can be parked here and later
///      moved by governance through `execute`.
///
///      Treasury is a minimal vault: a custody surface plus the
///      governance-only `dissolve` escape hatch that forwards the entire
///      balance to MemberPool. The protocol's splitting rules live on Templ;
///      Treasury simply receives its slice and holds it.
///
///      Topology guarantee: Treasury never holds member-pool TOKEN. The
///      member-pool slice is delivered directly to MemberPool by Templ, so the
///      treasury and member-pool custody boundaries are address-level.
contract Treasury is ITreasury, Executable {
  // ============ Set once in constructor / one-shot init ============
  // Not marked `immutable` so all instances share identical runtime bytecode,
  // enabling auto-verification on Etherscan/Sourcify after a single verified
  // deployment. Gas difference is negligible on L2s.
  //
  // TOKEN and FACTORY have no setter and are effectively immutable. TEMPL and
  // MEMBER_POOL each have a one-shot initializer callable only by FACTORY
  // (reverts after first call via AlreadyInitialized) and are also effectively
  // immutable once wired. All four use SCREAMING_SNAKE_CASE to signal that
  // "morally immutable" intent at the call site. The lint exemption below is
  // scoped to this block alone.

  // forge-lint: disable-start(mixed-case-variable)
  address public override TOKEN;
  address public override FACTORY;
  address public override TEMPL;
  address public override MEMBER_POOL;

  // forge-lint: disable-end(mixed-case-variable)

  // ============ Constructor ============

  /// @param _token ERC20 token used for all fee operations
  constructor(
    address _token
  ) {
    FACTORY = msg.sender;
    TOKEN = _token;
  }

  // ============ Init ============

  /// @inheritdoc ITreasury
  function setTempl(
    address _templ
  ) external override {
    if (msg.sender != FACTORY) revert NotDeployer();
    if (TEMPL != address(0)) revert AlreadyInitialized();
    if (_templ == address(0)) revert ZeroTempl();
    TEMPL = _templ;
    emit TemplSet(_templ);
  }

  /// @inheritdoc ITreasury
  function setMemberPool(
    address _memberPool
  ) external override {
    if (msg.sender != FACTORY) revert NotDeployer();
    if (MEMBER_POOL != address(0)) revert AlreadyInitialized();
    if (_memberPool == address(0)) revert ZeroMemberPool();
    MEMBER_POOL = _memberPool;
    emit MemberPoolSet(_memberPool);
  }

  // ============ Governance ============

  /// @inheritdoc ITreasury
  /// @dev Sends the entire treasury TOKEN balance to MemberPool. The pool's
  ///      next `onJoin` re-measures balance and folds the delta into that
  ///      round's distribution. Dissolve does NOT call any function on
  ///      MemberPool; the transfer is the protocol-level signal.
  ///      If no future paid joins occur, the dissolved funds are stranded in
  ///      MemberPool by design - this preserves the no-admin invariant on the
  ///      pool. Governance can avoid stranding by routing funds elsewhere
  ///      with `execute` before calling dissolve.
  function dissolve() external override onlyGovernance nonReentrant {
    address pool = MEMBER_POOL;
    if (pool == address(0)) revert NotInitialized();

    uint256 balance = _tokenBalance();
    if (balance == 0) revert EmptyTreasury();

    SafeTransferLib.safeTransfer(TOKEN, pool, balance);

    emit TreasuryDissolved(TEMPL, balance);
  }

  // ============ Internal ============

  function _checkGovernance() internal view override {
    if (msg.sender != ITempl(TEMPL).governance()) revert NotGovernance();
  }

  function _tokenBalance() internal view returns (uint256) {
    return SafeTransferLib.balanceOf(TOKEN, address(this));
  }
}
