// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {LearningModule} from "../src/LearningModule.sol";

/// @title DeployOnly — Deploy AgentNFA + LearningModule only (no external calls)
/// @notice Post-deploy config done via cast send
contract DeployOnly is Script {
    address constant POLICY_GUARD = 0x25d17eA0e3Bcb8CA08a2BFE917E817AFc05dbBB3;
    address constant REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address constant LISTING_MGR = 0x1f9CE85bD0FF75acc3D92eB79f1Eb472f0865071;
    address constant SUB_MGR = 0x66487D5509005825C85EB3AAE06c3Ec443eF7359;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy
        AgentNFA nfa = new AgentNFA(POLICY_GUARD);
        LearningModule lm = new LearningModule(address(nfa));
        console.log("AgentNFA:", address(nfa));
        console.log("LearningModule:", address(lm));

        // 2. Internal config on NFA only
        nfa.setIdentityRegistry(REGISTRY);
        nfa.setLearningModule(address(lm));
        nfa.setListingManager(LISTING_MGR);
        nfa.setSubscriptionManager(SUB_MGR);

        vm.stopBroadcast();
        console.log(
            "Done. Run setAgentNFA on ListingManager and SubscriptionManager"
        );
    }
}
