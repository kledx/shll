// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IPolicyGuardV4 {
    function getTemplatePolicies(
        bytes32 templateKey
    ) external view returns (address[] memory);
    function getActivePolicies(
        uint256 instanceId
    ) external view returns (address[] memory);
}

contract CheckPolicies is Script {
    function run() external view {
        IPolicyGuardV4 guard = IPolicyGuardV4(
            0xe8828aB104a24114A8fB3AfA5BcfCc09a069B427
        );

        bytes32 llmKey = keccak256("llm_trader_v3");
        console.log("LLM Trader template key:");
        console.logBytes32(llmKey);

        address[] memory templatePolicies = guard.getTemplatePolicies(llmKey);
        console.log("Template policies count:", templatePolicies.length);
        for (uint i = 0; i < templatePolicies.length; i++) {
            console.log("  Policy", i, ":", templatePolicies[i]);
        }

        // Check instance #2 (the rented agent)
        address[] memory instancePolicies = guard.getActivePolicies(2);
        console.log(
            "Instance #2 active policies count:",
            instancePolicies.length
        );
        for (uint i = 0; i < instancePolicies.length; i++) {
            console.log("  Active", i, ":", instancePolicies[i]);
        }
    }
}
