# SHLL Protocol — The Agent Smart Contract Layer

中文说明: [README.zh.md](./README.zh.md)

Official Website: https://shll.run
Official X: https://x.com/shllrun
Skills (MCP/CLI): [shll-skills](https://www.npmjs.com/package/shll-skills)

Secure, permissionless AI Agent rental and execution contracts on BNB Smart Chain.

SHLL lets an agent owner lease usage rights while keeping custody of funds in an isolated vault. Renters (or AI models) can execute approved strategy actions, but every single action is constrained by an on-chain firewall.

---

## What This Repository Contains

| Component | Contract | Description |
|---|---|---|
| **Agent Identity** | `AgentNFA.sol` | ERC-721 + ERC-4907 + BAP-578 (Non-Fungible Agent) standard |
| **Isolated Vaults** | `AgentAccountV2.sol` | ERC-6551 inspired vault holding agent capital |
| **On-chain Firewall** | `PolicyGuardV4.sol` | Policy engine coordinating all security policies |
| **Marketplace** | `ListingManagerV2.sol` | Rent-to-Mint logic, time-based leasing |
| **Subscriptions** | `SubscriptionManager.sol` | Subscription model and fee routing |
| **Protocol Registry** | `ProtocolRegistry.sol` | DeFi protocol + function whitelist registry |
| **Learning Module** | `LearningModule.sol` | On-chain agent learning and improvement tracking |

## 🛡️ 4-Core Security Model

The SHLL protocol protects renter capital from compromised or hallucinating AIs using 4 composable policies enforced by `PolicyGuardV4`:

| Policy | Defense Mechanism |
|---|---|
| **SpendingLimitPolicyV2** | Per-transaction and daily spending caps for both native BNB and ERC20 swaps. Integrates token whitelist — only approved high-liquidity tokens allowed. |
| **CooldownPolicyV2** | Minimum time interval between trades to prevent hyper-frequency fee draining. |
| **DeFiGuardPolicyV2** | Router + function selector whitelist. Only verified DEX routers (PancakeSwap V2/V3) with approved swap methods can be called. Subsumes the old DexWhitelist. |
| **ReceiverGuardPolicyV2** | All swap outputs strictly routed back to the Agent's Vault. No extraction to external addresses. |

> **Fail-close**: If no policies are bound, all actions are blocked. Not "default allow."
>
> *Even if an AI's hot wallet key is fully exposed, the attacker cannot steal vault funds.*

## BAP-578 (Non-Fungible Agents)

SHLL represents AI Agents as **BAP-578** tokens on BNB Chain.

- **Standardized Execution**: Native `.executeAction()` bindings for AIs
- **Rent-to-Mint**: Users can instantly clone a trading strategy into their own isolated Agent Account vault
- **True Ownership**: The AI is a tradeable, transferable, and inheritable on-chain economic entity
- **Policy Validation Framework**: [Contributed to the BAP-578 standard](https://github.com/ChatAndBuild/non-fungible-agents-BAP-578/pull/32)

## BSC Mainnet Contract Addresses

| Component / Policy | Mainnet Address |
|---|---|
| **Core Contracts** | |
| `AgentNFA` (V4.1) | [`0x71cE46099E4b2a2434111C009A7E9CFd69747c8E`](https://bscscan.com/address/0x71cE46099E4b2a2434111C009A7E9CFd69747c8E) |
| `PolicyGuardV4` | [`0x25d17eA0e3Bcb8CA08a2BFE917E817AFc05dbBB3`](https://bscscan.com/address/0x25d17eA0e3Bcb8CA08a2BFE917E817AFc05dbBB3) |
| `SubscriptionManager` | [`0x66487D5509005825C85EB3AAE06c3Ec443eF7359`](https://bscscan.com/address/0x66487D5509005825C85EB3AAE06c3Ec443eF7359) |
| `ListingManagerV2` | [`0x1f9CE85bD0FF75acc3D92eB79f1Eb472f0865071`](https://bscscan.com/address/0x1f9CE85bD0FF75acc3D92eB79f1Eb472f0865071) |
| `ProtocolRegistry` | [`0x1A5EA54a3beaf4fba75f73581cf6A945746E6DF1`](https://bscscan.com/address/0x1A5EA54a3beaf4fba75f73581cf6A945746E6DF1) |
| `LearningModule` | [`0x019765B2669b1A3FfffE8213E9bd0b0D8eb00892`](https://bscscan.com/address/0x019765B2669b1A3FfffE8213E9bd0b0D8eb00892) |
| **Security Policies (V5)** | |
| `SpendingLimitPolicyV2` | [`0x28efC8D513D44252EC26f710764ADe22b2569115`](https://bscscan.com/address/0x28efC8D513D44252EC26f710764ADe22b2569115) |
| `ReceiverGuardPolicyV2` | [`0x7A9618ec6c2e9D93712326a7797A829895c0AfF6`](https://bscscan.com/address/0x7A9618ec6c2e9D93712326a7797A829895c0AfF6) |
| `DeFiGuardPolicyV2` | [`0xD1b6a97400Bc62ed6000714E9810F36Fc1a251f1`](https://bscscan.com/address/0xD1b6a97400Bc62ed6000714E9810F36Fc1a251f1) |
| `CooldownPolicy` | [`0x0E0B2006DE4d68543C4069249a075C215510efDB`](https://bscscan.com/address/0x0E0B2006DE4d68543C4069249a075C215510efDB) |

*(All contracts are verified and open-source on BscScan)*

## Requirements

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`, `anvil`)
- Solidity `0.8.33`

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## Quick Start

```bash
# Build
forge build

# Test (283 tests)
forge test -vvv

# Deploy
cp .env.example .env
# Fill in your RPC_URL and deployer key
forge script script/DeployV32PostAudit.s.sol --rpc-url $RPC_URL --broadcast --verify
```

## Repository Structure

```
src/
├── AgentNFA.sol              # ERC-721 + BAP-578 agent identity
├── AgentNFAExtensions.sol    # Template/instance extension logic
├── AgentAccount.sol          # ERC-6551 vault V1
├── AgentAccountV2.sol        # ERC-6551 vault V2 (holds agent capital)
├── PolicyGuardV4.sol         # On-chain firewall / policy engine
├── ListingManagerV2.sol      # Marketplace & rental logic
├── SubscriptionManager.sol   # Subscription model
├── ProtocolRegistry.sol      # DeFi protocol whitelist
├── LearningModule.sol        # Agent learning tracking
├── interfaces/               # IPolicy, ICommittable, IBAP578, IERC8004, etc.
├── policies/                 # SpendingLimitV2, CooldownPolicy, DeFiGuardV2, ReceiverGuardV2, etc.
├── libs/                     # CalldataDecoder, Errors, PolicyKeys
└── types/                    # Shared type definitions (Action.sol)

test/                         # 283 Foundry test cases
script/                       # Deployment & migration scripts
```

## SHLL Ecosystem

| Component | Repository | Description |
|---|---|---|
| **Contracts** (this repo) | [shll-protocol/shll](https://github.com/shll-protocol/shll) | Core Solidity protocol |
| **Skills** | [kledx/shll-skills](https://github.com/kledx/shll-skills) | MCP Server & CLI tools (v5.4+) |
| **Policy SDK** | [kledx/shll-policy-sdk](https://github.com/kledx/shll-policy-sdk) | TypeScript SDK for BAP-578 & PolicyGuard |
| **Indexer** | [kledx/shll-indexer](https://github.com/kledx/shll-indexer) | Real-time Ponder indexing service |

## Contributing

We welcome contributions! See our [BAP-578 Policy Validation Framework PR](https://github.com/ChatAndBuild/non-fungible-agents-BAP-578/pull/32) for an example of how we contribute to the ecosystem.

## License

MIT
