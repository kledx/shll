# shll — Decentralized AI Agent Rental Protocol

> Secure, permissionless AI Agent leasing on BNB Chain (opBNB / BSC)

## Overview

shll enables AI Agent owners to rent out their agents via NFTs (ERC-721 + ERC-4907) while maintaining full asset security through an on-chain firewall — **PolicyGuard**.

**Core idea**: Renters can use an AI Agent to execute DeFi operations (swap, approve, repay), but every action is validated against configurable allowlists and parameter constraints. The agent's funds stay in an isolated vault — renters can never drain them.

## Architecture

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Renter EOA  │────▶│   AgentNFA   │────▶│ PolicyGuard  │
└──────────────┘     │  (ERC-721 +  │     │ (On-chain    │
                     │   ERC-4907)  │     │  Firewall)   │
                     └──────┬───────┘     └──────────────┘
                            │
                     ┌──────▼───────┐     ┌──────────────┐
                     │ AgentAccount │────▶│  DeFi Target │
                     │  (Vault)     │     │(Router/Token)│
                     └──────────────┘     └──────────────┘

┌──────────────┐
│ListingManager│  Marketplace: list / rent / extend / cancel
└──────────────┘
```

## Contracts

| Contract | Description |
|----------|-------------|
| **AgentNFA** | ERC-721 + ERC-4907 identity layer. Mint agents, manage rentals, route execution |
| **AgentAccount** | Isolated vault per agent. Holds funds, executes calls (only via NFA) |
| **PolicyGuard** | On-chain firewall. Validates swap/approve/repay with allowlists + limits |
| **ListingManager** | Rental marketplace. Listing, payment, income withdrawal |

### Libraries

| Library | Description |
|---------|-------------|
| **Errors** | Unified custom errors across all contracts |
| **CalldataDecoder** | Safe calldata parsing for swap/approve/repay |
| **PolicyKeys** | Limit key constants and known function selectors |

## Security Model

PolicyGuard enforces these invariants for renter-initiated actions:

- **Swap** (`swapExactTokensForTokens`): `to` must be AgentAccount (not renter EOA), deadline window limited, path length capped, all tokens must be whitelisted
- **Approve**: No infinite approval (`type(uint256).max` blocked), spender must be whitelisted per token, amount capped
- **Repay** (`repayBorrowBehalf`): Borrower must be current renter, amount capped, vToken must be whitelisted
- **General**: Target + selector allowlist, pause capability, owner-only admin

Owner bypasses PolicyGuard entirely — they have full control of their agent.

## Tech Stack

- **Solidity** 0.8.33 (Paris EVM)
- **Foundry** (forge, cast, anvil)
- **OpenZeppelin** v4.9.6
- **Networks**: opBNB (L2) + BSC (L1)

## Quick Start

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Build
forge build

# Test (41 tests: 18 PolicyGuard + 23 Integration)
forge test

# Test with verbosity
forge test -vvv
```

## Deploy

```bash
# 1. Deploy contracts
PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast

# 2. Apply policy (configure allowlists from JSON config)
PRIVATE_KEY=0x... POLICY_GUARD=0x... CONFIG_PATH=configs/bsc.mainnet.json \
  forge script script/ApplyPolicy.s.sol --rpc-url $RPC_URL --broadcast
```

## Configuration

Network configs in `configs/`:

```
configs/
├── opbnb.mainnet.json    # opBNB mainnet addresses
├── opbnb.testnet.json    # opBNB testnet addresses
├── bsc.mainnet.json      # BSC mainnet (PancakeSwap, Venus, WBNB, USDT)
└── bsc.testnet.json      # BSC testnet addresses
```

Each config contains router addresses, token addresses, Venus vToken addresses, and default policy limits.

## Project Structure

```
src/
├── types/Action.sol           # Unified Action struct
├── libs/
│   ├── Errors.sol             # Custom errors
│   ├── CalldataDecoder.sol    # Calldata parsing
│   └── PolicyKeys.sol         # Limit keys + selectors
├── interfaces/                # IERC4907, IPolicyGuard, IAgentAccount, IAgentNFA
├── PolicyGuard.sol            # On-chain firewall
├── AgentAccount.sol           # Isolated vault
├── AgentNFA.sol               # ERC-721 + ERC-4907 identity
└── ListingManager.sol         # Rental marketplace
test/
├── PolicyGuard.t.sol          # 18 unit tests
└── Integration.t.sol          # 23 E2E + attack scenario tests
script/
├── Deploy.s.sol               # Contract deployment
└── ApplyPolicy.s.sol          # Policy configuration from JSON
configs/
├── opbnb.mainnet.json
├── opbnb.testnet.json
├── bsc.mainnet.json
└── bsc.testnet.json
```

## Test Coverage

**41/41 tests passing** ✅

Attack scenarios validated:
1. Swap output to renter EOA → **blocked**
2. Approve to unauthorized spender → **blocked**
3. Infinite approval → **blocked**
4. Withdraw to third-party address → **blocked**
5. Execute after lease expiry → **blocked**
6. Non-renter execute → **blocked**
7. Direct AgentAccount bypass → **blocked**

## License

MIT
