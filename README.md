# templ.fun protocol

<img width="100%" alt="templ.fun" src="assets/banner.png" />

## Why

Crypto communities need spaces where members can organise, govern, and build trust - without relying on centralised platforms that weren't designed for it. Templ brings membership, treasury, and governance on-chain so communities can run themselves on their favourite EVM network. The first app built on top of this is a private chat where only members can see each other's messages and discuss proposals - but the contracts are designed to support whatever comes next.

## Overview

[`Templ.sol`](src/Templ.sol) is the core membership contract. The person who creates a Templ becomes the **priest** - the first member, who joins for free. Everyone after that [pays an entry fee that goes up](src/Templ.sol) with each new member, following a configurable curve (see [`EntryFeeCurve.sol`](src/libraries/EntryFeeCurve.sol)). Think of it like an early-bird discount: the earlier you join, the less you pay.

When someone joins, the fee is split four ways: burn, treasury, member pool, and protocol. The [`Templ`](src/Templ.sol) splitter pays each slice directly to its destination - the burn address, [`Treasury`](src/Treasury.sol), [`MemberPool`](src/MemberPool.sol), and the protocol fee recipient - in one transaction. Existing members earn a share of the member pool automatically - no staking or locking required, just claim whenever you want. If someone was referred, the referrer gets a cut of the member pool before it's distributed. Governance can dissolve the treasury, which moves the entire treasury balance into the MemberPool to be split among members on the next join.

Templs are created through [`Factory.sol`](src/Factory.sol), which deploys a `Templ` + `Treasury` + `MemberPool` + `Governance` quad from explicit caller-provided parameters - the Factory does not substitute defaults for any field, so the UI / SDK is responsible for sensible values. On chains with a native token (ETH, MATIC, etc.), [`JoinWithNative.sol`](src/utils/JoinWithNative.sol) wraps and joins in a single transaction. Governance can pause joins at any time.

Thanks to Templ's support for ERC-2612 and Permit2 Witness, there are never lingering token approvals. Templ supports four ways to join:

- **Permit2 Witness** (`joinWithPermit2Witness`) - Users who have already approved the Permit2 contract for the entry token can *optionally* join gaslessly by signing an off-chain message. Works with any EOA wallet (MetaMask, Rabby, etc.) on any chain. Recipient, referral, and relayer tip are cryptographically bound to the signature - safe for untrusted relayers.
- **Permit2** (`joinWithPermit2`) - Same Permit2 approval, but without the witness binding. Simpler UX (clean "Spending cap request" in MetaMask). Self-submit only (msg.sender is the payer and permit signer). For gasless relay, use Permit2 Witness instead.
- **ERC-2612** (`joinWithERC2612Permit`) - For tokens with native permit support, users don't need to approve *any* contract - not even Permit2. That means one free signature + one transaction = a safe join with zero lingering approvals. Self-submit only (msg.sender is always the payer). For gasless relay, use Permit2 Witness instead.
- **Classic approve + join** (`join`) - The traditional flow: approve the token, then call join.

For users with Smart Wallets (e.g. Base Wallet), gasless transactions cover even more ground regardless of the path chosen. See [`Templ.sol`](src/Templ.sol) for all join methods.

## Architecture

### Contracts

All contracts are non-upgradeable. No proxies, no delegatecall, no initializer pattern. The only mutable reference between contracts is `governance`, which can be replaced via a successful governance proposal through `setGovernance`.

