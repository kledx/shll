# 使用 ListDemoAgent 创建模版 Agent (Template)

该脚本 (`script/ListDemoAgent.s.sol`) 用于创建一个支持 **Rent-to-Mint (多租户)** 的模版 Agent。

## 1. 准备配置文件

在 `repos/shll` 目录创建一个名为 `.env.demo-agent` 的文件，填入**所有**配置（包含私钥和合约地址）：

```ini
# === 1. 基础配置 (必须填) ===
# 部署者私钥 (用于发送交易)
PRIVATE_KEY=0x...
# RPC 节点 (例如 BSC Testnet)
RPC_URL=https://data-seed-prebsc-1-s1.bnbchain.org:8545

# === 2. 合约地址 (必须填) ===
# AgentNFA 合约地址
AGENT_NFA=0x...
# ListingManager 合约地址
LISTING_MANAGER=0x...

# === 3. Demo Agent 专属配置 (必须填) ===

# 拥有者 (通常填你自己的钱包地址)
DEMO_OWNER=0x你的钱包地址

# 策略 ID (PolicyGuard 规则，测试可用默认值)
DEMO_POLICY_ID=0x0000000000000000000000000000000000000000000000000000000000000001

# Agent 描述 (前端显示的元数据)
DEMO_TOKEN_URI=ipfs://QmDataTemplate001
DEMO_PERSONA_JSON={"name": "Master Trader", "role": "Template", "description": "High-perf template for users"}
DEMO_EXPERIENCE="Expert Template Level 10"

# 代码包 (Runner 下载并执行的核心逻辑)
DEMO_VAULT_URI=https://vault.shll.run/template/master
DEMO_VAULT_HASH=0x0000000000000000000000000000000000000000000000000000000000000000

# 租赁价格规则
# 每日租金 (单位 wei, 示例为 0.01 BNB)
DEMO_PRICE_PER_DAY_WEI=10000000000000000
# 最短租期 (天)
DEMO_MIN_DAYS=1

# === 可选配置 ===
# DEMO_VOICE_HASH=Qm...
# DEMO_ANIMATION_URI=ipfs://...
```

## 2. 运行脚本 (PowerShell / Windows)

配置好文件后，打开 PowerShell，在项目根目录 (`repos/shll`) 运行以下命令块（只需这一步加载，无需其他前置操作）：

```powershell
# 1. 加载配置
Get-Content .env.demo-agent -Encoding UTF8 | ForEach-Object { if ($_ -match '^([^#=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim(), "Process") } }

# 2. 运行脚本
& "$env:USERPROFILE\.foundry\bin\forge.exe" script script/ListDemoAgent.s.sol --rpc-url $env:RPC_URL --broadcast --gas-price 5000000000
```

## 3. 运行脚本 (Shell / Mac / Linux)

如果你使用 Bash 或 Zsh，请使用以下命令：

```bash
# 1. 加载配置
set -a
source .env.demo-agent
set +a

# 2. 运行脚本
forge script script/ListDemoAgent.s.sol --rpc-url $RPC_URL --broadcast --gas-price 5000000000
```

## 4. 验证结果

执行成功后，你可以前往 SHLL Web 端查看刚刚创建的 Agent：

1.  **访问前端**: 打开 [https://test.shll.run/](https://test.shll.run/) (或你的部署地址)。
2.  **查看 Agent**: 点击导航栏的 **"Market"** (市场) 页面，或者如果你的 Agent 还在 **"Pending"** 状态，可能需要稍等 Indexer 同步。
3.  **确认功能**:
    - 你应该能看到一个新的 Agent 卡片（名称为你设置的 `DEMO_PERSONA_JSON` 中的名字）。
    - 点击进入详情页，可以进行 **Mint Instance** 操作。

## 常见问题

- **报错 `transaction gas price below minimum`**: 已添加 `--gas-price 5000000000` 解决。
- **报错 `Failed to resolve env var`**: 说明 `.env.demo-agent` 文件内容不完整或加载失败。
