// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITreasury } from "./ITreasury.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";

/// @title ITempl
/// @notice Interface for Templ membership contracts
interface ITempl {
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

  event EntryFeeUpdated(uint256 newEntryFee);

  event GovernanceUpdated(address indexed governance);

  event PriestTransferred(
    address indexed previousPriest, address indexed newPriest
  );

  event JoinPausedUpdated(bool paused);

  event MetadataUpdated(string name, string description, string logoLink);

  // ============ Errors ============

  error AlreadyMember();
  error NotMember();
  error NotPriest();
  error NotGovernance();
  error RecipientIsRequired();
  error JoinsPaused();
  error WrongToken();
  error FeeTokenMismatch();

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

  /// @notice Treasury contract that handles fee distribution
  function TREASURY() external view returns (ITreasury);

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
}