| Contract | Role |
| --- | --- |
| [`Factory`](src/Factory.sol) | Deploys Templ + Treasury + MemberPool + Governance per templ. Acts as temporary governance during deployment, then hands off control. |
| [`Templ`](src/Templ.sol) | Membership and entry fee splitter. On every paid join, fans the burn / treasury / member-pool / protocol slices out to their destinations atomically. Holds no funds. |
| [`Treasury`](src/Treasury.sol) | Programmable vault for the treasury slice of every join. Custodies any asset (ERC-20, ERC-721, native ETH). Governance can forward any portion via `execute(target, value, data)` or dissolve the entire balance into the MemberPool. |
| [`MemberPool`](src/MemberPool.sol) | Holds the member-claimable share of every paid join. No governance-callable function; the only TOKEN outflow is `claimRewards`, which always pays the member. |
| [`Governance`](src/governance/Governance.sol) | Shared proposal/voting logic. Extended by Democracy and Council. |
| [`Democracy`](src/governance/Democracy.sol) | All members vote. One person, one vote. |
| [`Council`](src/governance/Council.sol) | Only appointed council members vote. Quorum is based on council size. |
| [`EntryFeeCurve`](src/libraries/EntryFeeCurve.sol) | Library for configurable fee curves (static, linear, exponential, multi-segment). |
| [`JoinWithNative`](src/utils/JoinWithNative.sol) | Helper that wraps native ETH/MATIC and joins in a single transaction. |

### Dependencies

