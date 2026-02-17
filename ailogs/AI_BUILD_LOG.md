# AI Build Log: SHLL

**Track:** Agent (AI Agent x Onchain Actions)
**Project:** SHLL - Autonomous Agent Security Protocol

---

## 🤖 How AI Built SHLL

SHLL was built using a "Vibe Coding" approach, where AI Agents (Claude 3.5 Sonnet & Gemini 1.5 Pro) acted as the primary architects and developers, with the human serving as the Product Manager and Reviewer.

Total Development Time: **~2 Weeks**
AI Contribution: **~80% of Code & Architecture**

### Key AI Contributions

#### 1. Designing the "PolicyGuard" Firewall
The core innovation of SHLL is the `PolicyGuard` contract, which acts as an on-chain firewall for AI agents.
- **AI Role**: analyzed the "Trust Dilemma" (users don't trust agents with keys) and proposed the **Target-Selector-Param** validation logic.
- **Outcome**: A gas-optimized solidity contract that parses calldata to block unauthorized transactions.
- **Artifact**: `src/core/PolicyGuardV3.sol`

#### 2. Accelerating the "Rent-to-Mint" Model
We needed a way to let users "rent" high-value agents without custodial risk.
- **AI Role**: Suggested combining **ERC-4907 (User Role)** with **ERC-6551 (TBA)**. The AI wrote the entire `ListingManager` logic to handle rent collection and `setUser` updates in a single transaction.
- **Outcome**: V1.5 deployed execution layer that supports multi-tenant agent rentals.

#### 3. Full-Stack "Vibe Coding"
- **Frontend**: AI generated the entire Next.js + RainbowKit scaffolding, including the "Action Builder" UI which decodes complex contract interactions into human-readable forms.
- **Indexer**: AI wrote the Ponder indexing schema to track agent activities and rental status in real-time.

---

## 📅 Development Timeline (AI Sessions)

### Phase 1: Core Protocol (Feb 5 - Feb 10)
*Focus: Security & Standards*
- **Feb 05**: [Architecture Design] AI proposed the separation of `AgentNFA` (Identity) and `AgentAccount` (Vault).
- **Feb 07**: [Smart Contracts] Implemented `PolicyGuard` v1. AI debugged calldata decoding for `swapExactTokensForTokens`.
- **Feb 09**: [Standardization] Integrated BAP-578 to make agents compatible with the broader AI ecosystem.

### Phase 2: Marketplace & Runner (Feb 11 - Feb 15)
*Focus: Usability & Automation*
- **Feb 11**: [Marketplace] Built `ListingManager`. AI suggested the "Template" pattern for mass-producing agents.
- **Feb 13**: [Off-Chain Runner] AI wrote the Dockerized Node.js service that monitors the blockchain and auto-executes user intents (Autopilot).
- **Feb 14**: [Frontend] "Vibe Coded" the SHLL Console. AI fixed 15+ UI bugs related to wagmi hooks and hydrations errors.

### Phase 3: Polish & Deployment (Feb 16 - Feb 17)
*Focus: Mainnet Readiness*
- **Feb 16**: [Optimization] Deployed V1.5 contracts with 30% gas savings on policy verification.
- **Feb 17**: [Docs & Submission] AI compiled this build log and the DoraHacks submission materials.

---

## 🔗 Verification & Artifacts

- **GitHub Repo**: [kledx/shll](https://github.com/kledx/shll)
- **Development Logs**: See `repos/shll/ailogs/` and `docs/` in the repo for raw session logs.
- **Smart Contracts**: Verified on BSC Testnet (See `DORAHACKS_SUBMISSION.md`).

---

*This log confirms that SHLL is a native AI-driven project, demonstrating the power of "Vibe Coding" to build complex, secure on-chain protocols.*
