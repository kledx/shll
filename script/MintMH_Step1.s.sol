// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";

/// @title Step 1-2: Mint agent + register template
/// @dev forge script script/MintMH_Step1.s.sol --account deployer --rpc-url $RPC --broadcast --gas-price 1000000000 --slow -vvv
contract MintMH_Step1 is Script {
    function run() external {
        AgentNFA nfa = AgentNFA(vm.envAddress("AGENT_NFA"));
        bytes32 memeHunterType = keccak256("meme_hunter");
        bytes32 templateKey = keccak256("meme_hunter_free");
        address deployer = nfa.owner();

        IBAP578.AgentMetadata memory meta = IBAP578.AgentMetadata({
            persona: '{"name":"Meme Hunter","description":"Meme token trading agent"}',
            experience: "Production",
            voiceHash: "",
            animationURI: "",
            vaultURI: "",
            vaultHash: bytes32(0)
        });

        vm.startBroadcast();

        uint256 tokenId = nfa.mintAgent(
            deployer,
            bytes32(uint256(1)),
            memeHunterType,
            string.concat("https://api.shll.run/api/metadata/", vm.toString(nfa.nextTokenId())),
            meta
        );
        console.log("Token ID:", tokenId);
        console.log("Vault:", nfa.accountOf(tokenId));

        nfa.registerTemplate(tokenId, templateKey);
        console.log("Template registered");
        console.logBytes32(templateKey);

        vm.stopBroadcast();
    }
}
