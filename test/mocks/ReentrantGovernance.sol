// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITempl } from "../../src/interfaces/ITempl.sol";

/// @dev Malicious governance mock that re-enters Templ.setGovernance()
///      during emitConfig(). Used to verify nonReentrant protection.
contract ReentrantGovernance {
  ITempl public immutable TEMPL;
  address public reentryTarget;
  bool public attacked;

  constructor(
    address _templ
  ) {
    TEMPL = ITempl(_templ);
  }

  /// @dev Set the address to pass into the reentrant setGovernance call
  function arm(
    address _reentryTarget
  ) external {
    reentryTarget = _reentryTarget;
  }

  /// @dev Called by Templ.setGovernance() after governance is updated.
  ///      Attempts to re-enter setGovernance() while already inside it.
  function emitConfig() external {
    if (reentryTarget != address(0)) {
      attacked = true;
      // This should revert with Reentrancy() if the guard is active
      TEMPL.setGovernance(reentryTarget);
    }
  }
}
