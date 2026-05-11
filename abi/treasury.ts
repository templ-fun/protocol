/**
 * TREASURY ABI - minimal subset used by the web app
 * Full ABI: abi/Treasury.json
 *
 * Treasury is a minimal vault. The burn / treasury / member-pool BPS triple,
 * the burn destination, the referral share, the protocol BPS, and the
 * cumulative `totalBurned` counter live on Templ; web consumers that need
 * any of those values should reach for `TEMPL_ABI` instead.
 *
 * What lives here:
 *   - TOKEN()       - the ERC-20 used for entry fees / treasury custody
 *   - MEMBER_POOL() - the linked MemberPool contract (where dissolve forwards)
 *   - dissolve()    - governance-only escape hatch
 *
 * Member-claimable funds live in the companion MemberPool contract -
 * see abi/member-pool.ts.
 *
 * Treasury exposes a generic programmable-vault `execute(target, value, data)`
 * surface for arbitrary asset movement; consumers that need the live treasury
 * balance should read TOKEN() and call `IERC20.balanceOf(treasury)` directly.
 */
export const TREASURY_ABI = [
  {
    type: "function",
    name: "TOKEN",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "MEMBER_POOL",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "dissolve",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    type: "function",
    name: "execute",
    stateMutability: "nonpayable",
    inputs: [
      { name: "target", type: "address" },
      { name: "value", type: "uint256" },
      { name: "data", type: "bytes" },
    ],
    outputs: [{ name: "result", type: "bytes" }],
  },
] as const;
