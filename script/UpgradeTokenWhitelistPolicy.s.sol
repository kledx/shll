// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TokenWhitelistPolicy} from "../src/policies/TokenWhitelistPolicy.sol";

interface IPolicyGuardV4 {
    function instanceTemplateId(uint256) external view returns (bytes32);
    function getTemplatePolicies(
        bytes32 templateId
    ) external view returns (address[] memory);
    function removeTemplatePolicy(bytes32 templateId, uint256 index) external;
    function addTemplatePolicy(bytes32 templateId, address policy) external;
}

/// @notice Deploy upgraded TokenWhitelistPolicy with bypass support and swap in template.
/// Usage:
///   forge script script/UpgradeTokenWhitelistPolicy.s.sol \
///     --rpc-url $RPC_URL --broadcast --gas-price 3000000000 -vvv
contract UpgradeTokenWhitelistPolicy is Script {
    // Mainnet addresses
    address constant POLICY_GUARD = 0x25d17eA0e3Bcb8CA08a2BFE917E817AFc05dbBB3;
    address constant AGENT_NFA = 0xE98DCdbf370D7b52c9A2b88F79bEF514A5375a2b;
    address constant OLD_TOKEN_WL = 0xfD8E7f4180EA5aF0D61c2037Cd7cEECF34BEE1E1;
    uint256 constant INSTANCE_ID = 3; // Any instance to derive template ID

    function run() external {
        IPolicyGuardV4 guard = IPolicyGuardV4(POLICY_GUARD);

        // 1. Get template ID
        bytes32 templateId = guard.instanceTemplateId(INSTANCE_ID);
        console.log("Template ID:");
        console.logBytes32(templateId);

        // 2. List current policies
        address[] memory policies = guard.getTemplatePolicies(templateId);
        console.log("Current policies (%d):", policies.length);
        for (uint256 i = 0; i < policies.length; i++) {
            console.log("  [%d] %s", i, policies[i]);
        }

        // 3. Find old TokenWhitelistPolicy index
        uint256 targetIndex = type(uint256).max;
        for (uint256 i = 0; i < policies.length; i++) {
            if (policies[i] == OLD_TOKEN_WL) {
                targetIndex = i;
                break;
            }
        }

        vm.startBroadcast();

        // 4. Deploy new TokenWhitelistPolicy with bypass support
        TokenWhitelistPolicy newPolicy = new TokenWhitelistPolicy(
            POLICY_GUARD,
            AGENT_NFA
        );
        console.log("New TokenWhitelistPolicy deployed:", address(newPolicy));

        // 5. Remove old policy (if found)
        if (targetIndex != type(uint256).max) {
            console.log("Removing old policy at index:", targetIndex);
            guard.removeTemplatePolicy(templateId, targetIndex);
        } else {
            console.log(
                "Old TokenWhitelistPolicy not in template, skipping removal"
            );
        }

        // 6. Add new policy to template
        guard.addTemplatePolicy(templateId, address(newPolicy));
        console.log("New policy added to template");

        vm.stopBroadcast();

        // 7. Verify
        address[] memory updated = guard.getTemplatePolicies(templateId);
        console.log("Updated policies (%d):", updated.length);
        for (uint256 i = 0; i < updated.length; i++) {
            console.log("  [%d] %s", i, updated[i]);
        }
    }
}
