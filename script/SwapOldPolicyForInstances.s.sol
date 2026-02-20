// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";
import {DexWhitelistPolicy} from "../src/policies/DexWhitelistPolicy.sol";

/// @title SwapOldPolicyForInstances — Hotfix for existing agents
/// @notice Swaps the old DexWhitelistPolicy for the new one on existing instantiated agents
/// @dev Usage:
///   forge script script/SwapOldPolicyForInstances.s.sol --rpc-url $RPC_URL --broadcast -vvv
///
/// Required env vars:
///   PRIVATE_KEY        — deployer (must be owner of PolicyGuardV4 to bypass renter check)
///   POLICY_GUARD_V4    — existing PolicyGuardV4 address
///   NEW_POLICY         — the new fixed DexWhitelistPolicy address
///   TOKEN_IDS          — comma-separated list of token IDs to fix (e.g., "1,2,3")
contract SwapOldPolicyForInstances is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address guardV4Addr = vm.envAddress("POLICY_GUARD_V4");
        address newPolicy = vm.envAddress("NEW_POLICY");

        string[] memory tokenIdsStr = vm.envString("TOKEN_IDS", ",");

        uint256[] memory tokenIds = new uint256[](tokenIdsStr.length);
        for (uint256 i = 0; i < tokenIdsStr.length; i++) {
            tokenIds[i] = vm.parseUint(tokenIdsStr[i]);
        }

        vm.startBroadcast(deployerKey);
        PolicyGuardV4 guard = PolicyGuardV4(guardV4Addr);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            // Get active policies
            address[] memory policies = guard.getActivePolicies(tokenId);
            int256 oldIndex = -1;

            for (uint256 j = 0; j < policies.length; j++) {
                try DexWhitelistPolicy(policies[j]).policyType() returns (
                    bytes32 pt
                ) {
                    if (pt == keccak256("dex_whitelist")) {
                        oldIndex = int256(j);
                        break;
                    }
                } catch {
                    // Not a DexWhitelistPolicy
                }
            }

            if (oldIndex != -1) {
                console.log(
                    "Token",
                    tokenId,
                    "- Found old policy at index",
                    uint256(oldIndex)
                );
                // Remove old
                guard.removeInstancePolicy(tokenId, uint256(oldIndex));
                // Add new
                guard.addInstancePolicy(tokenId, newPolicy);
                console.log(
                    "Token",
                    tokenId,
                    "- Hot-swapped policy successfully."
                );
            } else {
                console.log(
                    "Token",
                    tokenId,
                    "- Old policy not found. Skipping."
                );
            }
        }

        vm.stopBroadcast();
        console.log("Done.");
    }
}
