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

        // ─── Check Targets ───
        mismatchCount += _checkTargets(guard, json);

        // ─── Check Selectors ───
        mismatchCount += _checkSelectors(guard, json);

        // ─── Check Tokens ───
        mismatchCount += _checkTokens(guard, json);

        // ─── Check Spenders ───
        mismatchCount += _checkSpenders(guard, json);

        // ─── Check Limits ───
        mismatchCount += _checkLimits(guard, json);

        // ─── Check Router Address ───
        address router = _resolveAddress(json, "{{router.address}}");
        if (guard.router() != router) {
            console.log("MISMATCH: router address on-chain:", guard.router(), "expected:", router);
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

    // ─── Check Targets from policyBundle.targets[] ───
    function _checkTargets(PolicyGuard guard, string memory json) internal view returns (uint256) {
        uint256 mismatchCount = 0;
        bytes memory targetsData = vm.parseJson(json, ".policyBundle.targets");

        if (targetsData.length == 0) {
            console.log("No targets found in policyBundle");
            return 0;
        }

        uint256 targetCount = 0;
        try vm.parseJsonUint(json, ".policyBundle.targets.length") returns (uint256 count) {
            targetCount = count;
        } catch {
            console.log("Warning: Could not parse targets.length");
            return 0;
        }

        for (uint256 i = 0; i < targetCount; i++) {
            string memory basePath = string.concat(".policyBundle.targets[", vm.toString(i), "]");

            string memory addrTemplate = vm.parseJsonString(json, string.concat(basePath, ".address"));
            address target = _resolveAddress(json, addrTemplate);
            string memory label = vm.parseJsonString(json, string.concat(basePath, ".label"));

            if (!guard.targetAllowed(target)) {
                console.log("MISMATCH: target not allowed:", label, vm.toString(target));
                mismatchCount++;
            }
        }

        return mismatchCount;
    }

    // ─── Check Selectors from policyBundle.selectors[] ───
    function _checkSelectors(PolicyGuard guard, string memory json) internal view returns (uint256) {
        uint256 mismatchCount = 0;
        bytes memory selectorsData = vm.parseJson(json, ".policyBundle.selectors");

        if (selectorsData.length == 0) {
            console.log("No selectors found in policyBundle");
            return 0;
        }

        uint256 selectorCount = 0;
        try vm.parseJsonUint(json, ".policyBundle.selectors.length") returns (uint256 count) {
            selectorCount = count;
        } catch {
            console.log("Warning: Could not parse selectors.length");
            return 0;
        }

        for (uint256 i = 0; i < selectorCount; i++) {
            string memory basePath = string.concat(".policyBundle.selectors[", vm.toString(i), "]");

            string memory targetTemplate = vm.parseJsonString(json, string.concat(basePath, ".target"));
            address target = _resolveAddress(json, targetTemplate);

            bytes4 selector = bytes4(vm.parseJsonBytes(json, string.concat(basePath, ".selector")));
            string memory label = vm.parseJsonString(json, string.concat(basePath, ".label"));

            if (!guard.selectorAllowed(target, selector)) {
                console.log("MISMATCH: selector not allowed:", label);
                mismatchCount++;
            }
        }

        return mismatchCount;
    }

    // ─── Check Tokens from policyBundle.tokens[] ───
    function _checkTokens(PolicyGuard guard, string memory json) internal view returns (uint256) {
        uint256 mismatchCount = 0;
        bytes memory tokensData = vm.parseJson(json, ".policyBundle.tokens");

        if (tokensData.length == 0) {
            console.log("No tokens found in policyBundle");
            return 0;
        }

        uint256 tokenCount = 0;
        try vm.parseJsonUint(json, ".policyBundle.tokens.length") returns (uint256 count) {
            tokenCount = count;
        } catch {
            console.log("Warning: Could not parse tokens.length");
            return 0;
        }

        for (uint256 i = 0; i < tokenCount; i++) {
            string memory basePath = string.concat(".policyBundle.tokens[", vm.toString(i), "]");

            string memory addrTemplate = vm.parseJsonString(json, string.concat(basePath, ".address"));
            address token = _resolveAddress(json, addrTemplate);
            string memory symbol = vm.parseJsonString(json, string.concat(basePath, ".symbol"));

            if (!guard.tokenAllowed(token)) {
                console.log("MISMATCH: token not allowed:", symbol, vm.toString(token));
                mismatchCount++;
            }

            // Check token as target
            if (!guard.targetAllowed(token)) {
                console.log("MISMATCH: token not in target allowlist:", symbol, vm.toString(token));
                mismatchCount++;
            }

            // Check approve selector
            if (!guard.selectorAllowed(token, PolicyKeys.APPROVE)) {
                console.log("MISMATCH: APPROVE selector not allowed on:", symbol);
                mismatchCount++;
            }
        }

        return mismatchCount;
    }

    // ─── Check Spenders from policyBundle.spenders[] ───
    function _checkSpenders(PolicyGuard guard, string memory json) internal view returns (uint256) {
        uint256 mismatchCount = 0;
        bytes memory spendersData = vm.parseJson(json, ".policyBundle.spenders");

        if (spendersData.length == 0) {
            console.log("No spenders found in policyBundle");
            return 0;
        }

        uint256 spenderCount = 0;
        try vm.parseJsonUint(json, ".policyBundle.spenders.length") returns (uint256 count) {
            spenderCount = count;
        } catch {
            console.log("Warning: Could not parse spenders.length");
            return 0;
        }

        for (uint256 i = 0; i < spenderCount; i++) {
            string memory basePath = string.concat(".policyBundle.spenders[", vm.toString(i), "]");

            string memory tokenTemplate = vm.parseJsonString(json, string.concat(basePath, ".token"));
            address token = _resolveAddress(json, tokenTemplate);

            string memory spenderTemplate = vm.parseJsonString(json, string.concat(basePath, ".spender"));
            address spender = _resolveAddress(json, spenderTemplate);

            string memory label = vm.parseJsonString(json, string.concat(basePath, ".label"));

            if (!guard.spenderAllowed(token, spender)) {
                console.log("MISMATCH: spender not allowed:", label);
                mismatchCount++;
            }
        }

        return mismatchCount;
    }

    // ─── Check Limits from policyDefaults ───
    function _checkLimits(PolicyGuard guard, string memory json) internal view returns (uint256) {
        uint256 mismatchCount = 0;

        uint256 cfgDeadline = vm.parseJsonUint(json, ".policyDefaults.maxDeadlineWindow");
        uint256 cfgPath = vm.parseJsonUint(json, ".policyDefaults.maxPathLength");
        uint256 cfgSlippage = vm.parseJsonUint(json, ".policyDefaults.maxSlippageBps");

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

        return mismatchCount;
    }

    // ─── Resolve {{template}} syntax ───
    function _resolveAddress(string memory json, string memory template) internal view returns (address) {
        // Check if template starts with {{
        bytes memory templateBytes = bytes(template);
        if (templateBytes.length < 4 || templateBytes[0] != '{' || templateBytes[1] != '{') {
            // Not a template, parse as direct address
            return vm.parseJsonAddress(json, template);
        }

        // Extract path from {{path}}
        string memory path = _extractTemplatePath(template);

        // Build JSON path
        string memory jsonPath = string.concat(".", path);

        return vm.parseJsonAddress(json, jsonPath);
    }

    function _extractTemplatePath(string memory template) internal pure returns (string memory) {
        bytes memory templateBytes = bytes(template);

        // Remove {{ and }}
        uint256 startIdx = 2; // Skip {{
        uint256 endIdx = templateBytes.length - 2; // Skip }}

        bytes memory pathBytes = new bytes(endIdx - startIdx);
        for (uint256 i = 0; i < pathBytes.length; i++) {
            pathBytes[i] = templateBytes[startIdx + i];
        }

        return string(pathBytes);
    }
}
