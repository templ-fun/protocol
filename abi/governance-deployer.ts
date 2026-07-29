/**
 * GovernanceDeployer ABI - subset for frontend operations.
 *
 * Routes genesis governance deployments to the appropriate sub-deployer
 * (DemocracyDeployer or CouncilDeployer) based on GovernanceConfig.mode.
 * The frontend reads `DEMOCRACY_DEPLOYER` and `COUNCIL_DEPLOYER` to resolve
 * the per-network deployer addresses, which avoids hard-coding them in
 * the UI config (each chain has its own pair).
 */
export const GOVERNANCE_DEPLOYER_ABI = [
  {
    type: "function",
    name: "DEMOCRACY_DEPLOYER",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "COUNCIL_DEPLOYER",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "factory",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
] as const;
