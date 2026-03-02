// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IProtocolRegistry {
    function emergencyCall(address target, bytes calldata data) external;
    function guardCall(bytes calldata data) external;
}

/// @title MigrateTemplate2 — Migrate instances #5 and #7 (template key 2)
contract MigrateTemplate2 is Script {
    IProtocolRegistry constant REGISTRY =
        IProtocolRegistry(0x1A5EA54a3beaf4fba75f73581cf6A945746E6DF1);

    // Template key for instances #5 and #7
    bytes32 constant TK2 =
        0xd715aef4de7741b1adc3cde0eaa7c9ad1314c56ebef45eebbfc5418008598f9f;

    // ── New Policies (already deployed and approved in Guard) ──
    address constant NEW_SPENDING = 0x28efC8D513D44252EC26f710764ADe22b2569115;
    address constant NEW_COOLDOWN = 0x0E0B2006DE4d68543C4069249a075C215510efDB;
    address constant NEW_RECEIVER = 0x7A9618ec6c2e9D93712326a7797A829895c0AfF6;
    address constant NEW_DEFI = 0xD1b6a97400Bc62ed6000714E9810F36Fc1a251f1;
    address constant NEW_DEX = 0x0D423290A050187AA15B7567aa9DB32535cEF8fb;
    address constant NEW_TOKEN = 0x4300e2111DB1DB41d74C98fAde2DB432DceF4dBA;

    // ── External addresses ──
    address constant PANCAKE_V2 = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant PANCAKE_V3 = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address constant FOUR_MEME_V2 = 0x5c952063c7fc8610FFDB798152D69F0B9550762b;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function run() external {
        vm.startBroadcast();

        // ═══════════════════════════════════════════════════════
        // Phase 1: Set template-level config on new policies for TK2
        //          (same config as TK1, just different template key)
        // ═══════════════════════════════════════════════════════

        // SpendingLimitV2
        _eCall(
            NEW_SPENDING,
            abi.encodeWithSignature(
                "setTemplateCeiling(bytes32,uint256,uint256,uint256)",
                TK2,
                10e18,
                50e18,
                500
            )
        );
        _eCall(
            NEW_SPENDING,
            abi.encodeWithSignature(
                "setTemplateApproveCeiling(bytes32,uint256)",
                TK2,
                1e30
            )
        );
        console.log("[1] spending: template config OK");

        // DexWhitelistPolicy for template (using template token ID)
        // TK2 corresponds to a different template token, need to find its ID
        // Since addDex uses uint256 templateTokenId, and we already set for #4,
        // let's check what template token #5 and #7 came from

        // ═══════════════════════════════════════════════════════
        // Phase 2: Remove old policies from TK2 (6 old, remove by index 5→0)
        // ═══════════════════════════════════════════════════════
        // Old policies are at indices 0-5, remove in reverse to avoid shifting
        for (uint256 i = 4; i > 0; i--) {
            _gCall(
                abi.encodeWithSignature(
                    "removeTemplatePolicy(bytes32,uint256)",
                    TK2,
                    i - 1
                )
            );
        }
        console.log("[2] guard: removed 6 old policies from TK2");

        // ═══════════════════════════════════════════════════════
        // Phase 3: Add new policies to TK2 (already approved)
        // ═══════════════════════════════════════════════════════
        _gCall(
            abi.encodeWithSignature(
                "addTemplatePolicy(bytes32,address)",
                TK2,
                NEW_SPENDING
            )
        );
        _gCall(
            abi.encodeWithSignature(
                "addTemplatePolicy(bytes32,address)",
                TK2,
                NEW_COOLDOWN
            )
        );
        _gCall(
            abi.encodeWithSignature(
                "addTemplatePolicy(bytes32,address)",
                TK2,
                NEW_RECEIVER
            )
        );
        _gCall(
            abi.encodeWithSignature(
                "addTemplatePolicy(bytes32,address)",
                TK2,
                NEW_DEFI
            )
        );
        _gCall(
            abi.encodeWithSignature(
                "addTemplatePolicy(bytes32,address)",
                TK2,
                NEW_DEX
            )
        );
        _gCall(
            abi.encodeWithSignature(
                "addTemplatePolicy(bytes32,address)",
                TK2,
                NEW_TOKEN
            )
        );
        console.log("[3] guard: added 6 new policies to TK2");

        // ═══════════════════════════════════════════════════════
        // Phase 4: Re-bind instances #5 and #7 to trigger initInstance
        // ═══════════════════════════════════════════════════════
        _gCall(
            abi.encodeWithSignature("bindInstance(uint256,bytes32)", 5, TK2)
        );
        console.log("[4] guard: bindInstance(5) OK");
        _gCall(
            abi.encodeWithSignature("bindInstance(uint256,bytes32)", 7, TK2)
        );
        console.log("[5] guard: bindInstance(7) OK");

        vm.stopBroadcast();
        console.log("\n=== TK2 Migration Complete ===");
    }

    function _eCall(address target, bytes memory data) internal {
        REGISTRY.emergencyCall(target, data);
    }

    function _gCall(bytes memory data) internal {
        REGISTRY.guardCall(data);
    }
}
