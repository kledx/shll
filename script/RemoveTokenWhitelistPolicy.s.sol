// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

interface IPolicyGuardV4 {
    function instanceTemplateId(uint256) external view returns (bytes32);
    function getTemplatePolicies(
        bytes32 templateId
    ) external view returns (address[] memory);
    function removeTemplatePolicy(bytes32 templateId, uint256 index) external;
}

/// @notice Remove TokenWhitelistPolicy from a template's policy set.
/// Usage: forge script script/RemoveTokenWhitelistPolicy.s.sol --rpc-url $RPC_URL --broadcast --gas-price 3000000000 -vvv
contract RemoveTokenWhitelistPolicy is Script {
    // Mainnet addresses from RESOURCE-MAP.yml
    address constant POLICY_GUARD = 0x25d17eA0e3Bcb8CA08a2BFE917E817AFc05dbBB3;
    address constant TOKEN_WL_POLICY =
        0xfD8E7f4180EA5aF0D61c2037Cd7cEECF34BEE1E1;
    uint256 constant INSTANCE_ID = 3; // Any instance to derive the template ID

    function run() external {
        IPolicyGuardV4 guard = IPolicyGuardV4(POLICY_GUARD);

        // 1. Get template ID from an existing instance
        bytes32 templateId = guard.instanceTemplateId(INSTANCE_ID);
        console.log("Template ID:");
        console.logBytes32(templateId);

        // 2. Get current template policies
        address[] memory policies = guard.getTemplatePolicies(templateId);
        console.log("Current template policies (%d):", policies.length);
        for (uint256 i = 0; i < policies.length; i++) {
            console.log("  [%d] %s", i, policies[i]);
        }

        // 3. Find the index of TokenWhitelistPolicy
        uint256 targetIndex = type(uint256).max;
        for (uint256 i = 0; i < policies.length; i++) {
            if (policies[i] == TOKEN_WL_POLICY) {
                targetIndex = i;
                break;
            }
        }
        require(
            targetIndex != type(uint256).max,
            "TokenWhitelistPolicy not found in template"
        );
        console.log("Found TokenWhitelistPolicy at index:", targetIndex);

        // 4. Remove it
        vm.startBroadcast();
        guard.removeTemplatePolicy(templateId, targetIndex);
        vm.stopBroadcast();

        console.log("TokenWhitelistPolicy removed from template!");

        // 5. Verify
        address[] memory remaining = guard.getTemplatePolicies(templateId);
        console.log("Remaining policies (%d):", remaining.length);
        for (uint256 i = 0; i < remaining.length; i++) {
            console.log("  [%d] %s", i, remaining[i]);
        }
    }
}
