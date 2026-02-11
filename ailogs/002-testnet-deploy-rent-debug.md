# AI Update Log #002 — Testnet Deploy + Rent Flow Debugging + Performance Optimization

**日期**: 2026-02-11 ~ 2026-02-12  
**AI 工具**: Antigravity  
**任务编号**: P-2026-001  
**耗时**: ~6 小时（涵盖部署、调试、优化全流程）

---

## 📋 任务背景

在 BAP-578 集成完成后，需要将合约部署到 BSC Testnet，连通前端，并完成 E2E 租赁测试。过程中遇到了多个链上/链下交互 Bug，逐一排查修复。

---

## 🚀 完成事项

### 1. BSC Testnet 合约部署

- 使用 `forge script` 部署 3 个核心合约：`AgentNFA`、`ListingManager`、`PolicyGuard`
- 通过 `MintTestAgents.s.sol` 脚本铸造 3 个测试 Agent（Token #1, #2, #3）
- 通过 `ApplyPolicy.s.sol` 配置 PolicyGuard 白名单（PancakeSwap Router、Venus Protocol）

### 2. Rent 交易调试

发现并修复 4 个层面的 Bug：

| Bug | 原因 | 修复 |
|-----|------|------|
| `MinDaysNotMet` | `MintTestAgents.s.sol` 中 `minDays` 写成 `1 days`（=86400 秒），合约当作秒来比较 | 改为 `1` |
| `InsufficientPayment` | 前端 `useRent.ts` 用浮点数算 BNB，精度丢失 | 改用 `BigInt` 全链路计算 |
| NaN 价格显示 | `useAgent.ts` 返回的 `pricePerDay` 类型不一致 | 统一 `BigInt` 处理 |
| 钱包显示"未知交易" | MetaMask 不识别 `rent` 函数 ABI | 仅 UI 问题，交易实际成功 |

### 3. Agent 可见性修复

**问题**: Marketplace 只显示 Agent #1，不显示新部署的 #2 和 #3。

**排查过程**:
1. 怀疑 RPC `getLogs` 限制 → 切换到 BlockPi RPC → 部分解决
2. 增加分片容错（独立 try-catch）→ 未完全解决
3. 发现根因：`userOf(tokenId)` 返回部署者地址（非零地址），过滤逻辑认为 Agent "已被租用" → **移除零地址过滤**

### 4. 性能优化（Event Scanning → Multicall）

**问题**: 每次打开页面需发起 ~56 次 `getLogs` RPC 请求（500 块/片 × ~28000 块范围）。

**解决方案**: 
- 重写 `useListings.ts`：用 wagmi `useReadContracts`（multicall）替代事件扫描
  - Phase 1: 批量 `getListingId(tokenId)` for tokenId 1..10
  - Phase 2: 批量读取 `listings + metadata + userOf`
  - 总共 **2 次 RPC** 替代之前的 ~56 次
- 重写 `useMyRentals.ts`：同样改为 multicall，**1 次 RPC** 完成

### 5. 已租用状态标识

- `AgentListing` 接口新增 `rented` / `renter` 字段
- Agent Card 对已租用 Agent 显示 "Rented" 徽章 + "View Details" 按钮
- 卡片显示半透明效果，明确区分可租用与已租用

---

## 📂 变更文件清单

### shll-web (Frontend)

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `src/hooks/useListings.ts` | **重写** | 事件扫描 → multicall 批量读取 |
| `src/hooks/useMyRentals.ts` | **重写** | 事件扫描 → multicall 批量读取 |
| `src/hooks/useRent.ts` | 修改 | BigInt 计算 + 交易模拟 |
| `src/hooks/useAgent.ts` | 修改 | BigInt 价格处理 |
| `src/components/business/agent-card.tsx` | 修改 | 新增 rented 状态展示 |
| `src/components/business/action-panel.tsx` | 修改 | 传递 listingId/pricePerDayRaw |
| `src/components/business/rent-form.tsx` | 修改 | 动态价格计算 |
| `src/components/business/policy-summary.tsx` | 修改 | UI 优化 |
| `src/app/agent/[nfa]/[tokenId]/page.tsx` | 修改 | 传递 listing 数据 |
| `src/config/wagmi.ts` | 修改 | RPC 切换到 BlockPi |
| `src/config/contracts.ts` | 修改 | 合约地址和 ABI 更新 |
| `src/app/globals.css` | 修改 | 样式修复 |
| `src/components/ui/button.tsx` | 修改 | UI 优化 |
| `src/components/ui/input.tsx` | 修改 | UI 优化 |

### shll (Contracts)

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `script/MintTestAgents.s.sol` | 修改 | `minDays` 从 `1 days` 改为 `1` |

---

## 💡 关键经验

1. **Solidity 时间字面量陷阱**: `1 days` = 86400（秒），不能直接当"1天"的数字使用。这在 `createListing` 参数中导致了 `MinDaysNotMet` 错误
2. **ERC4907 userOf 行为**: AgentNFA mint 后 `userOf` 可能不返回零地址，不能用它判断"未被租用"
3. **Event Scanning 不适合 MVP**: 公链 RPC 的 `getLogs` 限制多且不可靠，测试阶段用 multicall 遍历 Token ID 更实际
4. **BigInt 全链路**: Web3 前端的金额计算必须全链路使用 BigInt，浮点数计算在 wei 精度下会累积误差

---

## 🔗 链上记录

- **合约地址**:
  - AgentNFA: `0xB65Ca34b1526C926c75129Ef934c3Ba9fE6f29f6`
  - ListingManager: `0x71597c159007E9FF35bcF47822913cA78B182156`
  - PolicyGuard: `0x2D1b1a46D18AD3b810eE5A6f0Fe6891AB29B6f0D`
- **测试 Agent**: Token 1 (minDays 异常), Token 2 & 3 (正常, 已租用)
- **网络**: BSC Testnet (chain ID: 97)
