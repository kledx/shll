// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";
import {DexWhitelistPolicy} from "../src/policies/DexWhitelistPolicy.sol";

/// @title DeployHotfixDexWhitelist — Hotfix for approve() flaw in DexWhitelistPolicy
/// @notice Deploys a new DexWhitelistPolicy and swaps it into the llm_trader template
/// @dev Usage:
///   forge script script/DeployHotfixDexWhitelist.s.sol --rpc-url $RPC_URL --broadcast -vvv
///
/// Required env vars:
///   PRIVATE_KEY        — deployer private key
///   AGENT_NFA          — existing AgentNFA address
///   POLICY_GUARD_V4    — existing PolicyGuardV4 address
contract DeployHotfixDexWhitelist is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address agentNFA = vm.envAddress("AGENT_NFA");
        address guardV4Addr = vm.envAddress("POLICY_GUARD_V4");

        vm.startBroadcast(deployerKey);

        PolicyGuardV4 guardV4 = PolicyGuardV4(guardV4Addr);
        bytes32 templateId = keccak256("llm_trader");

        // 1. Deploy the new fixed version of DexWhitelistPolicy
        DexWhitelistPolicy newDexWL = new DexWhitelistPolicy(
            guardV4Addr,
            agentNFA
        );
        console.log("New DexWhitelistPolicy deployed at:", address(newDexWL));

        // 2. Approve the new policy in PolicyGuardV4
        guardV4.approvePolicyContract(address(newDexWL));
        console.log("New DexWhitelistPolicy approved in GuardV4");

        // 3. Find the old DexWhitelistPolicy in the template
        address[] memory currentPolicies = guardV4.getTemplatePolicies(
            templateId
        );
        int256 oldIndex = -1;
        address oldDexWL = address(0);

        for (uint256 i = 0; i < currentPolicies.length; i++) {
            // Find the policy whose policyType() is keccak256("dex_whitelist")
            try DexWhitelistPolicy(currentPolicies[i]).policyType() returns (
                bytes32 pType
            ) {
                if (pType == keccak256("dex_whitelist")) {
                    oldIndex = int256(i);
                    oldDexWL = currentPolicies[i];
                    break;
                }
            } catch {
                // Not the right contract or doesn't support policyType()
            }
        }

        if (oldIndex == -1) {
            console.log(
                "ERROR: Could not find old DexWhitelistPolicy in llm_trader template!"
            );
            // Still add the new one just in case
            guardV4.addTemplatePolicy(templateId, address(newDexWL));
            console.log("Added new DexWhitelistPolicy to template anyway.");
        } else {
            console.log(
                "Found old DexWhitelistPolicy at index",
                uint256(oldIndex),
                ":",
                oldDexWL
            );

            // 4. Remove the old policy
            // Wait, removeTemplatePolicy uses swap-and-pop.
            guardV4.removeTemplatePolicy(templateId, uint256(oldIndex));
            console.log("Removed old DexWhitelistPolicy from template.");

            // 5. Add the new policy
            guardV4.addTemplatePolicy(templateId, address(newDexWL));
            console.log("Added new DexWhitelistPolicy to template.");

            // 6. Optional: Revoke the old policy globally
            guardV4.revokePolicyContract(oldDexWL);
            console.log("Revoked old DexWhitelistPolicy globally.");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("========== HOTFIX COMPLETE ==========");
        console.log("Please note: Any existing agents will need to REDO their");
        console.log(
            "DEX whitelist configuration in the UI, as state was on the old policy."
        );
        console.log("New DexWhitelistPolicy :", address(newDexWL));
        console.log("=====================================");
    }
}
