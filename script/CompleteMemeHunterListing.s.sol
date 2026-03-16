// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentNFA} from "../src/AgentNFA.sol";

interface IProtocolRegistry {
    function guardCall(bytes calldata data) external returns (bytes memory);
    function emergencyCall(address target, bytes calldata data) external returns (bytes memory);
}

interface IPolicyGuardV4 {
    function addTemplatePolicy(bytes32 templateId, address policy) external;
    function getTemplatePolicies(bytes32 templateId) external view returns (address[] memory);
}

interface IListingManagerV2 {
    function createTemplateListing(address nfa, uint256 tokenId, uint96 pricePerDay, uint32 minDays) external returns (bytes32);
    function setListingConfig(bytes32 listingId, uint32 maxDays, uint32 gracePeriodDays) external;
}

/// @title CompleteMemeHunterListing — Complete Steps 3-5 for Token ID 30
/// @dev Steps 1-2 already done on-chain (tokenId=30, templateKey=keccak256("meme_hunter_free"))
///
///   Step 3: Bind 4 policies via ProtocolRegistry.guardCall() → PolicyGuardV4.addTemplatePolicy()
///   Step 4: Configure SpendingLimitV2 ceiling via ProtocolRegistry.emergencyCall()
///   Step 5: Create free listing on ListingManagerV2 (deployer owns token, direct call)
///
/// Usage:
///   forge script script/CompleteMemeHunterListing.s.sol --account deployer --rpc-url $RPC_URL --broadcast --gas-price 3000000000 -vvv
contract CompleteMemeHunterListing is Script {
    function run() external {
        // ── Contract addresses ──────────────────
        AgentNFA nfa = AgentNFA(vm.envAddress("AGENT_NFA"));
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY"));
        IListingManagerV2 listingManager = IListingManagerV2(vm.envAddress("LISTING_MANAGER_V2"));

        address spendingLimitAddr = vm.envAddress("SPENDING_LIMIT_V2");
        address cooldownAddr = vm.envAddress("COOLDOWN");
        address defiGuardAddr = vm.envAddress("DEFI_GUARD_V2");
        address receiverGuardAddr = vm.envAddress("RECEIVER_GUARD");

        // ── Already-deployed state ──────────────
        uint256 tokenId = 30;
        bytes32 templateKey = keccak256("meme_hunter_free");

        // ── Free tier params ────────────────────
        uint256 maxPerTx = 1 ether;       // 1 BNB per transaction
        uint256 maxPerDay = 0;             // disabled
        uint256 maxSlippageBps = 3000;     // 30%
        uint256 maxApprove = 100 ether;    // 100 BNB approve ceiling
        uint96 pricePerDay = 0;            // Free
        uint32 minDays = 7;

        console.log("=== Continuing from Token ID 30 ===");
        console.log("Template Key:");
        console.logBytes32(templateKey);

        vm.startBroadcast();

        // ── Step 3: Bind 4 Policies via guardCall ──
        // PolicyGuardV4.owner() == ProtocolRegistry, so we proxy through guardCall
        registry.guardCall(
            abi.encodeWithSelector(IPolicyGuardV4.addTemplatePolicy.selector, templateKey, spendingLimitAddr)
        );
        registry.guardCall(
            abi.encodeWithSelector(IPolicyGuardV4.addTemplatePolicy.selector, templateKey, cooldownAddr)
        );
        registry.guardCall(
            abi.encodeWithSelector(IPolicyGuardV4.addTemplatePolicy.selector, templateKey, defiGuardAddr)
        );
        registry.guardCall(
            abi.encodeWithSelector(IPolicyGuardV4.addTemplatePolicy.selector, templateKey, receiverGuardAddr)
        );
        console.log("=== Step 3: 4 Policies Bound (via guardCall) ===");
        console.log("  SpendingLimitV2 :", spendingLimitAddr);
        console.log("  Cooldown        :", cooldownAddr);
        console.log("  DeFiGuardV2     :", defiGuardAddr);
        console.log("  ReceiverGuard   :", receiverGuardAddr);

        // ── Step 4: Configure SpendingLimitV2 ceiling via emergencyCall ──
        // SpendingLimitV2._onlyOwner() checks Ownable(guard).owner() == ProtocolRegistry
        registry.emergencyCall(
            spendingLimitAddr,
            abi.encodeWithSignature(
                "setTemplateCeiling(bytes32,uint256,uint256,uint256)",
                templateKey, maxPerTx, maxPerDay, maxSlippageBps
            )
        );
        registry.emergencyCall(
            spendingLimitAddr,
            abi.encodeWithSignature(
                "setTemplateApproveCeiling(bytes32,uint256)",
                templateKey, maxApprove
            )
        );
        console.log("=== Step 4: Spending Ceiling Set (via emergencyCall) ===");
        console.log("  maxPerTx     : 1 BNB");
        console.log("  maxSlippage  : 3000 bps (30%)");
        console.log("  maxApprove   : 100 BNB");

        // ── Step 5: Create Free Listing ──────────
        // ListingManagerV2 checks IERC721.ownerOf == msg.sender (deployer owns token 30)
        bytes32 listingId = listingManager.createTemplateListing(
            address(nfa),
            tokenId,
            pricePerDay,
            minDays
        );
        listingManager.setListingConfig(listingId, 0, 7);
        console.log("=== Step 5: Free Listing Created ===");
        console.log("Listing ID:");
        console.logBytes32(listingId);
        console.log("  Price/Day   : 0 (FREE)");
        console.log("  Min Days    : 7");
        console.log("  Grace Days  : 7");

        vm.stopBroadcast();

        // ── Summary ─────────────────────────────
        console.log("");
        console.log("========================================");
        console.log("  MemeHunter Free NFA Template Ready!");
        console.log("========================================");
        console.log("Token ID  :", tokenId);
        console.log("Vault     :", nfa.accountOf(tokenId));
        console.log("Listing ID:");
        console.logBytes32(listingId);
        console.log("========================================");
    }
}
