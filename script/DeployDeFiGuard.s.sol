// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DeFiGuardPolicy} from "../src/policies/DeFiGuardPolicy.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";

/// @title DeployDeFiGuard — Deploy and configure DeFiGuardPolicy
/// @notice Can be run standalone to add DeFiGuardPolicy to an existing deployment.
/// @dev Usage:
///   forge script script/DeployDeFiGuard.s.sol --rpc-url $RPC_URL --broadcast --gas-price 5000000000 -vvv
///
/// Required env vars:
///   PRIVATE_KEY        — deployer private key
///   POLICY_GUARD_V4    — PolicyGuardV4 contract address
///   AGENT_NFA          — AgentNFA contract address
///   ROUTER_ADDRESS     — PancakeSwap V2 Router address
///   WBNB_ADDRESS       — WBNB token address
contract DeployDeFiGuard is Script {
    // Common DeFi function selectors
    bytes4 constant SWAP_EXACT_TOKENS = 0x38ed1739;
    bytes4 constant SWAP_EXACT_ETH = 0x7ff36ab5;
    bytes4 constant SWAP_ETH_EXACT_TOKENS = 0xfb3bdb41;
    bytes4 constant SWAP_TOKENS_EXACT_ETH = 0x4a25d94a;
    bytes4 constant SWAP_EXACT_TOKENS_ETH = 0x18cbafe5;
    bytes4 constant APPROVE = 0x095ea7b3;
    bytes4 constant TRANSFER = 0xa9059cbb;
    bytes4 constant DEPOSIT = 0xd0e30db0; // WBNB.deposit()
    bytes4 constant WITHDRAW = 0x2e1a7d4d; // WBNB.withdraw(uint256)

    // Template key (must match deployment setup)
    bytes32 constant TEMPLATE_LLM = keccak256("llm_trader_v3");

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        address guardAddr = vm.envAddress("POLICY_GUARD_V4");
        address nfa = vm.envAddress("AGENT_NFA");
        address router = vm.envAddress("ROUTER_ADDRESS");
        address wbnb = vm.envAddress("WBNB_ADDRESS");

        vm.startBroadcast(deployerKey);

        // ═══════════════════════════════════════════════════════
        //  STEP 1: Deploy DeFiGuardPolicy
        // ═══════════════════════════════════════════════════════

        DeFiGuardPolicy defiGuard = new DeFiGuardPolicy(guardAddr, nfa);
        console.log("DeFiGuardPolicy deployed at:", address(defiGuard));

        // ═══════════════════════════════════════════════════════
        //  STEP 2: Configure global whitelist (DEX Routers)
        // ═══════════════════════════════════════════════════════

        defiGuard.addGlobalTarget(router);
        defiGuard.addGlobalTarget(wbnb);
        console.log("Global whitelist: PancakeSwap Router + WBNB added");

        // ═══════════════════════════════════════════════════════
        //  STEP 3: Configure allowed function selectors
        // ═══════════════════════════════════════════════════════

        defiGuard.addSelector(SWAP_EXACT_TOKENS);
        defiGuard.addSelector(SWAP_EXACT_ETH);
        defiGuard.addSelector(SWAP_ETH_EXACT_TOKENS);
        defiGuard.addSelector(SWAP_TOKENS_EXACT_ETH);
        defiGuard.addSelector(SWAP_EXACT_TOKENS_ETH);
        defiGuard.addSelector(APPROVE);
        defiGuard.addSelector(TRANSFER);
        defiGuard.addSelector(DEPOSIT);
        defiGuard.addSelector(WITHDRAW);
        console.log(
            "9 selectors configured (5 swap + approve + transfer + deposit + withdraw)"
        );

        // ═══════════════════════════════════════════════════════
        //  STEP 4: Approve policy in PolicyGuardV4
        // ═══════════════════════════════════════════════════════

        PolicyGuardV4 guard = PolicyGuardV4(guardAddr);
        guard.approvePolicyContract(address(defiGuard));
        console.log("DeFiGuardPolicy approved in PolicyGuardV4");

        // ═══════════════════════════════════════════════════════
        //  STEP 5: Attach to templates
        // ═══════════════════════════════════════════════════════

        guard.addTemplatePolicy(TEMPLATE_LLM, address(defiGuard));
        console.log("DeFiGuardPolicy attached to LLM template");

        // ═══════════════════════════════════════════════════════
        //  STEP 6: Bind to existing Token #2 (has no template)
        // ═══════════════════════════════════════════════════════

        guard.addInstancePolicy(2, address(defiGuard));
        console.log("DeFiGuardPolicy bound to Token #2 as instance policy");

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════
        //  SUMMARY
        // ═══════════════════════════════════════════════════════

        console.log("");
        console.log("========== DEFI GUARD DEPLOYMENT COMPLETE ==========");
        console.log("");
        console.log("  Contract     :", address(defiGuard));
        console.log("  Guard        :", guardAddr);
        console.log("  Router (WL)  :", router);
        console.log("  WBNB (WL)    :", wbnb);
        console.log(
            "  Selectors    : 9 (swap variants + approve + transfer + deposit + withdraw)"
        );
        console.log("  Templates    : LLM Trader");
        console.log("  Instance #2  : bound");
        console.log("");
        console.log("Add to .env:");
        console.log("  DEFI_GUARD=", address(defiGuard));
        console.log("====================================================");
    }
}
