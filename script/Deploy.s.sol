// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyGuard} from "../src/PolicyGuard.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {ListingManager} from "../src/ListingManager.sol";

/// @title Deploy — Deploy all core contracts
/// @dev Usage: forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        // 1. Deploy PolicyGuard
        PolicyGuard guard = new PolicyGuard();
        console.log("PolicyGuard deployed:", address(guard));

        // 2. Deploy AgentNFA (depends on PolicyGuard)
        AgentNFA nfa = new AgentNFA(address(guard));
        console.log("AgentNFA deployed:", address(nfa));

        // 3. Deploy ListingManager
        ListingManager listing = new ListingManager();
        console.log("ListingManager deployed:", address(listing));

        // 4. Wire up: NFA -> ListingManager
        nfa.setListingManager(address(listing));
        console.log("ListingManager linked to AgentNFA");

        vm.stopBroadcast();

        // Output summary
        console.log("--- Deployment Summary ---");
        console.log("PolicyGuard:", address(guard));
        console.log("AgentNFA:", address(nfa));
        console.log("ListingManager:", address(listing));
    }
}
