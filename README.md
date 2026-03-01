# SHLL Protocol Contracts - The Agent Smart Contract Layer

中文说明: [README.zh.md](./README.zh.md)

Official Website: https://shll.run
Official X: https://x.com/shllrun
Skills (MCP/CLI): [shll-skills](https://www.npmjs.com/package/shll-skills)

Secure, permissionless AI Agent rental and execution contracts on BNB Smart Chain.

SHLL lets an agent owner lease usage rights while keeping custody of funds in an isolated vault. Renters (or AI models) can execute approved strategy actions, but every single action is constrained by an on-chain firewall. 

---

## What This Repository Contains

This repository (`repos/shll`) is the immutable smart-contract core of SHLL:

- **Agent Identity & Ownership** (`AgentNFA.sol`): Implements ERC-721, ERC-4907, and the native **BAP-578** (Non-Fungible Agent) standard for BNB Chain.
- **Isolated Vaults** (`AgentAccount.sol`): The ERC-6551 inspired vault that holds the actual capital safely.
- **On-chain Firewall** (`PolicyGuardV4.sol`): The 5-layer security engine that prevents AI from extracting value maliciously.
- **Marketplace & Subscriptions** (`ListingManagerV2.sol`, `SubscriptionManager.sol`): Rent-to-Mint logic, time-based leasing, and fee routing.

## 🛡️ V4 Architecture: The 5-Layer Security Model

The SHLL protocol protects renter capital from compromised or hallucinating AIs using a layered defense logic implemented in `PolicyGuardV4`:

| Layer | Policy | Defense Mechanism |
|---|---|---|
| **L1** | `ReceiverGuardPolicy` | **No Extraction**: AI cannot `transfer` funds. All swapped/yield assets are strictly routed back to the Agent's Vault. |
| **L2** | `SpendingLimitPolicyV2`| **Loss Capping**: Imposes maximum trade amounts and strict slippage tolerance per execution. |
| **L3** | `TokenWhitelistPolicy` / `DexWhitelistPolicy` | **Scam Protection**: Restricts operations exclusively to approved high-liquidity tokens and verifiable DEX routers. |
| **L4** | `DeFiGuardPolicyV2` | **Function Filtering**: Prevents malicious contract deployments or calling arbitrary, destructive functions. |
| **L5** | `CooldownPolicy` | **Circuit Breaker**: Enforces a minimum time delay between trades to prevent hyper-frequency fee draining. |

*Even if an AI's private key (hot wallet) is fully exposed, the attacker cannot steal the funds.*

## BAP-578 (Non-Fungible Agents)

SHLL represents AI Agents as **BAP-578** tokens. 
- **Standardized Execution**: Native `.executeAction()` bindings for AIs.
- **Rent-to-Mint**: Users can instantly clone a trading strategy into their own isolated Agent Account vault.
- **True Ownership**: The AI is a tradeable, transferable, and inheritable on-chain economic entity.

## BSC Mainnet Contract Addresses

| Component / Policy | V4 Mainnet Address |
| --- | --- |
| **Core Contracts** | |
| `AgentNFA` | `0xe98dcdbf370d7b52c9a2b88f79bef514a5375a2b` |
| `PolicyGuardV4` | `0x25d17ea0e3bcb8ca08a2bfe917e817afc05dbbb3` |
| `SubscriptionManager` | `0x66487D5509005825C85EB3AAE06c3Ec443eF7359` |
| `ListingManagerV2` | `0x1f9CE85bD0FF75acc3D92eB79f1Eb472f0865071` |
| **Security Policies** | |
| `SpendingLimitPolicyV2` | `0xd942dEe00d65c8012E39037a7a77Bc50645e5338` |
| `ReceiverGuardPolicyV2` | `0x54809f7B7801dD9689bb99dbb4d7Ac4bfcDd6d46` |
| `DexWhitelistPolicyV2` | `0xBa411c5Ef09f8116044dfC1356C6Cd1e0E7ede0D` |
| `TokenWhitelistPolicy` | `0xfd8e7f4180ea5af0d61c2037cd7ceecf34bee1e1` |
| `DeFiGuardPolicyV2` | `0xB248AF39b849fB10c271f13220c86be4cb56eD0e` |
| `CooldownPolicyV2` | `0x1169d1B2A6f597da152f153437376729371735ea` |

*(All contracts are verified and open-source on BscScan).*

## Requirements

- Foundry (`forge`, `cast`, `anvil`)
- Solidity `0.8.33` (configured in `foundry.toml`)

Install Foundry:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## Quick Start & Testing

```bash
forge build
forge test -vvv
```

## Deployment

Copy and fill environment values from `.env.example`:

```bash
cp .env.example .env
```

To deploy the V4 environment:

```bash
forge script script/DeployV40Full.s.sol:DeployV40Full --rpc-url $RPC_URL --broadcast --verify
```

## SHLL Monorepo Structure

This workspace has multiple SHLL repositories for end-to-end AI Agent development:

| Component | Repository Path | Description |
|---|---|---|
| **Contracts** (this repo) | [repos/shll](https://github.com/kledx/shll) | Core solidity protocol |
| **OpenClaw Skill** | [repos/shll-openclaw-skill](https://github.com/kledx/shll-skills) | MCP Server & CLI tools for AIs (v5.4+) |
| **Policy SDK** | [repos/shll-policy-sdk](https://github.com/kledx/shll-policy-sdk) | TypeScript SDK for BAP-578 & PolicyGuard interactions |
| **Indexer** | [repos/shll-indexer](https://github.com/kledx/shll-indexer) | Real-time Ponder indexing service |

## License

MIT
