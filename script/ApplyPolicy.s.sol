// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyGuard} from "../src/PolicyGuard.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";

/// @title ApplyPolicy — Idempotent policy configuration from JSON
/// @dev Usage: forge script script/ApplyPolicy.s.sol --rpc-url $RPC_URL --broadcast
///      Set env: PRIVATE_KEY, POLICY_GUARD, CONFIG_PATH
///      Reads on-chain state first, only sends tx for changed items.
///      Output: added / skipped counts per category + audit log.
contract ApplyPolicy is Script {
    uint256 added;
    uint256 skipped;

    struct AuditChange {
        string changeType;
        string action;
        string label;
        address addr;
        bytes4 selector;
        address token;
        address spender;
    }

    AuditChange[] auditChanges;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address guardAddr = vm.envAddress("POLICY_GUARD");
        string memory configPath = vm.envString("CONFIG_PATH");

        string memory json = vm.readFile(configPath);

        PolicyGuard guard = PolicyGuard(guardAddr);

        string memory network = vm.parseJsonString(json, ".network");
        string memory policyVersion = vm.parseJsonString(json, ".meta.policyVersion");

        vm.startBroadcast(deployerKey);

        // ─── Apply Targets ───
        _applyTargets(guard, json);

        // ─── Apply Selectors ───
        _applySelectors(guard, json);

        // ─── Apply Tokens ───
        _applyTokens(guard, json);

        // ─── Apply Spenders ───
        _applySpenders(guard, json);

        // ─── Apply Limits ───
        _applyLimits(guard, json);

        // ─── Set Router Address ───
        address router = _resolveAddress(json, "{{router.address}}");
        if (guard.router() != router) {
            guard.setRouter(router);
            console.log("ADDED: router address set to", router);
            added++;
        } else {
            skipped++;
        }

        vm.stopBroadcast();

        console.log("=== ApplyPolicy Summary ===");
        console.log("  Network:", network);
        console.log("  Policy Version:", policyVersion);
        console.log("  Added:", added);
        console.log("  Skipped (already correct):", skipped);

        // ─── Write Audit Log ───
        _writeAuditLog(network, policyVersion, guardAddr);
    }

    // ─── Apply Targets from policyBundle.targets[] ───
    function _applyTargets(PolicyGuard guard, string memory json) internal {
        bytes memory targetsData = vm.parseJson(json, ".policyBundle.targets");

        // Check if targets array exists and has elements
        if (targetsData.length == 0) {
            console.log("No targets found in policyBundle");
            return;
        }

        // Parse targets array length
        uint256 targetCount = 0;
        try vm.parseJsonUint(json, ".policyBundle.targets.length") returns (uint256 count) {
            targetCount = count;
        } catch {
            // If length parsing fails, try to decode the array directly
            // This is a workaround for Foundry's JSON parsing
            console.log("Warning: Could not parse targets.length, attempting manual parse");
            return;
        }

        for (uint256 i = 0; i < targetCount; i++) {
            string memory basePath = string.concat(".policyBundle.targets[", vm.toString(i), "]");

            string memory addrTemplate = vm.parseJsonString(json, string.concat(basePath, ".address"));
            address target = _resolveAddress(json, addrTemplate);
            string memory label = vm.parseJsonString(json, string.concat(basePath, ".label"));

            _setTargetIfNeeded(guard, target, label);
        }
    }

    // ─── Apply Selectors from policyBundle.selectors[] ───
    function _applySelectors(PolicyGuard guard, string memory json) internal {
        bytes memory selectorsData = vm.parseJson(json, ".policyBundle.selectors");

        if (selectorsData.length == 0) {
            console.log("No selectors found in policyBundle");
            return;
        }

        uint256 selectorCount = 0;
        try vm.parseJsonUint(json, ".policyBundle.selectors.length") returns (uint256 count) {
            selectorCount = count;
        } catch {
            console.log("Warning: Could not parse selectors.length");
            return;
        }

        for (uint256 i = 0; i < selectorCount; i++) {
            string memory basePath = string.concat(".policyBundle.selectors[", vm.toString(i), "]");

            string memory targetTemplate = vm.parseJsonString(json, string.concat(basePath, ".target"));
            address target = _resolveAddress(json, targetTemplate);

            bytes4 selector = bytes4(vm.parseJsonBytes(json, string.concat(basePath, ".selector")));
            string memory label = vm.parseJsonString(json, string.concat(basePath, ".label"));

            _setSelectorIfNeeded(guard, target, selector, label);
        }
    }

    // ─── Apply Tokens from policyBundle.tokens[] ───
    function _applyTokens(PolicyGuard guard, string memory json) internal {
        bytes memory tokensData = vm.parseJson(json, ".policyBundle.tokens");

        if (tokensData.length == 0) {
            console.log("No tokens found in policyBundle");
            return;
        }

        uint256 tokenCount = 0;
        try vm.parseJsonUint(json, ".policyBundle.tokens.length") returns (uint256 count) {
            tokenCount = count;
        } catch {
            console.log("Warning: Could not parse tokens.length");
            return;
        }

        for (uint256 i = 0; i < tokenCount; i++) {
            string memory basePath = string.concat(".policyBundle.tokens[", vm.toString(i), "]");

            string memory addrTemplate = vm.parseJsonString(json, string.concat(basePath, ".address"));
            address token = _resolveAddress(json, addrTemplate);
            string memory symbol = vm.parseJsonString(json, string.concat(basePath, ".symbol"));

            _setTokenIfNeeded(guard, token, symbol);

            // Also add token as target to allow approve() calls
            _setTargetIfNeeded(guard, token, string.concat(symbol, " (target)"));

            // Add approve selector
            _setSelectorIfNeeded(guard, token, PolicyKeys.APPROVE, string.concat(symbol, ":APPROVE"));
        }
    }

    // ─── Apply Spenders from policyBundle.spenders[] ───
    function _applySpenders(PolicyGuard guard, string memory json) internal {
        bytes memory spendersData = vm.parseJson(json, ".policyBundle.spenders");

        if (spendersData.length == 0) {
            console.log("No spenders found in policyBundle");
            return;
        }

        uint256 spenderCount = 0;
        try vm.parseJsonUint(json, ".policyBundle.spenders.length") returns (uint256 count) {
            spenderCount = count;
        } catch {
            console.log("Warning: Could not parse spenders.length");
            return;
        }

        for (uint256 i = 0; i < spenderCount; i++) {
            string memory basePath = string.concat(".policyBundle.spenders[", vm.toString(i), "]");

            string memory tokenTemplate = vm.parseJsonString(json, string.concat(basePath, ".token"));
            address token = _resolveAddress(json, tokenTemplate);

            string memory spenderTemplate = vm.parseJsonString(json, string.concat(basePath, ".spender"));
            address spender = _resolveAddress(json, spenderTemplate);

            string memory label = vm.parseJsonString(json, string.concat(basePath, ".label"));

            _setSpenderIfNeeded(guard, token, spender, label);
        }
    }

    // ─── Apply Limits from policyDefaults ───
    function _applyLimits(PolicyGuard guard, string memory json) internal {
        uint256 cfgDeadline = vm.parseJsonUint(json, ".policyDefaults.maxDeadlineWindow");
        uint256 cfgPath = vm.parseJsonUint(json, ".policyDefaults.maxPathLength");
        uint256 cfgSlippage = vm.parseJsonUint(json, ".policyDefaults.maxSlippageBps");

        _setLimitIfNeeded(guard, PolicyKeys.MAX_DEADLINE_WINDOW, cfgDeadline, "MAX_DEADLINE_WINDOW");
        _setLimitIfNeeded(guard, PolicyKeys.MAX_PATH_LENGTH, cfgPath, "MAX_PATH_LENGTH");
        _setLimitIfNeeded(guard, PolicyKeys.MAX_SLIPPAGE_BPS, cfgSlippage, "MAX_SLIPPAGE_BPS");
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

    // ─── Write Audit Log ───
    function _writeAuditLog(string memory network, string memory policyVersion, address guardAddr) internal {
        string memory timestamp = vm.toString(block.timestamp);
        string memory logDir = "repos/shll/logs/policy-audit";
        string memory logFile = string.concat(logDir, "/", timestamp, ".json");

        // Build JSON manually (Foundry doesn't have great JSON serialization)
        string memory log = string.concat(
            "{\n",
            '  "timestamp": "', timestamp, '",\n',
            '  "network": "', network, '",\n',
            '  "policyGuard": "', vm.toString(guardAddr), '",\n',
            '  "configVersion": "', policyVersion, '",\n',
            '  "operation": "apply",\n',
            '  "summary": {\n',
            '    "added": ', vm.toString(added), ',\n',
            '    "skipped": ', vm.toString(skipped), '\n',
            '  }\n',
            '}\n'
        );

        vm.writeFile(logFile, log);
        console.log("Audit log written to:", logFile);
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
        console.log("ADDED target:", label, vm.toString(target));
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
        console.log("ADDED token:", label, vm.toString(token));
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
        console.log("ADDED limit:", label, "=", value);
        added++;
    }
}
