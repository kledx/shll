// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SpendingLimitPolicyV2} from "../src/policies/SpendingLimitPolicyV2.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";

/// @title DeploySpendingLimitV2 — Deploy, configure, and migrate to SpendingLimitPolicyV2
/// @notice Replaces SpendingLimitPolicy V1 + TokenWhitelistPolicy with a single V2 contract.
///
/// @dev Usage:
///   # Testnet
///   forge script script/DeploySpendingLimitV2.s.sol --rpc-url $RPC_URL --broadcast --gas-price 5000000000 -vvv
///
///   # Mainnet (use account instead of env key)
///   forge script script/DeploySpendingLimitV2.s.sol --rpc-url $RPC_URL --broadcast --account deployer -vvv
///
/// Required env vars:
///   POLICY_GUARD_V4           — PolicyGuardV4 address
///   AGENT_NFA                 — AgentNFA address
///   ROUTER_ADDRESS            — PancakeSwap V2 Router
///   WBNB_ADDRESS              — WBNB token
///   USDT_ADDRESS              — USDT token
contract DeploySpendingLimitV2 is Script {
    // Template key (must match existing deployment)
    bytes32 constant TEMPLATE_LLM = keccak256("llm_trader_v3");

    // PancakeSwap V2 (ETH-input swaps)
    bytes4 constant SWAP_EXACT_ETH = 0x7ff36ab5;
    bytes4 constant SWAP_EXACT_ETH_FEE = 0xb6f9de95;
    // PancakeSwap V3
    bytes4 constant EXACT_INPUT_SINGLE = 0x04e45aaf;
    bytes4 constant EXACT_INPUT = 0xb858183f;

    function run() external {
        address guardAddr = vm.envAddress("POLICY_GUARD_V4");
        address nfa = vm.envAddress("AGENT_NFA");
        address router = vm.envAddress("ROUTER_ADDRESS");
        address wbnb = vm.envAddress("WBNB_ADDRESS");
        address usdt = vm.envAddress("USDT_ADDRESS");
        address v3Router = vm.envOr("V3_ROUTER_ADDRESS", address(0));
        address usdc = vm.envOr("USDC_ADDRESS", address(0));

        vm.startBroadcast();

        // ═══ STEP 1: Deploy ═══
        SpendingLimitPolicyV2 slV2 = new SpendingLimitPolicyV2(guardAddr, nfa);
        console.log("SpendingLimitPolicyV2 deployed at:", address(slV2));

        // ═══ STEP 2: Template ceiling ═══
        slV2.setTemplateCeiling(
            TEMPLATE_LLM,
            50 ether, // maxPerTx: 50 BNB
            100 ether, // maxPerDay: 100 BNB
            500 // maxSlippageBps: 5%
        );
        slV2.setTemplateApproveCeiling(TEMPLATE_LLM, 50 ether);
        console.log("Ceiling: 50 BNB/tx, 100 BNB/day, approve 50 BNB");

        // ═══ STEP 3: Approved spenders ═══
        slV2.setApprovedSpender(router, true);
        console.log("Approved spender: PancakeSwap V2 Router");
        if (v3Router != address(0)) {
            slV2.setApprovedSpender(v3Router, true);
            console.log("Approved spender: PancakeSwap V3 Router");
        }

        // ═══ STEP 4: Template token whitelist ═══
        slV2.setTemplateTokenRestriction(TEMPLATE_LLM, true);
        slV2.addTemplateToken(TEMPLATE_LLM, wbnb);
        slV2.addTemplateToken(TEMPLATE_LLM, usdt);
        if (usdc != address(0)) {
            slV2.addTemplateToken(TEMPLATE_LLM, usdc);
        }
        console.log("Token whitelist: WBNB, USDT configured");

        // ═══ STEP 5: Output patterns ═══
        bytes4[] memory v2Sels = new bytes4[](2);
        v2Sels[0] = SWAP_EXACT_ETH;
        v2Sels[1] = SWAP_EXACT_ETH_FEE;
        slV2.setOutputPatternBatch(
            v2Sels,
            SpendingLimitPolicyV2.OutputPattern.V2_PATH
        );
        slV2.setOutputPattern(
            EXACT_INPUT_SINGLE,
            SpendingLimitPolicyV2.OutputPattern.V3_SINGLE
        );
        slV2.setOutputPattern(
            EXACT_INPUT,
            SpendingLimitPolicyV2.OutputPattern.V3_MULTI
        );
        console.log("Output patterns: V2_PATH(2), V3_SINGLE(1), V3_MULTI(1)");

        // ═══ STEP 6: Register in PolicyGuardV4 ═══
        PolicyGuardV4 guard = PolicyGuardV4(guardAddr);
        guard.approvePolicyContract(address(slV2));
        guard.addTemplatePolicy(TEMPLATE_LLM, address(slV2));
        console.log("Registered in PolicyGuardV4 + attached to template");

        vm.stopBroadcast();

        // ═══ SUMMARY ═══
        console.log("");
        console.log("========== SPENDING LIMIT V2 DEPLOYED ==========");
        console.log("  Contract       :", address(slV2));
        console.log("  Guard          :", guardAddr);
        console.log("  Ceiling        : 50 BNB/tx, 100 BNB/day");
        console.log("  Approve ceil   : 50 BNB");
        console.log("  Token WL       : WBNB, USDT");
        console.log("  Patterns       : V2_PATH(2), V3_SINGLE(1), V3_MULTI(1)");
        console.log("");
        console.log("  SPENDING_LIMIT_V2=", address(slV2));
        console.log("");
        console.log("  NEXT: Remove old V1 policies from template:");
        console.log("  guard.removeTemplatePolicy(templateId, V1_INDEX)");
        console.log("  guard.removeTemplatePolicy(templateId, TOKEN_WL_INDEX)");
        console.log("================================================");
    }
}
