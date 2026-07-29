// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITempl } from "../../src/interfaces/ITempl.sol";
import { ITreasury } from "../../src/interfaces/ITreasury.sol";

interface IERC20Like {
  function balanceOf(
    address
  ) external view returns (uint256);
  function transfer(
    address,
    uint256
  ) external returns (bool);
}

/// @dev Malicious governance mock that drains the treasury during its own
///      emitConfig() callback. Pins the invariant that Templ.setGovernance
///      defers its storage write until after emitConfig() returns.
///
///      The attack path is Templ -> Treasury, not back into Templ, so
///      Templ's nonReentrant guard does not block it. Treasury reads the
///      current governance address dynamically via ITempl(templ).governance(),
///      so if Templ writes its `governance` storage before calling
///      emitConfig(), this contract is already recognised as governance
///      during the callback and execute() succeeds.
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
  ///      Drains the entire treasury TOKEN balance to `attacker` via
  ///      `execute(token, 0, transfer(attacker, balance))`.
  function emitConfig() external {
    ITreasury treasury = TEMPL.TREASURY();
    address token = treasury.TOKEN();
    uint256 available = IERC20Like(token).balanceOf(address(treasury));
    treasury.execute(
      token, 0, abi.encodeCall(IERC20Like.transfer, (attacker, available))
    );
  }
}
