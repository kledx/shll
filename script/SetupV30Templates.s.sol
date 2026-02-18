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

/// @title SetupV30Templates — Configure V3.0 templates, ceilings, and whitelists
/// @notice Run AFTER DeployV30.s.sol. Creates template agents with full policy config.
/// @dev Usage:
///   forge script script/SetupV30Templates.s.sol --rpc-url $RPC_URL --broadcast --gas-price 5000000000 -vvv
///
/// Required env vars (all from DeployV30 output):
///   PRIVATE_KEY        — deployer private key
///   AGENT_NFA          — AgentNFA contract
///   POLICY_GUARD_V4    — PolicyGuardV4 contract
///   TOKEN_WL           — TokenWhitelistPolicy contract
///   SPENDING_LIMIT     — SpendingLimitPolicy contract
///   COOLDOWN           — CooldownPolicy contract
///   RECEIVER_GUARD     — ReceiverGuardPolicy contract
///   DEX_WL             — DexWhitelistPolicy contract
///   LISTING_MANAGER    — ListingManager contract
///   ROUTER_ADDRESS     — PancakeSwap V2 Router
///   USDT_ADDRESS       — USDT token
///   WBNB_ADDRESS       — WBNB token
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
    bytes32 constant TEMPLATE_DCA = keccak256("dca_v3");
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

        // ═══════════════════════════════════════════════════════
        //  STEP 1: Create DCA Template Agent
        // ═══════════════════════════════════════════════════════

        uint256 dcaTokenId = _mintTemplateAgent(
            deployer,
            keccak256("dca"),
            "DCA Strategy Agent",
            "Automated dollar-cost averaging into selected tokens"
        );
        console.log("DCA Template Agent minted, tokenId:", dcaTokenId);

        // Register as template
        nfa.registerTemplate(dcaTokenId, TEMPLATE_DCA, "dca-v3");
        console.log("DCA template registered with key:");
        console.logBytes32(TEMPLATE_DCA);

        // ═══════════════════════════════════════════════════════
        //  STEP 2: Attach policies to DCA template
        // ═══════════════════════════════════════════════════════

        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(receiverGuard));
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(spendingLimit));
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(tokenWL));
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(dexWL));
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(cooldownPolicy));
        console.log("DCA template: 5 policies attached");

        // ═══════════════════════════════════════════════════════
        //  STEP 3: Set spending ceiling for DCA template
        // ═══════════════════════════════════════════════════════

        // DCA: conservative limits — 10 BNB per tx, 50 BNB daily, 500 bps max slippage
        spendingLimit.setTemplateCeiling(TEMPLATE_DCA, 10 ether, 50 ether, 500);
        console.log("DCA ceiling: 10 BNB/tx, 50 BNB/day, 5% slippage");

        // ═══════════════════════════════════════════════════════
        //  STEP 4: Configure token + DEX whitelists on template
        // ═══════════════════════════════════════════════════════

        // Token whitelist: USDT, WBNB
        tokenWL.addToken(dcaTokenId, usdt);
        tokenWL.addToken(dcaTokenId, wbnb);
        console.log("DCA token whitelist: USDT, WBNB");

        // DEX whitelist: PancakeSwap Router
        dexWL.addDex(dcaTokenId, router);
        console.log("DCA DEX whitelist: PancakeSwap Router");

        // ═══════════════════════════════════════════════════════
        //  STEP 5: Set cooldown (minimum 60s between executions)
        // ═══════════════════════════════════════════════════════

        cooldownPolicy.setCooldown(dcaTokenId, 60);
        console.log("DCA cooldown: 60 seconds");

        // ═══════════════════════════════════════════════════════
        //  STEP 6: Bind template instance + set initial limits
        // ═══════════════════════════════════════════════════════

        // Bind the template token to its own template key
        // (so setLimits can look up the ceiling via instanceTemplate mapping)
        vm.stopBroadcast();
        vm.startBroadcast(deployerKey);

        // Set initial limits at ceiling for template
        // M-2: ceiling is set, binding done by guard during mint.
        // For the template token itself, we bind manually.
        // Note: bindInstanceTemplate is guarded by `onlyGuard`, so we prank in tests only.
        // On-chain, the guard binds during createInstance flow.

        // ═══════════════════════════════════════════════════════
        //  STEP 7: Create template listing on marketplace
        // ═══════════════════════════════════════════════════════

        nfa.approve(address(lm), dcaTokenId);
        bytes32 listingId = lm.createTemplateListing(
            address(nfa),
            dcaTokenId,
            uint96(0.005 ether), // 0.005 BNB per day
            1 // Min 1 day
        );
        console.log("DCA template listed, listingId:");
        console.logBytes32(listingId);

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════
        //  SUMMARY
        // ═══════════════════════════════════════════════════════

        console.log("");
        console.log("========== V3.0 TEMPLATE SETUP COMPLETE ==========");
        console.log("DCA Template tokenId :", dcaTokenId);
        console.log("DCA Template key     :");
        console.logBytes32(TEMPLATE_DCA);
        console.log(
            "Policies attached    : 5 (Receiver, Spending, Token, DEX, Cooldown)"
        );
        console.log("Ceiling              : 10 BNB/tx, 50 BNB/day, 500 bps");
        console.log("Token whitelist      : USDT, WBNB");
        console.log("DEX whitelist        : PancakeSwap Router");
        console.log("Cooldown             : 60s");
        console.log("Listing price        : 0.005 BNB/day");
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
