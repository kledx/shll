// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";
import {TokenWhitelistPolicy} from "../src/policies/TokenWhitelistPolicy.sol";
import {SpendingLimitPolicy} from "../src/policies/SpendingLimitPolicy.sol";
import {CooldownPolicy} from "../src/policies/CooldownPolicy.sol";
import {ReceiverGuardPolicy} from "../src/policies/ReceiverGuardPolicy.sol";
import {DexWhitelistPolicy} from "../src/policies/DexWhitelistPolicy.sol";
import {AgentNFA} from "../src/AgentNFA.sol";

/// @title DeployV30 — Deploy V3.0 Composable Policy Architecture
/// @notice Deploys PolicyGuardV4 + 5 Policy Plugins, wires them with AgentNFA
/// @dev Usage:
///   forge script script/DeployV30.s.sol --rpc-url $RPC_URL --broadcast -vvv
///
/// Required env vars:
///   PRIVATE_KEY        — deployer private key
///   AGENT_NFA          — existing AgentNFA address (to wire PolicyGuardV4)
contract DeployV30 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address agentNFA = vm.envAddress("AGENT_NFA");

        vm.startBroadcast(deployerKey);

        // 1. Deploy PolicyGuardV4
        PolicyGuardV4 guardV4 = new PolicyGuardV4();
        console.log("PolicyGuardV4       :", address(guardV4));

        // 2. Deploy Policy Plugins (each needs guard + nfa references)
        TokenWhitelistPolicy tokenWL = new TokenWhitelistPolicy(
            address(guardV4),
            agentNFA
        );
        console.log("TokenWhitelistPolicy:", address(tokenWL));

        SpendingLimitPolicy spendingLimit = new SpendingLimitPolicy(
            address(guardV4),
            agentNFA
        );
        console.log("SpendingLimitPolicy :", address(spendingLimit));

        CooldownPolicy cooldownPolicy = new CooldownPolicy(
            address(guardV4),
            agentNFA
        );
        console.log("CooldownPolicy      :", address(cooldownPolicy));

        ReceiverGuardPolicy receiverGuard = new ReceiverGuardPolicy(agentNFA);
        console.log("ReceiverGuardPolicy :", address(receiverGuard));

        DexWhitelistPolicy dexWL = new DexWhitelistPolicy(
            address(guardV4),
            agentNFA
        );
        console.log("DexWhitelistPolicy  :", address(dexWL));

        // 3. Wire PolicyGuardV4 with AgentNFA
        guardV4.setAgentNFA(agentNFA);
        console.log("PolicyGuardV4 wired with AgentNFA");

        // 4. Register policies as approved in PolicyGuardV4
        guardV4.approvePolicyContract(address(tokenWL));
        guardV4.approvePolicyContract(address(spendingLimit));
        guardV4.approvePolicyContract(address(cooldownPolicy));
        guardV4.approvePolicyContract(address(receiverGuard));
        guardV4.approvePolicyContract(address(dexWL));
        console.log("All 5 policies approved");

        // 5. Upgrade AgentNFA to use PolicyGuardV4
        AgentNFA(agentNFA).setPolicyGuard(address(guardV4));
        console.log("AgentNFA PolicyGuard upgraded to V4");

        vm.stopBroadcast();

        console.log("");
        console.log("========== V3.0 DEPLOYMENT COMPLETE ==========");
        console.log("PolicyGuardV4       :", address(guardV4));
        console.log("TokenWhitelistPolicy:", address(tokenWL));
        console.log("SpendingLimitPolicy :", address(spendingLimit));
        console.log("CooldownPolicy      :", address(cooldownPolicy));
        console.log("ReceiverGuardPolicy :", address(receiverGuard));
        console.log("DexWhitelistPolicy  :", address(dexWL));
        console.log("AgentNFA            :", agentNFA);
        console.log("================================================");
        console.log("");
        console.log("Add to .env for SetupV30Templates.s.sol:");
        console.log(
            string.concat("POLICY_GUARD_V4=", vm.toString(address(guardV4)))
        );
        console.log(string.concat("TOKEN_WL=", vm.toString(address(tokenWL))));
        console.log(
            string.concat(
                "SPENDING_LIMIT=",
                vm.toString(address(spendingLimit))
            )
        );
        console.log(
            string.concat("COOLDOWN=", vm.toString(address(cooldownPolicy)))
        );
        console.log(
            string.concat(
                "RECEIVER_GUARD=",
                vm.toString(address(receiverGuard))
            )
        );
        console.log(string.concat("DEX_WL=", vm.toString(address(dexWL))));
    }
}
