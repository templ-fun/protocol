// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IExecutable } from "./IExecutable.sol";
import { IMemberPool } from "./IMemberPool.sol";
import { ITreasury } from "./ITreasury.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";

/// @title ITempl
/// @notice Interface for Templ membership contracts
/// @dev The programmable-vault surface (`execute`, `onERC721Received`, the
///      `Executed` event, `ExecuteFailed`/`NotGovernance` errors, and native
///      ETH `receive`) is inherited from `IExecutable`. Templ's runtime ABI
///      includes those entries via inheritance; Solidity tests reach the
///      selectors through `IExecutable`.
interface ITempl is IExecutable {
  // ============ Structs ============

  /// @param id Permanent member ID (0 = not a member)
  /// @param joinedAt Timestamp when member joined
  struct Member {
    uint64 id;
    uint64 joinedAt;
  }

  /// @notice Join intent, hashed into the Permit2 witness signature.
  ///         Every field is signed by the payer, so a relayer cannot modify them.
  ///         Used exclusively by joinWithPermit2Witness.
  /// @param recipient Address that receives the membership
  /// @param referral Referral address (address(0) if none)
  /// @param relayerTip Extra tokens paid to msg.sender (the relayer) as gas compensation.
  ///        Set to 0 for direct (non-relayed) joins.
  struct JoinIntent {
    address recipient;
    address referral;
    uint256 relayerTip;
  }

  // ============ Events ============

  event MemberJoined(
    address indexed member,
    address indexed payer,
    uint256 entryFee,
    uint256 timestamp
  );

  event EntryFeeUpdated(address indexed templ, uint256 newEntryFee);

  event BaseEntryFeeUpdated(address indexed templ, uint256 baseEntryFee);

  event GovernanceUpdated(
    address indexed oldGovernance, address indexed newGovernance
  );

  event PriestTransferred(
    address indexed previousPriest, address indexed newPriest
  );

  event JoinPausedUpdated(bool paused);

  event MetadataUpdated(string name, string description, string logoLink);

  /// @notice Emitted whenever the burn / treasury / member-pool BPS triple
  ///         changes. Factory fires this once after TemplCreated so indexers
  ///         capture the genesis values; governance can update later.
  /// @param templ The Templ contract that emitted this (always address(this))
  /// @param burnBps New burn share in basis points
  /// @param treasuryBps New treasury share in basis points
  /// @param memberPoolBps New member-pool share in basis points
  event FeeSplitUpdated(
    address indexed templ,
    uint256 burnBps,
    uint256 treasuryBps,
    uint256 memberPoolBps
  );

  /// @notice Emitted whenever the burn destination changes. Factory fires the
  ///         resolved value (DEAD when caller passed zero) once after
  ///         TemplCreated; governance can override later.
  event BurnAddressUpdated(address indexed templ, address indexed burnAddress);

  /// @notice Emitted whenever the referral cut of the member-pool slice
  ///         changes. Factory fires the genesis value once; governance can
  ///         update later.
  event ReferralShareBpsUpdated(address indexed templ, uint256 bps);

  /// @notice Emitted on every paid join after the fee has been split and
  ///         forwarded to its destinations.
  /// @param templ The Templ contract that emitted this (always address(this))
  /// @param totalFee Gross fee delivered to Templ for this join
  /// @param burnAmount Tokens forwarded to the burn address
  /// @param treasuryAmount Tokens forwarded to Treasury
  /// @param memberPoolAmount Member-pool slice before referral carve-out
  /// @param protocolAmount Tokens forwarded to the protocol fee recipient
  /// @param referral Referral target (zero if none paid)
  /// @param referralAmount Referral cut taken from memberPoolAmount
  event FeesDistributed(
    address indexed templ,
    uint256 totalFee,
    uint256 burnAmount,
    uint256 treasuryAmount,
    uint256 memberPoolAmount,
    uint256 protocolAmount,
    address referral,
    uint256 referralAmount
  );

  /// @notice Emitted when a referral receives their cut of the member-pool slice.
  /// @param templ The Templ contract that emitted this (always address(this))
  /// @param referral Address that received the referral payout
  /// @param member The new member whose join generated this reward
  /// @param amount Tokens transferred to the referral
  event ReferralRewardPaid(
    address indexed templ,
    address indexed referral,
    address indexed member,
    uint256 amount
  );

  // ============ Errors ============

