// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";

/// @title MintLLMAgent — Mint a new LLM Trader agent for E2E testing
/// @dev Usage:
///   forge script script/MintLLMAgent.s.sol --rpc-url $RPC_URL --broadcast --gas-price 5000000000 -vvv
contract MintLLMAgent is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        AgentNFA nfa = AgentNFA(vm.envAddress("AGENT_NFA"));
        bytes32 llmType = keccak256("llm_trader");

        IBAP578.AgentMetadata memory meta = IBAP578.AgentMetadata({
            persona: '{"name":"LLM Trader Agent","description":"AI-powered trading agent using LLM reasoning"}',
            experience: "E2E Test",
            voiceHash: "",
            animationURI: "",
            vaultURI: "",
            vaultHash: bytes32(0)
        });

        vm.startBroadcast(deployerKey);

        uint256 tokenId = nfa.mintAgent(
            deployer,
            bytes32(uint256(1)), // policyId
            llmType, // V3.0: agent type
            string.concat(
                "https://api.shll.run/api/metadata/",
                vm.toString(nfa.nextTokenId())
            ),
            meta
        );

        console.log("========== LLM Agent Minted ==========");
        console.log("Token ID    :", tokenId);
        console.log("Agent Type  : llm_trader");
        console.log("Agent Type Hash:");
        console.logBytes32(llmType);
        console.log("Owner       :", deployer);
        console.log("Account     :", nfa.accountOf(tokenId));
        console.log("=======================================");

        vm.stopBroadcast();
    }
}
