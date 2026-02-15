# SHLL Protocol Contracts

中文说明: [README.zh.md](./README.zh.md)

Official X: https://x.com/shllrun
Testnet: https://test.shll.run

Secure, permissionless AI Agent rental contracts on BNB Chain.

SHLL lets an agent owner lease usage rights while keeping custody of funds in an isolated vault. Renters can execute approved strategy actions, but every renter action is constrained by on-chain policy checks.

## 🏆 Hackathon Reproduction (Reviewers Start Here)

**Verifiable On-Chain Proof:**
- **Script**: `script/ListDemoAgent.s.sol`
- **Function**: Deploys a Multi-Tenant Agent (Template), registers it, and creates a listing.
- **Contracts (BSC Testnet)**:
  - `AgentNFA`: `0x636557BFe696221bd05B78b04FB3d091A322D1dE`
  - `PolicyGuard`: `0x6764B3eC699D56D3dA6a8a947107bEF416eA3d78`
  - `ListingManager`: `0x8c5B5ed82e2fAFfd3cEA3F22d7CA56d033ba658d`

**How to Reproduce:**
1. Clone this repo.
2. Follow the detailed guide: [SHLL_Template_Agent_Create_Guide.md](./script/SHLL_Template_Agent_Create_Guide.md)
3. View the result on [test.shll.run](https://test.shll.run) or verify the transactions on BscScan.


## What This Repository Contains

This repository (`repos/shll`) is the smart-contract core of SHLL:

- Agent identity and rental lifecycle (`AgentNFA`)
- Isolated per-agent vault execution (`AgentAccount`)
- On-chain firewall and limits (`PolicyGuard`)
- Listing and rental marketplace flow (`ListingManager`)

## System Design

Core flow:

1. Owner mints an Agent NFA.
2. Each agent maps to an isolated account vault.
3. Owner lists the agent for rental.
4. Renter receives temporary usage rights.
5. Renter triggers actions through `AgentNFA.executeAction`.
6. `PolicyGuard` validates target/selector/tokens/limits before vault call.

Security invariant:

- Renter can use the agent only within policy.
- Renter cannot arbitrarily transfer owner assets out of vault.
- Owner always retains ultimate control and can pause or reconfigure policy.

## Contract Modules

| Contract | Responsibility |
|---|---|
| `AgentNFA` | ERC-721 + ERC-4907 + BAP-578 metadata/lifecycle; rental user assignment; execution entrypoint |
| `AgentAccount` | Isolated vault account per agent; executes approved calls |
| `PolicyGuard` | On-chain policy engine: target/selector/token/spender/amount/deadline constraints |
| `ListingManager` | Listing, rental, extension, cancellation, and fee flow |

Supporting libraries:

- `src/libs/Errors.sol`
- `src/libs/CalldataDecoder.sol`
- `src/libs/PolicyKeys.sol`

## BAP-578 and Rental Semantics

- BAP-578 enriches each agent with machine-readable metadata and a standard action model.
- ERC-4907 provides owner/user separation with an expiry-based usage right.
- `AgentNFA` binds these capabilities into explicit on-chain rental behavior.

## Repository Links

This workspace has multiple SHLL repositories for end-to-end development:

| Component | Local Path | Repository URL |
|---|---|---|
| Contracts (this repo) | `repos/shll` | https://github.com/kledx/shll |
| Web App | `repos/shll-web` | https://github.com/kledx/shll-web |
| Runner Service | `repos/shll-runner` | https://github.com/kledx/shll-runner.git |
| Indexer | `repos/shll-indexer` | https://github.com/kledx/shll-indexer |

Note: the runner URL above is the remote currently configured in this workspace.

Development note: this project was completed fully with vibe coding. For full build context and decision trails, see [ailogs](./ailogs/).

## Requirements

- Foundry (`forge`, `cast`, `anvil`)
- Solidity `0.8.33` (configured in `foundry.toml`)

Install Foundry:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## Quick Start

```bash
forge build
forge test
```

Useful commands:

```bash
forge fmt
forge test -vvv
```

## Environment

Copy and fill environment values:

```bash
cp .env.example .env
```

Common variables:

- `PRIVATE_KEY`
- `RPC_URL`
- `ETHERSCAN_API_KEY` (optional)
- `POLICY_GUARD` (for policy scripts)

## Deployment

Deploy contracts:

```bash
PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

Apply policy configuration:

```bash
PRIVATE_KEY=0x... POLICY_GUARD=0x... CONFIG_PATH=configs/bsc.mainnet.json \
  forge script script/ApplyPolicy.s.sol --rpc-url $RPC_URL --broadcast
```

Mint + list one demo agent (template):

```bash
# 1) Fill env values
cp script/demo-agent.env.example .env.demo-agent

# 2) Export env vars and run (bash example)
set -a && source .env.demo-agent && set +a
forge script script/ListDemoAgent.s.sol --rpc-url $RPC_URL --broadcast
```

## Network Configs

Policy/address presets live in `configs/`:

- `configs/opbnb.mainnet.json`
- `configs/opbnb.testnet.json`
- `configs/bsc.mainnet.json`
- `configs/bsc.testnet.json`

## BSC Testnet Addresses

| Contract | Address |
|---|---|
| `PolicyGuard` | `0x6764B3eC699D56D3dA6a8a947107bEF416eA3d78` |
| `AgentNFA` | `0x636557BFe696221bd05B78b04FB3d091A322D1dE` |
| `ListingManager` | `0x8c5B5ed82e2fAFfd3cEA3F22d7CA56d033ba658d` |

## Project Structure

```text
src/
  AgentNFA.sol
  AgentAccount.sol
  PolicyGuard.sol
  ListingManager.sol
  types/Action.sol
  interfaces/
  libs/
script/
  Deploy.s.sol
  ApplyPolicy.s.sol
  CheckPolicy.s.sol
  ListDemoAgent.s.sol
  MintTestAgents.s.sol
  demo-agent.env.example
test/
  AgentNFA.t.sol
  PolicyGuard.t.sol
  OperatorPermit.t.sol
  Integration.t.sol
configs/
```

## AI Development Logs

Session logs are stored in [ailogs](./ailogs/).

## License

MIT