  error AlreadyMember();
  error NotMember();
  error NotPriest();
  error RecipientIsRequired();
  error JoinsPaused();
  error WrongToken();
  error FeeTokenMismatch();
  /// @notice Reverts when a setFeeSplit call would not sum to BPS
  ///         (`burnBps + treasuryBps + memberPoolBps + PROTOCOL_BPS != 10_000`)
  ///         or when `setReferralShareBps` exceeds 10_000.
  error InvalidSplit();
  /// @notice Reverts when `setBurnAddress` is called with the zero address.
  error ZeroBurnAddress();

  // ============ Views ============

  /// @notice ERC20 token used for entry fees and rewards
  function TOKEN() external view returns (address);

  /// @notice Current entry fee after curve adjustments
  function entryFee() external view returns (uint256);

  /// @notice Base entry fee anchor before curve adjustments
  function baseEntryFee() external view returns (uint256);

  /// @notice Number of paid joins (excludes the priest's free join)
  function paidJoins() external view returns (uint256);

  /// @notice Admin address with priest-level permissions
  function priest() external view returns (address);

  /// @notice Address authorized to execute governance actions on this contract
  function governance() external view returns (address);

  /// @notice Treasury contract that holds the treasury slice
  function TREASURY() external view returns (ITreasury);

  /// @notice MemberPool contract that holds member rewards
  function MEMBER_POOL() external view returns (IMemberPool);

  /// @notice Protocol fee share in basis points (set once in constructor)
  function PROTOCOL_BPS() external view returns (uint256);

  /// @notice Burn share in basis points
  function burnBps() external view returns (uint256);

  /// @notice Treasury share in basis points
  function treasuryBps() external view returns (uint256);

  /// @notice Member pool share in basis points
  function memberPoolBps() external view returns (uint256);

  /// @notice Destination address for burned tokens
  function burnAddress() external view returns (address);

  /// @notice Referral's cut of the member pool in basis points
  function referralShareBps() external view returns (uint256);

  /// @notice Cumulative tokens forwarded to the burn address by `_splitAndForward`
  function totalBurned() external view returns (uint256);

  /// @notice Total members including the priest (priest = 1, first paid join = 2, etc.)
  function memberCount() external view returns (uint64);

  /// @notice Returns the member record for an address (id=0 means not a member)
  /// @param account Address to query
  function members(
    address account
  ) external view returns (uint64 id, uint64 joinedAt);

  /// @notice Whether an address holds a membership
  /// @param account Address to check
  function isMember(
    address account
  ) external view returns (bool);

  // ============ Join ============
  //
  // Four join methods with different trust and UX tradeoffs:
  //
  //   join                   - Direct ERC-20 transfer. Caller pays with pre-approved tokens.
  //   joinWithERC2612Permit  - ERC-2612 native permit. Single-tx approve+join for tokens that
  //                            implement EIP-2612 (e.g. USDC, DAI). No Permit2 dependency.
  //                            Self-submit only (msg.sender is the payer and permit signer).
  //   joinWithPermit2        - Permit2 signature. Nicer wallet UX (MetaMask shows a clean
  //                            "Spending cap request"). Self-submit only (msg.sender is the
  //                            payer and permit signer).
  //   joinWithPermit2Witness - Permit2 witness signature. Recipient, referral, and relayerTip
  //                            are cryptographically bound to the signature. Safe for any
  //                            relayer, including third-party or untrusted ones.
  //
  // The non-witness permit methods (joinWithERC2612Permit, joinWithPermit2)
  // always use msg.sender as the payer. This eliminates the hijack attack
  // surface: there is no separate payer address to impersonate.
  // For trustless relayed joins, use joinWithPermit2Witness.

  /// @notice Pay the entry fee and grant membership to recipient.
  ///         Requires a prior ERC-20 approval to this contract.
  /// @param recipient Address that receives the membership
  /// @param referral Referral address (address(0) if none)
  function join(
    address recipient,
    address referral
  ) external;

