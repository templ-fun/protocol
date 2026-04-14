// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { GovernanceDeployer } from "./GovernanceDeployer.sol";
import { Templ } from "./Templ.sol";
import { Treasury } from "./Treasury.sol";
import {
  CreateConfig,
  GovernanceConfig,
  IFactory
} from "./interfaces/IFactory.sol";
import {
  CurveConfig,
  CurveSegment,
  EntryFeeCurve
} from "./libraries/EntryFeeCurve.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @title Factory
/// @notice Creates fully functional Templs in a single transaction.
///         Deploys Templ + Treasury via embedded bytecodes, then delegates
///         governance deployment to GovernanceDeployer (separate contract to
///         stay under the 24KB contract size limit).
///         The Factory acts as temporary governance during creation, then hands
///         off control to the deployed governance contract.
contract Factory is IFactory, Ownable {
  // ============ Constants ============

  uint256 public constant BPS_DENOMINATOR = 10_000;

  // ============ Immutables ============

  /// @notice Protocol fee: 10% of every entry fee, immutable
  uint256 public constant override PROTOCOL_FEE_BPS = 1000;
  GovernanceDeployer public immutable GOV_DEPLOYER;

  // ============ State ============

  address public override protocolFeeRecipient;
  bool public override isOpen;

  address[] internal _templs;
  mapping(address => bool) public override isTempl;

  /// @dev keccak256(slug) => templ address (zero if not registered)
  mapping(bytes32 => address) internal _slugToTempl;

  /// @dev templ address => slug string
  mapping(address => string) internal _templSlug;

  // ============ Constructor ============

  /// @param _initialOwner Address that becomes the Factory owner and initial
  ///        protocol fee recipient. Pass `address(0)` to fall back to
  ///        `tx.origin` (the EOA that submitted the deployment transaction).
  ///        The fallback exists so a CREATE2 deploy via the deterministic
  ///        deployment proxy never accidentally locks ownership at the proxy
  ///        address. `msg.sender` inside this constructor is the proxy
  ///        contract, not the deployer wallet, so it must not be used.
  ///        tx.origin is used here for initialization only, not as an
  ///        authentication mechanism - it runs once in the constructor and the
  ///        result is stored in Ownable's owner slot.
  /// @param _govDeployer GovernanceDeployer contract address
  /// @param _isOpen When true, anyone can call `createTempl`. When false, only
  ///        the owner can create new Templs.
  constructor(
    address _initialOwner,
    address _govDeployer,
    bool _isOpen
  ) {
    address owner_ = _initialOwner == address(0) ? tx.origin : _initialOwner;
    _initializeOwner(owner_);
    protocolFeeRecipient = owner_;
    GOV_DEPLOYER = GovernanceDeployer(_govDeployer);
    isOpen = _isOpen;
  }

  // ============ Views ============

  /// @inheritdoc IFactory
  function getTempls() external view override returns (address[] memory) {
    return _templs;
  }

  /// @inheritdoc IFactory
  function templCount() external view override returns (uint256) {
    return _templs.length;
  }

  /// @inheritdoc IFactory
  function getTemplsPaginated(
    uint256 offset,
    uint256 limit
  ) external view override returns (address[] memory result) {
    uint256 len = _templs.length;
    if (offset >= len) return result;
    uint256 end = offset + limit;
    if (end > len) end = len;
    result = new address[](end - offset);
    for (uint256 i = offset; i < end;) {
      result[i - offset] = _templs[i];
      unchecked {
        ++i;
      }
    }
  }

  /// @inheritdoc IFactory
  function slugToTempl(
    string calldata slug
  ) external view override returns (address) {
    return _slugToTempl[keccak256(bytes(slug))];
  }

  /// @inheritdoc IFactory
  function templSlug(
    address templ
  ) external view override returns (string memory) {
    return _templSlug[templ];
  }

  // ============ Slug Management ============

  /// @inheritdoc IFactory
  function updateSlug(
    address templ,
    string calldata newSlug
  ) external override {
    if (!isTempl[templ]) revert NotRegisteredTempl();
    if (msg.sender != Templ(templ).governance()) revert NotGovernance();

    _validateSlug(newSlug);

    bytes32 newHash = keccak256(bytes(newSlug));
    if (_slugToTempl[newHash] != address(0)) revert SlugTaken();

    // Release old slug
    string memory oldSlug = _templSlug[templ];
    if (bytes(oldSlug).length > 0) {
      delete _slugToTempl[keccak256(bytes(oldSlug))];
    }

    // Register new slug
    _slugToTempl[newHash] = templ;
    _templSlug[templ] = newSlug;

    emit SlugUpdated(templ, oldSlug, newSlug);
  }

  // ============ Create ============

  /// @inheritdoc IFactory
  function createTempl(
    CreateConfig calldata config
  ) external override returns (address templ) {
    return _createTempl(msg.sender, config);
  }

  /// @inheritdoc IFactory
  /// @dev Any caller can designate any address as priest. No access control
  ///      beyond the isOpen gate - the designated priest does not need to
  ///      approve the creation. Use createTempl() when the caller is the priest.
  function createTemplFor(
    address priest,
    CreateConfig calldata config
  ) external override returns (address templ) {
    return _createTempl(priest, config);
  }

  // ============ Owner Actions ============

  /// @inheritdoc IFactory
  function setOpen(
    bool _isOpen
  ) external override onlyOwner {
    isOpen = _isOpen;
    emit OpenUpdated(_isOpen);
  }

  /// @inheritdoc IFactory
  function setProtocolFeeRecipient(
    address _recipient
  ) external override onlyOwner {
    if (_recipient == address(0)) revert InvalidFeeRecipient();
    protocolFeeRecipient = _recipient;
    emit ProtocolFeeRecipientUpdated(_recipient);
  }

  // ============ Internal: Validation ============

  /// @dev Splits must sum exactly to BPS_DENOMINATOR - PROTOCOL_FEE_BPS.
  ///      The Factory does not substitute defaults; callers (UI / scripts)
  ///      provide explicit values.
  function _validateSplits(
    uint256 burnBps,
    uint256 treasuryBps,
    uint256 memberPoolBps
  ) internal pure {
    if (
      burnBps + treasuryBps + memberPoolBps + PROTOCOL_FEE_BPS
        != BPS_DENOMINATOR
    ) {
      revert InvalidSplit();
    }
  }

  /// @dev Copies a calldata curve into memory and runs the library validator.
  ///      No default substitution: an empty / zero curve must still be a
  ///      valid configuration on its own (e.g. a single static infinite tail).
  function _validatedCurve(
    CurveConfig calldata curve
  ) internal pure returns (CurveConfig memory resolved) {
    resolved.primary = curve.primary;
    uint256 len = curve.additionalSegments.length;
    resolved.additionalSegments = new CurveSegment[](len);
    for (uint256 i; i < len; ++i) {
      resolved.additionalSegments[i] = curve.additionalSegments[i];
    }
    EntryFeeCurve.validate(resolved);
  }

  // ============ Internal: Creation ============

  /// @dev Validates, deploys Templ + Treasury + Governance, and wires them together.
  ///      All config values are stored as-is; the Factory does not substitute
  ///      defaults for any field. Callers (UI / scripts) are responsible for
  ///      providing sensible values.
  function _createTempl(
    address priest,
    CreateConfig calldata config
  ) internal returns (address templ) {
    if (!isOpen) _checkOwner();
    if (priest == address(0)) revert InvalidPriest();
    if (config.token == address(0)) revert InvalidToken();

    _validateSplits(config.burnBps, config.treasuryBps, config.memberPoolBps);
    EntryFeeCurve.validateBaseFee(config.baseEntryFee);

    CurveConfig memory curve = _validatedCurve(config.curve);

    // 1. Validate slug format + uniqueness before deploying
    _validateSlug(config.slug);
    bytes32 slugHash = keccak256(bytes(config.slug));
    if (_slugToTempl[slugHash] != address(0)) revert SlugTaken();

    // 2. Deploy Treasury + Templ (Factory is temporary governance)
    address treasury;
    (templ, treasury) = _deploy(
      priest,
      config.token,
      config.baseEntryFee,
      config.slug,
      curve,
      config.referralShareBps
    );

    // 3. Register slug (deploy succeeded, safe to commit)
    _slugToTempl[slugHash] = templ;
    _templSlug[templ] = config.slug;

    // 4. Emit TemplCreated before any child events (indexer ordering)
    _emitTemplCreated(
      templ,
      treasury,
      config.baseEntryFee,
      config.slug,
      config.name,
      config.description,
      config.logoLink
    );

    // 5. Emit priest's MemberJoined after TemplCreated (indexer ordering)
    Templ(templ).emitPriestJoin();

    // 6. Set fee splits (indexer catches FeeSplitUpdated after TemplCreated)
    Treasury(treasury)
      .setFeeSplit(config.burnBps, config.treasuryBps, config.memberPoolBps);

    // 7. Deploy governance and hand off control
    _deployAndWireGovernance(templ, config.governance);
  }

  /// @dev Deploys Treasury + Templ contracts. Factory is set as initial governance
  ///      so it can later call setGovernance() to wire the real governance contract.
  function _deploy(
    address priest,
    address token,
    uint256 baseEntryFee,
    string calldata slug,
    CurveConfig memory curve,
    uint256 referralShareBps
  ) internal returns (address templ, address treasury) {
    // Deterministic salt: keccak256(priest, token, baseEntryFee, slug).
    // All four fields contribute - same 4-tuple on any chain produces the same address.
    bytes memory encoded = abi.encode(priest, token, baseEntryFee, slug);
    bytes32 salt;
    assembly ("memory-safe") {
      salt := keccak256(add(encoded, 0x20), mload(encoded))
    }

    // Deploy Treasury first (templ not yet known, splits set later)
    Treasury t = new Treasury{
      salt: salt
    }(
      token,
      PROTOCOL_FEE_BPS,
      address(0), // default burn address (0xdead inside constructor)
      referralShareBps
    );

    // Deploy Templ with Factory as initial governance
    Templ newTempl = new Templ{
      salt: salt
    }(priest, token, baseEntryFee, curve, address(t), address(this));

    // Connect Treasury to its Templ
    t.setTempl(address(newTempl));

    templ = address(newTempl);
    treasury = address(t);
    _templs.push(templ);
    isTempl[templ] = true;
  }

  /// @dev Deploys Democracy or Council via GovernanceDeployer, then calls
  ///      setGovernance() on the Templ. Factory is the current governance,
  ///      so the call succeeds.
  ///      setGovernance() emits GovernanceUpdated and calls emitConfig().
  ///      All governance parameters are passed through verbatim - the Factory
  ///      does not substitute any defaults. The Governance constructor
  ///      validates upper bounds (bps <= 10000), cross-field ordering
  ///      (immediateExecutionBps >= approvalThresholdBps), non-zero voting
  ///      period, and proposalFeeBps <= MAX_PROPOSAL_FEE_BPS. It does not
  ///      enforce minimum values for thresholds or delays.
  // NOTE: Minimum-value enforcement tracked in #179.
  function _deployAndWireGovernance(
    address templ,
    GovernanceConfig calldata govConfig
  ) internal {
    address governance = GOV_DEPLOYER.deploy(
      templ,
      govConfig,
      govConfig.approvalThresholdBps,
      govConfig.quorumBps,
      govConfig.votingPeriod,
      govConfig.executionDelay,
      govConfig.immediateExecutionBps,
      govConfig.proposalFeeBps
    );

    // Hand off governance from Factory to the deployed contract.
    // This emits GovernanceUpdated + config events for the indexer.
    Templ(templ).setGovernance(governance);
  }

  /// @dev Validates slug: 1-64 chars, lowercase a-z, digits 0-9, hyphens.
  ///      No leading/trailing hyphens, no consecutive hyphens, no empty string.
  function _validateSlug(
    string calldata slug
  ) internal pure {
    bytes calldata b = bytes(slug);
    uint256 len = b.length;
    if (len == 0 || len > 64) revert InvalidSlug();

    // No leading or trailing hyphen
    if (b[0] == 0x2D || b[len - 1] == 0x2D) revert InvalidSlug();

    bool prevHyphen = false;
    for (uint256 i; i < len;) {
      bytes1 c = b[i];
      bool isLower = c >= 0x61 && c <= 0x7A; // a-z
      bool isDigit = c >= 0x30 && c <= 0x39; // 0-9
      bool isHyphen = c == 0x2D; // -

      if (!isLower && !isDigit && !isHyphen) revert InvalidSlug();
      if (isHyphen && prevHyphen) revert InvalidSlug(); // no consecutive hyphens

      prevHyphen = isHyphen;
      unchecked {
        ++i;
      }
    }
  }

  /// @dev Emits TemplCreated. Reads priest/token from the Templ contract
  ///      to avoid stack-too-deep in the caller.
  function _emitTemplCreated(
    address templAddr,
    address treasury,
    uint256 baseEntryFee,
    string calldata slug,
    string calldata name,
    string calldata description,
    string calldata logoLink
  ) internal {
    Templ t = Templ(templAddr);
    emit TemplCreated(
      templAddr,
      t.priest(),
      t.TOKEN(),
      treasury,
      msg.sender,
      baseEntryFee,
      slug,
      name,
      description,
      logoLink
    );
  }
}
