// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IAgentNFAFix {
    function subscriptionManager() external view returns (address);
    function setSubscriptionManager(address manager) external;
}

contract FixNfaSubscriptionManager is Script {
    address constant NFA = 0x71cE46099E4b2a2434111C009A7E9CFd69747c8E;
    address constant EXPECTED_SUB_MANAGER = 0x66487D5509005825C85EB3AAE06c3Ec443eF7359;

    function run() external {
        vm.startBroadcast();

        address current = IAgentNFAFix(NFA).subscriptionManager();
        console.log("NFA:", NFA);
        console.log("Current subscriptionManager:", current);
        console.log("Expected subscriptionManager:", EXPECTED_SUB_MANAGER);

        if (current != EXPECTED_SUB_MANAGER) {
            IAgentNFAFix(NFA).setSubscriptionManager(EXPECTED_SUB_MANAGER);
            console.log("Updated subscriptionManager binding.");
        } else {
            console.log("No change needed.");
        }

        vm.stopBroadcast();
    }
}
