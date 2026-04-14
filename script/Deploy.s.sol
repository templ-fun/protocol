// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CouncilDeployer } from "../src/CouncilDeployer.sol";
import { DemocracyDeployer } from "../src/DemocracyDeployer.sol";
import { Factory } from "../src/Factory.sol";
import { GovernanceDeployer } from "../src/GovernanceDeployer.sol";
import { Script, console2 } from "forge-std/Script.sol";

/// @title Deploy
/// @notice Deploys DemocracyDeployer + CouncilDeployer + GovernanceDeployer + Factory
///         deterministically via CREATE2.
/// @dev Uses the Deterministic Deployment Proxy (0x4e59b44847b379578588920cA78FbF26c0B4956C)
///      which exists at the same address on all major EVM chains.
///      Same salt + same bytecode = same addresses on every chain.
contract Deploy is Script {
  /// @dev Pre-deployed on all major EVM chains
  address constant DETERMINISTIC_DEPLOYER =
    0x4e59b44847b379578588920cA78FbF26c0B4956C;

  /// @dev Bump this when redeploying (e.g. after a bug fix).
  ///      Salt 25 is the current staging Factory (Base + Arbitrum).
  ///      Salt 26 is the current production Factory (Base only).
  bytes32 constant DEPLOY_SALT = bytes32(uint256(26));

  function run() external {
    // Resolve the deployer EOA up front so it can be baked into the Factory
    // init code as the explicit `_initialOwner`. Without this, msg.sender
    // inside the Factory constructor would be the deterministic deployment
    // proxy and the Factory would be permanently un-owned.
    uint256 deployerKey = vm.envUint("PRIVATE_KEY");
    address deployerAddress = vm.addr(deployerKey);

    // 1. Compute DemocracyDeployer address
    bytes memory demInitCode =
      abi.encodePacked(type(DemocracyDeployer).creationCode);
    address expectedDem =
      _computeCreate2Address(DEPLOY_SALT, keccak256(demInitCode));

    // 2. Compute CouncilDeployer address
    bytes memory councilInitCode =
      abi.encodePacked(type(CouncilDeployer).creationCode);
    address expectedCouncil =
      _computeCreate2Address(DEPLOY_SALT, keccak256(councilInitCode));

    // 3. Compute GovernanceDeployer address (needs both sub-deployer addresses)
    bytes memory govInitCode = abi.encodePacked(
      type(GovernanceDeployer).creationCode,
      abi.encode(expectedDem, expectedCouncil)
    );
    address expectedGov =
      _computeCreate2Address(DEPLOY_SALT, keccak256(govInitCode));

    // 4. Compute Factory address (needs the deployer EOA + GovernanceDeployer address)
    bytes memory factoryInitCode = abi.encodePacked(
      type(Factory).creationCode, abi.encode(deployerAddress, expectedGov, true)
    );
    address expectedFactory =
      _computeCreate2Address(DEPLOY_SALT, keccak256(factoryInitCode));

    console2.log("Salt:", uint256(DEPLOY_SALT));
    console2.log("Deployer (initial owner):", deployerAddress);
    console2.log("Expected DemocracyDeployer:", expectedDem);
    console2.log("Expected CouncilDeployer:", expectedCouncil);
    console2.log("Expected GovernanceDeployer:", expectedGov);
    console2.log("Expected Factory:", expectedFactory);

    // Skip if Factory already deployed on this chain
    if (expectedFactory.code.length > 0) {
      console2.log("Already deployed at expected address, skipping");
      console2.log("Bump DEPLOY_SALT to deploy a new instance");
      return;
    }

    vm.startBroadcast(deployerKey);

    // Deploy DemocracyDeployer
    if (expectedDem.code.length == 0) {
      (bool demSuccess,) = DETERMINISTIC_DEPLOYER.call(
        abi.encodePacked(DEPLOY_SALT, demInitCode)
      );
      require(demSuccess, "DemocracyDeployer CREATE2 deploy failed");
      require(
        expectedDem.code.length > 0, "DemocracyDeployer not at expected address"
      );
      console2.log("DemocracyDeployer deployed:", expectedDem);
    } else {
      console2.log("DemocracyDeployer already deployed:", expectedDem);
    }

    // Deploy CouncilDeployer
    if (expectedCouncil.code.length == 0) {
      (bool councilSuccess,) = DETERMINISTIC_DEPLOYER.call(
        abi.encodePacked(DEPLOY_SALT, councilInitCode)
      );
      require(councilSuccess, "CouncilDeployer CREATE2 deploy failed");
      require(
        expectedCouncil.code.length > 0,
        "CouncilDeployer not at expected address"
      );
      console2.log("CouncilDeployer deployed:", expectedCouncil);
    } else {
      console2.log("CouncilDeployer already deployed:", expectedCouncil);
    }

    // Deploy GovernanceDeployer (router)
    if (expectedGov.code.length == 0) {
      (bool govSuccess,) = DETERMINISTIC_DEPLOYER.call(
        abi.encodePacked(DEPLOY_SALT, govInitCode)
      );
      require(govSuccess, "GovernanceDeployer CREATE2 deploy failed");
      require(
        expectedGov.code.length > 0,
        "GovernanceDeployer not at expected address"
      );
      console2.log("GovernanceDeployer deployed:", expectedGov);
    } else {
      console2.log("GovernanceDeployer already deployed:", expectedGov);
    }

    // Deploy Factory
    (bool factorySuccess,) = DETERMINISTIC_DEPLOYER.call(
      abi.encodePacked(DEPLOY_SALT, factoryInitCode)
    );
    require(factorySuccess, "Factory CREATE2 deploy failed");

    // Lock down the access control chain so only Factory -> GovernanceDeployer
    // -> sub-deployers can trigger CREATE2 governance deploys.
    CouncilDeployer(expectedCouncil).setGovernanceDeployer(expectedGov);
    DemocracyDeployer(expectedDem).setGovernanceDeployer(expectedGov);
    GovernanceDeployer(expectedGov).setFactory(expectedFactory);

    vm.stopBroadcast();

    require(expectedFactory.code.length > 0, "Factory not at expected address");
    console2.log("Factory deployed:", expectedFactory);
  }

  function _computeCreate2Address(
    bytes32 salt,
    bytes32 initCodeHash
  ) internal pure returns (address) {
    return address(
      uint160(
        uint256(
          keccak256(
            abi.encodePacked(
              bytes1(0xff), DETERMINISTIC_DEPLOYER, salt, initCodeHash
            )
          )
        )
      )
    );
  }
}
