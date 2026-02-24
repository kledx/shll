// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ReceiverGuardPolicy} from "../src/policies/ReceiverGuardPolicy.sol";
import {DexWhitelistPolicy} from "../src/policies/DexWhitelistPolicy.sol";
import {DeFiGuardPolicy} from "../src/policies/DeFiGuardPolicy.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";

/// @title UpgradeNonCommittablePolicies — Add ERC165 to eliminate BSCScan internal revert warnings
/// @notice Deploys new versions of ReceiverGuardPolicy, DexWhitelistPolicy, DeFiGuardPolicy
///         with ERC165 support, swaps them in PolicyGuardV4 template, and re-configures state.
///
/// Problem: PolicyGuardV4._commitPolicies() calls supportsInterface() on each policy.
///          Policies without ERC165 cause internal reverts (caught by try-catch) → BSCScan warning.
///
/// Solution: Add ERC165 to these 3 policies so supportsInterface() returns false for ICommittable
///           instead of reverting.
///
/// @dev Usage:
///   forge script script/UpgradeNonCommittablePolicies.s.sol \
///     --account deployer --rpc-url https://bsc-dataseed1.binance.org \
///     --broadcast --gas-price 3000000000 -vvv
contract UpgradeNonCommittablePolicies is Script {
    bytes32 constant TEMPLATE_LLM = keccak256("llm_trader_v3");
    uint256 constant TEMPLATE_TOKEN_ID = 0;

    // BSC Mainnet addresses (from RESOURCE-MAP.yml)
    address constant GUARD = 0x25d17eA0e3Bcb8CA08a2BFE917E817AFc05dbBB3;
    address constant NFA = 0xE98DCdbf370D7b52c9A2b88F79bEF514A5375a2b;

    // Current template policy order (after CooldownPolicy upgrade + TokenWL removal):
    //   [0]=ReceiverGuard, [1]=SpendingLimit, [2]=CooldownV2, [3]=DexWL, [4]=DeFiGuard
    //
    // We replace [0], [3], [4] with new ERC165-enabled versions.
    // Strategy: remove highest index first to avoid index shift.

    // Old policy addresses
    address constant OLD_RECEIVER_GUARD =
        0xFC73A41fC61f13A02892b8292C398BFE9BcFe2eA;
    address constant OLD_DEX_WL = 0x80222F2Ce92AFfcEcaC94EEA5f4C4fe568Bc25Af;
    address constant OLD_DEFI_GUARD =
        0x17C9EeCaCd139AF8c930c8Eb1eAFA22479Cff145;

    // PancakeSwap V2 Router (for DexWhitelist config)
    address constant PANCAKE_ROUTER =
        0x10ED43C718714eb63d5aA57B78B54704E256024E;

    // DeFiGuard allowed selectors
    bytes4 constant SEL_APPROVE = 0x095ea7b3;
    bytes4 constant SEL_SWAP_EXACT_TOKENS = 0x38ed1739;
    bytes4 constant SEL_SWAP_TOKENS_EXACT = 0x8803dbee;
    bytes4 constant SEL_SWAP_EXACT_ETH = 0x7ff36ab5;
    bytes4 constant SEL_SWAP_TOKENS_EXACT_ETH = 0x4a25d94a;
    bytes4 constant SEL_SWAP_EXACT_TOKENS_ETH = 0x791ac947;
    bytes4 constant SEL_SWAP_EXACT_TOKENS_FEE = 0x5c11d795;
    bytes4 constant SEL_SWAP_EXACT_ETH_FEE = 0xb6f9de95;
    bytes4 constant SEL_WBNB_DEPOSIT = 0xd0e30db0; // WBNB.deposit()
    bytes4 constant SEL_WBNB_WITHDRAW = 0x2e1a7d4d; // WBNB.withdraw(uint256)

    // USDT on BSC Mainnet
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    function run() external {
        console.log("========================================================");
        console.log("  ERC165 Policy Upgrade (BSCScan Warning Fix)");
        console.log("========================================================");
        console.log("Chain ID         :", block.chainid);
        console.log("PolicyGuardV4    :", GUARD);
        console.log("AgentNFA         :", NFA);
        console.log("========================================================");

        // Pre-upgrade: log current template policies
        address[] memory before = PolicyGuardV4(GUARD).getTemplatePolicies(
            TEMPLATE_LLM
        );
        console.log("Current template policies:", before.length);
        for (uint256 i = 0; i < before.length; i++) {
            console.log("  [%d] %s", i, before[i]);
        }

        vm.startBroadcast();

        // ─── Step 1: Deploy new policies ───
        ReceiverGuardPolicy newReceiverGuard = new ReceiverGuardPolicy(NFA);
        console.log(
            "[1/9] New ReceiverGuardPolicy:",
            address(newReceiverGuard)
        );

        DexWhitelistPolicy newDexWL = new DexWhitelistPolicy(GUARD, NFA);
        console.log("[2/9] New DexWhitelistPolicy:", address(newDexWL));

        DeFiGuardPolicy newDeFiGuard = new DeFiGuardPolicy(GUARD, NFA);
        console.log("[3/9] New DeFiGuardPolicy:", address(newDeFiGuard));

        // ─── Step 2: Approve new policies ───
        PolicyGuardV4(GUARD).approvePolicyContract(address(newReceiverGuard));
        PolicyGuardV4(GUARD).approvePolicyContract(address(newDexWL));
        PolicyGuardV4(GUARD).approvePolicyContract(address(newDeFiGuard));
        console.log("[4/9] All 3 new policies approved");

        // ─── Step 3: Remove old policies (highest index first!) ───
        // Current: [0]=ReceiverGuard, [1]=SpendingLimit, [2]=CooldownV2, [3]=DexWL, [4]=DeFiGuard
        PolicyGuardV4(GUARD).removeTemplatePolicy(TEMPLATE_LLM, 4); // Remove DeFiGuard
        // After: [0]=ReceiverGuard, [1]=SpendingLimit, [2]=CooldownV2, [3]=DexWL
        PolicyGuardV4(GUARD).removeTemplatePolicy(TEMPLATE_LLM, 3); // Remove DexWL
        // After: [0]=ReceiverGuard, [1]=SpendingLimit, [2]=CooldownV2
        PolicyGuardV4(GUARD).removeTemplatePolicy(TEMPLATE_LLM, 0); // Remove ReceiverGuard
        // After: [0]=CooldownV2, [1]=SpendingLimit
        // (swap-and-pop: CooldownV2 moved to idx 0)
        console.log("[5/9] Removed 3 old policies from template");

        // ─── Step 4: Add new policies ───
        PolicyGuardV4(GUARD).addTemplatePolicy(
            TEMPLATE_LLM,
            address(newReceiverGuard)
        );
        PolicyGuardV4(GUARD).addTemplatePolicy(TEMPLATE_LLM, address(newDexWL));
        PolicyGuardV4(GUARD).addTemplatePolicy(
            TEMPLATE_LLM,
            address(newDeFiGuard)
        );
        console.log("[6/9] Added 3 new policies to template");

        // ─── Step 5: Configure DexWhitelistPolicy ───
        // Re-add PancakeSwap Router to template-level DEX whitelist
        newDexWL.addDex(TEMPLATE_TOKEN_ID, PANCAKE_ROUTER);
        console.log("[7/9] DexWhitelist: PancakeRouter added");

        // ─── Step 6: Configure DeFiGuardPolicy ───
        // Re-add global whitelist (PancakeSwap Router + USDT)
        newDeFiGuard.addGlobalTarget(PANCAKE_ROUTER);
        newDeFiGuard.addGlobalTarget(USDT);
        // Re-add allowed selectors
        newDeFiGuard.addSelector(SEL_APPROVE);
        newDeFiGuard.addSelector(SEL_SWAP_EXACT_TOKENS);
        newDeFiGuard.addSelector(SEL_SWAP_TOKENS_EXACT);
        newDeFiGuard.addSelector(SEL_SWAP_EXACT_ETH);
        newDeFiGuard.addSelector(SEL_SWAP_TOKENS_EXACT_ETH);
        newDeFiGuard.addSelector(SEL_SWAP_EXACT_TOKENS_ETH);
        newDeFiGuard.addSelector(SEL_SWAP_EXACT_TOKENS_FEE);
        newDeFiGuard.addSelector(SEL_SWAP_EXACT_ETH_FEE);
        newDeFiGuard.addSelector(SEL_WBNB_DEPOSIT);
        newDeFiGuard.addSelector(SEL_WBNB_WITHDRAW);
        console.log(
            "[8/9] DeFiGuard: 2 global targets + 10 selectors configured"
        );

        vm.stopBroadcast();

        // ─── Post-upgrade: verify ───
        address[] memory after_ = PolicyGuardV4(GUARD).getTemplatePolicies(
            TEMPLATE_LLM
        );
        console.log("");
        console.log("[9/9] Post-upgrade template policies:", after_.length);
        for (uint256 i = 0; i < after_.length; i++) {
            console.log("  [%d] %s", i, after_[i]);
        }

        console.log("");
        console.log("========================================================");
        console.log("  UPGRADE COMPLETE");
        console.log("========================================================");
        console.log("New ReceiverGuardPolicy:", address(newReceiverGuard));
        console.log("New DexWhitelistPolicy :", address(newDexWL));
        console.log("New DeFiGuardPolicy    :", address(newDeFiGuard));
        console.log("");
        console.log("Update RESOURCE-MAP.yml with new addresses.");
        console.log("========================================================");
    }
}
