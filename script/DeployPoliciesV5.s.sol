// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SpendingLimitPolicyV2} from "../src/policies/SpendingLimitPolicyV2.sol";
import {CooldownPolicy} from "../src/policies/CooldownPolicy.sol";
import {ReceiverGuardPolicyV2} from "../src/policies/ReceiverGuardPolicyV2.sol";
import {DeFiGuardPolicyV2} from "../src/policies/DeFiGuardPolicyV2.sol";
import {DexWhitelistPolicy} from "../src/policies/DexWhitelistPolicy.sol";
import {TokenWhitelistPolicy} from "../src/policies/TokenWhitelistPolicy.sol";

/// @title DeployPoliciesV5 — Redeploy all policies with correct agentNFA
/// @notice Deploys 6 policies with correct immutables, prints addresses for migration.
contract DeployPoliciesV5 is Script {
    // ── Correct addresses ──
    address constant GUARD = 0x25d17eA0e3Bcb8CA08a2BFE917E817AFc05dbBB3;
    address constant AGENT_NFA = 0x71cE46099E4b2a2434111C009A7E9CFd69747c8E;

    function run() external {
        vm.startBroadcast();

        // 1. SpendingLimitPolicyV2
        SpendingLimitPolicyV2 spending = new SpendingLimitPolicyV2(
            GUARD,
            AGENT_NFA
        );
        console.log("SpendingLimitPolicyV2:", address(spending));

        // 2. CooldownPolicy
        CooldownPolicy cooldown = new CooldownPolicy(GUARD, AGENT_NFA);
        console.log("CooldownPolicy:", address(cooldown));

        // 3. ReceiverGuardPolicyV2
        ReceiverGuardPolicyV2 receiver = new ReceiverGuardPolicyV2(
            AGENT_NFA,
            GUARD
        );
        console.log("ReceiverGuardPolicyV2:", address(receiver));

        // 4. DeFiGuardPolicyV2
        DeFiGuardPolicyV2 defi = new DeFiGuardPolicyV2(GUARD, AGENT_NFA);
        console.log("DeFiGuardPolicyV2:", address(defi));

        // 5. DexWhitelistPolicy
        DexWhitelistPolicy dex = new DexWhitelistPolicy(GUARD, AGENT_NFA);
        console.log("DexWhitelistPolicy:", address(dex));

        // 6. TokenWhitelistPolicy
        TokenWhitelistPolicy token = new TokenWhitelistPolicy(GUARD, AGENT_NFA);
        console.log("TokenWhitelistPolicy:", address(token));

        vm.stopBroadcast();

        // Verify
        console.log("\n=== Verification ===");
        console.log("spending.agentNFA:", spending.agentNFA());
        console.log("spending.guard:", spending.guard());
        console.log("cooldown.agentNFA:", cooldown.agentNFA());
        console.log("receiver.agentNFA:", receiver.agentNFA());
        console.log("defi.agentNFA:", defi.agentNFA());
        console.log("dex.agentNFA:", dex.agentNFA());
        console.log("token.agentNFA:", token.agentNFA());
    }
}
