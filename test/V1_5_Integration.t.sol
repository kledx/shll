// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {AgentAccount} from "../src/AgentAccount.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {PolicyGuardV3} from "../src/PolicyGuardV3.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";
import {Action} from "../src/types/Action.sol";

/**
 * @title V1_5_IntegrationTest
 * @notice Integration tests for PolicyGuardV3 (merged firewall).
 *         Covers: regression (all V1.4 scenarios), mutable params,
 *         token bitmap, and execution modes (STRICT/MANUAL/EXPLORER).
 */
contract V1_5_IntegrationTest is Test {
    PolicyGuardV3 public guard;
    AgentNFA public nfa;
    ListingManager public listingManager;

    address public owner = address(0x1);
    address public renter = address(0x2);
    address public attacker = address(0x9);
    address public router = address(0x3);
    address public usdt = address(0x4);
    address public wbnb = address(0x5);
    address public unauthorizedRouter = address(0x6);
    address public operator = address(0xA);

    uint32 public policyId = 1;
    uint16 public version = 1;
    uint32 public tokenGroupId = 100;
    uint32 public dexGroupId = 200;

    bytes32 public listingId;
    uint256 public instanceId;

    function setUp() public {
        vm.startPrank(owner);

        // 1. Deploy PolicyGuardV3 (replaces PolicyRegistry + GroupRegistry + InstanceConfig + PolicyGuardV2)
        guard = new PolicyGuardV3();

        // 2. Deploy AgentNFA with V3 as the guard
        nfa = new AgentNFA(address(guard));

        // 3. Deploy ListingManager, wire V3 as instanceConfig
        listingManager = new ListingManager();
        nfa.setListingManager(address(listingManager));
        listingManager.setInstanceConfig(address(guard));

        // 4. Wire access control
        guard.setAllowedCaller(address(nfa));
        guard.setMinter(address(listingManager));

        // 5. Setup policy with V1.5 schema fields
        uint32[] memory tokenGroups = new uint32[](1);
        tokenGroups[0] = tokenGroupId;
        uint32[] memory dexGroups = new uint32[](1);
        dexGroups[0] = dexGroupId;

        PolicyGuardV3.ParamSchema memory schema = PolicyGuardV3.ParamSchema({
            maxSlippageBps: 1000,
            maxTradeLimit: 1000 ether,
            maxDailyLimit: 2000 ether,
            allowedTokenGroups: tokenGroups,
            allowedDexGroups: dexGroups,
            receiverMustBeVault: true,
            forbidInfiniteApprove: true,
            // V1.5 additions
            allowExplorerMode: true,
            explorerMaxTradeLimit: 5 ether,
            explorerMaxDailyLimit: 10 ether,
            allowParamsUpdate: true
        });

        guard.createPolicy(policyId, version, schema, 7); // Modules: 1|2|4 = 7

        // 6. Action rules (inline — no more separate PolicyRegistry)
        guard.setActionRule(
            policyId,
            version,
            router,
            PolicyKeys.SWAP_EXACT_TOKENS,
            5
        ); // Swap + SpendLimit
        guard.setActionRule(policyId, version, usdt, PolicyKeys.APPROVE, 2); // ApproveGuard

        // 7. Group members (inline — no more separate GroupRegistry)
        guard.setGroupMember(tokenGroupId, usdt, true);
        guard.setGroupMember(tokenGroupId, wbnb, true);
        guard.setGroupMember(dexGroupId, router, true);

        // 8. Create template agent and listing
        IBAP578.AgentMetadata memory meta = IBAP578.AgentMetadata({
            persona: "Agent",
            experience: "AI",
            voiceHash: "v1",
            animationURI: "ipfs://anim",
            vaultURI: "ipfs://vault",
            vaultHash: bytes32(0)
        });
        uint256 templateId = nfa.mintAgent(
            owner,
            bytes32(0),
            bytes32(0), // agentType (V3.0)
            "ipfs://template",
            meta
        );
        nfa.registerTemplate(templateId, bytes32("pack"), "ipfs://pack");
        listingManager.createTemplateListing(
            address(nfa),
            templateId,
            1 ether,
            1
        );
        listingId = listingManager.getListingId(address(nfa), templateId);

        vm.stopPrank();

        // 9. Rent instance with specific params
        vm.deal(renter, 100 ether);
        vm.startPrank(renter);

        PolicyGuardV3.InstanceParams memory params = PolicyGuardV3
            .InstanceParams({
                slippageBps: 200,
                tradeLimit: 10 ether,
                dailyLimit: 15 ether,
                tokenGroupId: tokenGroupId,
                dexGroupId: dexGroupId,
                riskTier: 1
            });
        bytes memory paramsPacked = abi.encode(params);

        instanceId = listingManager.rentToMintWithParams{value: 1 ether}(
            listingId,
            1,
            policyId,
            version,
            paramsPacked
        );

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          REGRESSION: V1.4 SCENARIOS ON V3
    // ═══════════════════════════════════════════════════════════

    function test_v1_5_swap_success() public {
        address account = nfa.accountOf(instanceId);
        vm.startPrank(renter);

        bytes memory data = _encodeSwap(5 ether, 4.8 ether, account);
        vm.mockCall(router, data, abi.encode(new uint256[](2)));
        nfa.execute(instanceId, Action(router, 0, data));

        uint32 dayIndex = uint32(block.timestamp / 1 days);
        assertEq(guard.dailySpent(instanceId, dayIndex), 5 ether);
        vm.stopPrank();
    }

    function test_v1_5_exceed_trade_limit() public {
        address account = nfa.accountOf(instanceId);
        vm.startPrank(renter);

        bytes memory data = _encodeSwap(11 ether, 10.5 ether, account);
        vm.expectRevert();
        nfa.execute(instanceId, Action(router, 0, data));
        vm.stopPrank();
    }

    function test_v1_5_exceed_daily_limit() public {
        address account = nfa.accountOf(instanceId);
        vm.startPrank(renter);

        // First trade: 8 ether
        bytes memory data1 = _encodeSwap(8 ether, 7.5 ether, account);
        vm.mockCall(router, data1, abi.encode(new uint256[](2)));
        nfa.execute(instanceId, Action(router, 0, data1));

        // Second trade: 8 ether => 16 > 15 dailyLimit
        bytes memory data2 = _encodeSwap(8 ether, 7.5 ether, account);
        vm.mockCall(router, data2, abi.encode(new uint256[](2)));
        vm.expectRevert();
        nfa.execute(instanceId, Action(router, 0, data2));
        vm.stopPrank();
    }

    function test_v1_5_token_not_allowed() public {
        address account = nfa.accountOf(instanceId);
        vm.startPrank(renter);

        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = address(0xDEAD); // Not in group
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            5 ether,
            4.5 ether,
            path,
            account,
            block.timestamp + 600
        );
        vm.expectRevert();
        nfa.execute(instanceId, Action(router, 0, data));
        vm.stopPrank();
    }

    function test_v1_5_swap_router_not_in_dex_group() public {
        address account = nfa.accountOf(instanceId);

        vm.prank(owner);
        guard.setActionRule(
            policyId,
            version,
            unauthorizedRouter,
            PolicyKeys.SWAP_EXACT_TOKENS,
            5
        );

        vm.startPrank(renter);
        bytes memory data = _encodeSwap(5 ether, 4.5 ether, account);
        vm.expectRevert();
        nfa.execute(instanceId, Action(unauthorizedRouter, 0, data));
        vm.stopPrank();
    }

    function test_v1_5_swap_receiver_not_vault() public {
        vm.startPrank(renter);
        bytes memory data = _encodeSwap(5 ether, 4.5 ether, address(0xBEEF));
        vm.expectRevert();
        nfa.execute(instanceId, Action(router, 0, data));
        vm.stopPrank();
    }

    function test_v1_5_approve_infinite_forbidden() public {
        vm.startPrank(renter);
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            router,
            type(uint256).max
        );
        vm.expectRevert();
        nfa.execute(instanceId, Action(usdt, 0, data));
        vm.stopPrank();
    }

    function test_v1_5_approve_exceeds_trade_limit() public {
        vm.startPrank(renter);
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            router,
            11 ether
        );
        vm.expectRevert();
        nfa.execute(instanceId, Action(usdt, 0, data));
        vm.stopPrank();
    }

    function test_v1_5_global_blocklist() public {
        address account = nfa.accountOf(instanceId);
        vm.prank(owner);
        guard.setTargetBlocked(router, true);

        vm.startPrank(renter);
        bytes memory data = _encodeSwap(5 ether, 4.5 ether, account);
        vm.expectRevert();
        nfa.execute(instanceId, Action(router, 0, data));
        vm.stopPrank();
    }

    function test_v1_5_commit_rejected_from_unauthorized() public {
        vm.startPrank(attacker);
        address account = nfa.accountOf(instanceId);
        bytes memory data = _encodeSwap(10 ether, 9 ether, account);
        vm.expectRevert("Unauthorized: not allowedCaller");
        guard.commit(instanceId, Action(router, 0, data));
        vm.stopPrank();
    }

    function test_v1_5_daily_limit_resets_next_day() public {
        address account = nfa.accountOf(instanceId);
        vm.startPrank(renter);

        bytes memory data1 = _encodeSwap(9 ether, 8.5 ether, account);
        vm.mockCall(router, data1, abi.encode(new uint256[](2)));
        nfa.execute(instanceId, Action(router, 0, data1));

        bytes memory data2 = _encodeSwap(5 ether, 4.5 ether, account);
        vm.mockCall(router, data2, abi.encode(new uint256[](2)));
        nfa.execute(instanceId, Action(router, 0, data2));

        uint32 dayIndex1 = uint32(block.timestamp / 1 days);
        assertEq(guard.dailySpent(instanceId, dayIndex1), 14 ether);

        vm.warp(block.timestamp + 1 days);

        bytes memory data3 = _encodeSwap(10 ether, 9.5 ether, account);
        vm.mockCall(router, data3, abi.encode(new uint256[](2)));
        nfa.execute(instanceId, Action(router, 0, data3));

        uint32 dayIndex2 = uint32(block.timestamp / 1 days);
        assertEq(guard.dailySpent(instanceId, dayIndex2), 10 ether);
        assertEq(guard.dailySpent(instanceId, dayIndex1), 14 ether);
        vm.stopPrank();
    }

    function test_v1_5_freeze_policy_prevents_modification() public {
        vm.startPrank(owner);
        guard.freezePolicy(policyId, version);
        vm.expectRevert(PolicyGuardV3.PolicyAlreadyFrozen.selector);
        guard.setActionRule(
            policyId,
            version,
            address(0x99),
            PolicyKeys.APPROVE,
            2
        );
        vm.stopPrank();
    }

    function test_v1_5_bind_already_bound() public {
        vm.startPrank(address(listingManager));
        PolicyGuardV3.InstanceParams memory p = PolicyGuardV3.InstanceParams({
            slippageBps: 200,
            tradeLimit: 10 ether,
            dailyLimit: 15 ether,
            tokenGroupId: tokenGroupId,
            dexGroupId: dexGroupId,
            riskTier: 1
        });
        vm.expectRevert(PolicyGuardV3.AlreadyBound.selector);
        guard.bindConfig(instanceId, policyId, version, abi.encode(p));
        vm.stopPrank();
    }

    function test_v1_5_bind_slippage_exceeds_schema() public {
        address r3 = address(0x8);
        vm.deal(r3, 100 ether);
        vm.startPrank(r3);

        PolicyGuardV3.InstanceParams memory badParams = PolicyGuardV3
            .InstanceParams({
                slippageBps: 2000,
                tradeLimit: 10 ether,
                dailyLimit: 15 ether,
                tokenGroupId: tokenGroupId,
                dexGroupId: dexGroupId,
                riskTier: 1
            });
        vm.expectRevert(PolicyGuardV3.SlippageExceedsSchema.selector);
        listingManager.rentToMintWithParams{value: 1 ether}(
            listingId,
            1,
            policyId,
            version,
            abi.encode(badParams)
        );
        vm.stopPrank();
    }

    function test_v1_5_two_instances_different_limits() public {
        address renter2 = address(0x7);
        vm.deal(renter2, 100 ether);
        vm.startPrank(renter2);

        PolicyGuardV3.InstanceParams memory params2 = PolicyGuardV3
            .InstanceParams({
                slippageBps: 100,
                tradeLimit: 5 ether,
                dailyLimit: 8 ether,
                tokenGroupId: tokenGroupId,
                dexGroupId: dexGroupId,
                riskTier: 2
            });
        uint256 instanceId2 = listingManager.rentToMintWithParams{
            value: 1 ether
        }(listingId, 1, policyId, version, abi.encode(params2));
        vm.stopPrank();

        // Instance 1: 7 ether should succeed (tradeLimit = 10)
        address account1 = nfa.accountOf(instanceId);
        vm.startPrank(renter);
        bytes memory data1 = _encodeSwap(7 ether, 6.5 ether, account1);
        vm.mockCall(router, data1, abi.encode(new uint256[](2)));
        nfa.execute(instanceId, Action(router, 0, data1));
        vm.stopPrank();

        // Instance 2: 7 ether should FAIL (tradeLimit = 5)
        address account2 = nfa.accountOf(instanceId2);
        vm.startPrank(renter2);
        bytes memory data2 = _encodeSwap(7 ether, 6.5 ether, account2);
        vm.expectRevert();
        nfa.execute(instanceId2, Action(router, 0, data2));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: MUTABLE PARAMS (updateParams)
    // ═══════════════════════════════════════════════════════════

    function test_v1_5_update_params_success() public {
        vm.startPrank(renter);

        PolicyGuardV3.InstanceParams memory newParams = PolicyGuardV3
            .InstanceParams({
                slippageBps: 300,
                tradeLimit: 8 ether, // Lower
                dailyLimit: 12 ether, // Lower
                tokenGroupId: tokenGroupId,
                dexGroupId: dexGroupId,
                riskTier: 1
            });
        guard.updateParams(instanceId, abi.encode(newParams));

        assertEq(guard.paramsVersion(instanceId), 2);

        // Verify new limit: 9 ether > 8 ether tradeLimit should fail
        address account = nfa.accountOf(instanceId);
        bytes memory data = _encodeSwap(9 ether, 8.5 ether, account);
        vm.expectRevert();
        nfa.execute(instanceId, Action(router, 0, data));

        vm.stopPrank();
    }

    function test_v1_5_update_params_exceeds_schema_reverts() public {
        vm.startPrank(renter);

        PolicyGuardV3.InstanceParams memory badParams = PolicyGuardV3
            .InstanceParams({
                slippageBps: 2000, // Exceeds schema max 1000
                tradeLimit: 10 ether,
                dailyLimit: 15 ether,
                tokenGroupId: tokenGroupId,
                dexGroupId: dexGroupId,
                riskTier: 1
            });
        vm.expectRevert(PolicyGuardV3.SlippageExceedsSchema.selector);
        guard.updateParams(instanceId, abi.encode(badParams));

        vm.stopPrank();
    }

    function test_v1_5_update_params_only_renter() public {
        vm.startPrank(attacker);

        PolicyGuardV3.InstanceParams memory newParams = PolicyGuardV3
            .InstanceParams({
                slippageBps: 300,
                tradeLimit: 8 ether,
                dailyLimit: 12 ether,
                tokenGroupId: tokenGroupId,
                dexGroupId: dexGroupId,
                riskTier: 1
            });
        vm.expectRevert(PolicyGuardV3.OnlyRenter.selector);
        guard.updateParams(instanceId, abi.encode(newParams));

        vm.stopPrank();
    }

    function test_v1_5_update_params_not_allowed_by_policy() public {
        // Create a policy that disallows param updates
        vm.startPrank(owner);
        uint32 lockedPolicyId = 2;

        uint32[] memory tg = new uint32[](1);
        tg[0] = tokenGroupId;
        uint32[] memory dg = new uint32[](1);
        dg[0] = dexGroupId;

        PolicyGuardV3.ParamSchema memory lockedSchema = PolicyGuardV3
            .ParamSchema({
                maxSlippageBps: 1000,
                maxTradeLimit: 1000 ether,
                maxDailyLimit: 2000 ether,
                allowedTokenGroups: tg,
                allowedDexGroups: dg,
                receiverMustBeVault: true,
                forbidInfiniteApprove: true,
                allowExplorerMode: false,
                explorerMaxTradeLimit: 0,
                explorerMaxDailyLimit: 0,
                allowParamsUpdate: false // <-- locked
            });
        guard.createPolicy(lockedPolicyId, version, lockedSchema, 7);
        guard.setActionRule(
            lockedPolicyId,
            version,
            router,
            PolicyKeys.SWAP_EXACT_TOKENS,
            5
        );
        vm.stopPrank();

        // Mint instance with locked policy
        address renter3 = address(0xB);
        vm.deal(renter3, 100 ether);
        vm.startPrank(renter3);
        PolicyGuardV3.InstanceParams memory p = PolicyGuardV3.InstanceParams({
            slippageBps: 200,
            tradeLimit: 10 ether,
            dailyLimit: 15 ether,
            tokenGroupId: tokenGroupId,
            dexGroupId: dexGroupId,
            riskTier: 1
        });
        uint256 lockedInstance = listingManager.rentToMintWithParams{
            value: 1 ether
        }(listingId, 1, lockedPolicyId, version, abi.encode(p));

        // Try update — should fail
        vm.expectRevert(PolicyGuardV3.ParamsUpdateNotAllowed.selector);
        guard.updateParams(lockedInstance, abi.encode(p));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: TOKEN PERMISSION BITMAP
    // ═══════════════════════════════════════════════════════════

    function test_v1_5_grant_and_revoke_permission() public {
        vm.startPrank(owner);
        guard.setSchemaAllowedBits(policyId, version, 0xFF);
        vm.stopPrank();

        vm.startPrank(renter);
        guard.grantTokenPermission(instanceId, 0x01);
        assertEq(guard.tokenPermissions(instanceId), 0x01);

        guard.grantTokenPermission(instanceId, 0x02);
        assertEq(guard.tokenPermissions(instanceId), 0x03);

        guard.revokeTokenPermission(instanceId, 0x01);
        assertEq(guard.tokenPermissions(instanceId), 0x02);
        vm.stopPrank();
    }

    function test_v1_5_grant_bit_not_allowed_by_schema() public {
        // Schema allows no bits by default (schemaAllowedBits = 0)
        vm.startPrank(renter);
        vm.expectRevert(PolicyGuardV3.BitNotAllowed.selector);
        guard.grantTokenPermission(instanceId, 0x01);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: EXECUTION MODES
    // ═══════════════════════════════════════════════════════════

    function test_v1_5_strict_mode_default() public {
        // Default mode is STRICT
        assertEq(
            uint256(guard.executionMode(instanceId)),
            uint256(PolicyGuardV3.ExecutionMode.STRICT)
        );
    }

    function test_v1_5_explorer_mode_uses_lower_limits() public {
        vm.startPrank(renter);

        // First: lower instance params to fit explorer limits
        PolicyGuardV3.InstanceParams memory newParams = PolicyGuardV3
            .InstanceParams({
                slippageBps: 200,
                tradeLimit: 5 ether, // <= explorerMaxTradeLimit (5 ether)
                dailyLimit: 10 ether, // <= explorerMaxDailyLimit (10 ether)
                tokenGroupId: tokenGroupId,
                dexGroupId: dexGroupId,
                riskTier: 1
            });
        guard.updateParams(instanceId, abi.encode(newParams));

        // Switch to EXPLORER mode
        guard.setExecutionMode(
            instanceId,
            PolicyGuardV3.ExecutionMode.EXPLORER
        );
        assertEq(
            uint256(guard.executionMode(instanceId)),
            uint256(PolicyGuardV3.ExecutionMode.EXPLORER)
        );
        vm.stopPrank();

        // Now test: 6 ether should fail (explorerMaxTradeLimit = 5 ether)
        address account = nfa.accountOf(instanceId);
        vm.startPrank(renter);
        bytes memory data = _encodeSwap(6 ether, 5.5 ether, account);
        vm.expectRevert();
        nfa.execute(instanceId, Action(router, 0, data));
        vm.stopPrank();
    }

    function test_v1_5_explorer_mode_not_allowed() public {
        // Create policy without explorer mode
        vm.startPrank(owner);
        uint32 noExplorerPolicy = 3;
        uint32[] memory tg = new uint32[](1);
        tg[0] = tokenGroupId;
        uint32[] memory dg = new uint32[](1);
        dg[0] = dexGroupId;

        PolicyGuardV3.ParamSchema memory s = PolicyGuardV3.ParamSchema({
            maxSlippageBps: 1000,
            maxTradeLimit: 1000 ether,
            maxDailyLimit: 2000 ether,
            allowedTokenGroups: tg,
            allowedDexGroups: dg,
            receiverMustBeVault: true,
            forbidInfiniteApprove: true,
            allowExplorerMode: false, // <-- no explorer
            explorerMaxTradeLimit: 0,
            explorerMaxDailyLimit: 0,
            allowParamsUpdate: true
        });
        guard.createPolicy(noExplorerPolicy, version, s, 7);
        guard.setActionRule(
            noExplorerPolicy,
            version,
            router,
            PolicyKeys.SWAP_EXACT_TOKENS,
            5
        );
        vm.stopPrank();

        // Mint instance with no-explorer policy
        address r4 = address(0xC);
        vm.deal(r4, 100 ether);
        vm.startPrank(r4);
        PolicyGuardV3.InstanceParams memory p = PolicyGuardV3.InstanceParams({
            slippageBps: 200,
            tradeLimit: 10 ether,
            dailyLimit: 15 ether,
            tokenGroupId: tokenGroupId,
            dexGroupId: dexGroupId,
            riskTier: 1
        });
        uint256 noExpInstance = listingManager.rentToMintWithParams{
            value: 1 ether
        }(listingId, 1, noExplorerPolicy, version, abi.encode(p));

        // Try to switch to EXPLORER — should fail
        vm.expectRevert(PolicyGuardV3.ExplorerNotAllowed.selector);
        guard.setExecutionMode(
            noExpInstance,
            PolicyGuardV3.ExecutionMode.EXPLORER
        );
        vm.stopPrank();
    }

    function test_v1_5_manual_mode_skips_token_group() public {
        // Must explicitly set MANUAL mode first
        vm.prank(renter);
        guard.setExecutionMode(instanceId, PolicyGuardV3.ExecutionMode.MANUAL);

        address account = nfa.accountOf(instanceId);
        vm.startPrank(renter);

        // Use a token NOT in the group — should succeed in MANUAL mode
        address[] memory path = new address[](2);
        path[0] = address(0xDEAD); // Not in tokenGroup
        path[1] = wbnb;
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            5 ether,
            4.5 ether,
            path,
            account,
            block.timestamp + 600
        );
        vm.mockCall(router, data, abi.encode(new uint256[](2)));

        // Should succeed — MANUAL mode skips token group
        nfa.execute(instanceId, Action(router, 0, data));
        vm.stopPrank();
    }

    function test_v1_5_manual_mode_still_enforces_receiver_vault() public {
        // Must explicitly set MANUAL mode
        vm.prank(renter);
        guard.setExecutionMode(instanceId, PolicyGuardV3.ExecutionMode.MANUAL);

        vm.startPrank(renter);

        // Even in MANUAL mode, receiver must be vault
        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = wbnb;
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            5 ether,
            4.5 ether,
            path,
            address(0xBEEF),
            block.timestamp + 600
        );
        vm.expectRevert();
        nfa.execute(instanceId, Action(router, 0, data));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: BATCH GROUP MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    function test_v1_5_batch_set_group_members() public {
        vm.startPrank(owner);
        address[] memory members = new address[](3);
        members[0] = address(0x10);
        members[1] = address(0x11);
        members[2] = address(0x12);

        guard.setGroupMembers(tokenGroupId, members, true);
        assertTrue(guard.isInGroup(tokenGroupId, address(0x10)));
        assertTrue(guard.isInGroup(tokenGroupId, address(0x11)));
        assertTrue(guard.isInGroup(tokenGroupId, address(0x12)));

        guard.setGroupMembers(tokenGroupId, members, false);
        assertFalse(guard.isInGroup(tokenGroupId, address(0x10)));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //             HELPERS
    // ═══════════════════════════════════════════════════════════

    function _encodeSwap(
        uint256 amountIn,
        uint256 amountOutMin,
        address to
    ) internal view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = wbnb;
        return
            abi.encodeWithSelector(
                PolicyKeys.SWAP_EXACT_TOKENS,
                amountIn,
                amountOutMin,
                path,
                to,
                block.timestamp + 600
            );
    }
}
