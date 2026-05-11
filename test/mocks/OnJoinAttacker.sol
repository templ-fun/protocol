// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IMemberPool } from "../../src/interfaces/IMemberPool.sol";

/// @dev Attacker contract that tries to call MemberPool.onJoin directly from
///      a tokensReceived hook. Used to verify that the onlyTempl gate plus
///      the transient nonReentrant guard combine to block any path to a
///      second onJoin within a single legitimate join. msg.sender during the
///      reentrant attempt is this contract (not templ), so onJoin reverts
///      with NotTempl.
contract OnJoinAttacker {
  IMemberPool public immutable POOL;
  bool public attackPrimed;
  bool public attackFired;
  bool public attackSucceeded;

  constructor(
    address pool
  ) {
    POOL = IMemberPool(pool);
  }

  function prime() external {
    attackPrimed = true;
    attackFired = false;
    attackSucceeded = false;
  }

  function tokensReceived(
    address, /* from */
    uint256 /* amount */
  ) external {
    if (!attackPrimed) return;
    attackPrimed = false;
    attackFired = true;

    try POOL.onJoin(1, address(this), 1) {
      attackSucceeded = true;
    } catch {
      // Expected: onlyTempl reverts with NotTempl.
    }
  }
}
