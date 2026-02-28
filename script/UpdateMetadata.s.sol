// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";

interface IAgentNFA {
    function updateAgentMetadata(
        uint256 tokenId,
        IBAP578.AgentMetadata calldata metadata
    ) external;
    function setLogicAddress(uint256 tokenId, address newLogic) external;
}

/// @notice Update AgentNFA template (Token #0) metadata for nfascan trust
contract UpdateMetadata is Script {
    function run() external {
        address agentNFA = vm.envAddress("AGENT_NFA");
        address policyGuard = vm.envAddress("POLICY_GUARD_V4");

        // Persona JSON — represents the AgentNFA platform
        string
            memory persona = '{"name":"SHLL Agent","description":"AI Agent marketplace with contract-level safety. Every agent is protected by PolicyGuard: spending limits, cooldown, receiver guard, DEX whitelist, and DeFi function filtering. Non-custodial - your keys, your assets."}';

        IBAP578.AgentMetadata memory metadata = IBAP578.AgentMetadata({
            persona: persona,
            experience: "Template",
            voiceHash: "",
            animationURI: "https://api.shll.run/logo-highres.png",
            vaultURI: "https://shll.xyz",
            vaultHash: bytes32(0)
        });

        vm.startBroadcast();

        // 1. Update metadata for Token #0 (the template that nfascan reads)
        IAgentNFA(agentNFA).updateAgentMetadata(0, metadata);
        console.log("Metadata updated for AgentNFA template (token 0)");

        // 2. Set logic address to PolicyGuardV4
        IAgentNFA(agentNFA).setLogicAddress(0, policyGuard);
        console.log("Logic address set to PolicyGuardV4:", policyGuard);

        vm.stopBroadcast();
    }
}
