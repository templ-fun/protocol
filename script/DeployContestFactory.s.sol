// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
  LinkContestFactory
} from "../src/plugins/link-contest/LinkContestFactory.sol";
import { Script, console2 } from "forge-std/Script.sol";

/// @title DeployContestFactory
/// @notice Deploys the LinkContestFactory plugin contract.
/// @dev Run via `make deploy-contest-factory NETWORK=base`, which passes
///      `--verify` so Etherscan/Sourcify verify the factory automatically.
///      The factory has no constructor args, so the forge-script broadcast
///      verifies it directly. Contests the factory deploys share identical
///      runtime bytecode (LinkContest uses no `immutable`), so verifying one
///      created instance once (`make verify-contest`) matches every future
///      contest. The deployer EOA only signs the deploy; it holds no role on
///      the factory. `createContest` is gated on-chain to the templ's priest
///      and, for council-governed templs, council members.
contract DeployContestFactory is Script {
  function run() external returns (address factory) {
    uint256 deployerKey = vm.envUint("PRIVATE_KEY");

    vm.startBroadcast(deployerKey);
    factory = address(new LinkContestFactory());
    vm.stopBroadcast();

    console2.log("LinkContestFactory deployed:", factory);
  }
}
