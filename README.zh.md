# SHLL 协议智能合约 - AI Agent 的底层安全网络

English: [README.md](./README.md)

官方网站: https://shll.run
官方推特 (X): https://x.com/shllrun
开发者工具 (MCP/CLI): [shll-skills](https://www.npmjs.com/package/shll-skills)

在 BNB Smart Chain 上构建的**安全、无许可的 AI Agent 租赁与执行智能合约系统**。

SHLL 允许策略开发者上架 AI，用户只需支付租金即可使用该策略。所有的用户本金都安全隔离在专属的金库中，AI 只能进行审核过的交易操作，且每一笔操作都会受到智能合约级的不可篡改的安全拦截。

---

## 核心设计

本仓库（`repos/shll`）是整个 SHLL 架构的核心智能合约层：

- **Agent 身份与产权** (`AgentNFA.sol`): 实现了 ERC-721 与基于角色的 ERC-4907，并原生支持 BNB Chain **BAP-578**（Non-Fungible Agent）标准。
- **独立资金隔离库** (`AgentAccount.sol`): 结合 ERC-6551，为每一个 AI Agent 部署完全独立的金库，隔绝跨 Agent 风险。
- **链上防火墙** (`PolicyGuardV4.sol`): 拦截一切恶意或失控的 AI 操作的 5 层风控引擎。
- **租赁与订阅市场** (`ListingManagerV2.sol`, `SubscriptionManager.sol`): 管理 Rent-to-Mint（边租边铸造）逻辑、租期管理与收益分配。

## 🛡️ V4 架构：五重安全防线

为了防止 AI 产生幻觉、或者大模型遭到越权与提示词注入攻击，SHLL 构建了 `PolicyGuardV4` 护城河：

| 防御层 | 策略合约 | 核心作用 |
|---|---|---|
| **L1** | `ReceiverGuardPolicy` | **禁止资金抽离**：AI 无法执行纯粹的 `transfer`。所有的交易、闪兑和借贷资金，必须只能流回 Agent 专属金库。 |
| **L2** | `SpendingLimitPolicyV2`| **单笔亏损兜底**：限制 AI 在一笔交易中的最大资金动用量以及滑点，即使 AI 发出梭哈指令，合约也会强制执行限额。 |
| **L3** | `TokenWhitelistPolicy` / `DexWhitelistPolicy` | **防土狗与杀猪盘**：AI 只能交易经过审计的主流代币，只能调用指定的去中心化交易所（如 PancakeSwap）。 |
| **L4** | `DeFiGuardPolicyV2` | **禁止恶意部署**：通过签名函数过滤，阻止 AI 调用危险的、不透明的非标合约函数。 |
| **L5** | `CooldownPolicy` | **防高频刷单**：强制设定每笔交易的冷却期，充当极端行情下的断路器（Circuit Breaker）。 |

*即使提供给 AI 的热钱包（代签钱包）私钥被黑客完全控制，它也无法盗走金库中的本金。*

## BAP-578 (Non-Fungible Agents) 实装

SHLL 是 BNB Chain 上首批实装 BAP-578 标准的协议之一：
- **执行标准化**：为 AI 提供标准的 `.executeAction()` 入口，AI 与合约交互不再需要复杂的适配开发。
- **Rent-to-Mint**：用户点击租赁，合约自动克隆模板 Agent 并在链上铸造一个新的 NFA 给用户。
- **链上产权**：AI 不再是跑在云端的黑匣子，而是你钱包中真实的、可以转移、继承甚至二次生息的数字资产。

## BSC Mainnet 主网合约地址

以下是 V4 版本的核心主网部署地址及其附属风控策略合约（所有合约均在 BscScan 开源验证）：

| 组件 / 策略 | V4 Mainnet 地址 |
| --- | --- |
| **核心管理合约** | |
| `AgentNFA` | `0xe98dcdbf370d7b52c9a2b88f79bef514a5375a2b` |
| `PolicyGuardV4` | `0x25d17ea0e3bcb8ca08a2bfe917e817afc05dbbb3` |
| `SubscriptionManager` | `0x66487D5509005825C85EB3AAE06c3Ec443eF7359` |
| `ListingManagerV2` | `0x1f9CE85bD0FF75acc3D92eB79f1Eb472f0865071` |
| **底层风控策略库** | |
| `SpendingLimitPolicyV2` | `0xd942dEe00d65c8012E39037a7a77Bc50645e5338` |
| `ReceiverGuardPolicyV2` | `0x54809f7B7801dD9689bb99dbb4d7Ac4bfcDd6d46` |
| `DexWhitelistPolicyV2` | `0xBa411c5Ef09f8116044dfC1356C6Cd1e0E7ede0D` |
| `TokenWhitelistPolicy` | `0xfd8e7f4180ea5af0d61c2037cd7ceecf34bee1e1` |
| `DeFiGuardPolicyV2` | `0xB248AF39b849fB10c271f13220c86be4cb56eD0e` |
| `CooldownPolicyV2` | `0x1169d1B2A6f597da152f153437376729371735ea` |

## 构建与测试

需要安装 Foundry 工具链 (`forge`, `cast`, `anvil`)，并且要求 Solidity 版本为 `0.8.33`。

```bash
# 全局编译
forge build

# 运行 V4 全量回归测试
forge test -vvv
```

## 部署执行

设置环境变量：

```bash
cp .env.example .env
# 配置好 PRIVATE_KEY 与 RPC_URL
```

部署全新 V4 环境脚本：

```bash
forge script script/DeployV40Full.s.sol:DeployV40Full --rpc-url $RPC_URL --broadcast --verify
```

## 协议仓库全景分布

SHLL 的完整实现由以下几个代码仓库共同构成：

| 组件名称 | 仓库链接 | 功能职责 |
|---|---|---|
| **核心合约库** (本仓库) | [repos/shll](https://github.com/kledx/shll) | SHLL 协议 V4 智能合约底层逻辑 |
| **AI 技能插件舱** | [repos/shll-openclaw-skill](https://github.com/kledx/shll-skills) | 支持 MCP 与 CLI 双端的 DeFi 交互工具链 (v5.4+) |
| **底层风控 SDK** | [repos/shll-policy-sdk](https://github.com/kledx/shll-policy-sdk) | 提供 BAP-578 以及 PolicyGuard 的 TypeScript 调用方案 |
| **链上数据索引器** | [repos/shll-indexer](https://github.com/kledx/shll-indexer) | 基于 Ponder 构建的实时底层事件分析 API |

## 开源许可

MIT License
