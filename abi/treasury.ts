/**
 * TREASURY ABI - minimal subset used by the web app
 * Full ABI: abi/Treasury.json
 */
export const TREASURY_ABI = [
  {
    type: "function",
    name: "burnBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "treasuryBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "memberPoolBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "PROTOCOL_BPS",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "referralShareBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "treasuryBalance",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "memberPoolBalance",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "totalBurned",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "getClaimableRewards",
    stateMutability: "view",
    inputs: [{ name: "member", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "claimRewards",
    stateMutability: "nonpayable",
    inputs: [{ name: "member", type: "address" }],
    outputs: [],
  },
  {
    type: "function",
    name: "setFeeSplit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_burnBps", type: "uint256" },
      { name: "_treasuryBps", type: "uint256" },
      { name: "_memberPoolBps", type: "uint256" },
    ],
    outputs: [],
  },
] as const;
