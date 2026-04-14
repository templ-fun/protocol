// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IGovernance } from "../../src/interfaces/IGovernance.sol";

/// @dev Malicious callback target that re-enters Governance.vote()
///      when called during execute()'s batch. Used to verify that
///      vote's nonReentrant guard blocks cross-function reentrancy.
contract ReentrantVoter {
  IGovernance public immutable GOV;
  uint256 public targetProposalId;
  bool public attacked;

  constructor(
    address _gov
  ) {
    GOV = IGovernance(_gov);
  }

  function arm(
    uint256 _proposalId
  ) external {
    targetProposalId = _proposalId;
  }

  /// @dev Called by execute()'s batch - tries to re-enter vote().
  ///      No receive() function - payable fallback intentionally catches
  ///      all calls including those with empty calldata.
  fallback() external payable {
    if (targetProposalId != 0) {
      attacked = true;
      // Should revert with Reentrancy() due to shared guard
      GOV.vote(targetProposalId, 0);
    }
  }
}
