// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Council } from "../../governance/Council.sol";
import { ITempl } from "../../interfaces/ITempl.sol";
import { LinkContest } from "./LinkContest.sol";

/// @title LinkContestFactory
/// @notice Deployer for LinkContest plugins. Emits a creation event the indexer
///         subscribes to (Envio `contractRegister`) so each per-templ contest
///         is auto-discovered. Gated to the templ's priest and, on
///         council-governed templs, council members.
contract LinkContestFactory {
  /// @notice Reverts when the caller is neither the templ's priest nor a
  ///         council member of a council-governed templ.
  error NotAuthorized();

  /// @notice Emitted when a LinkContest is deployed. This is the discovery
  ///         hook the indexer subscribes to.
  /// @param contest Address of the deployed LinkContest
  /// @param templ Templ the contest is attached to
  /// @param token ERC20 token used for submission fees
  /// @param submissionFee Fee paid by each submission
  /// @param roundDuration Round length in seconds
  /// @param firstRoundStart Unix timestamp round 0 begins
  event LinkContestCreated(
    address indexed contest,
    address indexed templ,
    address token,
    uint256 submissionFee,
    uint256 roundDuration,
    uint256 firstRoundStart
  );

  /// @notice Deploy a LinkContest for a templ and announce it for indexing.
  /// @dev Caller must be the templ's current priest or, when governance is
  ///      Council, a council member. Other governance types (Democracy,
  ///      Quadratic, Elders) restrict deploys to the priest only - broaden
  ///      later if there is demand. The `owner_` parameter (the contest
  ///      judge) is unrestricted: any address may be designated once past
  ///      the gate.
  /// @param templ Templ membership contract the contest attaches to
  /// @param token ERC20 token used for submission fees
  /// @param submissionFee Amount each submission pays
  /// @param roundDuration Round length in seconds
  /// @param firstRoundStart Unix timestamp round 0 begins (calendar anchor)
  /// @param owner_ The judge; typically the priest
  /// @return contest Address of the deployed LinkContest
  function createContest(
    address templ,
    address token,
    uint256 submissionFee,
    uint256 roundDuration,
    uint256 firstRoundStart,
    address owner_
  ) external returns (address contest) {
    if (!_canDeploy(templ, msg.sender)) revert NotAuthorized();

    contest = address(
      new LinkContest(
        templ, token, submissionFee, roundDuration, firstRoundStart, owner_
      )
    );

    emit LinkContestCreated(
      contest, templ, token, submissionFee, roundDuration, firstRoundStart
    );
  }

  /// @dev Priest always passes. Council membership is probed via try/catch:
  ///      `isCouncilMember` is unique to Council among current governance
  ///      types, so the call reverts for Democracy / Quadratic / Elders and
  ///      the fallback denies. Adding a public `governanceType()` getter to
  ///      Governance is tracked in #461 and would replace this probe.
  function _canDeploy(
    address templ,
    address account
  ) internal view returns (bool) {
    if (account == ITempl(templ).priest()) return true;

    address gov = ITempl(templ).governance();
    if (gov == address(0)) return false;

    try Council(payable(gov)).isCouncilMember(account) returns (bool ok) {
      return ok;
    } catch {
      return false;
    }
  }
}
