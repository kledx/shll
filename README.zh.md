# SHLL 协议智能合约 — AI Agent 的底层安全网络

English: [README.md](./README.md)

官方网站: https://shll.run
官方推特 (X): https://x.com/shllrun
开发者工具 (MCP/CLI): [shll-skills](https://www.npmjs.com/package/shll-skills)

在 BNB Smart Chain 上构建的**安全、无许可的 AI Agent 租赁与执行智能合约系统**。

SHLL 允许策略开发者上架 AI，用户只需支付租金即可使用该策略。所有的用户本金都安全隔离在专属的金库中，AI 只能进行审核过的交易操作，且每一笔操作都会受到智能合约级的不可篡改的安全拦截。

---

## 核心设计

| 组件 | 合约 | 功能 |
|---|---|---|
| **Agent 身份与产权** | `AgentNFA.sol` | ERC-721 + ERC-4907 + BAP-578 标准 |
| **独立资金隔离库** | `AgentAccountV2.sol` | 基于 ERC-6551 的 Agent 专属金库 |
| **链上防火墙** | `PolicyGuardV4.sol` | 策略引擎，协调所有安全策略 |
| **租赁市场** | `ListingManagerV2.sol` | Rent-to-Mint 逻辑、租期管理 |
| **订阅系统** | `SubscriptionManager.sol` | 订阅模式与收益分配 |
| **协议注册表** | `ProtocolRegistry.sol` | DeFi 协议 + 函数白名单注册表 |
| **学习模块** | `LearningModule.sol` | 链上 Agent 学习与优化追踪 |

## 🛡️ 四核心安全策略

为了防止 AI 产生幻觉、或遭到提示词注入攻击，SHLL 构建了 `PolicyGuardV4` 安全引擎：

| 策略 | 核心作用 |
|---|---|
| **SpendingLimitPolicyV2** | 单笔 + 每日支出上限（支持原生 BNB 及 ERC20 swap）。集成代币白名单 — 仅允许经审核的高流动性主流代币。 |
| **CooldownPolicyV2** | 强制交易冷却间隔，防止高频刷单，充当极端行情下的断路器。 |
| **DeFiGuardPolicyV2** | 路由器 + 函数选择器白名单。仅允许已验证的 DEX 路由器（PancakeSwap V2/V3）调用已审批的 swap 方法。 |
| **ReceiverGuardPolicyV2** | 所有交易输出严格路由回 Agent 专属金库。禁止资金抽离到外部地址。 |

> **Fail-close 原则**：未绑定策略 = 全部阻止。不是「默认放行」。
>
> *即使 AI 的热钱包私钥被完全暴露，攻击者也无法盗走金库中的本金。*

## BAP-578 (Non-Fungible Agents)

SHLL 是 BNB Chain 上首个实装 BAP-578 标准的协议：

- **执行标准化**：为 AI 提供标准的 `.executeAction()` 入口
- **Rent-to-Mint**：用户点击租赁，合约自动克隆模板 Agent 并铸造一个新的 NFA
- **链上产权**：AI 是你钱包中真实的、可转移和继承的数字资产
- **策略验证框架**：[已贡献至 BAP-578 标准](https://github.com/ChatAndBuild/non-fungible-agents-BAP-578/pull/32)

## BSC Mainnet 主网合约地址

| 组件 / 策略 | 主网地址 |
|---|---|
| **核心合约** | |
| `AgentNFA` (V4.1) | [`0x71cE46099E4b2a2434111C009A7E9CFd69747c8E`](https://bscscan.com/address/0x71cE46099E4b2a2434111C009A7E9CFd69747c8E) |
| `PolicyGuardV4` | [`0x25d17eA0e3Bcb8CA08a2BFE917E817AFc05dbBB3`](https://bscscan.com/address/0x25d17eA0e3Bcb8CA08a2BFE917E817AFc05dbBB3) |
| `SubscriptionManager` | [`0x66487D5509005825C85EB3AAE06c3Ec443eF7359`](https://bscscan.com/address/0x66487D5509005825C85EB3AAE06c3Ec443eF7359) |
| `ListingManagerV2` | [`0x1f9CE85bD0FF75acc3D92eB79f1Eb472f0865071`](https://bscscan.com/address/0x1f9CE85bD0FF75acc3D92eB79f1Eb472f0865071) |
| `ProtocolRegistry` | [`0x1A5EA54a3beaf4fba75f73581cf6A945746E6DF1`](https://bscscan.com/address/0x1A5EA54a3beaf4fba75f73581cf6A945746E6DF1) |
| `LearningModule` | [`0x019765B2669b1A3FfffE8213E9bd0b0D8eb00892`](https://bscscan.com/address/0x019765B2669b1A3FfffE8213E9bd0b0D8eb00892) |
| **安全策略 (V5)** | |
| `SpendingLimitPolicyV2` | [`0x28efC8D513D44252EC26f710764ADe22b2569115`](https://bscscan.com/address/0x28efC8D513D44252EC26f710764ADe22b2569115) |
| `ReceiverGuardPolicyV2` | [`0x7A9618ec6c2e9D93712326a7797A829895c0AfF6`](https://bscscan.com/address/0x7A9618ec6c2e9D93712326a7797A829895c0AfF6) |
| `DeFiGuardPolicyV2` | [`0xD1b6a97400Bc62ed6000714E9810F36Fc1a251f1`](https://bscscan.com/address/0xD1b6a97400Bc62ed6000714E9810F36Fc1a251f1) |
| `CooldownPolicy` | [`0x0E0B2006DE4d68543C4069249a075C215510efDB`](https://bscscan.com/address/0x0E0B2006DE4d68543C4069249a075C215510efDB) |

## 构建与测试

需要 [Foundry](https://book.getfoundry.sh/) 工具链，Solidity `^0.8.24`。

```bash
# 编译
forge build

# 测试（278 用例）
forge test -vvv

# 部署
cp .env.example .env
forge script script/DeployV32PostAudit.s.sol --rpc-url $RPC_URL --broadcast --verify
```

## 协议仓库全景

| 组件 | 仓库 | 功能 |
|---|---|---|
| **核心合约** (本仓库) | [shll-protocol/shll](https://github.com/shll-protocol/shll) | SHLL 协议智能合约 |
| **AI 技能工具** | [shll-protocol/shll-skills](https://github.com/shll-protocol/shll-skills) | MCP Server & CLI 工具链 |
| **风控 SDK** | [shll-protocol/shll-policy-sdk](https://github.com/shll-protocol/shll-policy-sdk) | TypeScript SDK |
| **数据索引器** | [shll-protocol/shll-indexer](https://github.com/shll-protocol/shll-indexer) | 基于 Ponder 的实时索引 |

## 开源许可

MIT License
