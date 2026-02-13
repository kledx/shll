// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyGuard} from "../src/PolicyGuard.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";

/// @title CheckPolicy — Read-only verification: compare JSON config vs on-chain PolicyGuard state
/// @dev Usage: forge script script/CheckPolicy.s.sol --rpc-url $RPC_URL
///      Set env: POLICY_GUARD=<address> CONFIG_PATH=<path>
///      Exit code 1 if any mismatch is found (CI-friendly)
contract CheckPolicy is Script {
    uint256 mismatches;

    function run() external view {
        address guardAddr = vm.envAddress("POLICY_GUARD");
        string memory configPath = vm.envString("CONFIG_PATH");
        string memory json = vm.readFile(configPath);

        PolicyGuard guard = PolicyGuard(guardAddr);

        uint256 mismatchCount = 0;

        // ─── Check router target ───
        address router = vm.parseJsonAddress(json, ".router.address");
        if (!guard.targetAllowed(router)) {
            console.log("MISMATCH: router target not allowed:", router);
            mismatchCount++;
        }

        // ─── Check router selectors ───
        if (!guard.selectorAllowed(router, PolicyKeys.SWAP_EXACT_TOKENS)) {
            console.log(
                "MISMATCH: SWAP_EXACT_TOKENS selector not allowed on router"
            );
            mismatchCount++;
        }
        if (!guard.selectorAllowed(router, PolicyKeys.SWAP_EXACT_ETH)) {
            console.log(
                "MISMATCH: SWAP_EXACT_ETH selector not allowed on router"
            );
            mismatchCount++;
        }

        // ─── Check tokens ───
        address wbnb = vm.parseJsonAddress(json, ".tokens.WBNB");
        address usdt = vm.parseJsonAddress(json, ".tokens.USDT");

        if (!guard.tokenAllowed(wbnb)) {
            console.log("MISMATCH: WBNB not in token allowlist:", wbnb);
            mismatchCount++;
        }
        if (!guard.tokenAllowed(usdt)) {
            console.log("MISMATCH: USDT not in token allowlist:", usdt);
            mismatchCount++;
        }
        if (!guard.targetAllowed(wbnb)) {
            console.log("MISMATCH: WBNB not in target allowlist:", wbnb);
            mismatchCount++;
        }
        if (!guard.targetAllowed(usdt)) {
            console.log("MISMATCH: USDT not in target allowlist:", usdt);
            mismatchCount++;
        }

        // ─── Check WBNB selectors ───
        if (!guard.selectorAllowed(wbnb, PolicyKeys.APPROVE)) {
            console.log("MISMATCH: APPROVE not allowed on WBNB");
            mismatchCount++;
        }
        if (!guard.selectorAllowed(wbnb, PolicyKeys.WRAP_NATIVE)) {
            console.log("MISMATCH: WRAP_NATIVE not allowed on WBNB");
            mismatchCount++;
        }
        if (!guard.selectorAllowed(wbnb, PolicyKeys.UNWRAP_NATIVE)) {
            console.log("MISMATCH: UNWRAP_NATIVE not allowed on WBNB");
            mismatchCount++;
        }

        // ─── Check USDT selectors ───
        if (!guard.selectorAllowed(usdt, PolicyKeys.APPROVE)) {
            console.log("MISMATCH: APPROVE not allowed on USDT");
            mismatchCount++;
        }

        // ─── Check spenders ───
        if (!guard.spenderAllowed(usdt, router)) {
            console.log("MISMATCH: router not allowed as spender for USDT");
            mismatchCount++;
        }
        if (!guard.spenderAllowed(wbnb, router)) {
            console.log("MISMATCH: router not allowed as spender for WBNB");
            mismatchCount++;
        }

        // ─── Check Venus ───
        address vUsdt = vm.parseJsonAddress(json, ".venus.vUSDT");
        if (!guard.targetAllowed(vUsdt)) {
            console.log("MISMATCH: vUSDT not in target allowlist:", vUsdt);
            mismatchCount++;
        }
        if (!guard.selectorAllowed(vUsdt, PolicyKeys.REPAY_BORROW_BEHALF)) {
            console.log("MISMATCH: REPAY_BORROW_BEHALF not allowed on vUSDT");
            mismatchCount++;
        }

        // ─── Check limits ───
        uint256 cfgDeadline = vm.parseJsonUint(
            json,
            ".policyDefaults.maxDeadlineWindow"
        );
        uint256 cfgPath = vm.parseJsonUint(
            json,
            ".policyDefaults.maxPathLength"
        );
        uint256 cfgSlippage = vm.parseJsonUint(
            json,
            ".policyDefaults.maxSlippageBps"
        );

        if (guard.limits(PolicyKeys.MAX_DEADLINE_WINDOW) != cfgDeadline) {
            console.log(
                "MISMATCH: MAX_DEADLINE_WINDOW on-chain:",
                guard.limits(PolicyKeys.MAX_DEADLINE_WINDOW),
                "expected:",
                cfgDeadline
            );
            mismatchCount++;
        }
        if (guard.limits(PolicyKeys.MAX_PATH_LENGTH) != cfgPath) {
            console.log(
                "MISMATCH: MAX_PATH_LENGTH on-chain:",
                guard.limits(PolicyKeys.MAX_PATH_LENGTH),
                "expected:",
                cfgPath
            );
            mismatchCount++;
        }
        if (guard.limits(PolicyKeys.MAX_SLIPPAGE_BPS) != cfgSlippage) {
            console.log(
                "MISMATCH: MAX_SLIPPAGE_BPS on-chain:",
                guard.limits(PolicyKeys.MAX_SLIPPAGE_BPS),
                "expected:",
                cfgSlippage
            );
            mismatchCount++;
        }

        // ─── Check router address ───
        if (guard.router() != router) {
            console.log(
                "MISMATCH: router address on-chain:",
                guard.router(),
                "expected:",
                router
            );
            mismatchCount++;
        }

        // ─── Summary ───
        if (mismatchCount == 0) {
            console.log("CHECK PASSED: all policy items match config");
        } else {
            console.log("CHECK FAILED: mismatches found:", mismatchCount);
            revert("Policy mismatch");
        }
    }
}
