/**
 * MEMBER POOL ABI - minimal subset used by the web app
 * Full ABI: abi/MemberPool.json
 *
 * MemberPool holds the user-claimable share of every paid join. Custody of
 * member funds lives here, isolated from the protocol-controlled Treasury
 * surface.
 */
export const MEMBER_POOL_ABI = [
  {
    type: "function",
    name: "TOKEN",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "TEMPL",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "TREASURY",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "totalDeposited",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "totalClaimed",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "rewardRemainder",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "cumulativeRewards",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "claims",
    stateMutability: "view",
    inputs: [{ name: "member", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "rewardSnapshot",
    stateMutability: "view",
    inputs: [{ name: "member", type: "address" }],
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
    name: "accrue",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    type: "event",
    name: "RewardsAccrued",
    inputs: [
      { name: "templ", type: "address", indexed: true },
      { name: "absorbed", type: "uint256", indexed: false },
      { name: "memberCount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "MemberRewardsClaimed",
    inputs: [
      { name: "templ", type: "address", indexed: true },
      { name: "member", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "MemberJoined",
    inputs: [
      { name: "templ", type: "address", indexed: true },
      { name: "member", type: "address", indexed: true },
      { name: "amountAdded", type: "uint256", indexed: false },
      { name: "newCumulative", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
] as const;