| Dependency | Version | Usage |
| --- | --- | --- |
| [Solady](https://github.com/Vectorized/solady) | 0.1.26 | `SafeTransferLib`, `ReentrancyGuard` (transient storage variant), `FixedPointMathLib` |
| [Permit2](https://github.com/Uniswap/permit2) | 1.0.0 | Gasless joins and votes via signed approvals |
| forge-std | 1.14.0 | Testing only - not deployed |

Permit2's canonical address (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) is hardcoded in [`Templ.sol`](src/Templ.sol) and [`Governance.sol`](src/governance/Governance.sol).

### Trust Assumptions

- **Membership is permanent.** There is no leave, exit, or burn-membership function. Once joined, a member stays a member. This is by design - membership entitles the holder to future reward shares and dissolution payouts.
- **There is always a priest.** The priest role can be transferred to another member but not renounced. `transferPriest` requires the new priest to be an existing member, so it can never be set to `address(0)`.
- **Protocol fee percentage is immutable.** Fixed at 10% in `Factory.sol`. Neither governance, the priest, nor the Factory owner can change it. The protocol fee recipient defaults to the deployer and is changeable by the Factory owner via `setProtocolFeeRecipient`. Changes are retroactive - all existing Treasuries read the recipient from Factory on each join.
- **`setGovernance` accepts any non-zero address.** The contract validates that the new governance address is not `address(0)` and calls `emitConfig()` on it, but does not verify it implements a specific interface. A governance proposal that sets this to an invalid address would brick governance for that Templ.
- **Permit2 canonical deployment is trusted.** The hardcoded Permit2 address is assumed to be the legitimate Uniswap deployment on the target chain.
- **ERC20 token is trusted.** The entry token is set at creation and assumed to behave as a standard ERC20 (see [Token Compatibility](#token-compatibility)).

## Governance

Each Templ has a governance contract that controls its rules. The [`Factory`](src/Factory.sol) deploys one during creation - either a [`Democracy`](src/governance/Democracy.sol) or a [`Council`](src/governance/Council.sol), both built on shared [`Governance`](src/governance/Governance.sol) foundations. The only way to change the governance contract is through a successful proposal.

**Democracy** - every member can propose and vote. One person, one vote.

**Council** - any member can propose, but only appointed council members can vote. Quorum is based on the number of council members (not total members). Council seats are managed through governance proposals.

### What Governance Can Do

Through proposals, governance controls the economic and operational rules of a Templ:

- Change the base entry fee
- Adjust the fee split between burn, treasury, and member pool
- Forward treasury assets via `execute` or dissolve the balance into the MemberPool
- Change the burn address and referral share
- Pause and unpause joins
- Upgrade the governance contract itself (e.g. switch from Council to Democracy)
- Adjust voting rules: quorum, approval threshold, execution delay, voting period, immediate execution, and proposal fee
- In a Council, add or remove council members
- **Execute arbitrary external calls** - interact with any contract (DeFi protocols, multisigs, NFTs, etc.) via batch proposals. This enables yield strategies, token swaps, and any on-chain operation the community votes to approve

The priest can transfer the priest role to another member without a proposal. The priest (and council members in a Council) can also create emergency dissolution proposals (see [below](#emergency-dissolution)).

### Voting Rules

All rules are configurable through proposals. Changing any rule requires the same voting process as any other proposal - a minority can't weaken governance on their own.

> **Note on the "Typical" column.** The Factory does **not** substitute defaults
> for any field - every value is stored as-is. The numbers below are what the
> templ.fun UI pre-fills on the create form, and what our deploy CLI mirrors.
> If you call `Factory.createTempl` directly (e.g. from etherscan or your own
> SDK), you must provide explicit values for every field.

| Parameter                 | Typical      | What it means |
| ------------------------- | ------------ | ------------- |
| **quorumBps**             | 1000 (10%)   | **"Did enough people show up?"** At least this percentage of eligible members must vote (For + Against + Abstain) for the result to count. With the default 10%, a proposal where only 5% of members voted fails regardless of how many said Yes. Prevents a tiny group from passing proposals while everyone else is inactive. |
| **approvalThresholdBps**  | 5100 (51%)   | **"Of the people who picked a side, did enough say Yes?"** Measured as For / (For + Against) - abstain votes don't count here. At 51%, a bare majority is enough. Set it to 67% if you want supermajority requirements. This prevents proposals from passing on a slim margin of a few votes. |
| **executionDelay**        | 1 day        | **"How long do we wait before executing?"** After enough people have voted (quorum is reached), there's a waiting period before the proposal can actually run. This gives members time to review, change their vote, or prepare. The countdown starts when quorum is reached, not when the proposal was created. Anyone can trigger execution once the delay passes. |
| **votingPeriod**          | 3 days       | **"How long can people vote?"** Members can cast or change their vote until this window closes. After it expires, the proposal either passes or fails based on the thresholds above. |
| **immediateExecutionBps** | 10000 (100%) | **"When can we skip the wait?"** If this percentage of all eligible members vote Yes, the execution delay is bypassed - the proposal runs immediately. At the default 100%, literally everyone must vote Yes to skip the wait. Lower it to 75% if you want faster execution when there's strong consensus. Must be >= approvalThresholdBps. |
| **proposalFeeBps**        | 2500 (25%)   | **"Does it cost anything to create a proposal?"** A percentage of the current entry fee, charged on creation and sent to treasury. Useful for preventing spam in active communities. At 25%, creating a proposal costs 25% of what it costs to join. Payable via direct transfer (`propose`) or Permit2 signature (`proposeWithPermitWitness`). |

**Why immediateExecutionBps must be >= approvalThresholdBps:** Immediate execution measures Yes votes against *all* eligible members, while approval threshold only measures against people who picked a side. If the fast-track bar were lower than the approval bar, a proposal could skip the waiting period with fewer Yes votes than it needs to actually pass. The contract enforces this.

### How Proposals Work

A proposal is a batch of actions that can target **any address**: the Templ, Treasury, governance contract, or any external contract (DeFi protocols, tokens, multisigs, etc.). All actions execute together or not at all (atomic batch). When a proposal is created, the current membership is snapshotted: only people who were already members can vote. This prevents someone from joining just to swing a vote.

Votes are simple: **Against (0)**, **For (1)**, or **Abstain (2)**.

A proposal passes when two conditions are met:

- **Enough people showed up** (quorum) - total votes divided by eligible members reaches `quorumBps`. Abstain counts as showing up but doesn't push the result either way.
- **Enough said Yes** (approval) - Yes votes divided by (Yes + No) reaches `approvalThresholdBps`. Abstain is excluded here - it helps meet quorum without influencing the outcome.

Once both are met, the execution delay starts (counted from when quorum was first reached). After the delay, anyone can call `execute()`. If the fast-track threshold is met, execution happens immediately.

Members can change their vote any time before voting closes. Each member can only have one active proposal at a time, and only the proposer can cancel it. A `state()` view returns the current stage: Pending, Active, Succeeded, Defeated, Executed, or Cancelled.

The governance contract accepts ETH via `receive()` for proposals that need to forward value.

### Emergency Dissolution

The priest (and council members in a Council) can create special dissolution proposals via `proposeDissolution`. These skip the normal quorum and approval requirements - the only rule is that Yes > No. They still go through the full voting period and execution delay. Members can vote No to block them.

This exists for one scenario only: distributing treasury funds back to members when normal governance can't act - for example, a community went inactive and quorum is unreachable, funds are stuck, or there's a vulnerability that needs urgent action. It cannot be used for anything else.

### Relationship to OZ Governor

The governance follows the same conventions as [OpenZeppelin Governor](https://docs.openzeppelin.com/contracts/5.x/governance) - same vote values (0/1/2), same `targets/values/calldatas` proposal format - but adapted for one-person-one-vote membership instead of token-weighted voting.

Key differences from OZ Governor:

- **Approval threshold** - OZ only requires Yes > No. Templ also requires a minimum approval percentage (default 51%), so proposals can't pass on a handful of votes that technically have more Yes than No.
- **Immediate execution** - If enough members vote Yes (default: everyone), the execution delay is skipped. Think of it as: "if everyone agrees, just do it now."
- **Execution delay starts at quorum** - OZ uses a separate timelock queue step. Templ starts the countdown as soon as enough people have voted, which is simpler.

## Incentives

### Typical Fee Split

The protocol fee is hardcoded at 10% (immutable). The other three splits must
be provided explicitly on every `createTempl` call - the Factory does not
substitute defaults. The numbers below are what the UI pre-fills.

| Where it goes | Share |
| ------------- | ----- |
| Burn          | 30%   |
| Treasury      | 30%   |
| Member Pool   | 30%   |
| Protocol      | 10%   |

When a referral is active, the referrer gets 25% of the member pool portion before the rest is distributed.

### Priests

Join for free. Earn the same share of the member pool as everyone else on every new join and on dissolution. Zero cost, proportional upside. Can create emergency dissolution proposals, but those still require voting and can be blocked.

### Early Members

The entry fee grows with each join (the UI's pre-filled curve is 0.5% exponential growth for 500 joins, then flat; the Factory accepts any caller-provided curve that passes `EntryFeeCurve.validate`). Earlier members pay less, earn rewards from more future joins, and split the pool among fewer people.

### Members

Every member earns from the member pool on each new join, claimable any time with no lock-up. In a Democracy, every member can propose and vote. In a Council, any member can propose but only council members vote.

### Referrers

Referring a new member pays the referrer a direct cut (typical: 25% of the member pool portion) on top of their regular share. The cut is set per-templ at deploy time via `referralShareBps` and the Factory stores whatever value is passed.

### Burns

30% of every entry fee is burned, reducing token supply. Token holders outside the Templ benefit indirectly.

### Treasury

30% goes to a governance-controlled treasury. Governance can forward it via `execute` (any asset, any recipient), dissolve it into the MemberPool (split equally among members on the next join), or let it grow.

### Protocol

A fixed percentage of every join fee, set at deploy time. Not changeable by governance - this is how the protocol sustains itself.

## Rug Pull Resistance

No single person - including the priest - can drain funds or take control unilaterally.

### The Priest Cannot

- **Drain funds.** The priest can only create dissolution proposals, which distribute funds *equally* to all members. Members vote to approve or block. No funds leave the system.
- **Change governance.** Only a successful proposal can replace the governance contract.
- **Change fees or rules.** Entry fee, fee splits, burn address, pause state - all require a governance vote.
- **Remove members or block claims.** There's no member removal function. Members claim rewards directly from the MemberPool, which has no governance-callable function and no withdraw - the only TOKEN outflow is `claimRewards` paying the member.

The priest can transfer the priest role to another member and create emergency dissolution proposals. That's it.

### Governance Requires Voting

Every governance action goes through the full proposal lifecycle: creation, voting, waiting period, execution. The membership snapshot prevents join-and-vote attacks.

### Voting Rules Are Self-Protecting

All governance rules can be changed through proposals - but changing them requires the same voting process as anything else. A minority can't lower quorum or weaken thresholds on their own.

Governance parameters are snapshotted when each proposal is created. If a parameter changes while a proposal is being voted on, the original values still apply to that proposal. This prevents retroactive manipulation of active votes.

### Member Pool Is Protected

Member rewards live on a separate `MemberPool` contract, not the Treasury. The MemberPool has no governance-callable function and no withdraw - the only TOKEN outflow is `claimRewards`, which always pays the member. The address boundary is the safety guarantee. Dissolution moves the entire treasury balance into the MemberPool, where it is folded into the next per-member distribution.

### Protocol Fee Is Fixed

The protocol fee percentage (10%) is a constant in `Factory.sol` - not changeable by anyone. The fee recipient defaults to the Factory deployer and is changeable by the Factory owner. Neither governance nor the priest can change the fee percentage or the recipient.

### Arbitrary External Calls (OZ Governor Pattern)

Proposals can target **any address** with any calldata and ETH value, just like [OpenZeppelin Governor](https://docs.openzeppelin.com/contracts/5.x/governance). This enables the community to invest in yield protocols, swap tokens, interact with DeFi, recover stuck assets, and do anything else on-chain, as long as it passes a vote.

Security is enforced by the governance process itself:

- **Voting + quorum** - every external call requires community approval
- **Execution delay** - members have time to review and change their vote before execution
- **Membership snapshot** - prevents join-and-vote attacks
- **No delegatecall** - proposals use `call`, never `delegatecall`, so governance storage cannot be corrupted
- **Reentrancy guard** - proposal creation and execution are protected by Solady's transient reentrancy guard
- **Atomic batch** - all actions in a proposal execute together or revert together

## Development

Built with [Foundry](https://book.getfoundry.sh/) and [Soldeer](https://soldeer.xyz/). See `makefile` for all commands.

```bash
make install   # install dependencies
make build     # compile contracts
make test      # run tests
```

## Deploy

All contracts are deployed via CREATE2 through the [Deterministic Deployment Proxy](https://github.com/Arachnid/deterministic-deployment-proxy) (`0x4e59b44847b379578588920cA78FbF26c0B4956C`), producing identical addresses across all EVM chains.

The deploy script ([`Deploy.s.sol`](script/Deploy.s.sol)) deploys four contracts in order:

1. `DemocracyDeployer` - deploys Democracy governance instances
2. `CouncilDeployer` - deploys Council governance instances
3. `GovernanceDeployer` - routes to the correct sub-deployer based on governance mode
4. `Factory` - the public entry point for creating Templs

Individual Templs are created via `Factory.createTempl()` after deployment.

```bash
cp .env.example .env
make predict NETWORK=base_sepolia   # preview deterministic addresses
make deploy NETWORK=base_sepolia    # deploy + verify on Etherscan and Sourcify
```

## Edge Cases

### Fee Drift on Permit2 Signatures

The entry fee goes up with each join. If you sign a Permit2 message to join or create a proposal, and other people join between your signing and execution, the fee may have increased.

How it's handled:

- You set a max fee when signing (`permit.permitted.amount`). Think of it as a slippage tolerance - "I'll pay up to this much."
- If the actual fee is within your cap, it works. You only pay the real fee, not the full cap.
- If the fee went above your cap, the transaction reverts **without using your nonce**. You can re-sign with the same nonce and a higher cap.

This applies to any action where the cost depends on the entry fee: joining, proposing (when proposal fees are enabled), and any future fee-based actions.

`voteWithPermitWitness` is not affected - voting uses a 0-amount transfer for authentication only.

## Token Compatibility

All four join methods measure the actual `Templ` balance delta (`balanceOf` before/after the transfer) and compare it against the expected entry fee. If the delivered amount differs from the expected fee, the transaction reverts with `FeeTokenMismatch`. This rejects **fee-on-transfer tokens** and **rebasing tokens** at the join gate - no accounting drift, no partial deliveries, no shortfalls.

`SafeTransferLib` (Solady) handles missing return values and reverts on failure.
