# SHLL Protocol Contracts

中文说明: [README.zh.md](./README.zh.md)

Official X: https://x.com/shllrun
Testnet: https://test.shll.run

Secure, permissionless AI Agent rental contracts on BNB Chain.

SHLL lets an agent owner lease usage rights while keeping custody of funds in an isolated vault. Renters can execute approved strategy actions, but every renter action is constrained by on-chain policy checks.

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

## Network Configs

Policy/address presets live in `configs/`:

- `configs/opbnb.mainnet.json`
- `configs/opbnb.testnet.json`
- `configs/bsc.mainnet.json`
- `configs/bsc.testnet.json`

## BSC Testnet Addresses

| Contract | Address |
|---|---|
| `PolicyGuard` | `0xf087B0e4e829109603533FA3c81BAe101e46934b` |
| `AgentNFA` | `0xb65ca34b1526c926c75129ef934c3ba9fe6f29f6` |
| `ListingManager` | `0x71597c159007E9FF35bcF47822913cA78B182156` |

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
  MintTestAgents.s.sol
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
