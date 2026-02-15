# Script Guide (Full Flow Test)

This file explains what each script in `repos/shll/script` does and how to run it.

## 0. Prerequisites

- Foundry installed (`forge --version`)
- PowerShell on Windows
- Wallet in `PRIVATE_KEY` has testnet gas
- Recommended working directory: `E:\work_space\shll`

## 1. Script Index

1. `script/Deploy.s.sol`  
Deploys core contracts: `PolicyGuard`, `AgentNFA`, `ListingManager`, and links them.

2. `script/ApplyPolicy.s.sol`  
Applies allowlists and limits from `configs/*.json` to `PolicyGuard` (idempotent).

3. `script/CheckPolicy.s.sol`  
Read-only validation between config JSON and on-chain `PolicyGuard` state.

4. `script/MintTestAgents.s.sol`  
Mints 2 fixed test agents and lists them.

5. `script/ListDemoAgent.s.sol`  
Mints and lists 1 configurable demo agent from env vars.

6. `script/UpdateAgentPack.s.sol`  
Updates `vaultURI` and `vaultHash` for an existing agent token.

7. `script/hashPack.ts`  
Canonicalizes manifest JSON and generates SHA256 for `vaultHash`.

8. `script/run-list-demo.ps1`  
Loads `.env.demo-agent`, runs `ListDemoAgent`, optional `-Broadcast`.

9. `script/run-update-pack.ps1`  
Loads `.env.update-pack`, runs `UpdateAgentPack`, optional `-Broadcast`.

## 2. Env Templates

1. `script/demo-agent.env.example`  
Template for `ListDemoAgent` and `run-list-demo.ps1`.  
Copy to `repos/shll/.env.demo-agent`.

2. `script/update-pack.env.example`  
Template for `UpdateAgentPack` and `run-update-pack.ps1`.  
Copy to `repos/shll/.env.update-pack`.

## 3. One-line Commands

### 3.1 Deploy Contracts

```powershell
cd repos/shll; forge script script/Deploy.s.sol:Deploy --rpc-url https://data-seed-prebsc-1-s1.bnbchain.org:8545 --broadcast
```

Required env:
- `PRIVATE_KEY`

### 3.2 Apply Policy (write on-chain)

```powershell
cd repos/shll; $env:POLICY_GUARD="0xYourPolicyGuard"; $env:CONFIG_PATH="configs/bsc.testnet.json"; forge script script/ApplyPolicy.s.sol:ApplyPolicy --rpc-url https://data-seed-prebsc-1-s1.bnbchain.org:8545 --broadcast
```

Required env:
- `PRIVATE_KEY`
- `POLICY_GUARD`
- `CONFIG_PATH` (use files under `configs/` due Foundry fs permissions)

### 3.3 Check Policy (read-only)

```powershell
cd repos/shll; $env:POLICY_GUARD="0xYourPolicyGuard"; $env:CONFIG_PATH="configs/bsc.testnet.json"; forge script script/CheckPolicy.s.sol:CheckPolicy --rpc-url https://data-seed-prebsc-1-s1.bnbchain.org:8545
```

Required env:
- `POLICY_GUARD`
- `CONFIG_PATH`

### 3.4 Mint and List 2 Test Agents

```powershell
cd repos/shll; forge script script/MintTestAgents.s.sol:MintTestAgents --rpc-url https://data-seed-prebsc-1-s1.bnbchain.org:8545 --broadcast
```

Required env:
- `PRIVATE_KEY`
- `AGENT_NFA`
- `LISTING_MANAGER`

### 3.5 Mint and List Demo Agent (recommended)

```powershell
powershell -ExecutionPolicy Bypass -File .\repos\shll\script\run-list-demo.ps1 -EnvFile .\repos\shll\.env.demo-agent -Broadcast
```

Common env keys in `.env.demo-agent`:
- `PRIVATE_KEY`
- `RPC_URL`
- `AGENT_NFA`
- `LISTING_MANAGER`
- `DEMO_OWNER`
- `DEMO_POLICY_ID`
- `DEMO_VAULT_URI`
- `DEMO_VAULT_HASH`
- Display fields: `DEMO_TOKEN_URI`, `DEMO_PERSONA_JSON`, `DEMO_EXPERIENCE`, etc.

### 3.6 Update Agent Pack Pointer

```powershell
powershell -ExecutionPolicy Bypass -File .\repos\shll\script\run-update-pack.ps1 -EnvFile .\repos\shll\.env.update-pack -Broadcast
```

Required env in `.env.update-pack`:
- `PRIVATE_KEY`
- `RPC_URL`
- `AGENT_NFA`
- `UPDATE_TOKEN_ID`
- `UPDATE_VAULT_URI`
- `UPDATE_VAULT_HASH`

### 3.7 Generate Pack Hash (`vaultHash`)

```powershell
cd repos/shll; node --experimental-strip-types script/hashPack.ts ..\shll-packs-private\base_trader\manifest.json
```

Output includes:
- canonical JSON
- `SHA256` hex
- `bytes32` value for on-chain metadata

## 4. Recommended Full-flow Order

1. Deploy contracts (`Deploy.s.sol`) if not already deployed.
2. Apply policy (`ApplyPolicy.s.sol`).
3. Verify policy (`CheckPolicy.s.sol`).
4. Publish pack in `repos/shll-packs-private` and get `vaultURI`.
5. Generate `vaultHash` (`hashPack.ts`).
6. Fill `.env.demo-agent`, run `run-list-demo.ps1 -Broadcast`.
7. For existing token updates, fill `.env.update-pack`, run `run-update-pack.ps1 -Broadcast`.
8. Wait for indexer catch-up, then verify pack/autopilot behavior in Console UI.

## 5. Common Errors

1. `contract source info format must be <path>:<contractname>`  
Use full target format like `script/File.s.sol:ContractName`.

2. `vm.envAddress ... odd number of digits`  
Address must be exact `0x` + 40 hex chars. Do not pass placeholders like `$DEMO_OWNER`.

3. `environment variable "... not found"`  
Check env key names exactly match script expectations (case-sensitive).

4. No on-chain state changes  
Without `--broadcast` or `-Broadcast`, execution is dry-run only.
