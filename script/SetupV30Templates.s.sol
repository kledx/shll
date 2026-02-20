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
import {ListingManager} from "../src/ListingManager.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";

// V3.1: Use AgentNFA directly (5-param mintAgent with agentType)

/// @title SetupV30Templates 鈥?Configure V3.0 templates, ceilings, and whitelists
/// @notice Run AFTER DeployV30.s.sol. Creates template agents with full policy config.
/// @dev Usage:
///   forge script script/SetupV30Templates.s.sol --rpc-url $RPC_URL --broadcast --gas-price 5000000000 -vvv
///
/// Required env vars (all from DeployV30 output):
///   PRIVATE_KEY        鈥?deployer private key
///   AGENT_NFA          鈥?AgentNFA contract
///   POLICY_GUARD_V4    鈥?PolicyGuardV4 contract
///   TOKEN_WL           鈥?TokenWhitelistPolicy contract
///   SPENDING_LIMIT     鈥?SpendingLimitPolicy contract
///   COOLDOWN           鈥?CooldownPolicy contract
///   RECEIVER_GUARD     鈥?ReceiverGuardPolicy contract
///   DEX_WL             鈥?DexWhitelistPolicy contract
///   LISTING_MANAGER    鈥?ListingManager contract
///   ROUTER_ADDRESS     鈥?PancakeSwap V2 Router
///   USDT_ADDRESS       鈥?USDT token
///   WBNB_ADDRESS       鈥?WBNB token
contract SetupV30Templates is Script {
    // Contract references
    PolicyGuardV4 guardV4;
    AgentNFA nfa;
    ListingManager lm;
    TokenWhitelistPolicy tokenWL;
    SpendingLimitPolicy spendingLimit;
    CooldownPolicy cooldownPolicy;
    ReceiverGuardPolicy receiverGuard;
    DexWhitelistPolicy dexWL;

    // BSC Testnet tokens & DEX
    address router;
    address usdt;
    address wbnb;

    // Template keys
    bytes32 constant TEMPLATE_LLM_BASE = keccak256("llm_base_v3");
    bytes32 constant TEMPLATE_LLM = keccak256("llm_trader_v3");

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Load contract addresses
        guardV4 = PolicyGuardV4(vm.envAddress("POLICY_GUARD_V4"));
        nfa = AgentNFA(vm.envAddress("AGENT_NFA"));
        lm = ListingManager(vm.envAddress("LISTING_MANAGER"));
        tokenWL = TokenWhitelistPolicy(vm.envAddress("TOKEN_WL"));
        spendingLimit = SpendingLimitPolicy(vm.envAddress("SPENDING_LIMIT"));
        cooldownPolicy = CooldownPolicy(vm.envAddress("COOLDOWN"));
        receiverGuard = ReceiverGuardPolicy(vm.envAddress("RECEIVER_GUARD"));
        dexWL = DexWhitelistPolicy(vm.envAddress("DEX_WL"));

        router = vm.envAddress("ROUTER_ADDRESS");
        usdt = vm.envAddress("USDT_ADDRESS");
        wbnb = vm.envAddress("WBNB_ADDRESS");

        vm.startBroadcast(deployerKey);

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 1: Create LLM Base Template Agent
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        uint256 llmBaseTokenId = _mintTemplateAgent(
            deployer,
            keccak256("llm_trader"),
            "LLM Base Strategy Agent",
            "AI-powered autonomous trading with conservative risk profile"
        );
        console.log("LLM Base Template Agent minted, tokenId:", llmBaseTokenId);

        // Register as template
        nfa.registerTemplate(llmBaseTokenId, TEMPLATE_LLM_BASE);
        console.log("LLM Base template registered with key:");
        console.logBytes32(TEMPLATE_LLM_BASE);

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 2: Attach policies to LLM Base template
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        guardV4.addTemplatePolicy(TEMPLATE_LLM_BASE, address(receiverGuard));
        guardV4.addTemplatePolicy(TEMPLATE_LLM_BASE, address(spendingLimit));
        guardV4.addTemplatePolicy(TEMPLATE_LLM_BASE, address(tokenWL));
        guardV4.addTemplatePolicy(TEMPLATE_LLM_BASE, address(dexWL));
        guardV4.addTemplatePolicy(TEMPLATE_LLM_BASE, address(cooldownPolicy));
        console.log("LLM Base template: 5 policies attached");

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 3: Set spending ceiling for LLM Base template
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        // LLM Base: conservative limits 鈥?10 BNB per tx, 50 BNB daily, 500 bps max slippage
        spendingLimit.setTemplateCeiling(TEMPLATE_LLM_BASE, 10 ether, 50 ether, 500);
        console.log("LLM Base ceiling: 10 BNB/tx, 50 BNB/day, 5% slippage");

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 4: Configure token + DEX whitelists on template
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        // Token whitelist: USDT, WBNB
        tokenWL.addToken(llmBaseTokenId, usdt);
        tokenWL.addToken(llmBaseTokenId, wbnb);
        console.log("LLM Base token whitelist: USDT, WBNB");

        // DEX whitelist: PancakeSwap Router
        dexWL.addDex(llmBaseTokenId, router);
        console.log("LLM Base DEX whitelist: PancakeSwap Router");

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 5: Set cooldown (minimum 60s between executions)
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        cooldownPolicy.setCooldown(llmBaseTokenId, 60);
        console.log("LLM Base cooldown: 60 seconds");

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 6: Bind template instance + set initial limits
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        // Bind the template token to its own template key
        // (so setLimits can look up the ceiling via instanceTemplate mapping)
        vm.stopBroadcast();
        vm.startBroadcast(deployerKey);

        // Set initial limits at ceiling for template
        // M-2: ceiling is set, binding done by guard during mint.
        // For the template token itself, we bind manually.
        // Note: bindInstanceTemplate is guarded by `onlyGuard`, so we prank in tests only.
        // On-chain, the guard binds during createInstance flow.

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 7: Create template listing on marketplace
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        nfa.approve(address(lm), llmBaseTokenId);
        bytes32 listingId = lm.createTemplateListing(
            address(nfa),
            llmBaseTokenId,
            uint96(0.005 ether), // 0.005 BNB per day
            1 // Min 1 day
        );
        console.log("LLM Base template listed, listingId:");
        console.logBytes32(listingId);

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 8: Create LLM Trader Template Agent
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        uint256 llmTokenId = _mintTemplateAgent(
            deployer,
            keccak256("llm_trader"),
            "LLM Trader Agent",
            "AI-powered trading agent using LLM for market analysis and execution"
        );
        console.log("LLM Trader Template minted, tokenId:", llmTokenId);

        // Register as template
        nfa.registerTemplate(llmTokenId, TEMPLATE_LLM);
        console.log("LLM Trader template registered with key:");
        console.logBytes32(TEMPLATE_LLM);

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 9: Attach policies to LLM Trader template
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        guardV4.addTemplatePolicy(TEMPLATE_LLM, address(receiverGuard));
        guardV4.addTemplatePolicy(TEMPLATE_LLM, address(spendingLimit));
        guardV4.addTemplatePolicy(TEMPLATE_LLM, address(tokenWL));
        guardV4.addTemplatePolicy(TEMPLATE_LLM, address(dexWL));
        guardV4.addTemplatePolicy(TEMPLATE_LLM, address(cooldownPolicy));
        console.log("LLM Trader template: 5 policies attached");

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 10: Set spending ceiling for LLM Trader
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        // LLM Trader: higher limits 鈥?20 BNB per tx, 100 BNB daily, 300 bps max slippage
        spendingLimit.setTemplateCeiling(
            TEMPLATE_LLM,
            20 ether,
            100 ether,
            300
        );
        console.log("LLM ceiling: 20 BNB/tx, 100 BNB/day, 3% slippage");

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 11: Configure token + DEX whitelists for LLM Trader
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        tokenWL.addToken(llmTokenId, usdt);
        tokenWL.addToken(llmTokenId, wbnb);
        console.log("LLM token whitelist: USDT, WBNB");

        dexWL.addDex(llmTokenId, router);
        console.log("LLM DEX whitelist: PancakeSwap Router");

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 12: Set cooldown for LLM Trader (30s 鈥?faster than LLM Base)
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        cooldownPolicy.setCooldown(llmTokenId, 30);
        console.log("LLM cooldown: 30 seconds");

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  STEP 13: Create LLM Trader template listing
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        nfa.approve(address(lm), llmTokenId);
        bytes32 llmListingId = lm.createTemplateListing(
            address(nfa),
            llmTokenId,
            uint96(0.01 ether), // 0.01 BNB per day (premium)
            1 // Min 1 day
        );
        console.log("LLM Trader template listed, listingId:");
        console.logBytes32(llmListingId);

        vm.stopBroadcast();

        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
        //  SUMMARY
        // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

        console.log("");
        console.log("========== V3.1 TEMPLATE SETUP COMPLETE ==========");
        console.log("");
        console.log("--- LLM Base Template ---");
        console.log("  tokenId      :", llmBaseTokenId);
        console.log(
            "  Policies     : 5 (Receiver, Spending, Token, DEX, Cooldown)"
        );
        console.log("  Ceiling      : 10 BNB/tx, 50 BNB/day, 500 bps");
        console.log("  Cooldown     : 60s");
        console.log("  Listing price: 0.005 BNB/day");
        console.log("");
        console.log("--- LLM Trader Template ---");
        console.log("  tokenId      :", llmTokenId);
        console.log(
            "  Policies     : 5 (Receiver, Spending, Token, DEX, Cooldown)"
        );
        console.log("  Ceiling      : 20 BNB/tx, 100 BNB/day, 300 bps");
        console.log("  Cooldown     : 30s");
        console.log("  Listing price: 0.01 BNB/day");
        console.log("===================================================");
    }

    /// @dev Mint a template agent using V3.1 ABI (5-param mintAgent with agentType)
    function _mintTemplateAgent(
        address owner,
        bytes32 _agentType,
        string memory name,
        string memory description
    ) internal returns (uint256) {
        IBAP578.AgentMetadata memory meta = IBAP578.AgentMetadata({
            persona: string.concat(
                '{"name":"',
                name,
                '","description":"',
                description,
                '"}'
            ),
            experience: "Template",
            voiceHash: "",
            animationURI: "",
            vaultURI: "",
            vaultHash: bytes32(0)
        });

        uint256 tokenId = nfa.mintAgent(
            owner,
            bytes32(uint256(1)), // policyId
            _agentType, // V3.1: agent type hash
            string.concat(
                "https://api.shll.run/api/metadata/",
                vm.toString(nfa.nextTokenId())
            ),
            meta
        );
        return tokenId;
    }
}



