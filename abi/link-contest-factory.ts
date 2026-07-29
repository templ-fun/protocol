/**
 * LINK_CONTEST_FACTORY ABI - the createContest entrypoint and the
 * LinkContestCreated discovery event.
 *
 * createContest deploys a LinkContest for a templ and emits LinkContestCreated,
 * which the indexer subscribes to (Envio contractRegister) to auto-index each
 * per-templ contest. See src/plugins/link-contest/LinkContestFactory.sol.
 */
export const LINK_CONTEST_FACTORY_ABI = [
  {
    type: "function",
    name: "createContest",
    stateMutability: "nonpayable",
    inputs: [
      { name: "templ", type: "address" },
      { name: "token", type: "address" },
      { name: "submissionFee", type: "uint256" },
      { name: "roundDuration", type: "uint256" },
      { name: "firstRoundStart", type: "uint256" },
      { name: "owner_", type: "address" },
    ],
    outputs: [{ name: "contest", type: "address" }],
  },
  {
    type: "event",
    name: "LinkContestCreated",
    inputs: [
      { name: "contest", type: "address", indexed: true },
      { name: "templ", type: "address", indexed: true },
      { name: "token", type: "address", indexed: false },
      { name: "submissionFee", type: "uint256", indexed: false },
      { name: "roundDuration", type: "uint256", indexed: false },
      { name: "firstRoundStart", type: "uint256", indexed: false },
    ],
  },
  { type: "error", name: "NotAuthorized", inputs: [] },
] as const;
