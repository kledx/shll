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

/// @title DeployV30Full — Production-grade V3.0 Full Deployment
/// @notice Deploys 8 contracts + DCA template in 2 phases:
///   Phase 1: Deploy all contracts + wire + approve (8 CREATE + 8 CALL = 16 txns)
///   Phase 2: Template setup — mint, register, policies, whitelist, list (14 txns)
///   Total: 30 transactions, 9 contracts on-chain (including auto-created AgentAccount)
///
/// @dev Usage (MUST use --gas-price for BSC):
///   forge script script/DeployV30Full.s.sol \
///     --rpc-url $RPC_URL --broadcast --gas-price 5000000000 -vvv
///
///   Mainnet (BSC):
///   forge script script/DeployV30Full.s.sol \
///     --rpc-url $BSC_MAINNET_RPC --broadcast --gas-price 3000000000 \
///     --verify --etherscan-api-key $BSC_API_KEY -vvv
///
/// Required .env:
///   PRIVATE_KEY        — deployer private key
///   ROUTER_ADDRESS     — PancakeSwap V2 Router
///   USDT_ADDRESS       — USDT token address
///   WBNB_ADDRESS       — WBNB token address
contract DeployV30Full is Script {
    bytes32 constant TEMPLATE_DCA = keccak256("dca_v3");

    // Deployed contract references (set during Phase 1)
    PolicyGuardV4 guardV4;
    AgentNFA nfa;
    ListingManager lm;
    TokenWhitelistPolicy tokenWL;
    SpendingLimitPolicy spendingLimit;
    CooldownPolicy cooldown;
    ReceiverGuardPolicy receiverGuard;
    DexWhitelistPolicy dexWL;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address router = vm.envAddress("ROUTER_ADDRESS");
        address usdt = vm.envAddress("USDT_ADDRESS");
        address wbnb = vm.envAddress("WBNB_ADDRESS");

        console.log("========================================================");
        console.log("  SHLL V3.0 Full Deployment");
        console.log("========================================================");
        console.log("Deployer     :", deployer);
        console.log("Start Block  :", block.number);
        console.log("Timestamp    :", block.timestamp);
        console.log("Chain ID     :", block.chainid);
        console.log("Router       :", router);
        console.log("USDT         :", usdt);
        console.log("WBNB         :", wbnb);
        console.log("========================================================");
        console.log("");

        // ══════════════════════════════════════════════════════════
        //  PHASE 1: Deploy contracts + wire + approve
        //  16 transactions: 8 CREATE + 8 CALL
        // ══════════════════════════════════════════════════════════

        console.log("[PHASE 1] Deploying 8 contracts + wiring...");
        console.log("");

        vm.startBroadcast(deployerKey);

        _phase1_deploy(deployer);

        vm.stopBroadcast();

        console.log("");
        console.log("[PHASE 1] Complete. 8 contracts deployed + wired.");
        console.log("Block after Phase 1:", block.number);
        console.log("");

        // ══════════════════════════════════════════════════════════
        //  PHASE 2: Template setup
        //  14 transactions: mintAgent, registerTemplate, 5x addTemplatePolicy,
        //  setTemplateCeiling, 2x addToken, addDex, setCooldown, approve, createTemplateListing
        // ══════════════════════════════════════════════════════════

        console.log("[PHASE 2] Setting up DCA template...");
        console.log("");

        vm.startBroadcast(deployerKey);

        _phase2_template(deployer, router, usdt, wbnb);

        vm.stopBroadcast();

        // ══════════════════════════════════════════════════════════
        //  SUMMARY
        // ══════════════════════════════════════════════════════════

        console.log("");
        console.log("========================================================");
        console.log("  V3.0 FULL DEPLOYMENT COMPLETE");
        console.log("========================================================");
        console.log("");
        console.log("Deploy Block :", block.number);
        console.log("");
        console.log("--- Core Contracts (3) ---");
        console.log("AgentNFA            :", address(nfa));
        console.log("PolicyGuardV4       :", address(guardV4));
        console.log("ListingManager      :", address(lm));
        console.log("");
        console.log("--- Policy Plugins (5) ---");
        console.log("TokenWhitelistPolicy:", address(tokenWL));
        console.log("SpendingLimitPolicy :", address(spendingLimit));
        console.log("CooldownPolicy      :", address(cooldown));
        console.log("ReceiverGuardPolicy :", address(receiverGuard));
        console.log("DexWhitelistPolicy  :", address(dexWL));
        console.log("");
        console.log("--- DCA Template ---");
        console.log("Template tokenId    : 0");
        console.log("Template key        :");
        console.logBytes32(TEMPLATE_DCA);
        console.log("Ceiling             : 10 BNB/tx, 50 BNB/day, 500 bps");
        console.log("Token whitelist     : USDT, WBNB");
        console.log("DEX whitelist       : Router");
        console.log("Cooldown            : 60s");
        console.log("Listing price       : 0.005 BNB/day");
        console.log("");
        console.log("========================================================");
        console.log("  ENV VARIABLES (copy to .env)");
        console.log("========================================================");
        console.log("");
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
        console.log("");
        console.log("--- Indexer Env ---");
        console.log(
            string.concat("AGENT_NFA_ADDRESS_97=", vm.toString(address(nfa)))
        );
        console.log(
            string.concat(
                "LISTING_MANAGER_ADDRESS_97=",
                vm.toString(address(lm))
            )
        );
        console.log(
            string.concat(
                "POLICY_GUARD_V4_ADDRESS_97=",
                vm.toString(address(guardV4))
            )
        );
        console.log(
            string.concat("CONTRACT_START_BLOCK_97=", vm.toString(block.number))
        );
        console.log("");
        console.log("--- Frontend Env ---");
        console.log(
            string.concat("NEXT_PUBLIC_AGENT_NFA=", vm.toString(address(nfa)))
        );
        console.log(
            string.concat(
                "NEXT_PUBLIC_LISTING_MANAGER=",
                vm.toString(address(lm))
            )
        );
        console.log(
            string.concat(
                "NEXT_PUBLIC_POLICY_GUARD_V3=",
                vm.toString(address(guardV4))
            )
        );
        console.log(
            string.concat(
                "NEXT_PUBLIC_DEPLOY_BLOCK=",
                vm.toString(block.number)
            )
        );
        console.log("");
        console.log("========================================================");
        console.log("  Total: 8 deployed + 1 auto-created = 9 contracts");
        console.log("  Total: 30 transactions");
        console.log("========================================================");
    }

    // ══════════════════════════════════════════════════════════════
    //  Phase 1: Deploy + Wire + Approve
    // ══════════════════════════════════════════════════════════════

    function _phase1_deploy(address /*deployer*/) internal {
        // --- Step 1: Deploy PolicyGuardV4 ---
        guardV4 = new PolicyGuardV4();
        console.log("  [1/8] PolicyGuardV4       :", address(guardV4));

        // --- Step 2: Deploy AgentNFA (needs guard in constructor) ---
        nfa = new AgentNFA(address(guardV4));
        console.log("  [2/8] AgentNFA            :", address(nfa));

        // --- Step 3: Deploy ListingManager ---
        lm = new ListingManager();
        console.log("  [3/8] ListingManager      :", address(lm));

        // --- Step 4-8: Deploy Policy Plugins ---
        tokenWL = new TokenWhitelistPolicy(address(guardV4), address(nfa));
        console.log("  [4/8] TokenWhitelistPolicy:", address(tokenWL));

        spendingLimit = new SpendingLimitPolicy(address(guardV4), address(nfa));
        console.log("  [5/8] SpendingLimitPolicy :", address(spendingLimit));

        cooldown = new CooldownPolicy(address(guardV4), address(nfa));
        console.log("  [6/8] CooldownPolicy      :", address(cooldown));

        receiverGuard = new ReceiverGuardPolicy(address(nfa));
        console.log("  [7/8] ReceiverGuardPolicy :", address(receiverGuard));

        dexWL = new DexWhitelistPolicy(address(guardV4), address(nfa));
        console.log("  [8/8] DexWhitelistPolicy  :", address(dexWL));

        console.log("");
        console.log("  Wiring contracts...");

        // --- Wire: Guard <-> NFA ---
        guardV4.setAgentNFA(address(nfa));
        console.log("  [wire] GuardV4.setAgentNFA  -> NFA");

        // --- Wire: NFA <-> ListingManager ---
        nfa.setListingManager(address(lm));
        console.log("  [wire] NFA.setListingManager -> LM");

        // --- Wire: Guard <-> ListingManager ---
        guardV4.setListingManager(address(lm));
        console.log("  [wire] GuardV4.setListingManager -> LM");

        console.log("");
        console.log("  Approving policies...");

        // --- Approve all 5 policy contracts ---
        guardV4.approvePolicyContract(address(tokenWL));
        console.log("  [approve] TokenWhitelistPolicy");

        guardV4.approvePolicyContract(address(spendingLimit));
        console.log("  [approve] SpendingLimitPolicy");

        guardV4.approvePolicyContract(address(cooldown));
        console.log("  [approve] CooldownPolicy");

        guardV4.approvePolicyContract(address(receiverGuard));
        console.log("  [approve] ReceiverGuardPolicy");

        guardV4.approvePolicyContract(address(dexWL));
        console.log("  [approve] DexWhitelistPolicy");
    }

    // ══════════════════════════════════════════════════════════════
    //  Phase 2: Template Setup
    // ══════════════════════════════════════════════════════════════

    function _phase2_template(
        address deployer,
        address router,
        address usdt,
        address wbnb
    ) internal {
        // --- Step 1: Mint DCA Template Agent ---
        IBAP578.AgentMetadata memory meta = IBAP578.AgentMetadata({
            persona: '{"name":"DCA Strategy Agent","description":"Automated dollar-cost averaging into selected tokens"}',
            experience: "Template",
            voiceHash: "",
            animationURI: "",
            vaultURI: "",
            vaultHash: bytes32(0)
        });

        uint256 dcaTokenId = nfa.mintAgent(
            deployer,
            bytes32(uint256(1)), // legacy policyId
            nfa.TYPE_DCA(), // V3.0 agentType
            "https://api.shll.run/api/metadata/0",
            meta
        );
        console.log("  [mint]     DCA Template tokenId:", dcaTokenId);

        // --- Step 2: Register as template ---
        nfa.registerTemplate(dcaTokenId, TEMPLATE_DCA, "dca-v3");
        console.log("  [register] Template key dca_v3");

        // --- Step 3: Attach 5 policies to template ---
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(receiverGuard));
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(spendingLimit));
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(tokenWL));
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(dexWL));
        guardV4.addTemplatePolicy(TEMPLATE_DCA, address(cooldown));
        console.log("  [policies] 5 policies attached to DCA template");

        // --- Step 4: Configure ceilings ---
        // 10 BNB per tx, 50 BNB per day, 500 bps (5%) max slippage
        spendingLimit.setTemplateCeiling(TEMPLATE_DCA, 10 ether, 50 ether, 500);
        console.log("  [ceiling]  10 BNB/tx, 50 BNB/day, 5% slippage");

        // --- Step 5: Token whitelist ---
        tokenWL.addToken(dcaTokenId, usdt);
        tokenWL.addToken(dcaTokenId, wbnb);
        console.log("  [whitelist] Tokens: USDT, WBNB");

        // --- Step 6: DEX whitelist ---
        dexWL.addDex(dcaTokenId, router);
        console.log("  [whitelist] DEX: PancakeSwap Router");

        // --- Step 7: Cooldown ---
        cooldown.setCooldown(dcaTokenId, 60);
        console.log("  [cooldown] 60 seconds");

        // --- Step 8: Approve + List on marketplace ---
        nfa.approve(address(lm), dcaTokenId);
        bytes32 listingId = lm.createTemplateListing(
            address(nfa),
            dcaTokenId,
            uint96(0.005 ether), // 0.005 BNB per day
            1 // min 1 day
        );
        console.log("  [listing]  Listed at 0.005 BNB/day");
        console.log("  [listing]  Listing ID:");
        console.logBytes32(listingId);
    }
}
