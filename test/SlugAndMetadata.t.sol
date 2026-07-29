// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CouncilDeployer } from "../src/CouncilDeployer.sol";
import { DemocracyDeployer } from "../src/DemocracyDeployer.sol";
import { Factory } from "../src/Factory.sol";
import { GovernanceDeployer } from "../src/GovernanceDeployer.sol";
import { Templ } from "../src/Templ.sol";
import { IExecutable } from "../src/interfaces/IExecutable.sol";
import {
  CreateConfig,
  GovMode,
  GovernanceConfig,
  IFactory
} from "../src/interfaces/IFactory.sol";
import { ITempl } from "../src/interfaces/ITempl.sol";
import { CurveConfig, EntryFeeCurve } from "../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { Test } from "forge-std/Test.sol";

contract SlugAndMetadataTest is Test {
  Factory public factory;
  MockERC20 public token;

  address public protocolRecipient = makeAddr("protocol");
  address public creator = makeAddr("creator");

  uint256 public constant PROTOCOL_FEE_BPS = 1000;
  uint256 public constant BASE_ENTRY_FEE = 1000e18;

  // Sensible explicit values used by the test fixture. The Factory does not
  // substitute defaults, so every test config provides these explicitly.
  function _sensibleGov() internal pure returns (GovernanceConfig memory) {
    return GovernanceConfig({
      mode: GovMode.Democracy,
      approvalThresholdBps: 5100,
      quorumBps: 1000,
      votingPeriod: 3 days,
      executionDelay: 1 days,
      immediateExecutionBps: 10_000,
      proposalFeeBps: 2500,
      council: new address[](0)
    });
  }

  function _sensibleCurve() internal pure returns (CurveConfig memory) {
    return EntryFeeCurve.exponentialWithTail(10_050, 500);
  }

  function _createConfig(
    string memory slug
  ) internal view returns (CreateConfig memory) {
    return CreateConfig({
      token: address(token),
      baseEntryFee: BASE_ENTRY_FEE,
      slug: slug,
      name: "Test Templ",
      description: "A test templ",
      logoLink: "https://example.com/logo.png",
      burnBps: 3000,
      treasuryBps: 3000,
      memberPoolBps: 3000,
      referralShareBps: 2500,
      curve: _sensibleCurve(),
      governance: _sensibleGov()
    });
  }

  function setUp() public {
    DemocracyDeployer demDeployer = new DemocracyDeployer(address(this));
    CouncilDeployer councilDeployer = new CouncilDeployer(address(this));
    GovernanceDeployer govDeployer = new GovernanceDeployer(
      address(demDeployer), address(councilDeployer), address(this)
    );
    factory = new Factory(address(this), address(govDeployer), true);

    councilDeployer.setGovernanceDeployer(address(govDeployer));
    demDeployer.setGovernanceDeployer(address(govDeployer));
    govDeployer.setFactory(address(factory));

    token = new MockERC20();
  }

  // ============ Slug Validation ============

  function test_slug_createAndLookup() public {
    vm.startPrank(creator);

    // Valid slug with hyphens and digits
    address templ = factory.createTempl(_createConfig("the-wormhole-42"));
    assertEq(factory.slugToTempl("the-wormhole-42"), templ);
    assertEq(factory.templSlug(templ), "the-wormhole-42");

    // Boundary: single char and max length (64 chars)
    factory.createTempl(_createConfig("x"));
    factory.createTempl(
      _createConfig(
        "abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghij"
      )
    );

    vm.stopPrank();
  }

  function test_slug_rejectsInvalidFormats() public {
    vm.startPrank(creator);

    // Empty
    vm.expectRevert(IFactory.InvalidSlug.selector);
    factory.createTempl(_createConfig(""));

    // Uppercase
    vm.expectRevert(IFactory.InvalidSlug.selector);
    factory.createTempl(_createConfig("The-Wormhole"));

    // Space
    vm.expectRevert(IFactory.InvalidSlug.selector);
    factory.createTempl(_createConfig("the wormhole"));

    // Leading/trailing hyphens
    vm.expectRevert(IFactory.InvalidSlug.selector);
    factory.createTempl(_createConfig("-wormhole"));

    vm.expectRevert(IFactory.InvalidSlug.selector);
    factory.createTempl(_createConfig("wormhole-"));

    // Consecutive hyphens
    vm.expectRevert(IFactory.InvalidSlug.selector);
    factory.createTempl(_createConfig("the--wormhole"));

    // Too long (65 chars)
    vm.expectRevert(IFactory.InvalidSlug.selector);
    factory.createTempl(
      _createConfig(
        "abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijk"
      )
    );

    vm.stopPrank();
  }

  function test_slug_enforceUniqueness() public {
    vm.startPrank(creator);
    factory.createTempl(_createConfig("taken"));

    vm.expectRevert(IFactory.SlugTaken.selector);
    factory.createTempl(_createConfig("taken"));
    vm.stopPrank();
  }

  // ============ Update Slug ============

  function test_updateSlug_success() public {
    vm.prank(creator);
    address templ = factory.createTempl(_createConfig("old-slug"));
    address governance = Templ(payable(templ)).governance();

    vm.expectEmit(true, false, false, true);
    emit IFactory.SlugUpdated(templ, "old-slug", "new-slug");

    vm.prank(governance);
    factory.updateSlug(templ, "new-slug");

    assertEq(factory.slugToTempl("new-slug"), templ);
    assertEq(factory.slugToTempl("old-slug"), address(0));
    assertEq(factory.templSlug(templ), "new-slug");
  }

  function test_updateSlug_accessControl() public {
    // Not a registered templ
    vm.prank(makeAddr("random"));
    vm.expectRevert(IFactory.NotRegisteredTempl.selector);
    factory.updateSlug(makeAddr("fake"), "new-slug");

    // Not governance
    vm.prank(creator);
    address templ = factory.createTempl(_createConfig("my-slug"));

    vm.prank(makeAddr("random"));
    vm.expectRevert(IFactory.NotGovernance.selector);
    factory.updateSlug(templ, "hacked");
  }

  function test_updateSlug_validationAndUniqueness() public {
    vm.startPrank(creator);
    address templ1 = factory.createTempl(_createConfig("slug-one"));
    factory.createTempl(_createConfig("slug-two"));
    vm.stopPrank();

    address governance = Templ(payable(templ1)).governance();

    // Invalid format
    vm.prank(governance);
    vm.expectRevert(IFactory.InvalidSlug.selector);
    factory.updateSlug(templ1, "UPPERCASE");

    // Already taken
    vm.prank(governance);
    vm.expectRevert(IFactory.SlugTaken.selector);
    factory.updateSlug(templ1, "slug-two");
  }

  // ============ Metadata ============

  function test_updateMetadata_emitsEvent() public {
    vm.prank(creator);
    address templ = factory.createTempl(_createConfig("meta-test"));
    address governance = Templ(payable(templ)).governance();

    vm.expectEmit(false, false, false, true);
    emit ITempl.MetadataUpdated("New Name", "New desc", "https://new.logo");

    vm.prank(governance);
    Templ(payable(templ))
      .updateMetadata("New Name", "New desc", "https://new.logo");
  }

  function test_updateMetadata_onlyGovernance() public {
    vm.prank(creator);
    address templ = factory.createTempl(_createConfig("meta-test-2"));

    vm.prank(makeAddr("random"));
    vm.expectRevert(IExecutable.NotGovernance.selector);
    Templ(payable(templ)).updateMetadata("Hacked", "Hacked", "Hacked");
  }
}
