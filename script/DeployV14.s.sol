// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyRegistry} from "../src/PolicyRegistry.sol";
import {GroupRegistry} from "../src/GroupRegistry.sol";
import {InstanceConfig} from "../src/InstanceConfig.sol";
import {PolicyGuardV2} from "../src/PolicyGuardV2.sol";

/// @title DeployV14 — Deploy V1.4 Extension Contracts
/// @dev Usage: forge script script/DeployV14.s.sol --rpc-url $RPC_URL --broadcast
contract DeployV14 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        // 1. Deploy PolicyRegistry
        PolicyRegistry policyRegistry = new PolicyRegistry();
        console.log("PolicyRegistry deployed:", address(policyRegistry));

        // 2. Deploy GroupRegistry
        GroupRegistry groupRegistry = new GroupRegistry();
        console.log("GroupRegistry deployed:", address(groupRegistry));

        // 3. Deploy InstanceConfig
        InstanceConfig instanceConfig = new InstanceConfig();
        console.log("InstanceConfig deployed:", address(instanceConfig));

        // 4. Deploy PolicyGuardV2 (Depends on the previous 3)
        PolicyGuardV2 guardV2 = new PolicyGuardV2(
            address(policyRegistry),
            address(groupRegistry),
            address(instanceConfig)
        );
        console.log("PolicyGuardV2 deployed:", address(guardV2));

        vm.stopBroadcast();

        console.log("--- V1.4 Deployment Summary ---");
        console.log("PolicyRegistry:", address(policyRegistry));
        console.log("GroupRegistry:", address(groupRegistry));
        console.log("InstanceConfig:", address(instanceConfig));
        console.log("PolicyGuardV2:", address(guardV2));
    }
}
