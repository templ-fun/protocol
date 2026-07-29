/**
 * DemocracyDeployer ABI - subset for frontend operations.
 *
 * The deployer exposes two entry points:
 *   - `deploy`: genesis path, called by GovernanceDeployer during Factory.createTempl.
 *     Salt = bytes32(uint160(templ)); fires exactly once per templ.
 *   - `deployFor`: switch path, called by the templ's current governance through
 *     a passing proposal. Salt is namespaced by a per-templ nonce
 *     (keccak256(templ, ++switchNonce[templ])) so successive switches never collide.
 *
 * The frontend uses `predictDeployForAddress` to compute the next CREATE2 address
 * before the proposal executes, so a `Templ.setGovernance(predicted)` call can be
 * batched into the same proposal.
 */
export const DEMOCRACY_DEPLOYER_ABI = [
  {
    type: "function",
    name: "deployFor",
    inputs: [
      { name: "templ", type: "address" },
      { name: "approvalThresholdBps", type: "uint256" },
      { name: "quorumBps", type: "uint256" },
      { name: "executionDelay", type: "uint256" },
      { name: "votingPeriod", type: "uint256" },
      { name: "immediateExecutionBps", type: "uint256" },
      { name: "proposalFeeBps", type: "uint256" },
    ],
    outputs: [{ type: "address" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "predictDeployForAddress",
    inputs: [
      { name: "templ", type: "address" },
      { name: "approvalThresholdBps", type: "uint256" },
      { name: "quorumBps", type: "uint256" },
      { name: "executionDelay", type: "uint256" },
      { name: "votingPeriod", type: "uint256" },
      { name: "immediateExecutionBps", type: "uint256" },
      { name: "proposalFeeBps", type: "uint256" },
    ],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "switchNonce",
    inputs: [{ name: "templ", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "governanceDeployer",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "DEPLOYER_EOA",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "error",
    name: "NotAuthorized",
    inputs: [],
  },
  {
    type: "error",
    name: "AlreadyInitialized",
    inputs: [],
  },
  {
    type: "error",
    name: "ZeroAddress",
    inputs: [],
  },
] as const;
