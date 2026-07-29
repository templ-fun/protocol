/**
 * Factory ABI - subset for frontend and script operations.
 * Full ABI: abi/Factory.json
 *
 * createTempl takes a single CreateConfig struct containing:
 *   - Core: token, baseEntryFee, slug, name, description, logoLink
 *   - Fee splits: burnBps, treasuryBps, memberPoolBps (must sum to 9000;
 *     the protocol fee takes the remaining 1000 bps)
 *   - Curve: primary segment + additional segments (must validate via
 *     EntryFeeCurve.validate; pass `{ Static, 0, 0 }` for a flat curve)
 *   - Governance: mode (Democracy/Council), thresholds, council addresses
 *
 * The Factory does not substitute defaults for any field - the
 * convenience layer (UI / SDK) is the canonical source of defaults.
 */
const CREATE_CONFIG_COMPONENTS = [
  { name: "token", type: "address" },
  { name: "baseEntryFee", type: "uint256" },
  { name: "slug", type: "string" },
  { name: "name", type: "string" },
  { name: "description", type: "string" },
  { name: "logoLink", type: "string" },
  { name: "burnBps", type: "uint256" },
  { name: "treasuryBps", type: "uint256" },
  { name: "memberPoolBps", type: "uint256" },
  { name: "referralShareBps", type: "uint256" },
  {
    name: "curve",
    type: "tuple",
    components: [
      {
        name: "primary",
        type: "tuple",
        components: [
          { name: "style", type: "uint8" },
          { name: "rateBps", type: "uint32" },
          { name: "length", type: "uint32" },
        ],
      },
      {
        name: "additionalSegments",
        type: "tuple[]",
        components: [
          { name: "style", type: "uint8" },
          { name: "rateBps", type: "uint32" },
          { name: "length", type: "uint32" },
        ],
      },
    ],
  },
  {
    name: "governance",
    type: "tuple",
    components: [
      { name: "mode", type: "uint8" },
      { name: "approvalThresholdBps", type: "uint256" },
      { name: "quorumBps", type: "uint256" },
      { name: "votingPeriod", type: "uint256" },
      { name: "executionDelay", type: "uint256" },
      { name: "immediateExecutionBps", type: "uint256" },
      { name: "proposalFeeBps", type: "uint256" },
      { name: "council", type: "address[]" },
    ],
  },
] as const;

export const FACTORY_ABI = [
  {
    type: "function",
    name: "createTempl",
    inputs: [
      { name: "config", type: "tuple", components: CREATE_CONFIG_COMPONENTS },
    ],
    outputs: [{ name: "templ", type: "address" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "createTemplFor",
    inputs: [
      { name: "priest", type: "address" },
      { name: "config", type: "tuple", components: CREATE_CONFIG_COMPONENTS },
    ],
    outputs: [{ name: "templ", type: "address" }],
    stateMutability: "nonpayable",
  },
  {
    type: "event",
    name: "TemplCreated",
    inputs: [
      { name: "templ", type: "address", indexed: true },
      { name: "priest", type: "address", indexed: true },
      { name: "token", type: "address", indexed: true },
      { name: "treasury", type: "address", indexed: false },
      { name: "memberPool", type: "address", indexed: false },
      { name: "creator", type: "address", indexed: false },
      { name: "baseEntryFee", type: "uint256", indexed: false },
      { name: "slug", type: "string", indexed: false },
      { name: "name", type: "string", indexed: false },
      { name: "description", type: "string", indexed: false },
      { name: "logoLink", type: "string", indexed: false },
    ],
  },
  {
    type: "function",
    name: "slugToTempl",
    inputs: [{ name: "slug", type: "string" }],
    outputs: [{ name: "templ", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "updateSlug",
    inputs: [
      { name: "templ", type: "address" },
      { name: "newSlug", type: "string" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "event",
    name: "SlugUpdated",
    inputs: [
      { name: "templ", type: "address", indexed: true },
      { name: "oldSlug", type: "string", indexed: false },
      { name: "newSlug", type: "string", indexed: false },
    ],
  },
  {
    type: "function",
    name: "isTempl",
    inputs: [{ name: "templ", type: "address" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "protocolFeeRecipient",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "PROTOCOL_FEE_BPS",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isOpen",
    inputs: [],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "setOpen",
    inputs: [{ name: "_isOpen", type: "bool" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "setProtocolFeeRecipient",
    inputs: [{ name: "_recipient", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "owner",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "GOV_DEPLOYER",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "event",
    name: "OpenUpdated",
    inputs: [{ name: "isOpen", type: "bool", indexed: false }],
  },
  {
    type: "event",
    name: "ProtocolFeeRecipientUpdated",
    inputs: [{ name: "recipient", type: "address", indexed: true }],
  },
  {
    type: "function",
    name: "transferOwnership",
    inputs: [{ name: "newOwner", type: "address" }],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "event",
    name: "OwnershipTransferred",
    inputs: [
      { name: "oldOwner", type: "address", indexed: true },
      { name: "newOwner", type: "address", indexed: true },
    ],
  },
] as const;
