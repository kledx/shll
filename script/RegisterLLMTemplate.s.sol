// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";
import {TokenWhitelistPolicy} from "../src/policies/TokenWhitelistPolicy.sol";
import {SpendingLimitPolicy} from "../src/policies/SpendingLimitPolicy.sol";
import {CooldownPolicy} from "../src/policies/CooldownPolicy.sol";
import {ReceiverGuardPolicy} from "../src/policies/ReceiverGuardPolicy.sol";
import {DexWhitelistPolicy} from "../src/policies/DexWhitelistPolicy.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";

/// @title RegisterLLMTemplate — Register LLM Trader template on existing deployment
/// @notice Mints an LLM template agent, registers it, attaches policies, and lists it
contract RegisterLLMTemplate is Script {
    bytes32 constant TEMPLATE_LLM = keccak256("llm_trader_v3");

    function run() external {
        // Read deployed contract addresses from env
        address nfaAddr = vm.envAddress("AGENT_NFA");
        address guardAddr = vm.envAddress("POLICY_GUARD_V4");
        address lmAddr = vm.envAddress("LISTING_MANAGER");
        address tokenWLAddr = vm.envAddress("TOKEN_WL");
        address spendingLimitAddr = vm.envAddress("SPENDING_LIMIT");
        address cooldownAddr = vm.envAddress("COOLDOWN");
        address receiverGuardAddr = vm.envAddress("RECEIVER_GUARD");
        address dexWLAddr = vm.envAddress("DEX_WL");
        address router = vm.envAddress("ROUTER_ADDRESS");
        address usdt = vm.envAddress("USDT_ADDRESS");
        address wbnb = vm.envAddress("WBNB_ADDRESS");

        // Cast to contract types
        AgentNFA nfa = AgentNFA(nfaAddr);
        PolicyGuardV4 guardV4 = PolicyGuardV4(guardAddr);
        ListingManager lm = ListingManager(lmAddr);
        TokenWhitelistPolicy tokenWL = TokenWhitelistPolicy(tokenWLAddr);
        SpendingLimitPolicy spendingLimit = SpendingLimitPolicy(
            spendingLimitAddr
        );
        CooldownPolicy cooldown = CooldownPolicy(cooldownAddr);
        ReceiverGuardPolicy receiverGuard = ReceiverGuardPolicy(
            receiverGuardAddr
        );
        DexWhitelistPolicy dexWL = DexWhitelistPolicy(dexWLAddr);

        // Use on-chain owner to avoid msg.sender/broadcast sender mismatch.
        address deployer = nfa.owner();

        console.log("========================================================");
        console.log("  Register LLM Trader Template");
        console.log("========================================================");
        console.log("Deployer:", deployer);
        console.log("AgentNFA:", nfaAddr);
        console.log("");

        vm.startBroadcast();

        // 1. Mint LLM Template Agent
        IBAP578.AgentMetadata memory meta = IBAP578.AgentMetadata({
            persona: '{"name":"LLM Trader Agent","description":"AI-powered autonomous trading agent driven by LLM reasoning"}',
            experience: "Template",
            voiceHash: "",
            animationURI: "",
            vaultURI: "",
            vaultHash: bytes32(0)
        });

        uint256 llmTokenId = nfa.mintAgent(
            deployer,
            bytes32(uint256(2)),
            nfa.TYPE_LLM_TRADER(),
            "https://api.shll.run/api/metadata/1",
            meta
        );
        console.log("  [mint]     LLM Template tokenId:", llmTokenId);

        // 2. Register as template
        nfa.registerTemplate(llmTokenId, TEMPLATE_LLM);
        console.log("  [register] Template key llm_trader_v3");

        // 3. Attach 5 policies
        guardV4.addTemplatePolicy(TEMPLATE_LLM, address(receiverGuard));
        guardV4.addTemplatePolicy(TEMPLATE_LLM, address(spendingLimit));
        guardV4.addTemplatePolicy(TEMPLATE_LLM, address(tokenWL));
        guardV4.addTemplatePolicy(TEMPLATE_LLM, address(dexWL));
        guardV4.addTemplatePolicy(TEMPLATE_LLM, address(cooldown));
        console.log("  [policies] 5 policies attached");

        // 4. Configure ceilings: 10 BNB/tx, 50 BNB/day, 5% slippage
        spendingLimit.setTemplateCeiling(TEMPLATE_LLM, 10 ether, 50 ether, 500);
        console.log("  [ceiling]  10 BNB/tx, 50 BNB/day, 5%");

        // 5. Token whitelist
        tokenWL.addToken(llmTokenId, usdt);
        tokenWL.addToken(llmTokenId, wbnb);
        console.log("  [whitelist] Tokens: USDT, WBNB");

        // 6. DEX whitelist
        dexWL.addDex(llmTokenId, router);
        console.log("  [whitelist] DEX: PancakeSwap Router");

        // 7. Cooldown
        cooldown.setCooldown(llmTokenId, 60);
        console.log("  [cooldown] 60 seconds");

        // 8. Approve + List
        nfa.approve(address(lm), llmTokenId);
        bytes32 listingId = lm.createTemplateListing(
            address(nfa),
            llmTokenId,
            uint96(0.0005 ether), // ~0.3 USDT/day at BNB=$620
            1
        );
        console.log("  [listing]  Listed at 0.005 BNB/day");
        console.log("  [listing]  Listing ID:");
        console.logBytes32(listingId);

        vm.stopBroadcast();

        console.log("");
        console.log("========================================================");
        console.log("  LLM TEMPLATE REGISTERED SUCCESSFULLY");
        console.log("  Token ID:", llmTokenId);
        console.log("========================================================");
    }
}
