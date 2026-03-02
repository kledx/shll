// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IProtocolRegistry {
    function emergencyCall(address target, bytes calldata data) external;
    function guardCall(bytes calldata data) external;
}

/// @title MigratePoliciesV5 — Configure new policies + register in PolicyGuardV4
contract MigratePoliciesV5 is Script {
    IProtocolRegistry constant REGISTRY =
        IProtocolRegistry(0x1A5EA54a3beaf4fba75f73581cf6A945746E6DF1);

    bytes32 constant TEMPLATE_KEY =
        0xd715aef4de7741b1adc3cde0eaa7c9ad1314c56ebef45eeebbfc5418008598f9;

    // ── New Policies ──
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
        // Phase 1: Configure NEW SpendingLimitV2 (template-level)
        // ═══════════════════════════════════════════════════════
        _eCall(
            NEW_SPENDING,
            abi.encodeWithSignature(
                "setTemplateCeiling(bytes32,uint256,uint256,uint256)",
                TEMPLATE_KEY,
                10e18,
                50e18,
                500
            )
        );
        console.log("[1] spending: setTemplateCeiling OK");

        _eCall(
            NEW_SPENDING,
            abi.encodeWithSignature(
                "setTemplateApproveCeiling(bytes32,uint256)",
                TEMPLATE_KEY,
                1e30
            )
        );
        console.log("[2] spending: setTemplateApproveCeiling OK");

        _eCall(
            NEW_SPENDING,
            abi.encodeWithSignature(
                "setApprovedSpender(address,bool)",
                PANCAKE_V2,
                true
            )
        );
        _eCall(
            NEW_SPENDING,
            abi.encodeWithSignature(
                "setApprovedSpender(address,bool)",
                PANCAKE_V3,
                true
            )
        );
        _eCall(
            NEW_SPENDING,
            abi.encodeWithSignature(
                "setApprovedSpender(address,bool)",
                FOUR_MEME_V2,
                true
            )
        );
        console.log("[3] spending: 3 approved spenders OK");

        // Output patterns
        bytes4[7] memory v2Sels = [
            bytes4(0x38ed1739),
            bytes4(0x7ff36ab5),
            bytes4(0x791ac947),
            bytes4(0x5c11d795),
            bytes4(0x8803dbee),
            bytes4(0x4a25d94a),
            bytes4(0xb6f9de95)
        ];
        for (uint256 i = 0; i < v2Sels.length; i++) {
            _eCall(
                NEW_SPENDING,
                abi.encodeWithSignature(
                    "setOutputPattern(bytes4,uint8)",
                    v2Sels[i],
                    1
                )
            );
        }
        _eCall(
            NEW_SPENDING,
            abi.encodeWithSignature(
                "setOutputPattern(bytes4,uint8)",
                bytes4(0x04e45aaf),
                2
            )
        );
        _eCall(
            NEW_SPENDING,
            abi.encodeWithSignature(
                "setOutputPattern(bytes4,uint8)",
                bytes4(0x6cfade7c),
                3
            )
        );
        _eCall(
            NEW_SPENDING,
            abi.encodeWithSignature(
                "setOutputPattern(bytes4,uint8)",
                bytes4(0x4e050bab),
                3
            )
        );
        console.log("[4] spending: output patterns OK");

        // ═══════════════════════════════════════════════════════
        // Phase 2: Configure NEW DeFiGuardV2
        // ═══════════════════════════════════════════════════════
        _eCall(
            NEW_DEFI,
            abi.encodeWithSignature("addGlobalTarget(address)", PANCAKE_V2)
        );
        _eCall(
            NEW_DEFI,
            abi.encodeWithSignature("addGlobalTarget(address)", WBNB)
        );
        _eCall(
            NEW_DEFI,
            abi.encodeWithSignature("addGlobalTarget(address)", PANCAKE_V3)
        );
        _eCall(
            NEW_DEFI,
            abi.encodeWithSignature("addGlobalTarget(address)", FOUR_MEME_V2)
        );
        console.log("[5] defi: 4 global targets OK");

        bytes4[13] memory globalSels = [
            bytes4(0x38ed1739),
            bytes4(0x8803dbee),
            bytes4(0x4a25d94a),
            bytes4(0x791ac947),
            bytes4(0x5c11d795),
            bytes4(0x7ff36ab5),
            bytes4(0xb6f9de95),
            bytes4(0x095ea7b3),
            bytes4(0xa457c2d7),
            bytes4(0xd0e30db0),
            bytes4(0x04e45aaf),
            bytes4(0x6cfade7c),
            bytes4(0x4e050bab)
        ];
        for (uint256 i = 0; i < globalSels.length; i++) {
            _eCall(
                NEW_DEFI,
                abi.encodeWithSignature("addSelector(bytes4)", globalSels[i])
            );
        }
        console.log("[6] defi: 13 selectors OK");

        // ═══════════════════════════════════════════════════════
        // Phase 3: ReceiverGuardV2 — Four.meme patterns
        // ═══════════════════════════════════════════════════════
        _eCall(
            NEW_RECEIVER,
            abi.encodeWithSignature(
                "setPattern(bytes4,uint8)",
                bytes4(0x6cfade7c),
                5
            )
        );
        _eCall(
            NEW_RECEIVER,
            abi.encodeWithSignature(
                "setPattern(bytes4,uint8)",
                bytes4(0x4e050bab),
                5
            )
        );
        console.log("[7] receiver: Four.meme patterns OK");

        // ═══════════════════════════════════════════════════════
        // Phase 4: DexWhitelistPolicy — template #4
        // ═══════════════════════════════════════════════════════
        _eCall(
            NEW_DEX,
            abi.encodeWithSignature("addDex(uint256,address)", 4, PANCAKE_V2)
        );
        _eCall(
            NEW_DEX,
            abi.encodeWithSignature("addDex(uint256,address)", 4, PANCAKE_V3)
        );
        _eCall(
            NEW_DEX,
            abi.encodeWithSignature("addDex(uint256,address)", 4, FOUR_MEME_V2)
        );
        _eCall(
            NEW_DEX,
            abi.encodeWithSignature("addDex(uint256,address)", 4, WBNB)
        );
        console.log("[8] dex: 4 targets OK");

        // ═══════════════════════════════════════════════════════
        // Phase 5: TokenWhitelistPolicy — bypass for template #4
        // ═══════════════════════════════════════════════════════
        _eCall(
            NEW_TOKEN,
            abi.encodeWithSignature("setBypass(uint256,bool)", 4, true)
        );
        console.log("[9] token: bypass OK");

        // ═══════════════════════════════════════════════════════
        // Phase 6: Register new policies in PolicyGuardV4
        //   Step A: approvePolicyContract(address) for each
        //   Step B: addTemplatePolicy(bytes32, address) for each
        //   Step C: bindInstance(6, TEMPLATE_KEY) to re-init instance
        // ═══════════════════════════════════════════════════════
        _gCall(
            abi.encodeWithSignature(
                "approvePolicyContract(address)",
                NEW_SPENDING
            )
        );
        _gCall(
            abi.encodeWithSignature(
                "approvePolicyContract(address)",
                NEW_COOLDOWN
            )
        );
        _gCall(
            abi.encodeWithSignature(
                "approvePolicyContract(address)",
                NEW_RECEIVER
            )
        );
        _gCall(
            abi.encodeWithSignature("approvePolicyContract(address)", NEW_DEFI)
        );
        _gCall(
            abi.encodeWithSignature("approvePolicyContract(address)", NEW_DEX)
        );
        _gCall(
            abi.encodeWithSignature("approvePolicyContract(address)", NEW_TOKEN)
        );
        console.log("[10] guard: 6 policies approved");

        _gCall(
            abi.encodeWithSignature(
                "addTemplatePolicy(bytes32,address)",
                TEMPLATE_KEY,
                NEW_SPENDING
            )
        );
        _gCall(
            abi.encodeWithSignature(
                "addTemplatePolicy(bytes32,address)",
                TEMPLATE_KEY,
                NEW_COOLDOWN
            )
        );
        _gCall(
            abi.encodeWithSignature(
                "addTemplatePolicy(bytes32,address)",
                TEMPLATE_KEY,
                NEW_RECEIVER
            )
        );
        _gCall(
            abi.encodeWithSignature(
                "addTemplatePolicy(bytes32,address)",
                TEMPLATE_KEY,
                NEW_DEFI
            )
        );
        _gCall(
            abi.encodeWithSignature(
                "addTemplatePolicy(bytes32,address)",
                TEMPLATE_KEY,
                NEW_DEX
            )
        );
        _gCall(
            abi.encodeWithSignature(
                "addTemplatePolicy(bytes32,address)",
                TEMPLATE_KEY,
                NEW_TOKEN
            )
        );
        console.log("[11] guard: 6 template policies added");

        // Re-bind instance #6 to trigger initInstance on all new policies
        // Note: instanceTemplateId[6] is already set from old binding,
        // but we need the new policies' initInstance to be called.
        // bindInstance will call initInstance on each IInstanceInitializable policy.
        _gCall(
            abi.encodeWithSignature(
                "bindInstance(uint256,bytes32)",
                6,
                TEMPLATE_KEY
            )
        );
        console.log("[12] guard: bindInstance(6) OK");

        vm.stopBroadcast();
        console.log("\n=== ALL DONE ===");
    }

    function _eCall(address target, bytes memory data) internal {
        REGISTRY.emergencyCall(target, data);
    }

    function _gCall(bytes memory data) internal {
        REGISTRY.guardCall(data);
    }
}
