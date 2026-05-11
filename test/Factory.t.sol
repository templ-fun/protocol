// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CouncilDeployer } from "../src/CouncilDeployer.sol";
import { DemocracyDeployer } from "../src/DemocracyDeployer.sol";
import { Factory } from "../src/Factory.sol";
import { GovernanceDeployer } from "../src/GovernanceDeployer.sol";
import { MemberPool } from "../src/MemberPool.sol";
import { Templ } from "../src/Templ.sol";
import { Treasury } from "../src/Treasury.sol";
import {
  CreateConfig,
  GovMode,
  GovernanceConfig,
  IFactory
} from "../src/interfaces/IFactory.sol";
import { IGovernance } from "../src/interfaces/IGovernance.sol";
import {
  CurveConfig,
  CurveSegment,
  CurveStyle,
  EntryFeeCurve
} from "../src/libraries/EntryFeeCurve.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { Test, Vm } from "forge-std/Test.sol";
import { Ownable } from "solady/auth/Ownable.sol";

contract FactoryTest is Test {
  Factory public factory;
  MockERC20 public token;

  address public protocolRecipient = makeAddr("protocol");
  address public creator = makeAddr("creator");
  address public user = makeAddr("user");

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
    address _token,
    uint256 fee,
    string memory slug
  ) internal pure returns (CreateConfig memory) {
    return _createConfigWithSlug(_token, fee, slug, slug);
  }

  function _createConfigWithSlug(
    address _token,
    uint256 fee,
    string memory name,
    string memory slug
  ) internal pure returns (CreateConfig memory) {
    return CreateConfig({
      token: _token,
      baseEntryFee: fee,
      slug: slug,
      name: name,
      description: "",
      logoLink: "",
      burnBps: 3000,
      treasuryBps: 3000,
      memberPoolBps: 3000,
      referralShareBps: 2500,
      curve: _sensibleCurve(),
      governance: _sensibleGov()
    });
  }

  /// @dev Creates a fresh deployer stack with the sub-deployers wired to the
  ///      GovernanceDeployer. Caller must still call `gd.setFactory(factory)`
  ///      after creating the Factory.
  function _newWiredGovernanceDeployer()
    internal
    returns (GovernanceDeployer gd)
  {
    DemocracyDeployer dd = new DemocracyDeployer(address(this));
    CouncilDeployer cd = new CouncilDeployer(address(this));
    gd = new GovernanceDeployer(address(dd), address(cd), address(this));
    cd.setGovernanceDeployer(address(gd));
    dd.setGovernanceDeployer(address(gd));
  }

  function setUp() public {
    DemocracyDeployer demDeployer = new DemocracyDeployer(address(this));
    CouncilDeployer councilDeployer = new CouncilDeployer(address(this));
    GovernanceDeployer govDeployer = new GovernanceDeployer(
      address(demDeployer), address(councilDeployer), address(this)
    );
    factory = new Factory(address(this), address(govDeployer), true);

    // Lock the access control chain
    councilDeployer.setGovernanceDeployer(address(govDeployer));
    demDeployer.setGovernanceDeployer(address(govDeployer));
    govDeployer.setFactory(address(factory));

    token = new MockERC20();
  }

  // ============ Constructor ============

  function test_constructor_setsDefaults() public view {
    // Deployer (this contract) is both owner and initial fee recipient
    assertEq(factory.protocolFeeRecipient(), address(this));
    assertEq(factory.PROTOCOL_FEE_BPS(), 1000);
    assertTrue(factory.isOpen());
  }

  /// @dev Indexers rely on genesis values arriving via events rather than
  ///      reading constructor args. The Factory must emit OpenUpdated and
  ///      ProtocolFeeRecipientUpdated during deployment.
  function test_constructor_emitsGenesisEvents() public {
    GovernanceDeployer gd = _newWiredGovernanceDeployer();
    address owner = makeAddr("owner");

    vm.expectEmit(true, true, true, true);
    emit IFactory.ProtocolFeeRecipientUpdated(owner);
    vm.expectEmit(true, true, true, true);
    emit IFactory.OpenUpdated(true);
    Factory deployed = new Factory(owner, address(gd), true);
    gd.setFactory(address(deployed));

    assertEq(deployed.protocolFeeRecipient(), owner);
    assertTrue(deployed.isOpen());
  }

  function test_constructor_emitsGenesisEvents_closedFactory() public {
    GovernanceDeployer gd = _newWiredGovernanceDeployer();
    address owner = makeAddr("owner");

    vm.expectEmit(true, true, true, true);
    emit IFactory.ProtocolFeeRecipientUpdated(owner);
    vm.expectEmit(true, true, true, true);
    emit IFactory.OpenUpdated(false);
    Factory deployed = new Factory(owner, address(gd), false);
    gd.setFactory(address(deployed));

    assertFalse(deployed.isOpen());
  }

  // ============ CreateTempl ============

  function test_createTempl_success() public {
    vm.prank(creator);
    address templ = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE, "test")
    );

    assertTrue(templ != address(0));
    assertEq(factory.templCount(), 1);
    assertEq(factory.getTempls()[0], templ);
  }

  function test_createTempl_setsPriestAsCaller() public {
    vm.prank(creator);
    address templ = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE, "test")
    );

    assertEq(Templ(payable(templ)).priest(), creator);
  }

  function test_createTempl_setsCorrectParams() public {
    vm.prank(creator);
    address templ = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE, "test")
    );

    assertEq(Templ(payable(templ)).TOKEN(), address(token));
    assertEq(Templ(payable(templ)).entryFee(), BASE_ENTRY_FEE);
    assertEq(Templ(payable(templ)).baseEntryFee(), BASE_ENTRY_FEE);
    assertEq(Templ(payable(templ)).priest(), creator);
    assertEq(Templ(payable(templ)).paidJoins(), 0);

    // Treasury is connected
    address treasuryAddr = address(Templ(payable(templ)).TREASURY());
    assertTrue(treasuryAddr != address(0));
  }

  function test_createTempl_customSplits() public {
    vm.prank(creator);
    address templ = factory.createTempl(
      CreateConfig({
        token: address(token),
        baseEntryFee: BASE_ENTRY_FEE,
        slug: "custom",
        name: "Custom",
        description: "",
        logoLink: "",
        burnBps: 5000,
        treasuryBps: 2000,
        memberPoolBps: 2000,
        referralShareBps: 2500,
        curve: _sensibleCurve(),
        governance: _sensibleGov()
      })
    );

    // Fee-split knobs live on Templ.
    Templ t = Templ(payable(templ));
    assertEq(t.burnBps(), 5000);
    assertEq(t.treasuryBps(), 2000);
    assertEq(t.memberPoolBps(), 2000);
  }

  function test_createTempl_customReferralShare() public {
    vm.prank(creator);
    address templ = factory.createTempl(
      CreateConfig({
        token: address(token),
        baseEntryFee: BASE_ENTRY_FEE,
        slug: "referral",
        name: "Referral",
        description: "",
        logoLink: "",
        burnBps: 3000,
        treasuryBps: 3000,
        memberPoolBps: 3000,
        referralShareBps: 5000,
        curve: _sensibleCurve(),
        governance: _sensibleGov()
      })
    );

    // referralShareBps lives on Templ.
    assertEq(Templ(payable(templ)).referralShareBps(), 5000);
  }

  /// @dev The indexer hydrates initial fee-split state from events fired
  ///      during createTempl. This test asserts that the genesis
  ///      ReferralShareBpsUpdated and BurnAddressUpdated events are emitted
  ///      in the same tx as TemplCreated. The events fire from Templ.
  function test_createTempl_emitsTreasuryBootstrapEvents() public {
    vm.recordLogs();
    vm.prank(creator);
    address templ = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE, "bootstrap-events")
    );

    Vm.Log[] memory entries = vm.getRecordedLogs();

    bytes32 sigReferral = keccak256("ReferralShareBpsUpdated(address,uint256)");
    bytes32 sigBurnAddr = keccak256("BurnAddressUpdated(address,address)");
    bytes32 sigFeeSplit =
      keccak256("FeeSplitUpdated(address,uint256,uint256,uint256)");

    bool sawReferral;
    bool sawBurnAddress;
    bool sawFeeSplit;
    for (uint256 i; i < entries.length; ++i) {
      Vm.Log memory log = entries[i];
      if (log.emitter != templ) continue;
      bytes32 sig = log.topics[0];
      address indexedTempl = address(uint160(uint256(log.topics[1])));
      if (indexedTempl != templ) continue;
      if (sig == sigReferral) {
        sawReferral = true;
        assertEq(abi.decode(log.data, (uint256)), 2500);
      } else if (sig == sigBurnAddr) {
        sawBurnAddress = true;
        // Resolved DEAD address (since config passes address(0))
        assertEq(
          address(uint160(uint256(log.topics[2]))),
          0x000000000000000000000000000000000000dEaD
        );
      } else if (sig == sigFeeSplit) {
        sawFeeSplit = true;
      }
    }

    assertTrue(sawFeeSplit, "FeeSplitUpdated missing");
    assertTrue(sawReferral, "ReferralShareBpsUpdated missing");
    assertTrue(sawBurnAddress, "BurnAddressUpdated missing");
  }

  function test_createTempl_zeroReferralShareIsStoredLiterally() public {
    // The Factory does not substitute a default when callers pass 0; 0 must
    // be stored as 0 (no referral kickbacks at all).
    vm.prank(creator);
    address templ = factory.createTempl(
      CreateConfig({
        token: address(token),
        baseEntryFee: BASE_ENTRY_FEE,
        slug: "zero-ref",
        name: "Zero Ref",
        description: "",
        logoLink: "",
        burnBps: 3000,
        treasuryBps: 3000,
        memberPoolBps: 3000,
        referralShareBps: 0,
        curve: _sensibleCurve(),
        governance: _sensibleGov()
      })
    );

    // referralShareBps lives on Templ.
    assertEq(Templ(payable(templ)).referralShareBps(), 0);
  }

  function test_createTempl_revertsIfBadSplitSum() public {
    vm.prank(creator);
    vm.expectRevert(IFactory.InvalidSplit.selector);
    // 1000 + 1000 + 1000 + 1000 protocol = 4000 != 10000
    factory.createTempl(
      CreateConfig({
        token: address(token),
        baseEntryFee: BASE_ENTRY_FEE,
        slug: "bad",
        name: "Bad",
        description: "",
        logoLink: "",
        burnBps: 1000,
        treasuryBps: 1000,
        memberPoolBps: 1000,
        referralShareBps: 2500,
        curve: _sensibleCurve(),
        governance: _sensibleGov()
      })
    );
  }

  function test_createTempl_revertsIfZeroToken() public {
    vm.prank(creator);
    vm.expectRevert(IFactory.InvalidToken.selector);
    factory.createTempl(_createConfig(address(0), BASE_ENTRY_FEE, "test"));
  }

  function test_createTempl_zeroEntryFee() public {
    vm.prank(creator);
    address templ =
      factory.createTempl(_createConfig(address(token), 0, "free-templ"));

    assertTrue(templ != address(0));
    assertEq(Templ(payable(templ)).entryFee(), 0);
    assertEq(Templ(payable(templ)).baseEntryFee(), 0);
  }

  function test_createTempl_revertsIfBaseFeeUnderMinimum() public {
    vm.prank(creator);
    vm.expectRevert(EntryFeeCurve.EntryFeeTooSmall.selector);
    factory.createTempl(_createConfig(address(token), 5, "tiny-fee"));
  }

  function test_createTempl_revertsIfBaseFeeOverMaximum() public {
    vm.prank(creator);
    vm.expectRevert(EntryFeeCurve.EntryFeeTooLarge.selector);
    factory.createTempl(
      _createConfig(address(token), uint256(type(uint128).max) + 1, "huge-fee")
    );
  }

  // ============ CreateTemplFor ============

  function test_createTemplFor_success() public {
    vm.prank(creator);
    address templ = factory.createTemplFor(
      user, _createConfig(address(token), BASE_ENTRY_FEE, "test")
    );

    assertEq(Templ(payable(templ)).priest(), user);
    assertTrue(Templ(payable(templ)).isMember(user));
  }

  function test_createTemplFor_revertsIfZeroPriest() public {
    vm.prank(creator);
    vm.expectRevert(IFactory.InvalidPriest.selector);
    factory.createTemplFor(
      address(0), _createConfig(address(token), BASE_ENTRY_FEE, "test")
    );
  }

  // ============ Integration ============

  function test_createdTempl_canAcceptMembers() public {
    vm.prank(creator);
    address templAddr = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE, "test")
    );

    Templ templ = Templ(payable(templAddr));
    token.mint(user, BASE_ENTRY_FEE);

    vm.startPrank(user);
    token.approve(templAddr, BASE_ENTRY_FEE);
    templ.join(user, address(0));
    vm.stopPrank();

    assertTrue(templ.isMember(user));
    assertEq(templ.memberCount(), 2);
  }

  function test_createdTempl_entryFeeIncreasesAfterJoin() public {
    vm.prank(creator);
    address templAddr = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE, "test")
    );

    Templ templ = Templ(payable(templAddr));
    token.mint(user, BASE_ENTRY_FEE);

    vm.startPrank(user);
    token.approve(templAddr, BASE_ENTRY_FEE);
    templ.join(user, address(0));
    vm.stopPrank();

    uint256 expectedFee = (BASE_ENTRY_FEE * 10_050) / 10_000;
    assertEq(templ.entryFee(), expectedFee);
  }

  function test_createdTempl_feeSplitFlows() public {
    vm.prank(creator);
    address templAddr = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE, "test")
    );

    Templ templ = Templ(payable(templAddr));
    token.mint(user, BASE_ENTRY_FEE);

    address feeRecipient = factory.protocolFeeRecipient();
    uint256 protocolBefore = token.balanceOf(feeRecipient);

    vm.startPrank(user);
    token.approve(templAddr, BASE_ENTRY_FEE);
    templ.join(user, address(0));
    vm.stopPrank();

    uint256 expectedProtocol = (BASE_ENTRY_FEE * PROTOCOL_FEE_BPS) / 10_000;
    assertEq(token.balanceOf(feeRecipient) - protocolBefore, expectedProtocol);
  }

  // ============ isTempl ============

  function test_isTempl_trueForCreated() public {
    vm.prank(creator);
    address templ =
      factory.createTempl(_createConfig(address(token), BASE_ENTRY_FEE, "a"));

    assertTrue(factory.isTempl(templ));
  }

  function test_isTempl_falseForRandom() public {
    assertFalse(factory.isTempl(makeAddr("random")));
    assertFalse(factory.isTempl(address(0)));
    assertFalse(factory.isTempl(address(token)));
  }

  // ============ getTemplsPaginated ============

  function test_getTemplsPaginated_basic() public {
    vm.startPrank(creator);
    address a =
      factory.createTempl(_createConfig(address(token), BASE_ENTRY_FEE, "a"));
    address b = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE + 1, "b")
    );
    address c = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE + 2, "c")
    );
    vm.stopPrank();

    address[] memory page = factory.getTemplsPaginated(0, 2);
    assertEq(page.length, 2);
    assertEq(page[0], a);
    assertEq(page[1], b);

    page = factory.getTemplsPaginated(2, 2);
    assertEq(page.length, 1);
    assertEq(page[0], c);
  }

  function test_getTemplsPaginated_limitExceedsLength() public {
    vm.startPrank(creator);
    factory.createTempl(_createConfig(address(token), BASE_ENTRY_FEE, "a"));
    address b = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE + 1, "b")
    );
    vm.stopPrank();

    address[] memory page = factory.getTemplsPaginated(1, 100);
    assertEq(page.length, 1);
    assertEq(page[0], b);
  }

  function test_getTemplsPaginated_offsetBeyondLength() public {
    vm.prank(creator);
    factory.createTempl(_createConfig(address(token), BASE_ENTRY_FEE, "a"));

    address[] memory page = factory.getTemplsPaginated(5, 10);
    assertEq(page.length, 0);
  }

  function test_getTemplsPaginated_fullRange() public {
    vm.startPrank(creator);
    address a =
      factory.createTempl(_createConfig(address(token), BASE_ENTRY_FEE, "a"));
    address b = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE + 1, "b")
    );
    vm.stopPrank();

    address[] memory page = factory.getTemplsPaginated(0, 100);
    assertEq(page.length, 2);
    assertEq(page[0], a);
    assertEq(page[1], b);
  }

  function test_getTemplsPaginated_emptyArray() public view {
    address[] memory page = factory.getTemplsPaginated(0, 10);
    assertEq(page.length, 0);
  }

  // ============ Fuzz ============

  function testFuzz_createTempl_anyValidEntryFee(
    uint256 _baseEntryFee
  ) public {
    // validateBaseFee allows 0 (free) or 10..type(uint128).max
    _baseEntryFee = bound(_baseEntryFee, 10, type(uint128).max);

    vm.prank(creator);
    address templ = factory.createTempl(
      _createConfig(address(token), _baseEntryFee, "fuzz")
    );

    assertEq(Templ(payable(templ)).entryFee(), _baseEntryFee);
  }

  function testFuzz_createMultipleTempls(
    uint8 count
  ) public {
    count = uint8(bound(count, 1, 50));

    for (uint8 i = 0; i < count; i++) {
      vm.prank(creator);
      factory.createTempl(
        _createConfigWithSlug(
          address(token),
          BASE_ENTRY_FEE + i,
          "Templ",
          string(abi.encodePacked("templ-", vm.toString(uint256(i))))
        )
      );
    }

    assertEq(factory.templCount(), count);
  }

  // ============ Curve Validation ============

  function _createConfigWithCurve(
    CurveConfig memory curve
  ) internal view returns (CreateConfig memory) {
    return CreateConfig({
      token: address(token),
      baseEntryFee: BASE_ENTRY_FEE,
      slug: "curve-test",
      name: "Curve Test",
      description: "",
      logoLink: "",
      burnBps: 3000,
      treasuryBps: 3000,
      memberPoolBps: 3000,
      referralShareBps: 2500,
      curve: curve,
      governance: _sensibleGov()
    });
  }

  function test_createTempl_rejectsFiniteOnlyCurve() public {
    // A finite-only curve would deploy but brick after N joins, so the
    // Factory must reject it at creation time.
    CurveConfig memory curve;
    curve.primary = CurveSegment({
      style: CurveStyle.Exponential, rateBps: 10_094, length: 100
    });

    vm.prank(creator);
    vm.expectRevert(EntryFeeCurve.InvalidCurveConfig.selector);
    factory.createTempl(_createConfigWithCurve(curve));
  }

  function test_createTempl_rejectsLastSegmentWithFiniteLength() public {
    CurveConfig memory curve;
    curve.primary = CurveSegment({
      style: CurveStyle.Exponential, rateBps: 10_094, length: 100
    });
    curve.additionalSegments = new CurveSegment[](1);
    curve.additionalSegments[0] =
      CurveSegment({ style: CurveStyle.Static, rateBps: 0, length: 50 });

    vm.prank(creator);
    vm.expectRevert(EntryFeeCurve.InvalidCurveConfig.selector);
    factory.createTempl(_createConfigWithCurve(curve));
  }

  function test_createTempl_acceptsValidCustomCurve() public {
    CurveConfig memory curve = EntryFeeCurve.exponentialWithTail(10_094, 248);

    vm.prank(creator);
    address templ = factory.createTempl(_createConfigWithCurve(curve));

    assertTrue(templ != address(0));
  }

  function test_createTempl_acceptsSingleInfiniteSegment() public {
    CurveConfig memory curve;
    curve.primary =
      CurveSegment({ style: CurveStyle.Static, rateBps: 0, length: 0 });

    vm.prank(creator);
    address templ = factory.createTempl(_createConfigWithCurve(curve));

    assertTrue(templ != address(0));
  }

  // ============ Integration: Default Config at Scale ============

  function test_freeTempl_joinWithoutTokens() public {
    vm.prank(creator);
    address templAddr =
      factory.createTempl(_createConfig(address(token), 0, "free"));
    Templ templ = Templ(payable(templAddr));

    // User joins without any tokens or approvals
    vm.prank(user);
    templ.join(user, address(0));

    assertTrue(templ.isMember(user));
    assertEq(templ.memberCount(), 2);
    // Fee stays zero after join
    assertEq(templ.entryFee(), 0);
  }

  function test_freeTempl_feeSplitsAllZero() public {
    vm.prank(creator);
    address templAddr =
      factory.createTempl(_createConfig(address(token), 0, "free-splits"));
    Templ templ = Templ(payable(templAddr));
    Treasury treasury = Treasury(payable(address(templ.TREASURY())));

    vm.prank(user);
    templ.join(user, address(0));

    // All balances stay at zero
    assertEq(token.balanceOf(address(treasury)), 0);
    MemberPool pool = MemberPool(address(templ.MEMBER_POOL()));
    assertEq(pool.totalDeposited(), 0);
    // totalBurned lives on Templ.
    assertEq(templ.totalBurned(), 0);
    assertEq(token.balanceOf(protocolRecipient), 0);
  }

  function test_freeTempl_multipleJoins() public {
    vm.prank(creator);
    address templAddr =
      factory.createTempl(_createConfig(address(token), 0, "free-multi"));
    Templ templ = Templ(payable(templAddr));

    // 10 users join for free
    for (uint256 i; i < 10; ++i) {
      address member =
        makeAddr(string(abi.encodePacked("free-member-", vm.toString(i))));
      vm.prank(member);
      templ.join(member, address(0));
    }

    assertEq(templ.memberCount(), 11); // priest + 10
    assertEq(templ.entryFee(), 0);
  }

  function test_sensibleConfig_300Members_proposalLifecycle() public {
    // Create templ with the standard test fixture (sensible explicit values).
    // Exercises the full proposal lifecycle with the explicit values that the
    // UI / scripts provide on every deploy.
    vm.prank(creator);
    address templAddr = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE, "scale-test")
    );
    Templ templ = Templ(payable(templAddr));
    address govAddr = templ.governance();

    // Join 300 members (past the 249 growth phase into static tail)
    address[] memory members = new address[](300);
    for (uint256 i; i < 300; ++i) {
      members[i] = makeAddr(string(abi.encodePacked("member-", vm.toString(i))));
      uint256 fee = templ.entryFee();
      token.mint(members[i], fee);
      vm.startPrank(members[i]);
      token.approve(templAddr, fee);
      templ.join(members[i], address(0));
      vm.stopPrank();
    }

    // 301 total members (creator/priest + 300 joined)
    assertEq(templ.memberCount(), 301);

    // Fee should have grown during the exponential phase
    uint256 feeAt300 = templ.entryFee();
    assertGt(feeAt300, BASE_ENTRY_FEE, "fee should have grown");

    // Create and execute a governance proposal (setJoinPaused)
    // Default quorum = 10%, so need ~31 of 302 members to vote
    address[] memory targets = new address[](1);
    targets[0] = templAddr;
    uint256[] memory values = new uint256[](1);
    bytes[] memory calldatas = new bytes[](1);
    calldatas[0] = abi.encodeCall(Templ.setJoinPaused, (true));

    // Member 0 proposes (auto-votes FOR)
    // Must pay proposal fee (25% of current entry fee)
    uint256 proposalFee = (templ.entryFee() * 2500) / 10_000;
    token.mint(members[0], proposalFee);
    vm.startPrank(members[0]);
    token.approve(govAddr, proposalFee);
    (bool ok, bytes memory ret) = govAddr.call(
      abi.encodeCall(
        IGovernance.propose, (targets, values, calldatas, "pause joins")
      )
    );
    vm.stopPrank();
    assertTrue(ok, "propose should succeed");
    uint256 proposalId = abi.decode(ret, (uint256));

    // 30 more members vote FOR (31 total with proposer = ~10.3% of 302)
    for (uint256 i = 1; i <= 30; ++i) {
      vm.prank(members[i]);
      IGovernance(govAddr).vote(proposalId, 1); // FOR
    }

    // Fast forward past voting period (3 days) + execution delay (1 day)
    vm.warp(block.timestamp + 4 days);

    // Execute
    IGovernance(govAddr).execute(proposalId);

    // Verify the proposal took effect
    assertTrue(templ.joinPaused(), "joins should be paused");
  }

  // ============ Ownership ============

  function test_ownership_deployerIsOwner() public view {
    assertEq(factory.owner(), address(this));
  }

  function test_ownership_transferOwnership() public {
    address newOwner = makeAddr("newOwner");
    factory.transferOwnership(newOwner);
    assertEq(factory.owner(), newOwner);
  }

  function test_ownership_renounceOwnership() public {
    factory.renounceOwnership();
    assertEq(factory.owner(), address(0));
  }

  function test_ownership_nonOwnerCannotTransfer() public {
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(user);
    factory.transferOwnership(user);
  }

  // ============ Creation Gate (isOpen) ============

  function test_setOpen_onlyOwner() public {
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(user);
    factory.setOpen(true);
  }

  function test_setOpen_emitsEvent() public {
    vm.expectEmit(address(factory));
    emit IFactory.OpenUpdated(true);
    factory.setOpen(true);

    vm.expectEmit(address(factory));
    emit IFactory.OpenUpdated(false);
    factory.setOpen(false);
  }

  function test_creationGate_ownerCanCreateWhenClosed() public {
    factory.setOpen(false);
    // address(this) is the owner - should succeed
    address templ = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE, "owner-create")
    );
    assertTrue(templ != address(0));
  }

  function test_creationGate_nonOwnerRevertsWhenClosed() public {
    factory.setOpen(false);
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(user);
    factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE, "should-fail")
    );
  }

  function test_creationGate_nonOwnerSucceedsWhenOpen() public {
    factory.setOpen(true);
    vm.prank(user);
    address templ = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE, "user-create")
    );
    assertTrue(templ != address(0));
  }

  function test_creationGate_createTemplForRespectsGate() public {
    factory.setOpen(false);
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(user);
    factory.createTemplFor(
      creator, _createConfig(address(token), BASE_ENTRY_FEE, "gated")
    );
  }

  function test_setOpen_idempotent() public {
    // Calling setOpen with the same value should succeed without side effects
    factory.setOpen(true);
    assertTrue(factory.isOpen());

    factory.setOpen(true);
    assertTrue(factory.isOpen());

    factory.setOpen(false);
    assertFalse(factory.isOpen());

    factory.setOpen(false);
    assertFalse(factory.isOpen());
  }

  function test_isOpen_constructorParam() public {
    GovernanceDeployer gd = _newWiredGovernanceDeployer();
    Factory closed = new Factory(address(this), address(gd), false);
    gd.setFactory(address(closed));
    assertFalse(closed.isOpen());

    GovernanceDeployer gd2 = _newWiredGovernanceDeployer();
    Factory opened = new Factory(address(this), address(gd2), true);
    gd2.setFactory(address(opened));
    assertTrue(opened.isOpen());
  }

  // ============ Initial Owner (constructor _initialOwner parameter) ============

  function test_initialOwner_explicit() public {
    address explicitOwner = makeAddr("explicitOwner");
    GovernanceDeployer gd = _newWiredGovernanceDeployer();
    Factory f = new Factory(explicitOwner, address(gd), true);
    gd.setFactory(address(f));

    assertEq(f.owner(), explicitOwner);
    assertEq(f.protocolFeeRecipient(), explicitOwner);
  }

  /// @dev When the Factory is deployed via the deterministic deployment
  ///      proxy (CREATE2), `msg.sender` is the proxy address (0x4e59...),
  ///      not the EOA that triggered the deploy. The constructor takes an
  ///      explicit `_initialOwner` parameter with a `tx.origin` fallback so
  ///      ownership lands on the EOA, not the proxy. Simulate the proxy
  ///      deploy by setting `msg.sender` and `tx.origin` independently.
  function test_initialOwner_fallbackToTxOrigin() public {
    address proxy = makeAddr("deterministicDeployerProxy");
    address deployerEoa = makeAddr("deployerEoa");
    GovernanceDeployer gd = _newWiredGovernanceDeployer();

    // Two-arg vm.prank sets BOTH msg.sender and tx.origin for the next call,
    // mirroring how the deterministic deployment proxy works on-chain.
    vm.prank(proxy, deployerEoa);
    Factory f = new Factory(address(0), address(gd), true);
    gd.setFactory(address(f));

    assertEq(f.owner(), deployerEoa, "owner must be the EOA, not the proxy");
    assertEq(f.protocolFeeRecipient(), deployerEoa);
    assertTrue(f.owner() != proxy, "owner must NOT be the proxy address");
  }

  function test_initialOwner_zero_directDeploy() public {
    GovernanceDeployer gd = _newWiredGovernanceDeployer();

    // Direct `new Factory(...)` from this test contract: msg.sender is the
    // test contract, tx.origin is foundry's default sender. Passing
    // address(0) takes the tx.origin path.
    Factory f = new Factory(address(0), address(gd), true);
    gd.setFactory(address(f));

    assertEq(f.owner(), tx.origin);
    assertEq(f.protocolFeeRecipient(), tx.origin);
  }

  // ============ Protocol Fee Recipient ============

  function test_setProtocolFeeRecipient_onlyOwner() public {
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(user);
    factory.setProtocolFeeRecipient(user);
  }

  function test_setProtocolFeeRecipient_revertsIfZero() public {
    vm.expectRevert(IFactory.InvalidFeeRecipient.selector);
    factory.setProtocolFeeRecipient(address(0));
  }

  function test_setProtocolFeeRecipient_emitsEvent() public {
    address newRecipient = makeAddr("newRecipient");
    vm.expectEmit(address(factory));
    emit IFactory.ProtocolFeeRecipientUpdated(newRecipient);
    factory.setProtocolFeeRecipient(newRecipient);
    assertEq(factory.protocolFeeRecipient(), newRecipient);
  }

  function test_setProtocolFeeRecipient_nextJoinUsesNewAddress() public {
    // Create a templ while open
    address templAddr = factory.createTempl(
      _createConfig(address(token), BASE_ENTRY_FEE, "fee-test")
    );

    // Change fee recipient
    address newRecipient = makeAddr("newFeeRecipient");
    factory.setProtocolFeeRecipient(newRecipient);

    // Join - protocol fees should go to the new recipient
    Templ templ = Templ(payable(templAddr));
    uint256 fee = templ.entryFee();
    token.mint(user, fee);

    uint256 newRecipientBefore = token.balanceOf(newRecipient);

    vm.startPrank(user);
    token.approve(templAddr, fee);
    templ.join(user, address(0));
    vm.stopPrank();

    uint256 expectedProtocol = (fee * PROTOCOL_FEE_BPS) / 10_000;
    assertEq(
      token.balanceOf(newRecipient) - newRecipientBefore, expectedProtocol
    );
  }

  // ============ No Defaults: 0 means 0 ============
  //
  // The Factory does not substitute defaults for any governance/economic
  // param. Every value is stored as-is so that callers can express e.g.
  // `proposalFeeBps = 0` (free proposals) or `executionDelay = 0` (instant
  // execution) at deploy time. UI / scripts are responsible for picking
  // sensible defaults. The tests below pin this contract: passing 0 must
  // store 0.

  function test_noDefaults_zeroProposalFeeIsFree() public {
    GovernanceConfig memory gov = _sensibleGov();
    gov.proposalFeeBps = 0;

    vm.prank(creator);
    address templAddr = factory.createTempl(
      CreateConfig({
        token: address(token),
        baseEntryFee: BASE_ENTRY_FEE,
        slug: "free-proposals",
        name: "Free Proposals",
        description: "",
        logoLink: "",
        burnBps: 3000,
        treasuryBps: 3000,
        memberPoolBps: 3000,
        referralShareBps: 2500,
        curve: _sensibleCurve(),
        governance: gov
      })
    );

    address govAddr = Templ(payable(templAddr)).governance();
    assertEq(IGovernance(govAddr).proposalFeeBps(), 0);
  }

  function test_noDefaults_zeroExecutionDelayIsInstant() public {
    GovernanceConfig memory gov = _sensibleGov();
    gov.executionDelay = 0;

    vm.prank(creator);
    address templAddr = factory.createTempl(
      CreateConfig({
        token: address(token),
        baseEntryFee: BASE_ENTRY_FEE,
        slug: "instant-exec",
        name: "Instant Exec",
        description: "",
        logoLink: "",
        burnBps: 3000,
        treasuryBps: 3000,
        memberPoolBps: 3000,
        referralShareBps: 2500,
        curve: _sensibleCurve(),
        governance: gov
      })
    );

    address govAddr = Templ(payable(templAddr)).governance();
    assertEq(IGovernance(govAddr).executionDelay(), 0);
  }

  function test_noDefaults_governanceParamsStoredVerbatim() public {
    // Spot-check every governance param: pass an unusual but valid explicit
    // value, then read it back from the deployed Governance contract. The
    // values below are deliberately offbeat so any silent substitution by the
    // Factory would surface immediately as a failed assertion.
    GovernanceConfig memory gov = GovernanceConfig({
      mode: GovMode.Democracy,
      approvalThresholdBps: 6000,
      quorumBps: 2000,
      votingPeriod: 5 days,
      executionDelay: 12 hours,
      immediateExecutionBps: 7500, // must be >= approvalThresholdBps
      proposalFeeBps: 1234,
      council: new address[](0)
    });

    vm.prank(creator);
    address templAddr = factory.createTempl(
      CreateConfig({
        token: address(token),
        baseEntryFee: BASE_ENTRY_FEE,
        slug: "verbatim",
        name: "Verbatim",
        description: "",
        logoLink: "",
        burnBps: 3000,
        treasuryBps: 3000,
        memberPoolBps: 3000,
        referralShareBps: 2500,
        curve: _sensibleCurve(),
        governance: gov
      })
    );

    address govAddr = Templ(payable(templAddr)).governance();
    assertEq(IGovernance(govAddr).approvalThresholdBps(), 6000);
    assertEq(IGovernance(govAddr).quorumBps(), 2000);
    assertEq(IGovernance(govAddr).votingPeriod(), 5 days);
    assertEq(IGovernance(govAddr).executionDelay(), 12 hours);
    assertEq(IGovernance(govAddr).immediateExecutionBps(), 7500);
    assertEq(IGovernance(govAddr).proposalFeeBps(), 1234);
  }

  function test_noDefaults_zeroSplitsRevert() public {
    // All-three-zero must fail the sum check
    // (0 + 0 + 0 + 1000 protocol = 1000 != 10000) rather than triggering
    // any default substitution.
    vm.prank(creator);
    vm.expectRevert(IFactory.InvalidSplit.selector);
    factory.createTempl(
      CreateConfig({
        token: address(token),
        baseEntryFee: BASE_ENTRY_FEE,
        slug: "zero-splits",
        name: "Zero Splits",
        description: "",
        logoLink: "",
        burnBps: 0,
        treasuryBps: 0,
        memberPoolBps: 0,
        referralShareBps: 2500,
        curve: _sensibleCurve(),
        governance: _sensibleGov()
      })
    );
  }

  function test_noDefaults_staticCurveIsAccepted() public {
    // `{ Static, 0, 0 }` must be accepted as a literal single-segment static
    // infinite curve (flat fee forever) rather than triggering default
    // substitution.
    CurveConfig memory flatCurve;
    flatCurve.primary =
      CurveSegment({ style: CurveStyle.Static, rateBps: 0, length: 0 });

    vm.prank(creator);
    address templAddr = factory.createTempl(
      CreateConfig({
        token: address(token),
        baseEntryFee: BASE_ENTRY_FEE,
        slug: "flat-curve",
        name: "Flat Curve",
        description: "",
        logoLink: "",
        burnBps: 3000,
        treasuryBps: 3000,
        memberPoolBps: 3000,
        referralShareBps: 2500,
        curve: flatCurve,
        governance: _sensibleGov()
      })
    );

    Templ templ = Templ(payable(templAddr));
    assertEq(templ.entryFee(), BASE_ENTRY_FEE);

    // Fee should NOT grow after a join (flat curve, not the old exponential default)
    token.mint(user, BASE_ENTRY_FEE);
    vm.startPrank(user);
    token.approve(templAddr, BASE_ENTRY_FEE);
    templ.join(user, address(0));
    vm.stopPrank();

    assertEq(templ.entryFee(), BASE_ENTRY_FEE, "flat curve fee must not grow");
  }

  // ============ Deployer Access Control ============

  function test_councilDeployer_directCallReverts() public {
    CouncilDeployer cd = new CouncilDeployer(address(this));
    cd.setGovernanceDeployer(makeAddr("govDeployer"));

    address[] memory council = new address[](1);
    council[0] = makeAddr("councilMember");

    vm.expectRevert(CouncilDeployer.NotAuthorized.selector);
    cd.deploy(
      makeAddr("templ"), 5100, 1000, 1 days, 3 days, 10_000, 2500, council
    );
  }

  function test_democracyDeployer_directCallReverts() public {
    DemocracyDeployer dd = new DemocracyDeployer(address(this));
    dd.setGovernanceDeployer(makeAddr("govDeployer"));

    vm.expectRevert(DemocracyDeployer.NotAuthorized.selector);
    dd.deploy(makeAddr("templ"), 5100, 1000, 1 days, 3 days, 10_000, 2500);
  }

  function test_governanceDeployer_directCallReverts() public {
    GovernanceDeployer gd = _newWiredGovernanceDeployer();
    gd.setFactory(makeAddr("factory"));

    GovernanceConfig memory gov = _sensibleGov();

    vm.expectRevert(GovernanceDeployer.NotAuthorized.selector);
    gd.deploy(makeAddr("templ"), gov, 5100, 1000, 3 days, 1 days, 10_000, 2500);
  }

  function test_councilDeployer_setGovernanceDeployer_revertsOnSecondCall()
    public
  {
    CouncilDeployer cd = new CouncilDeployer(address(this));
    cd.setGovernanceDeployer(makeAddr("govDeployer"));

    vm.expectRevert(CouncilDeployer.AlreadyInitialized.selector);
    cd.setGovernanceDeployer(makeAddr("attacker"));
  }

  function test_democracyDeployer_setGovernanceDeployer_revertsOnSecondCall()
    public
  {
    DemocracyDeployer dd = new DemocracyDeployer(address(this));
    dd.setGovernanceDeployer(makeAddr("govDeployer"));

    vm.expectRevert(DemocracyDeployer.AlreadyInitialized.selector);
    dd.setGovernanceDeployer(makeAddr("attacker"));
  }

  function test_governanceDeployer_setFactory_revertsOnSecondCall() public {
    GovernanceDeployer gd = _newWiredGovernanceDeployer();
    gd.setFactory(makeAddr("factory"));

    vm.expectRevert(GovernanceDeployer.AlreadyInitialized.selector);
    gd.setFactory(makeAddr("attacker"));
  }

  function test_councilDeployer_setGovernanceDeployer_revertsOnZeroAddress()
    public
  {
    CouncilDeployer cd = new CouncilDeployer(address(this));
    vm.expectRevert(CouncilDeployer.ZeroAddress.selector);
    cd.setGovernanceDeployer(address(0));
  }

  function test_democracyDeployer_setGovernanceDeployer_revertsOnZeroAddress()
    public
  {
    DemocracyDeployer dd = new DemocracyDeployer(address(this));
    vm.expectRevert(DemocracyDeployer.ZeroAddress.selector);
    dd.setGovernanceDeployer(address(0));
  }

  function test_governanceDeployer_setFactory_revertsOnZeroAddress() public {
    GovernanceDeployer gd = _newWiredGovernanceDeployer();
    vm.expectRevert(GovernanceDeployer.ZeroAddress.selector);
    gd.setFactory(address(0));
  }
}
