// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyGuard} from "../src/PolicyGuard.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";

/// @title ApplyPolicy — Idempotent policy configuration from JSON
/// @dev Usage: forge script script/ApplyPolicy.s.sol --rpc-url $RPC_URL --broadcast
///      Set env: PRIVATE_KEY, POLICY_GUARD, CONFIG_PATH
///      Reads on-chain state first, only sends tx for changed items.
///      Output: added / skipped counts per category.
contract ApplyPolicy is Script {
    uint256 added;
    uint256 skipped;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address guardAddr = vm.envAddress("POLICY_GUARD");
        string memory configPath = vm.envString("CONFIG_PATH");

        string memory json = vm.readFile(configPath);

        PolicyGuard guard = PolicyGuard(guardAddr);

        // ─── Parse addresses ───
        address router = vm.parseJsonAddress(json, ".router.address");
        address wbnb = vm.parseJsonAddress(json, ".tokens.WBNB");
        address usdt = vm.parseJsonAddress(json, ".tokens.USDT");
        address vUsdt = vm.parseJsonAddress(json, ".venus.vUSDT");

        vm.startBroadcast(deployerKey);

        // ─── Router target + selectors ───
        _setTargetIfNeeded(guard, router, "Router");
        _setSelectorIfNeeded(
            guard,
            router,
            PolicyKeys.SWAP_EXACT_TOKENS,
            "Router:SWAP_EXACT_TOKENS"
        );
        _setSelectorIfNeeded(
            guard,
            router,
            PolicyKeys.SWAP_EXACT_ETH,
            "Router:SWAP_EXACT_ETH"
        );

        // ─── WBNB ───
        _setTokenIfNeeded(guard, wbnb, "WBNB");
        _setTargetIfNeeded(guard, wbnb, "WBNB");
        _setSelectorIfNeeded(guard, wbnb, PolicyKeys.APPROVE, "WBNB:APPROVE");
        _setSelectorIfNeeded(
            guard,
            wbnb,
            PolicyKeys.WRAP_NATIVE,
            "WBNB:WRAP_NATIVE"
        );
        _setSelectorIfNeeded(
            guard,
            wbnb,
            PolicyKeys.UNWRAP_NATIVE,
            "WBNB:UNWRAP_NATIVE"
        );
        _setSpenderIfNeeded(guard, wbnb, router, "WBNB->Router");

        // ─── USDT ───
        _setTokenIfNeeded(guard, usdt, "USDT");
        _setTargetIfNeeded(guard, usdt, "USDT");
        _setSelectorIfNeeded(guard, usdt, PolicyKeys.APPROVE, "USDT:APPROVE");
        _setSpenderIfNeeded(guard, usdt, router, "USDT->Router");

        // ─── Venus vUSDT ───
        _setTargetIfNeeded(guard, vUsdt, "vUSDT");
        _setSelectorIfNeeded(
            guard,
            vUsdt,
            PolicyKeys.REPAY_BORROW_BEHALF,
            "vUSDT:REPAY_BORROW_BEHALF"
        );

        // ─── Limits ───
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

        _setLimitIfNeeded(
            guard,
            PolicyKeys.MAX_DEADLINE_WINDOW,
            cfgDeadline,
            "MAX_DEADLINE_WINDOW"
        );
        _setLimitIfNeeded(
            guard,
            PolicyKeys.MAX_PATH_LENGTH,
            cfgPath,
            "MAX_PATH_LENGTH"
        );
        _setLimitIfNeeded(
            guard,
            PolicyKeys.MAX_SLIPPAGE_BPS,
            cfgSlippage,
            "MAX_SLIPPAGE_BPS"
        );

        // ─── Router address for slippage quote ───
        if (guard.router() != router) {
            guard.setRouter(router);
            console.log("ADDED: router address set to", router);
            added++;
        } else {
            skipped++;
        }

        vm.stopBroadcast();

        console.log("=== ApplyPolicy Summary ===");
        console.log("  Added:", added);
        console.log("  Skipped (already correct):", skipped);
    }

    // ─── Idempotent helpers ───

    function _setTargetIfNeeded(
        PolicyGuard guard,
        address target,
        string memory label
    ) internal {
        if (guard.targetAllowed(target)) {
            skipped++;
            return;
        }
        guard.setTargetAllowed(target, true);
        console.log("ADDED target:", label);
        added++;
    }

    function _setSelectorIfNeeded(
        PolicyGuard guard,
        address target,
        bytes4 sel,
        string memory label
    ) internal {
        if (guard.selectorAllowed(target, sel)) {
            skipped++;
            return;
        }
        guard.setSelectorAllowed(target, sel, true);
        console.log("ADDED selector:", label);
        added++;
    }

    function _setTokenIfNeeded(
        PolicyGuard guard,
        address token,
        string memory label
    ) internal {
        if (guard.tokenAllowed(token)) {
            skipped++;
            return;
        }
        guard.setTokenAllowed(token, true);
        console.log("ADDED token:", label);
        added++;
    }

    function _setSpenderIfNeeded(
        PolicyGuard guard,
        address token,
        address spender,
        string memory label
    ) internal {
        if (guard.spenderAllowed(token, spender)) {
            skipped++;
            return;
        }
        guard.setSpenderAllowed(token, spender, true);
        console.log("ADDED spender:", label);
        added++;
    }

    function _setLimitIfNeeded(
        PolicyGuard guard,
        bytes32 key,
        uint256 value,
        string memory label
    ) internal {
        if (guard.limits(key) == value) {
            skipped++;
            return;
        }
        guard.setLimit(key, value);
        console.log("ADDED limit:", label);
        added++;
    }
}
