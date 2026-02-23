// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SubscriptionManager} from "../src/SubscriptionManager.sol";
import {ListingManagerV2} from "../src/ListingManagerV2.sol";

/// @title DeploySubscription — Deploy Subscription Model (P-033)
/// @notice Deploys SubscriptionManager + ListingManagerV2 and wires to existing infra.
///   Does NOT touch AgentNFA — call setListingManager separately when ready.
///
/// @dev Usage:
///   forge script script/DeploySubscription.s.sol \
///     --rpc-url $RPC_URL --broadcast --gas-price 5000000000 -vvv
///
/// Required .env:
///   PRIVATE_KEY        — deployer private key
///   AGENT_NFA          — existing AgentNFA address
///   POLICY_GUARD_V4    — existing PolicyGuardV4 address
contract DeploySubscription is Script {
    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = deployerKey != 0 ? vm.addr(deployerKey) : msg.sender;

        address agentNfa = vm.envAddress("AGENT_NFA");
        address policyGuard = vm.envAddress("POLICY_GUARD_V4");

        console.log("========================================================");
        console.log("  P-033: Subscription Model Deployment");
        console.log("========================================================");
        console.log("Deployer      :", deployer);
        console.log("Chain ID      :", block.chainid);
        console.log("AgentNFA      :", agentNfa);
        console.log("PolicyGuardV4 :", policyGuard);
        console.log("========================================================");
        console.log("");

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }

        // ── Deploy SubscriptionManager ──
        SubscriptionManager subManager = new SubscriptionManager();
        console.log("[1/2] SubscriptionManager :", address(subManager));

        // ── Deploy ListingManagerV2 ──
        ListingManagerV2 listingV2 = new ListingManagerV2();
        console.log("[2/2] ListingManagerV2    :", address(listingV2));

        // ── Wire contracts ──
        console.log("");
        console.log("Wiring contracts...");

        listingV2.setAgentNFA(agentNfa);
        console.log("  [wire] ListingManagerV2.setAgentNFA     -> NFA");

        listingV2.setPolicyGuard(policyGuard);
        console.log("  [wire] ListingManagerV2.setPolicyGuard  -> Guard");

        listingV2.setSubscriptionManager(address(subManager));
        console.log("  [wire] ListingManagerV2.setSubManager   -> SubMgr");

        subManager.setListingManager(address(listingV2));
        console.log("  [wire] SubscriptionManager.setLM        -> LMv2");

        subManager.setAgentNFA(agentNfa);
        console.log("  [wire] SubscriptionManager.setAgentNFA  -> NFA");

        vm.stopBroadcast();

        // ── Summary ──
        console.log("");
        console.log("========================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("========================================================");
        console.log("");
        console.log("--- New Contracts ---");
        console.log(
            string.concat(
                "SUBSCRIPTION_MANAGER=",
                vm.toString(address(subManager))
            )
        );
        console.log(
            string.concat(
                "LISTING_MANAGER_V2=",
                vm.toString(address(listingV2))
            )
        );
        console.log("");
        console.log("--- Runner Env ---");
        console.log(
            string.concat(
                "SUBSCRIPTION_MANAGER_ADDRESS=",
                vm.toString(address(subManager))
            )
        );
        console.log("");
        console.log("--- Frontend Env ---");
        console.log(
            string.concat(
                "NEXT_PUBLIC_SUBSCRIPTION_MANAGER=",
                vm.toString(address(subManager))
            )
        );
        console.log("");
        console.log("========================================================");
        console.log("  IMPORTANT: NFA NOT SWITCHED YET");
        console.log("  To activate V2 for new mints, run:");
        console.log(
            string.concat(
                "  AgentNFA(",
                vm.toString(agentNfa),
                ").setListingManager(",
                vm.toString(address(listingV2)),
                ")"
            )
        );
        console.log("========================================================");
    }
}
