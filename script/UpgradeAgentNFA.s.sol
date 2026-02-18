// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";

/// @title UpgradeAgentNFA — Redeploy AgentNFA with V3.1 fixes
/// @notice Deploys fresh AgentNFA (with setAgentType + instance type inheritance),
///         wires to existing PolicyGuardV4. Testnet only — tokens are not migrated.
/// @dev Usage:
///   forge script script/UpgradeAgentNFA.s.sol --rpc-url $RPC_URL --broadcast --gas-price 5000000000 -vvv
///
/// Required env vars:
///   PRIVATE_KEY        — deployer private key
///   POLICY_GUARD_V4    — existing PolicyGuardV4 address
///   LISTING_MANAGER    — existing ListingManager address
contract UpgradeAgentNFA is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address guardV4 = vm.envAddress("POLICY_GUARD_V4");
        address listingMgr = vm.envAddress("LISTING_MANAGER");

        vm.startBroadcast(deployerKey);

        // 1. Deploy new AgentNFA (constructor takes policyGuard address)
        AgentNFA nfa = new AgentNFA(guardV4);
        console.log("New AgentNFA deployed:", address(nfa));

        // 3. Wire ListingManager on NFA
        nfa.setListingManager(listingMgr);
        console.log("ListingManager wired:", listingMgr);

        // 4. Re-point PolicyGuardV4 to new NFA
        PolicyGuardV4(guardV4).setAgentNFA(address(nfa));
        console.log("PolicyGuardV4 re-pointed to new NFA");

        vm.stopBroadcast();

        console.log("");
        console.log("========== V3.1 AGENT NFA UPGRADE COMPLETE ==========");
        console.log("New AgentNFA  :", address(nfa));
        console.log("Owner        :", deployer);
        console.log("PolicyGuardV4:", guardV4);
        console.log("ListingMgr   :", listingMgr);
        console.log("=====================================================");
        console.log("");
        console.log("UPDATE .env:");
        console.log(string.concat("AGENT_NFA=", vm.toString(address(nfa))));
        console.log("");
        console.log("NEXT STEPS:");
        console.log("  1. Update AGENT_NFA in .env");
        console.log("  2. Re-run SetupV30Templates.s.sol");
        console.log("  3. Update shll-runner, shll-indexer, shll-web env vars");
        console.log("  4. Redeploy all services");
    }
}
