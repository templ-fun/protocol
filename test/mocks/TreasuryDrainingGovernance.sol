// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITempl } from "../../src/interfaces/ITempl.sol";
import { ITreasury } from "../../src/interfaces/ITreasury.sol";

/// @dev Malicious governance mock that drains the treasury during its own
///      emitConfig() callback. Used as a regression guard for the deferred
///      storage write in Templ.setGovernance.
///
///      The attack path is Templ -> Treasury, not back into Templ, so
///      Templ's nonReentrant guard does not block it. Treasury reads the
///      current governance address dynamically via ITempl(templ).governance(),
///      so if Templ writes its `governance` storage before calling
///      emitConfig(), this contract is already recognised as governance
///      during the callback and withdraw() succeeds.
contract TreasuryDrainingGovernance {
  ITempl public immutable TEMPL;
  address public attacker;

  constructor(
    address _templ,
    address _attacker
  ) {
    TEMPL = ITempl(_templ);
    attacker = _attacker;
  }

  /// @dev Called by Templ.setGovernance() after the new governance is wired in.
  ///      Drains all available treasury funds to `attacker` in the same tx.
  function emitConfig() external {
    ITreasury treasury = TEMPL.TREASURY();
    uint256 available = treasury.treasuryBalance();
    treasury.withdraw(attacker, available);
  }
}
