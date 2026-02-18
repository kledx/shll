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

/// @title DeployV30Full — Full V3.0 Deployment (all contracts from scratch)
/// @notice Deploys AgentNFA V3 + PolicyGuardV4 + 5 Plugins + ListingManager + DCA Template
/// @dev Usage:
///   forge script script/DeployV30Full.s.sol --rpc-url $RPC_URL --broadcast --gas-price 5000000000 -vvv
///
/// Required env vars:
///   PRIVATE_KEY        — deployer private key
///   ROUTER_ADDRESS     — PancakeSwap V2 Router
///   USDT_ADDRESS       — USDT token
///   WBNB_ADDRESS       — WBNB token
contract DeployV30Full is Script {
    // Template keys
    bytes32 constant TEMPLATE_DCA = keccak256("dca_v3");

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address router = vm.envAddress("ROUTER_ADDRESS");
        address usdt = vm.envAddress("USDT_ADDRESS");
        address wbnb = vm.envAddress("WBNB_ADDRESS");

        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(deployerKey);

        // ═══════════════════════════════════════════════════════
        //  PHASE 1: Deploy PolicyGuardV4 + Policy Plugins
        // ═══════════════════════════════════════════════════════

        PolicyGuardV4 guardV4 = new PolicyGuardV4();
        console.log("1. PolicyGuardV4       :", address(guardV4));

        // Deploy with a temporary NFA address (will set after NFA deploy)
        // Plugins need guard + nfa, but NFA needs guard in constructor.
        // Solution: deploy plugins with guard address, set NFA later.

        // We deploy NFA first (needs guard), then plugins (need guard + nfa)
        // Actually NFA constructor takes _policyGuard.

        // ═══════════════════════════════════════════════════════
        //  PHASE 2: Deploy AgentNFA V3.0 (with guard reference)
        // ═══════════════════════════════════════════════════════

        AgentNFA nfa = new AgentNFA(address(guardV4));
        console.log("2. AgentNFA (V3.0)     :", address(nfa));

        // Wire guard → NFA
        guardV4.setAgentNFA(address(nfa));

        // ═══════════════════════════════════════════════════════
        //  PHASE 3: Deploy ListingManager
        // ═══════════════════════════════════════════════════════

        ListingManager lm = new ListingManager();
        console.log("3. ListingManager      :", address(lm));

        // Wire NFA → LM
        nfa.setListingManager(address(lm));
        // Wire guard → LM (so guard.bindInstance is callable by LM)
        guardV4.setListingManager(address(lm));

        // ═══════════════════════════════════════════════════════
        //  PHASE 4: Deploy Policy Plugins
        // ═══════════════════════════════════════════════════════

        TokenWhitelistPolicy tokenWL = new TokenWhitelistPolicy(
            address(guardV4),
            address(nfa)
        );
        console.log("4a. TokenWhitelistPolicy:", address(tokenWL));

        SpendingLimitPolicy spendingLimit = new SpendingLimitPolicy(
            address(guardV4),
            address(nfa)
        );
        console.log("4b. SpendingLimitPolicy :", address(spendingLimit));

        CooldownPolicy cooldown = new CooldownPolicy(
            address(guardV4),
            address(nfa)
        );
        console.log("4c. CooldownPolicy      :", address(cooldown));

        ReceiverGuardPolicy receiverGuard = new ReceiverGuardPolicy(
            address(nfa)
        );
        console.log("4d. ReceiverGuardPolicy :", address(receiverGuard));

        DexWhitelistPolicy dexWL = new DexWhitelistPolicy(
            address(guardV4),
            address(nfa)
        );
        console.log("4e. DexWhitelistPolicy  :", address(dexWL));

        // ═══════════════════════════════════════════════════════
        //  PHASE 5: Approve all policy contracts
        // ═══════════════════════════════════════════════════════

        guardV4.approvePolicyContract(address(tokenWL));
        guardV4.approvePolicyContract(address(spendingLimit));
        guardV4.approvePolicyContract(address(cooldown));
        guardV4.approvePolicyContract(address(receiverGuard));
        guardV4.approvePolicyContract(address(dexWL));
        console.log("5. All 5 policies approved");

        // ═══════════════════════════════════════════════════════
        //  PHASE 6: Mint DCA Template Agent (V3.0 mintAgent with agentType)
        // ═══════════════════════════════════════════════════════

        IBAP578.AgentMetadata memory meta = IBAP578.AgentMetadata({
            persona: '{"name":"DCA Strategy Agent","description":"Automated dollar-cost averaging into selected tokens"}',
            experience: "Template",
            voiceHash: "",
            animationURI: "",
            vaultURI: "",
            vaultHash: bytes32(0)
        });

        // V3.0: mintAgent with 5 params including agentType
        uint256 dcaTokenId = nfa.mintAgent(
            deployer,
            bytes32(uint256(1)), // policyId (legacy compat)
            nfa.TYPE_DCA(), // V3.0 agent type
            "https://api.shll.run/api/metadata/0",
            meta
        );
        console.log("6. DCA Template Agent minted, tokenId:", dcaTokenId);

        // Register as template
        nfa.registerTemplate(dcaTokenId, TEMPLATE_DCA, "dca-v3");
        console.log("   Template registered");

        // ═══════════════════════════════════════════════════════
        //  PHASE 7: Attach policies to DCA template
        // ═══════════════════════════════════════════════════════

        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(receiverGuard));
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(spendingLimit));
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(tokenWL));
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(dexWL));
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(cooldown));
        console.log("7. DCA template: 5 policies attached");

        // ═══════════════════════════════════════════════════════
        //  PHASE 8: Configure template ceilings + whitelists
        // ═══════════════════════════════════════════════════════

        // Spending ceiling: 10 BNB/tx, 50 BNB/day, 500 bps slippage
        spendingLimit.setTemplateCeiling(TEMPLATE_DCA, 10 ether, 50 ether, 500);

        // Token whitelist: USDT, WBNB
        tokenWL.addToken(dcaTokenId, usdt);
        tokenWL.addToken(dcaTokenId, wbnb);

        // DEX whitelist: PancakeSwap Router
        dexWL.addDex(dcaTokenId, router);

        // Cooldown: 60 seconds
        cooldown.setCooldown(dcaTokenId, 60);
        console.log("8. Ceilings + whitelists configured");

        // ═══════════════════════════════════════════════════════
        //  PHASE 9: List DCA template on marketplace
        // ═══════════════════════════════════════════════════════

        nfa.approve(address(lm), dcaTokenId);
        bytes32 listingId = lm.createTemplateListing(
            address(nfa),
            dcaTokenId,
            uint96(0.005 ether), // 0.005 BNB per day
            1 // Min 1 day
        );
        console.log("9. DCA template listed on marketplace");

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════
        //  SUMMARY
        // ═══════════════════════════════════════════════════════

        console.log("");
        console.log("============ V3.0 FULL DEPLOYMENT COMPLETE ============");
        console.log("");
        console.log("--- Core Contracts ---");
        console.log("AgentNFA            :", address(nfa));
        console.log("PolicyGuardV4       :", address(guardV4));
        console.log("ListingManager      :", address(lm));
        console.log("");
        console.log("--- Policy Plugins ---");
        console.log("TokenWhitelistPolicy:", address(tokenWL));
        console.log("SpendingLimitPolicy :", address(spendingLimit));
        console.log("CooldownPolicy      :", address(cooldown));
        console.log("ReceiverGuardPolicy :", address(receiverGuard));
        console.log("DexWhitelistPolicy  :", address(dexWL));
        console.log("");
        console.log("--- DCA Template ---");
        console.log("DCA tokenId         :", dcaTokenId);
        console.log("DCA listingId       :");
        console.logBytes32(listingId);
        console.log("DCA template key    :");
        console.logBytes32(TEMPLATE_DCA);
        console.log("");
        console.log("========================================================");
        console.log("");
        console.log("--- Copy to .env ---");
        console.log(string.concat("AGENT_NFA=", vm.toString(address(nfa))));
        console.log(
            string.concat("POLICY_GUARD_V4=", vm.toString(address(guardV4)))
        );
        console.log(
            string.concat("LISTING_MANAGER=", vm.toString(address(lm)))
        );
        console.log(string.concat("TOKEN_WL=", vm.toString(address(tokenWL))));
        console.log(
            string.concat(
                "SPENDING_LIMIT=",
                vm.toString(address(spendingLimit))
            )
        );
        console.log(string.concat("COOLDOWN=", vm.toString(address(cooldown))));
        console.log(
            string.concat(
                "RECEIVER_GUARD=",
                vm.toString(address(receiverGuard))
            )
        );
        console.log(string.concat("DEX_WL=", vm.toString(address(dexWL))));
    }
}