  /// @notice Pay the entry fee using an ERC-2612 native permit and grant membership.
  ///         For tokens that implement EIP-2612 (permit on the token itself).
  ///         Calls token.permit() to set allowance, then transfers to Treasury.
  ///         Recipient and referral are passed as calldata (not signed).
  ///         Self-submit only: msg.sender is always the payer.
  /// @dev Not relayable - msg.sender must be the ERC-2612 permit signer.
  ///      Recipient and referral are unsigned calldata. For trustless relaying
  ///      where a third party submits the transaction, use
  ///      `joinWithPermit2Witness` instead.
  /// @param recipient Address that receives the membership
  /// @param referral Referral address (address(0) if none)
  /// @param deadline Permit signature deadline
  /// @param v Signature recovery byte
  /// @param r Signature r value
  /// @param s Signature s value
  function joinWithERC2612Permit(
    address recipient,
    address referral,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external;

  /// @notice Pay the entry fee via Permit2 signature and grant membership.
  ///         Recipient and referral are passed as calldata (not signed).
  ///         Self-submit only: msg.sender is always the payer.
  ///         Produces a clean "Spending cap request" UI in MetaMask.
  /// @dev Not relayable - msg.sender must be the Permit2 signer. Recipient and
  ///      referral are unsigned calldata. For trustless relaying where a third
  ///      party submits the transaction, use `joinWithPermit2Witness`.
  /// @param recipient Address that receives the membership
  /// @param referral Referral address (address(0) if none)
  /// @param permit Permit2 transfer details (token, amount, nonce, deadline)
  /// @param signature EIP-712 signature authorizing the transfer
  function joinWithPermit2(
    address recipient,
    address referral,
    ISignatureTransfer.PermitTransferFrom calldata permit,
    bytes calldata signature
  ) external;

  /// @notice Pay the entry fee via Permit2 witness signature and grant membership.
  ///         The JoinIntent (recipient, referral, relayerTip) is hashed into the
  ///         signature as a Permit2 witness, so no field can be tampered with.
  ///         Safe for untrusted or third-party relayers.
  ///         Tokens flow to the contract first, then split: entryFee to Treasury,
  ///         relayerTip to msg.sender (the relayer). For direct joins, set relayerTip to 0.
  /// @param payer Address whose tokens are transferred (must be the permit signer)
  /// @param permit Permit2 transfer details (token, amount, nonce, deadline)
  /// @param signature EIP-712 signature covering both the transfer and the JoinIntent witness
  /// @param intent Join intent (recipient, referral, relayerTip), bound to the signature
  function joinWithPermit2Witness(
    address payer,
    ISignatureTransfer.PermitTransferFrom calldata permit,
    bytes calldata signature,
    JoinIntent calldata intent
  ) external;

  // ============ Priest ============

  /// @notice Transfer priest role to another member
  /// @param newPriest Address of the new priest (must already be a member)
  function transferPriest(
    address newPriest
  ) external;

  /// @notice Emit the priest's MemberJoined event. Called once by Factory after
  ///         TemplCreated so indexers create the Templ entity before the join event.
  function emitPriestJoin() external;

  /// @notice Set the governance address. Only callable by current governance.
  /// @param gov New governance address (can be an EOA, multisig, or governance contract)
  function setGovernance(
    address gov
  ) external;

  // ============ Governance ============

  /// @notice Update the base entry fee anchor (curve recomputes from this)
  /// @param baseEntryFeeValue New base entry fee
  function setBaseEntryFee(
    uint256 baseEntryFeeValue
  ) external;

  /// @notice Pause or unpause new joins
  /// @param _paused True to pause, false to unpause
  function setJoinPaused(
    bool _paused
  ) external;

  /// @notice Whether new joins are currently paused
  function joinPaused() external view returns (bool);

  /// @notice Update display metadata. Only callable by governance.
  /// @param name New display name
  /// @param description New description
  /// @param logoLink New logo URL or IPFS hash
  function updateMetadata(
    string calldata name,
    string calldata description,
    string calldata logoLink
  ) external;

  /// @notice Update fee split (PROTOCOL_BPS is set once in constructor).
  ///         The triple plus PROTOCOL_BPS must sum to BPS (10_000).
  /// @param burnBpsValue New burn share in basis points
  /// @param treasuryBpsValue New treasury share in basis points
  /// @param memberPoolBpsValue New member pool share in basis points
  function setFeeSplit(
    uint256 burnBpsValue,
    uint256 treasuryBpsValue,
    uint256 memberPoolBpsValue
  ) external;

  /// @notice Update the token burn destination address. Reverts on the zero
  ///         address; defaults are resolved in the Templ constructor.
  /// @param burnAddressValue New burn address (must not be zero)
  function setBurnAddress(
    address burnAddressValue
  ) external;

  /// @notice Update the referral's share of the member pool.
  /// @param bps New referral share in basis points (0 = no referral, 10000 = full pool)
  function setReferralShareBps(
    uint256 bps
  ) external;
}
