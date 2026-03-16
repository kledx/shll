// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";

interface IProtocolRegistry {
    function guardCall(bytes calldata data) external returns (bytes memory);
    function emergencyCall(address target, bytes calldata data) external returns (bytes memory);
}

interface IPolicyGuardV4 {
    function addTemplatePolicy(bytes32 templateId, address policy) external;
}

interface IListingManagerV2 {
    function createTemplateListing(address nfa, uint256 tokenId, uint96 pricePerDay, uint32 minDays) external returns (bytes32);
    function setListingConfig(bytes32 listingId, uint32 maxDays, uint32 gracePeriodDays) external;
}

/// @title MintMemeHunterFree
/// @dev Full pipeline: Mint + Register + Bind Policies + List (all 5 steps)
///   forge script script/MintMemeHunterFree.s.sol --account deployer --rpc-url $RPC_URL --broadcast --gas-price 3000000000 -vvv
contract MintMemeHunterFree is Script {
    function run() external {
        AgentNFA nfa = AgentNFA(vm.envAddress("AGENT_NFA"));
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY"));
        IListingManagerV2 listingManager = IListingManagerV2(vm.envAddress("LISTING_MANAGER_V2"));

        address spendingLimitAddr = vm.envAddress("SPENDING_LIMIT_V2");
        address cooldownAddr = vm.envAddress("COOLDOWN");
        address defiGuardAddr = vm.envAddress("DEFI_GUARD_V2");
        address receiverGuardAddr = vm.envAddress("RECEIVER_GUARD");

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

        // Step 1: Mint Agent (AgentNFA.onlyOwner -> deployer direct)
        uint256 tokenId = nfa.mintAgent(
            deployer,
            bytes32(uint256(1)),
            memeHunterType,
            string.concat("https://api.shll.run/api/metadata/", vm.toString(nfa.nextTokenId())),
            meta
        );
        console.log("Step 1 done - Token ID:", tokenId);

        // Step 2: Register Template
        nfa.registerTemplate(tokenId, templateKey);
        console.log("Step 2 done - Template registered");

        // Step 3: Bind 4 Policies via ProtocolRegistry.guardCall
        registry.guardCall(abi.encodeWithSelector(IPolicyGuardV4.addTemplatePolicy.selector, templateKey, spendingLimitAddr));
        registry.guardCall(abi.encodeWithSelector(IPolicyGuardV4.addTemplatePolicy.selector, templateKey, cooldownAddr));
        registry.guardCall(abi.encodeWithSelector(IPolicyGuardV4.addTemplatePolicy.selector, templateKey, defiGuardAddr));
        registry.guardCall(abi.encodeWithSelector(IPolicyGuardV4.addTemplatePolicy.selector, templateKey, receiverGuardAddr));
        console.log("Step 3 done - 4 policies bound");

        // Step 4: Spending ceiling via ProtocolRegistry.emergencyCall
        registry.emergencyCall(spendingLimitAddr, abi.encodeWithSignature(
            "setTemplateCeiling(bytes32,uint256,uint256,uint256)", templateKey, uint256(1 ether), uint256(0), uint256(3000)
        ));
        registry.emergencyCall(spendingLimitAddr, abi.encodeWithSignature(
            "setTemplateApproveCeiling(bytes32,uint256)", templateKey, uint256(100 ether)
        ));
        console.log("Step 4 done - Spending ceiling set");

        // Step 5: Create free listing
        bytes32 listingId = listingManager.createTemplateListing(address(nfa), tokenId, 0, 7);
        listingManager.setListingConfig(listingId, 0, 7);
        console.log("Step 5 done - Free listing created");

        vm.stopBroadcast();

        console.log("Token ID:", tokenId);
        console.log("Vault:", nfa.accountOf(tokenId));
        console.logBytes32(listingId);
    }
}
