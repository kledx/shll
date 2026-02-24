// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CooldownPolicy} from "../src/policies/CooldownPolicy.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";

/// @title UpgradeCooldownPolicy — Replace CooldownPolicy with approve-exempt version
/// @notice Deploys new CooldownPolicy, swaps it in PolicyGuardV4 templates, sets cooldown.
///
/// This enables executeBatch([approve, swap]) by exempting ERC20.approve from cooldown
/// check and commit, so the second action (swap) in a batch is not blocked.
///
/// @dev Usage:
///   forge script script/UpgradeCooldownPolicy.s.sol \
///     --account deployer --rpc-url https://bsc-dataseed1.binance.org \
///     --broadcast --gas-price 3000000000 -vvv
contract UpgradeCooldownPolicy is Script {
    bytes32 constant TEMPLATE_LLM = keccak256("llm_trader_v3");

    // BSC Mainnet addresses (from RESOURCE-MAP.yml, EIP-55 checksummed)
    address constant GUARD = 0x25d17eA0e3Bcb8CA08a2BFE917E817AFc05dbBB3;
    address constant NFA = 0xE98DCdbf370D7b52c9A2b88F79bEF514A5375a2b;
    address constant OLD_COOLDOWN = 0x6E76d3Fa74a4Cfff9c6dD0cA6f24533d4c8C4058;

    // CooldownPolicy is at index 4 in template policies (verified via cast call)
    // [0]=ReceiverGuard, [1]=SpendingLimit, [2]=TokenWL, [3]=DexWL, [4]=Cooldown, [5]=DeFiGuard
    uint256 constant OLD_COOLDOWN_INDEX = 4;
    uint256 constant TEMPLATE_TOKEN_ID = 0;
    uint256 constant COOLDOWN_SECS = 60;

    function run() external {
        console.log("========================================================");
        console.log("  CooldownPolicy Upgrade (Approve-Exempt)");
        console.log("========================================================");
        console.log("Chain ID         :", block.chainid);
        console.log("PolicyGuardV4    :", GUARD);
        console.log("AgentNFA         :", NFA);
        console.log("Old Cooldown     :", OLD_COOLDOWN);
        console.log("Old Index        :", OLD_COOLDOWN_INDEX);
        console.log("========================================================");

        vm.startBroadcast();

        // Step 1: Deploy new CooldownPolicy
        CooldownPolicy newCooldown = new CooldownPolicy(GUARD, NFA);
        console.log("[1/5] New CooldownPolicy:", address(newCooldown));

        // Step 2: Approve new policy in PolicyGuardV4
        PolicyGuardV4(GUARD).approvePolicyContract(address(newCooldown));
        console.log("[2/5] Approved in PolicyGuardV4");

        // Step 3: Remove old CooldownPolicy from template (at index 4)
        PolicyGuardV4(GUARD).removeTemplatePolicy(
            TEMPLATE_LLM,
            OLD_COOLDOWN_INDEX
        );
        console.log("[3/5] Removed old CooldownPolicy from template");

        // Step 4: Add new CooldownPolicy to template
        PolicyGuardV4(GUARD).addTemplatePolicy(
            TEMPLATE_LLM,
            address(newCooldown)
        );
        console.log("[4/5] Added new CooldownPolicy to template");

        // Step 5: Set cooldown for template token
        newCooldown.setCooldown(TEMPLATE_TOKEN_ID, COOLDOWN_SECS);
        console.log("[5/5] Cooldown set to 60 seconds");

        vm.stopBroadcast();

        console.log("");
        console.log("========================================================");
        console.log("  UPGRADE COMPLETE");
        console.log("========================================================");
        console.log("New CooldownPolicy:", address(newCooldown));
        console.log("");
        console.log("Update RESOURCE-MAP.yml:");
        console.log(
            string.concat(
                '  CooldownPolicy: "',
                vm.toString(address(newCooldown)),
                '"'
            )
        );
        console.log("========================================================");
    }
}
