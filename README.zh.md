# SHLL 协议合约

English Version: [README.md](./README.md)

官方 X： https://x.com/shllrun
测试网： https://test.shll.run

基于 BNB Chain 的安全、无许可 AI Agent 租赁合约系统。

SHLL 允许 Agent 所有者出租使用权，同时保持资产托管在隔离金库中。租户可以执行策略动作，但所有租户动作都必须通过链上策略校验。

## 🏆 黑客松复现指南 (评审员请看这里)

**链上验证证明:**
- **复现脚本**: `script/ListDemoAgent.s.sol`
- **功能**: 部署一个支持多租户的模版 Agent (Template)，注册模版，并创建租赁列表。
- **合约地址 (BSC Testnet)**:
  - `AgentNFA`: `0x636557BFe696221bd05B78b04FB3d091A322D1dE`
  - `PolicyGuard`: `0x6764B3eC699D56D3dA6a8a947107bEF416eA3d78`
  - `ListingManager`: `0x8c5B5ed82e2fAFfd3cEA3F22d7CA56d033ba658d`

**如何复现:**
1. 克隆本仓库。
2. 按照详细指南操作: [SHLL_Template_Agent_Create_Guide.md](./script/SHLL_Template_Agent_Create_Guide.md)
3. 在 [test.shll.run](https://test.shll.run) 查看结果，或在 BscScan 上验证交易。


## 仓库定位

本仓库（`repos/shll`）是 SHLL 的智能合约核心，包含：

- Agent 身份与租赁生命周期（`AgentNFA`）
- 单 Agent 隔离金库执行（`AgentAccount`）
- 链上防火墙与参数限制（`PolicyGuard`）
- 上架/租赁市场流程（`ListingManager`）

## 系统流程

核心流程：

1. 所有者铸造 Agent NFA。
2. 每个 Agent 绑定一个隔离账户金库。
3. 所有者上架 Agent 供租赁。
4. 租户获得临时使用权。
5. 租户通过 `AgentNFA.executeAction` 触发动作。
6. `PolicyGuard` 在金库调用前校验目标、函数选择器、代币与限制参数。

安全不变量：

- 租户只能在策略边界内使用 Agent。
- 租户不能任意把所有者资产转出金库。
- 所有者始终保留最终控制权，可暂停或重配策略。

## 合约模块

| 合约 | 职责 |
|---|---|
| `AgentNFA` | ERC-721 + ERC-4907 + BAP-578 元数据/生命周期，租赁用户分配，执行入口 |
| `AgentAccount` | 每个 Agent 的隔离金库账户，执行被允许的调用 |
| `PolicyGuard` | 链上策略引擎：目标/选择器/代币/spender/金额/时限约束 |
| `ListingManager` | 上架、租赁、续租、取消与费用流转 |

辅助库：

- `src/libs/Errors.sol`
- `src/libs/CalldataDecoder.sol`
- `src/libs/PolicyKeys.sol`

## BAP-578 与租赁语义

- BAP-578 为每个 Agent 提供机器可读元数据与标准动作模型。
- ERC-4907 提供 owner/user 分离与到期型使用权语义。
- `AgentNFA` 将两者绑定为清晰的链上租赁行为。

## 相关仓库链接

当前工作区用于端到端开发的仓库：

| 组件 | 本地路径 | 仓库地址 |
|---|---|---|
| 合约（本仓库） | `repos/shll` | https://github.com/kledx/shll |
| Web 应用 | `repos/shll-web` | https://github.com/kledx/shll-web |
| Runner 服务 | `repos/shll-runner` | https://github.com/kledx/shll-runner.git |
| Indexer | `repos/shll-indexer` | https://github.com/kledx/shll-indexer |

说明：本项目完全由 vibe coding 完成。完整构建过程与决策轨迹见 [ailogs](./ailogs/)。

## 环境要求

- Foundry（`forge`、`cast`、`anvil`）
- Solidity `0.8.33`（见 `foundry.toml`）

安装 Foundry：

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## 快速开始

```bash
forge build
forge test
```

常用命令：

```bash
forge fmt
forge test -vvv
```

## 环境变量

复制并填写环境变量：

```bash
cp .env.example .env
```

常用变量：

- `PRIVATE_KEY`
- `RPC_URL`
- `ETHERSCAN_API_KEY`（可选）
- `POLICY_GUARD`（策略脚本使用）

## 部署

部署合约：

```bash
PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

应用策略配置：

```bash
PRIVATE_KEY=0x... POLICY_GUARD=0x... CONFIG_PATH=configs/bsc.mainnet.json \
  forge script script/ApplyPolicy.s.sol --rpc-url $RPC_URL --broadcast
```

上架演示 Agent（模板脚本，一次 mint + list）：

```bash
# 1) 复制模板并填写参数
cp script/demo-agent.env.example .env.demo-agent

# 2) 导出变量并执行（bash 示例）
set -a && source .env.demo-agent && set +a
forge script script/ListDemoAgent.s.sol --rpc-url $RPC_URL --broadcast
```

## 网络配置

策略与地址预设位于 `configs/`：

- `configs/opbnb.mainnet.json`
- `configs/opbnb.testnet.json`
- `configs/bsc.mainnet.json`
- `configs/bsc.testnet.json`

## BSC Testnet 地址

| 合约 | 地址 |
|---|---|
| `PolicyGuard` | `0x6764B3eC699D56D3dA6a8a947107bEF416eA3d78` |
| `AgentNFA` | `0x636557BFe696221bd05B78b04FB3d091A322D1dE` |
| `ListingManager` | `0x8c5B5ed82e2fAFfd3cEA3F22d7CA56d033ba658d` |

## 目录结构

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

## AI 开发日志

会话日志位于 [ailogs](./ailogs/)。

## License

MIT
