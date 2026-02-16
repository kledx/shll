// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyGuardV3} from "../src/PolicyGuardV3.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";

/**
 * @title DeployV15
 * @notice Full deployment: AgentNFA + ListingManager + PolicyGuardV3.
 *         All contracts are freshly deployed and wired together.
 *
 * Usage:
 *   forge script script/DeployV15.s.sol --rpc-url $RPC_URL --broadcast --gas-price 5000000000
 *
 * Required env vars:
 *   PRIVATE_KEY     — deployer private key
 *   ROUTER_ADDRESS  — PancakeSwap V2 router
 *   USDT_ADDRESS    — USDT token
 *   WBNB_ADDRESS    — WBNB token
 */
contract DeployV15 is Script {
    PolicyGuardV3 guard;
    AgentNFA nfa;
    ListingManager listing;

    address routerAddr;
    address usdtAddr;
    address wbnbAddr;

    uint32 constant policyId = 1;
    uint16 constant version = 1;
    uint32 constant tokenGroupId = 100;
    uint32 constant dexGroupId = 200;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        routerAddr = vm.envAddress("ROUTER_ADDRESS");
        usdtAddr = vm.envAddress("USDT_ADDRESS");
        wbnbAddr = vm.envAddress("WBNB_ADDRESS");

        vm.startBroadcast(deployerKey);

        // ═══════════════════════════════════════════════════════════
        //               STEP 1: Deploy all contracts
        // ═══════════════════════════════════════════════════════════

        PolicyGuardV3 guard = new PolicyGuardV3();
        console.log("PolicyGuardV3 deployed:", address(guard));

        AgentNFA nfa = new AgentNFA(address(guard));
        console.log("AgentNFA deployed:", address(nfa));

        listing = new ListingManager();
        console.log("ListingManager deployed:", address(listing));
    }

    function wireContracts() internal {
        // ═══════════════════════════════════════════════════════════
        //               STEP 2: Wire contracts
        // ═══════════════════════════════════════════════════════════

        // AgentNFA -> ListingManager
        nfa.setListingManager(address(listing));
        console.log("AgentNFA -> ListingManager wired");

        // PolicyGuardV3 access control
        guard.setAllowedCaller(address(nfa));
        guard.setMinter(address(listing));
        console.log("PolicyGuardV3 access: allowedCaller=NFA, minter=Listing");

        // ListingManager -> PolicyGuardV3 (as instanceConfig)
        listing.setInstanceConfig(address(guard));
        console.log("ListingManager -> PolicyGuardV3 wired");
    }

    function setupPolicy() internal {
        // ═══════════════════════════════════════════════════════════
        //               STEP 3: Create default policy (id=1, v=1)
        // ═══════════════════════════════════════════════════════════

        uint32[] memory tokenGroups = new uint32[](1);
        tokenGroups[0] = tokenGroupId;
        uint32[] memory dexGroups = new uint32[](1);
        dexGroups[0] = dexGroupId;

        PolicyGuardV3.ParamSchema memory schema = PolicyGuardV3.ParamSchema({
            maxSlippageBps: 1000, // 10%
            maxTradeLimit: 100 ether,
            maxDailyLimit: 200 ether,
            allowedTokenGroups: tokenGroups,
            allowedDexGroups: dexGroups,
            receiverMustBeVault: true,
            forbidInfiniteApprove: true,
            allowExplorerMode: true,
            explorerMaxTradeLimit: 10 ether,
            explorerMaxDailyLimit: 25 ether,
            allowParamsUpdate: true
        });
        guard.createPolicy(policyId, version, schema, 7); // SWAP|APPROVE|SPEND_LIMIT
        console.log("Policy created (id=1, v=1, modules=7)");
    }

    function configureActionRules() internal {
        // ═══════════════════════════════════════════════════════════
        //               STEP 4: Action rules
        // ═══════════════════════════════════════════════════════════

        // Swap rules: moduleMask=5 (SWAP|SPEND_LIMIT)
        guard.setActionRule(
            policyId,
            version,
            routerAddr,
            PolicyKeys.SWAP_EXACT_TOKENS,
            5
        );
        guard.setActionRule(
            policyId,
            version,
            routerAddr,
            PolicyKeys.SWAP_EXACT_ETH,
            5
        );
        // Approve rules: moduleMask=2 (APPROVE only)
        guard.setActionRule(policyId, version, usdtAddr, PolicyKeys.APPROVE, 2);
        guard.setActionRule(policyId, version, wbnbAddr, PolicyKeys.APPROVE, 2);
        console.log("Action rules set");
    }

    function configureGroups() internal {
        // ═══════════════════════════════════════════════════════════
        //               STEP 5: Group whitelist
        // ═══════════════════════════════════════════════════════════

        guard.setGroupMember(tokenGroupId, usdtAddr, true);
        guard.setGroupMember(tokenGroupId, wbnbAddr, true);
        guard.setGroupMember(dexGroupId, routerAddr, true);
        console.log("Groups set (USDT, WBNB, Router)");
    }

    function logSummary() internal view {
        // ═══════════════════════════════════════════════════════════
        //               SUMMARY
        // ═══════════════════════════════════════════════════════════

        console.log("");
        console.log("========== V1.5 FULL DEPLOYMENT COMPLETE ==========");
        console.log("PolicyGuardV3  :", address(guard));
        console.log("AgentNFA       :", address(nfa));
        console.log("ListingManager :", address(listing));
        console.log("====================================================");
        console.log("");
        console.log(
            "UPDATE .env / docker-compose / frontend with these addresses."
        );
        console.log(
            "NEXT: Run RegisterTemplate.s.sol + ListDemoAgent.s.sol to create test agents."
        );
    }
}
