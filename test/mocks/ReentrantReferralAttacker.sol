// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IMemberPool } from "../../src/interfaces/IMemberPool.sol";

/// @dev Attacker contract that probes a cross-contract reentrancy path:
///
///      1. Registers as a member (legitimately joining the Templ once).
///      2. Becomes the `referral` for a fresh attacker-controlled address `E`.
///      3. When the splitter transfers the referral slice to this contract,
///         the hook-bearing TOKEN fires `tokensReceived` synchronously.
///      4. From inside the hook, this contract calls
///         `MemberPool.claimRewards(E)` while `rewardSnapshot[E] == 0` and
///         `cumulativeRewards == X > 0`. Without the defense, this would
///         drain X tokens to E.
///
///      Templ pins `rewardSnapshot[E] = cumulativeRewards` BEFORE the
///      referral transfer, so the reentrant claim sees
///      `snapshot >= cumulative` and reverts with NoRewardsToClaim.
contract ReentrantReferralAttacker {
  IMemberPool public immutable POOL;
  address public claimTarget;
  bool public attackPrimed;

  /// @notice Set to true if a reentrant claim was attempted (regardless of
  ///         whether it succeeded). Used by the test to confirm the attack
  ///         path actually fired.
  bool public attackFired;

  /// @notice Set to true if a reentrant claim succeeded (transferred any
  ///         tokens). Used by the test to confirm the defense.
  bool public attackSucceeded;

  constructor(
    address pool
  ) {
    POOL = IMemberPool(pool);
  }

  /// @notice Arm the attacker for the next inbound transfer hook.
  /// @param target The address whose pending rewards we try to drain - this
  ///        is the freshly-joined attacker EOA.
  function primeAttack(
    address target
  ) external {
    claimTarget = target;
    attackPrimed = true;
    attackFired = false;
    attackSucceeded = false;
  }

  /// @notice ERC777-style callback invoked by HookERC20.transfer when this
  ///         contract is the recipient.
  function tokensReceived(
    address, /* from */
    uint256 /* amount */
  ) external {
    if (!attackPrimed) return;
    attackPrimed = false;
    attackFired = true;

    address target = claimTarget;
    try POOL.claimRewards(target) {
      attackSucceeded = true;
    } catch {
      // Swallow revert - the test asserts on attackSucceeded.
    }
  }
}
