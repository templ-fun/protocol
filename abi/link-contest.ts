/**
 * LINK_CONTEST ABI - minimal subset used by the web app.
 * Full ABI: abi/LinkContest.json (after `make abi-export`).
 *
 * LinkContest is a per-templ plugin: each `submit` pays the live submissionFee,
 * split 90/10 between the templ Treasury and the protocol, into the open round.
 * The owner ranks a closed round via setWinners and can retune token /
 * submissionFee / firstRoundStart / paused, and whitelist fee-exempt wallets
 * via setFeeExempt (read with feeExempt). See src/plugins/link-contest.
 */
export const LINK_CONTEST_ABI = [
  {
    type: "function",
    name: "token",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "submissionFee",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "firstRoundStart",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "paused",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "feeExempt",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "currentRound",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "submitterOf",
    stateMutability: "view",
    inputs: [
      { name: "round", type: "uint256" },
      { name: "id", type: "uint256" },
    ],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "roundEndsAt",
    stateMutability: "view",
    inputs: [{ name: "round", type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "isSubmitted",
    stateMutability: "view",
    inputs: [{ name: "normalizedLink", type: "string" }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "submit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "rawLink", type: "string" },
      { name: "normalizedLink", type: "string" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setToken",
    stateMutability: "nonpayable",
    inputs: [{ name: "newToken", type: "address" }],
    outputs: [],
  },
  {
    type: "function",
    name: "setSubmissionFee",
    stateMutability: "nonpayable",
    inputs: [{ name: "newFee", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "setFirstRoundStart",
    stateMutability: "nonpayable",
    inputs: [{ name: "newStart", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "setPaused",
    stateMutability: "nonpayable",
    inputs: [{ name: "paused_", type: "bool" }],
    outputs: [],
  },
  {
    type: "function",
    name: "setFeeExempt",
    stateMutability: "nonpayable",
    inputs: [
      { name: "accounts", type: "address[]" },
      { name: "exempt", type: "bool" },
    ],
    outputs: [],
  },
  {
    type: "event",
    name: "Submitted",
    inputs: [
      { name: "round", type: "uint256", indexed: true },
      { name: "id", type: "uint256", indexed: true },
      { name: "submitter", type: "address", indexed: true },
      { name: "link", type: "string", indexed: false },
      { name: "normalizedLink", type: "string", indexed: false },
      { name: "linkHash", type: "bytes32", indexed: false },
      { name: "feePaid", type: "uint256", indexed: false },
      { name: "treasuryAmount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "WinnersSet",
    inputs: [
      { name: "round", type: "uint256", indexed: true },
      { name: "first", type: "uint256", indexed: false },
      { name: "second", type: "uint256", indexed: false },
      { name: "third", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "TokenUpdated",
    inputs: [{ name: "newToken", type: "address", indexed: false }],
  },
  {
    type: "event",
    name: "SubmissionFeeUpdated",
    inputs: [{ name: "newFee", type: "uint256", indexed: false }],
  },
  {
    type: "event",
    name: "FirstRoundStartUpdated",
    inputs: [{ name: "newStart", type: "uint256", indexed: false }],
  },
  {
    type: "event",
    name: "PausedUpdated",
    inputs: [{ name: "paused", type: "bool", indexed: false }],
  },
  {
    type: "event",
    name: "FeeExemptUpdated",
    inputs: [
      { name: "account", type: "address", indexed: true },
      { name: "exempt", type: "bool", indexed: false },
    ],
  },
  {
    type: "error",
    name: "DuplicateLink",
    inputs: [],
  },
] as const;
