// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";

/// @title QuickMint — Hardcoded NFA address for immediate use
contract QuickMint is Script {
    function run() external {
        AgentNFA nfa = AgentNFA(0x71cE46099E4b2a2434111C009A7E9CFd69747c8E);
        address deployer = 0x51eD50c9e29481dB812d004EC4322CCdFa9a2868;

        string
            memory uri = "data:application/json;base64,eyJ0eXBlIjoiaHR0cHM6Ly9laXBzLmV0aGVyZXVtLm9yZy9FSVBTL2VpcC04MDA0IyIsInZlcnNpb24iOiIxLjAuMCIsIm5hbWUiOiJTSExMIERlRmkgQWdlbnQiLCJkZXNjcmlwdGlvbiI6IkFJLXBvd2VyZWQgYXV0b25vbW91cyBEZUZpIGFnZW50IHdpdGggb24tY2hhaW4gc2FmZXR5IGVuZm9yY2VtZW50IHZpYSBQb2xpY3lHdWFyZC4gU3VwcG9ydHMgc3dhcCwgbGVuZGluZywgYW5kIHBvcnRmb2xpbyBtYW5hZ2VtZW50IG9uIEJOQiBDaGFpbi4iLCJpbWFnZSI6Imh0dHBzOi8vc2hsbC5ydW4vbG9nby1oaWdocmVzLnBuZyIsInVybCI6Imh0dHBzOi8vc2hsbC5ydW4iLCJwcm92aWRlciI6IlNITEwiLCJjYXBhYmlsaXRpZXMiOlsiZGVmaV90cmFkaW5nIiwicG9ydGZvbGlvX21hbmFnZW1lbnQiLCJsZW5kaW5nIiwicmlza19tYW5hZ2VtZW50IiwiYXV0b25vbW91c19leGVjdXRpb24iXSwic3VwcG9ydGVkQ2hhaW5zIjpbIjU2Il0sImFjdGl2ZSI6dHJ1ZSwieDQwMlN1cHBvcnQiOmZhbHNlLCJzdXBwb3J0ZWRUcnVzdCI6WyJyZXB1dGF0aW9uIl19";

        IBAP578.AgentMetadata memory meta = IBAP578.AgentMetadata({
            persona: '{"name":"SHLL DeFi Agent"}',
            experience: "Template",
            voiceHash: "",
            animationURI: "https://shll.run/logo-highres.png",
            vaultURI: "https://shll.run",
            vaultHash: bytes32(0)
        });

        vm.startBroadcast();
        uint256 tokenId = nfa.mintAgent(
            deployer,
            bytes32(uint256(1)),
            keccak256("TYPE_LLM_TRADER"),
            uri,
            meta
        );
        console.log("tokenId:", tokenId);
        console.log("vault:", nfa.accountOf(tokenId));
        console.log("isRegistered8004:", nfa.isRegistered8004(tokenId));
        vm.stopBroadcast();
    }
}
