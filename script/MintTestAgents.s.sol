// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AgentNFA.sol";
import "../src/ListingManager.sol";
import "../src/interfaces/IBAP578.sol";

contract MintTestAgents is Script {
    AgentNFA agentNFA;
    ListingManager listingManager;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // BSC Testnet addresses from env
        agentNFA = AgentNFA(vm.envAddress("AGENT_NFA"));
        listingManager = ListingManager(vm.envAddress("LISTING_MANAGER"));

        vm.startBroadcast(deployerPrivateKey);

        // 1. Mint Agent 1: "DeFi Trader"
        IBAP578.AgentMetadata memory meta1 = IBAP578.AgentMetadata({
            persona: '{"name": "Alpha Trader", "role": "DeFi Sniper", "description": "High-frequency arbitrage bot"}',
            experience: "Level 10",
            voiceHash: "QmVoiceHash1",
            animationURI: "ipfs://QmAnimation1",
            vaultURI: "https://vault.shll.io/agent/1",
            vaultHash: bytes32(uint256(1))
        });

        // Minting Agent 1
        uint256 tokenId1 = agentNFA.mintAgent(
            deployer,
            bytes32(uint256(1)), // policyId 1
            "https://api.shll.io/metadata/1",
            meta1
        );
        console.log("Minted Agent 1:", tokenId1);

        // Approve ListingManager
        agentNFA.approve(address(listingManager), tokenId1);

        // List Agent 1
        listingManager.createListing(
            address(agentNFA),
            tokenId1,
            uint96(0.01 ether), // 0.01 BNB per day
            1 days // Min duration
        );
        console.log("Listed Agent 1");

        // 2. Mint Agent 2: "Yield Farmer"
        IBAP578.AgentMetadata memory meta2 = IBAP578.AgentMetadata({
            persona: '{"name": "Yield Harvester", "role": "Farmer", "description": "Automated yield compounding"}',
            experience: "Level 5",
            voiceHash: "QmVoiceHash2",
            animationURI: "ipfs://QmAnimation2",
            vaultURI: "https://vault.shll.io/agent/2",
            vaultHash: bytes32(uint256(2))
        });

        uint256 tokenId2 = agentNFA.mintAgent(
            deployer,
            bytes32(uint256(1)),
            "https://api.shll.io/metadata/2",
            meta2
        );
        console.log("Minted Agent 2:", tokenId2);

        agentNFA.approve(address(listingManager), tokenId2);
        listingManager.createListing(
            address(agentNFA),
            tokenId2,
            uint96(0.005 ether),
            1 days
        );
        console.log("Listed Agent 2");

        vm.stopBroadcast();
    }
}
