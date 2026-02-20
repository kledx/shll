// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";
import {DexWhitelistPolicy} from "../src/policies/DexWhitelistPolicy.sol";

contract FixTemplateDexWL is Script {
    function run() external {
        address guardV4Addr = 0xe8828aB104a24114A8fB3AfA5BcfCc09a069B427;
        address newPolicy = 0xca225Ac06fDC05eD1d05f17D1D6f7A4C07c85C65;

        vm.startBroadcast();
        PolicyGuardV4 guardV4 = PolicyGuardV4(guardV4Addr);

        // The real template key used in production
        bytes32 templateId = keccak256("llm_trader_v3");

        address[] memory currentPolicies = guardV4.getTemplatePolicies(
            templateId
        );
        int256 oldIndex = -1;

        for (uint256 i = 0; i < currentPolicies.length; i++) {
            try DexWhitelistPolicy(currentPolicies[i]).policyType() returns (
                bytes32 pType
            ) {
                if (pType == keccak256("dex_whitelist")) {
                    oldIndex = int256(i);
                    break;
                }
            } catch {
                // Not the right contract
            }
        }

        if (oldIndex != -1) {
            guardV4.removeTemplatePolicy(templateId, uint256(oldIndex));
            console.log(
                "Removed old DexWhitelistPolicy from llm_trader_v3 template."
            );
        } else {
            console.log(
                "Could not find dex_whitelist in llm_trader_v3. Maybe already removed?"
            );
        }

        // Add the new policy
        guardV4.addTemplatePolicy(templateId, newPolicy);
        console.log("Added new DexWhitelistPolicy to llm_trader_v3 template.");

        vm.stopBroadcast();
    }
}
