// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {AgentAccount} from "../src/AgentAccount.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";
import {TokenWhitelistPolicy} from "../src/policies/TokenWhitelistPolicy.sol";
import {SpendingLimitPolicy} from "../src/policies/SpendingLimitPolicy.sol";
import {CooldownPolicy} from "../src/policies/CooldownPolicy.sol";
import {ReceiverGuardPolicy} from "../src/policies/ReceiverGuardPolicy.sol";
import {DexWhitelistPolicy} from "../src/policies/DexWhitelistPolicy.sol";
import {IPolicy} from "../src/interfaces/IPolicy.sol";
import {ICommittable} from "../src/interfaces/ICommittable.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";
import {Action} from "../src/types/Action.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";
import {CalldataDecoder} from "../src/libs/CalldataDecoder.sol";

/// @title V3.0 Integration Tests — Composable Policy Architecture
/// @notice 17+ test cases covering PolicyGuardV4, all 5 policies, AgentNFA V2 features
contract V3_0_IntegrationTest is Test {
    AgentNFA public nfa;
    PolicyGuardV4 public guardV4;

    // Policies
    TokenWhitelistPolicy public tokenWL;
    SpendingLimitPolicy public spendingLimit;
    CooldownPolicy public cooldownPolicy;
    ReceiverGuardPolicy public receiverGuard;
    DexWhitelistPolicy public dexWL;

    // Roles
    address public owner;
    address public renter = address(0xBEEF);

    // Mock addresses
    address constant ROUTER = address(0x1111);
    address constant USDT = address(0x2222);
    address constant WBNB = address(0x3333);

    uint256 public templateId;
    bytes32 public templateKey;

    // ═══════════════════════════════════════════════════════════
    //                    SETUP
    // ═══════════════════════════════════════════════════════════

    function setUp() public {
        owner = address(this);

        // 1. Deploy PolicyGuardV4
        guardV4 = new PolicyGuardV4();

        // 2. Deploy AgentNFA (with guardV4)
        nfa = new AgentNFA(address(guardV4));

        // 3. Wire PolicyGuardV4 -> AgentNFA
        guardV4.setAgentNFA(address(nfa));

        // 4. Deploy Policy Plugins
        tokenWL = new TokenWhitelistPolicy(address(guardV4), address(nfa));
        spendingLimit = new SpendingLimitPolicy(address(guardV4), address(nfa));
        cooldownPolicy = new CooldownPolicy(address(guardV4), address(nfa));
        receiverGuard = new ReceiverGuardPolicy(address(nfa));
        dexWL = new DexWhitelistPolicy(address(guardV4), address(nfa));

        // 5. Approve policies in guard
        guardV4.approvePolicyContract(address(tokenWL));
        guardV4.approvePolicyContract(address(spendingLimit));
        guardV4.approvePolicyContract(address(cooldownPolicy));
        guardV4.approvePolicyContract(address(receiverGuard));
        guardV4.approvePolicyContract(address(dexWL));

        // 6. Mint template agent with TYPE_DCA
        IBAP578.AgentMetadata memory meta = IBAP578.AgentMetadata({
            persona: '{"role":"trader"}',
            experience: "V3.0 test agent",
            voiceHash: "",
            animationURI: "",
            vaultURI: "v3-test",
            vaultHash: bytes32(0)
        });
        templateId = nfa.mintAgent(
            owner,
            bytes32(0),
            nfa.TYPE_DCA(),
            "ipfs://v3-test",
            meta
        );

        // 7. Register template
        templateKey = bytes32("v3template");
        nfa.registerTemplate(templateId, templateKey, "ipfs://v3");

        // 8. Add template policies (one at a time via addTemplatePolicy)
        guardV4.addTemplatePolicy(templateKey, address(tokenWL));
        guardV4.addTemplatePolicy(templateKey, address(spendingLimit));
        guardV4.addTemplatePolicy(templateKey, address(receiverGuard));

        // 9. Configure policies on template
        // Token whitelist: allow USDT and WBNB on templateId
        tokenWL.addToken(templateId, USDT);
        tokenWL.addToken(templateId, WBNB);

        // Spending limit: set ceiling, bind instance template, then set limits
        spendingLimit.setTemplateCeiling(
            templateKey,
            100 ether,
            500 ether,
            500
        );
        // Bind templateId instance to templateKey (M-2: ceiling lookup needs this)
        vm.prank(address(guardV4));
        spendingLimit.bindInstanceTemplate(templateId, templateKey);
        // Now set instance limits (must be <= ceiling)
        spendingLimit.setLimits(templateId, 100 ether, 500 ether, 500);

        // Fund renter
        vm.deal(renter, 100 ether);
    }

    // ═══════════════════════════════════════════════════════════
    //     1. AgentNFA V2: agentType
    // ═══════════════════════════════════════════════════════════

    function test_v3_agentType_set_on_mint() public view {
        assertEq(nfa.agentType(templateId), nfa.TYPE_DCA());
    }

    function test_v3_agentType_constants() public view {
        assertTrue(nfa.TYPE_DCA() != bytes32(0));
        assertTrue(nfa.TYPE_LLM_TRADER() != bytes32(0));
        assertTrue(nfa.TYPE_DCA() != nfa.TYPE_LLM_TRADER());
    }

    // ═══════════════════════════════════════════════════════════
    //     2. AgentNFA V2: Per-Instance Pause (Circuit Breaker)
    // ═══════════════════════════════════════════════════════════

    function test_v3_pauseAgentInstance() public {
        nfa.pauseAgentInstance(templateId);
        assertTrue(nfa.agentPaused(templateId));
    }

    function test_v3_unpauseAgentInstance() public {
        nfa.pauseAgentInstance(templateId);
        nfa.unpauseAgentInstance(templateId);
        assertFalse(nfa.agentPaused(templateId));
    }

    function test_v3_pauseAgentInstance_only_owner_or_renter() public {
        address evil = address(0xDEAD);
        vm.prank(evil);
        vm.expectRevert();
        nfa.pauseAgentInstance(templateId);
    }

    // ═══════════════════════════════════════════════════════════
    //     3. PolicyGuardV4: Template Policy Management
    // ═══════════════════════════════════════════════════════════

    function test_v3_templatePolicies_set() public view {
        address[] memory policies = guardV4.getTemplatePolicies(templateKey);
        assertEq(policies.length, 3);
        assertEq(policies[0], address(tokenWL));
        assertEq(policies[1], address(spendingLimit));
        assertEq(policies[2], address(receiverGuard));
    }

    function test_v3_unapproved_policy_rejected() public {
        address fakePolicy = address(0x9999);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyGuardV4.PolicyNotApproved.selector,
                fakePolicy
            )
        );
        guardV4.addTemplatePolicy(templateKey, fakePolicy);
    }

    function test_v3_removeTemplatePolicy() public {
        // Remove first policy (tokenWL) by index
        guardV4.removeTemplatePolicy(templateKey, 0);
        address[] memory policies = guardV4.getTemplatePolicies(templateKey);
        assertEq(policies.length, 2);
        // After swap-and-pop, first element should be receiverGuard (was last)
        assertEq(policies[0], address(receiverGuard));
    }

    // ═══════════════════════════════════════════════════════════
    //     4. TokenWhitelistPolicy
    // ═══════════════════════════════════════════════════════════

    function test_v3_tokenWhitelist_allowed_token_passes() public view {
        bytes4 selector = PolicyKeys.SWAP_EXACT_TOKENS;
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WBNB;
        bytes memory data = abi.encodeWithSelector(
            selector,
            10 ether,
            9 ether,
            path,
            owner,
            block.timestamp + 600
        );

        (bool ok, ) = tokenWL.check(
            templateId,
            owner,
            ROUTER,
            selector,
            data,
            0
        );
        assertTrue(ok);
    }

    function test_v3_tokenWhitelist_blocked_token_fails() public view {
        bytes4 selector = PolicyKeys.SWAP_EXACT_TOKENS;
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = address(0xDEAD); // Not whitelisted
        bytes memory data = abi.encodeWithSelector(
            selector,
            10 ether,
            9 ether,
            path,
            owner,
            block.timestamp + 600
        );

        (bool ok, string memory reason) = tokenWL.check(
            templateId,
            owner,
            ROUTER,
            selector,
            data,
            0
        );
        assertFalse(ok);
        assertEq(reason, "Token not in whitelist");
    }

    function test_v3_tokenWhitelist_addRemoveToken() public {
        address newToken = address(0x5555);
        tokenWL.addToken(templateId, newToken);
        assertTrue(tokenWL.tokenAllowed(templateId, newToken));

        tokenWL.removeToken(templateId, newToken);
        assertFalse(tokenWL.tokenAllowed(templateId, newToken));
    }

    // ═══════════════════════════════════════════════════════════
    //     5. SpendingLimitPolicy
    // ═══════════════════════════════════════════════════════════

    function test_v3_spendingLimit_within_limit_passes() public view {
        bytes4 selector = PolicyKeys.SWAP_EXACT_TOKENS;
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WBNB;
        // 10 ether in, 9.8 ether min out = ~2% slippage (200 bps), within 500 bps limit
        bytes memory data = abi.encodeWithSelector(
            selector,
            10 ether,
            9.8 ether,
            path,
            owner,
            block.timestamp + 600
        );

        (bool ok, ) = spendingLimit.check(
            templateId,
            owner,
            ROUTER,
            selector,
            data,
            0
        );
        assertTrue(ok);
    }

    function test_v3_spendingLimit_exceeds_per_tx_fails() public view {
        bytes4 selector = PolicyKeys.SWAP_EXACT_TOKENS;
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WBNB;
        bytes memory data = abi.encodeWithSelector(
            selector,
            10 ether,
            9.8 ether,
            path,
            owner,
            block.timestamp + 600
        );

        // Per-tx limit checks native value, pass 200 ether to exceed 100 ether limit
        (bool ok, string memory reason) = spendingLimit.check(
            templateId,
            owner,
            ROUTER,
            selector,
            data,
            200 ether
        );
        assertFalse(ok);
        assertEq(reason, "Exceeds per-tx limit");
    }

    // ═══════════════════════════════════════════════════════════
    //     6. CooldownPolicy
    // ═══════════════════════════════════════════════════════════

    function test_v3_cooldown_blocks_rapid_execution() public {
        // Warp to a reasonable timestamp so first check passes (elapsed > cooldown)
        vm.warp(1000);

        // Setup cooldown for templateId
        cooldownPolicy.setCooldown(templateId, 60); // 60 seconds

        // First check passes (lastExecution=0, elapsed=1000 > 60)
        bytes4 selector = PolicyKeys.SWAP_EXACT_TOKENS;
        (bool ok1, ) = cooldownPolicy.check(
            templateId,
            owner,
            ROUTER,
            selector,
            "",
            0
        );
        assertTrue(ok1);

        // Simulate commit from guard (update lastExecution to now=1000)
        vm.prank(address(guardV4));
        cooldownPolicy.onCommit(templateId, ROUTER, selector, "", 0);

        // Second check within cooldown should fail
        (bool ok2, string memory reason) = cooldownPolicy.check(
            templateId,
            owner,
            ROUTER,
            selector,
            "",
            0
        );
        assertFalse(ok2);
        assertEq(reason, "Cooldown active");

        // After cooldown passes, should succeed
        vm.warp(block.timestamp + 61);
        (bool ok3, ) = cooldownPolicy.check(
            templateId,
            owner,
            ROUTER,
            selector,
            "",
            0
        );
        assertTrue(ok3);
    }

    function test_v3_cooldown_onCommit_only_guard() public {
        cooldownPolicy.setCooldown(templateId, 60);

        // Non-guard caller should revert
        vm.prank(address(0xDEAD));
        vm.expectRevert(CooldownPolicy.OnlyGuard.selector);
        cooldownPolicy.onCommit(templateId, ROUTER, bytes4(0), "", 0);
    }

    // ═══════════════════════════════════════════════════════════
    //     7. ReceiverGuardPolicy
    // ═══════════════════════════════════════════════════════════

    function test_v3_receiverGuard_vault_passes() public view {
        address vault = nfa.accountOf(templateId);
        bytes4 selector = PolicyKeys.SWAP_EXACT_TOKENS;
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WBNB;
        bytes memory data = abi.encodeWithSelector(
            selector,
            10 ether,
            9 ether,
            path,
            vault,
            block.timestamp + 600
        );

        (bool ok, ) = receiverGuard.check(
            templateId,
            owner,
            ROUTER,
            selector,
            data,
            0
        );
        assertTrue(ok);
    }

    function test_v3_receiverGuard_non_vault_fails() public view {
        bytes4 selector = PolicyKeys.SWAP_EXACT_TOKENS;
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WBNB;
        bytes memory data = abi.encodeWithSelector(
            selector,
            10 ether,
            9 ether,
            path,
            renter,
            block.timestamp + 600
        );

        (bool ok, string memory reason) = receiverGuard.check(
            templateId,
            owner,
            ROUTER,
            selector,
            data,
            0
        );
        assertFalse(ok);
        assertEq(reason, "Receiver must be vault");
    }

    function test_v3_receiverGuard_not_renter_configurable() public view {
        assertFalse(receiverGuard.renterConfigurable());
    }

    // ═══════════════════════════════════════════════════════════
    //     8. DexWhitelistPolicy
    // ═══════════════════════════════════════════════════════════

    function test_v3_dexWhitelist_allowed_passes() public view {
        // No DEX whitelist configured for templateId → pass through
        (bool ok, ) = dexWL.check(templateId, owner, ROUTER, bytes4(0), "", 0);
        assertTrue(ok);
    }

    function test_v3_dexWhitelist_blocked_fails() public {
        // Add ROUTER to whitelist
        dexWL.addDex(templateId, ROUTER);

        // Unknown dex should fail
        address badRouter = address(0xBAD);
        (bool ok, string memory reason) = dexWL.check(
            templateId,
            owner,
            badRouter,
            bytes4(0),
            "",
            0
        );
        assertFalse(ok);
        assertEq(reason, "DEX not whitelisted");
    }

    function test_v3_dexWhitelist_addDex() public {
        dexWL.addDex(templateId, ROUTER);
        assertTrue(dexWL.dexAllowed(templateId, ROUTER));

        // Allowed now
        (bool ok, ) = dexWL.check(templateId, owner, ROUTER, bytes4(0), "", 0);
        assertTrue(ok);
    }

    // ═══════════════════════════════════════════════════════════
    //     9. BAP-578: Circuit Breaker default
    // ═══════════════════════════════════════════════════════════

    function test_v3_bap578_agentPaused_default() public view {
        assertFalse(nfa.agentPaused(templateId));
    }

    // ═══════════════════════════════════════════════════════════
    //     10. Policy Composability Flags
    // ═══════════════════════════════════════════════════════════

    function test_v3_renterConfigurable_flags() public view {
        assertTrue(tokenWL.renterConfigurable());
        assertTrue(spendingLimit.renterConfigurable());
        assertTrue(cooldownPolicy.renterConfigurable());
        assertTrue(dexWL.renterConfigurable());
        assertFalse(receiverGuard.renterConfigurable()); // Owner-only
    }

    function test_v3_policyType_unique() public view {
        bytes32 t1 = tokenWL.policyType();
        bytes32 t2 = spendingLimit.policyType();
        bytes32 t3 = cooldownPolicy.policyType();
        bytes32 t4 = receiverGuard.policyType();
        bytes32 t5 = dexWL.policyType();

        // All should be unique
        assertTrue(t1 != t2);
        assertTrue(t1 != t3);
        assertTrue(t1 != t4);
        assertTrue(t1 != t5);
        assertTrue(t2 != t3);
    }

    // ═══════════════════════════════════════════════════════════
    //     11. ICommittable detection via ERC-165
    // ═══════════════════════════════════════════════════════════

    function test_v3_committable_detection() public view {
        // SpendingLimit and Cooldown implement ICommittable
        bytes4 committableId = type(ICommittable).interfaceId;
        assertTrue(spendingLimit.supportsInterface(committableId));
        assertTrue(cooldownPolicy.supportsInterface(committableId));
    }

    // Allow this contract to receive ERC721
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // Allow this contract to receive ETH
    receive() external payable {}
}
