// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {AgentAccount} from "../src/AgentAccount.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {PolicyGuardV2} from "../src/PolicyGuardV2.sol";
import {PolicyRegistry} from "../src/PolicyRegistry.sol";
import {GroupRegistry} from "../src/GroupRegistry.sol";
import {InstanceConfig} from "../src/InstanceConfig.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";
import {Action} from "../src/types/Action.sol";

contract V1_4_IntegrationTest is Test {
    AgentNFA public nfa;
    ListingManager public listingManager;
    PolicyGuardV2 public guardV2;
    PolicyRegistry public registry;
    GroupRegistry public groupRegistry;
    InstanceConfig public config;

    address public owner = address(0x1);
    address public renter = address(0x2);
    address public attacker = address(0x9);
    address public router = address(0x3);
    address public usdt = address(0x4);
    address public wbnb = address(0x5);
    address public unauthorizedRouter = address(0x6);

    uint32 public policyId = 1;
    uint16 public version = 1;
    uint32 public tokenGroupId = 100;
    uint32 public dexGroupId = 200;

    bytes32 public listingId;
    uint256 public instanceId;

    function setUp() public {
        vm.startPrank(owner);

        // 1. Deploy Infrastructure
        registry = new PolicyRegistry();
        groupRegistry = new GroupRegistry();
        config = new InstanceConfig();

        guardV2 = new PolicyGuardV2(
            address(registry),
            address(groupRegistry),
            address(config)
        );

        nfa = new AgentNFA(address(guardV2));
        listingManager = new ListingManager();
        nfa.setListingManager(address(listingManager));
        config.setMinter(address(listingManager));
        config.setPolicyRegistry(address(registry));
        listingManager.setInstanceConfig(address(config));

        // H-1 fix: Set AgentNFA as allowed caller for commit
        guardV2.setAllowedCaller(address(nfa));

        // 2. Setup Policy Registry
        PolicyRegistry.ParamSchema memory schema = PolicyRegistry.ParamSchema({
            maxSlippageBps: 1000,
            maxTradeLimit: 1000 ether,
            maxDailyLimit: 2000 ether,
            allowedTokenGroups: new uint32[](1),
            allowedDexGroups: new uint32[](1),
            receiverMustBeVault: true,
            forbidInfiniteApprove: true
        });
        schema.allowedTokenGroups[0] = tokenGroupId;
        schema.allowedDexGroups[0] = dexGroupId;

        registry.createPolicy(policyId, version, schema, 7); // Modules: 1|2|4 = 7

        // Allow Swap on Router
        registry.setActionRule(
            policyId,
            version,
            router,
            PolicyKeys.SWAP_EXACT_TOKENS,
            5
        ); // Swap + SpendLimit
        // Allow Approve on USDT
        registry.setActionRule(policyId, version, usdt, PolicyKeys.APPROVE, 2); // ApproveGuard

        // 3. Setup Group Registry
        groupRegistry.setGroupMember(tokenGroupId, usdt, true);
        groupRegistry.setGroupMember(tokenGroupId, wbnb, true);
        groupRegistry.setGroupMember(dexGroupId, router, true);

        // 4. Create Template Agent and List it
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

        // 5. Rent Instance with specific params
        vm.deal(renter, 100 ether);
        vm.startPrank(renter);

        InstanceConfig.InstanceParams memory params = InstanceConfig
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
    //          EXISTING: HAPPY PATH / BASIC ENFORCEMENT
    // ═══════════════════════════════════════════════════════════

    function test_v1_4_validation_success() public {
        address account = nfa.accountOf(instanceId);

        vm.startPrank(renter);

        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = wbnb;
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            5 ether,
            4.8 ether,
            path,
            account,
            block.timestamp + 600
        );
        Action memory action = Action(router, 0, data);
        vm.mockCall(router, data, abi.encode(new uint256[](2)));

        nfa.execute(instanceId, action);

        uint32 dayIndex = uint32(block.timestamp / 1 days);
        assertEq(guardV2.dailySpent(instanceId, dayIndex), 5 ether);

        vm.stopPrank();
    }

    function test_v1_4_validation_exceed_trade_limit() public {
        address account = nfa.accountOf(instanceId);

        vm.startPrank(renter);

        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = wbnb;
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            11 ether,
            10.5 ether,
            path,
            account,
            block.timestamp + 600
        );
        Action memory action = Action(router, 0, data);

        vm.expectRevert();
        nfa.execute(instanceId, action);

        vm.stopPrank();
    }

    function test_v1_4_validation_exceed_daily_limit() public {
        address account = nfa.accountOf(instanceId);

        vm.startPrank(renter);

        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = wbnb;

        // First trade: 8 ether (passes)
        bytes memory data1 = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            8 ether,
            7.5 ether,
            path,
            account,
            block.timestamp + 600
        );
        vm.mockCall(router, data1, abi.encode(new uint256[](2)));
        nfa.execute(instanceId, Action(router, 0, data1));

        // Second trade: 8 ether (8 + 8 = 16 > 15 dailyLimit)
        bytes memory data2 = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            8 ether,
            7.5 ether,
            path,
            account,
            block.timestamp + 600
        );
        vm.mockCall(router, data2, abi.encode(new uint256[](2)));

        vm.expectRevert();
        nfa.execute(instanceId, Action(router, 0, data2));

        vm.stopPrank();
    }

    function test_v1_4_validation_token_not_allowed() public {
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
        Action memory action = Action(router, 0, data);

        vm.expectRevert();
        nfa.execute(instanceId, action);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: POLICY FREEZE TESTS
    // ═══════════════════════════════════════════════════════════

    function test_v1_4_freeze_policy_prevents_modification() public {
        vm.startPrank(owner);
        registry.freezePolicy(policyId, version);

        // Attempt to set a new action rule should revert
        vm.expectRevert(PolicyRegistry.PolicyAlreadyFrozen.selector);
        registry.setActionRule(
            policyId,
            version,
            address(0x99),
            PolicyKeys.APPROVE,
            2
        );

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: APPROVE GUARD TESTS
    // ═══════════════════════════════════════════════════════════

    function test_v1_4_approve_infinite_forbidden() public {
        vm.startPrank(renter);

        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            router, // spender (in dexGroup)
            type(uint256).max // infinite approve
        );
        Action memory action = Action(usdt, 0, data);

        vm.expectRevert();
        nfa.execute(instanceId, action);

        vm.stopPrank();
    }

    function test_v1_4_approve_exceeds_trade_limit() public {
        vm.startPrank(renter);

        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            router, // spender
            11 ether // > 10 ether tradeLimit
        );
        Action memory action = Action(usdt, 0, data);

        vm.expectRevert();
        nfa.execute(instanceId, action);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: ROUTER NOT IN DEX GROUP (M-2 fix)
    // ═══════════════════════════════════════════════════════════

    function test_v1_4_swap_router_not_in_dex_group() public {
        address account = nfa.accountOf(instanceId);

        // Register action rule for unauthorized router too
        vm.prank(owner);
        registry.setActionRule(
            policyId,
            version,
            unauthorizedRouter,
            PolicyKeys.SWAP_EXACT_TOKENS,
            5
        );

        vm.startPrank(renter);

        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = wbnb;
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            5 ether,
            4.5 ether,
            path,
            account,
            block.timestamp + 600
        );
        // Use unauthorized router (not in dexGroup)
        Action memory action = Action(unauthorizedRouter, 0, data);

        vm.expectRevert();
        nfa.execute(instanceId, action);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: RECEIVER NOT VAULT
    // ═══════════════════════════════════════════════════════════

    function test_v1_4_swap_receiver_not_vault() public {
        vm.startPrank(renter);

        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = wbnb;
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            5 ether,
            4.5 ether,
            path,
            address(0xBEEF), // Not the vault
            block.timestamp + 600
        );
        Action memory action = Action(router, 0, data);

        vm.expectRevert();
        nfa.execute(instanceId, action);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: SAME TEMPLATE, TWO INSTANCES, DIFFERENT PARAMS
    // ═══════════════════════════════════════════════════════════

    function test_v1_4_two_instances_different_limits() public {
        // Mint second instance with LOWER tradeLimit (5 ether vs 10 ether)
        address renter2 = address(0x7);
        vm.deal(renter2, 100 ether);
        vm.startPrank(renter2);

        InstanceConfig.InstanceParams memory params2 = InstanceConfig
            .InstanceParams({
                slippageBps: 100,
                tradeLimit: 5 ether, // Lower limit
                dailyLimit: 8 ether,
                tokenGroupId: tokenGroupId,
                dexGroupId: dexGroupId,
                riskTier: 2
            });
        bytes memory paramsPacked2 = abi.encode(params2);

        uint256 instanceId2 = listingManager.rentToMintWithParams{
            value: 1 ether
        }(listingId, 1, policyId, version, paramsPacked2);
        vm.stopPrank();

        // Instance 1: 7 ether swap should succeed (tradeLimit = 10)
        address account1 = nfa.accountOf(instanceId);
        vm.startPrank(renter);
        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = wbnb;
        bytes memory data1 = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            7 ether,
            6.5 ether,
            path,
            account1,
            block.timestamp + 600
        );
        vm.mockCall(router, data1, abi.encode(new uint256[](2)));
        nfa.execute(instanceId, Action(router, 0, data1));
        vm.stopPrank();

        // Instance 2: 7 ether swap should FAIL (tradeLimit = 5)
        address account2 = nfa.accountOf(instanceId2);
        vm.startPrank(renter2);
        bytes memory data2 = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            7 ether,
            6.5 ether,
            path,
            account2,
            block.timestamp + 600
        );
        vm.expectRevert();
        nfa.execute(instanceId2, Action(router, 0, data2));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: COMMIT ACCESS CONTROL (H-1 fix)
    // ═══════════════════════════════════════════════════════════

    function test_v1_4_commit_rejected_from_unauthorized() public {
        // Attacker tries to call commit directly to inflate dailySpent
        vm.startPrank(attacker);

        address account = nfa.accountOf(instanceId);
        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = wbnb;
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            10 ether,
            9 ether,
            path,
            account,
            block.timestamp + 600
        );
        Action memory action = Action(router, 0, data);

        // Call commit directly — should be no-op (not revert, just skip)
        guardV2.commit(instanceId, action);

        // Verify dailySpent was NOT updated
        uint32 dayIndex = uint32(block.timestamp / 1 days);
        assertEq(guardV2.dailySpent(instanceId, dayIndex), 0);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: BIND CONFIG DUPLICATE PROTECTION
    // ═══════════════════════════════════════════════════════════

    function test_v1_4_bind_config_already_bound() public {
        // Try to bind config again to the same instance
        vm.startPrank(address(listingManager));

        InstanceConfig.InstanceParams memory params = InstanceConfig
            .InstanceParams({
                slippageBps: 500,
                tradeLimit: 20 ether,
                dailyLimit: 30 ether,
                tokenGroupId: tokenGroupId,
                dexGroupId: dexGroupId,
                riskTier: 3
            });
        bytes memory paramsPacked = abi.encode(params);

        vm.expectRevert(InstanceConfig.AlreadyBound.selector);
        config.bindConfig(instanceId, policyId, version, paramsPacked);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: GLOBAL BLOCKLIST
    // ═══════════════════════════════════════════════════════════

    function test_v1_4_global_blocklist() public {
        address account = nfa.accountOf(instanceId);

        // Owner blocks the router
        vm.prank(owner);
        guardV2.setTargetBlocked(router, true);

        // Renter tries swap — should fail even though params are valid
        vm.startPrank(renter);
        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = wbnb;
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            5 ether,
            4.5 ether,
            path,
            account,
            block.timestamp + 600
        );
        Action memory action = Action(router, 0, data);

        vm.expectRevert();
        nfa.execute(instanceId, action);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: CROSS-DAY DAILY LIMIT RESET
    // ═══════════════════════════════════════════════════════════

    function test_v1_4_daily_limit_resets_next_day() public {
        address account = nfa.accountOf(instanceId);
        vm.startPrank(renter);

        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = wbnb;

        // Day 1: Spend 14 ether (under 15 limit)
        bytes memory data1 = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            9 ether,
            8.5 ether,
            path,
            account,
            block.timestamp + 600
        );
        vm.mockCall(router, data1, abi.encode(new uint256[](2)));
        nfa.execute(instanceId, Action(router, 0, data1));

        bytes memory data2 = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            5 ether,
            4.5 ether,
            path,
            account,
            block.timestamp + 600
        );
        vm.mockCall(router, data2, abi.encode(new uint256[](2)));
        nfa.execute(instanceId, Action(router, 0, data2));

        uint32 dayIndex1 = uint32(block.timestamp / 1 days);
        assertEq(guardV2.dailySpent(instanceId, dayIndex1), 14 ether);

        // Warp to next day
        vm.warp(block.timestamp + 1 days);

        // Day 2: Should be able to spend again (fresh day)
        bytes memory data3 = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            10 ether,
            9.5 ether,
            path,
            account,
            block.timestamp + 600
        );
        vm.mockCall(router, data3, abi.encode(new uint256[](2)));
        nfa.execute(instanceId, Action(router, 0, data3));

        uint32 dayIndex2 = uint32(block.timestamp / 1 days);
        assertEq(guardV2.dailySpent(instanceId, dayIndex2), 10 ether);
        // Day 1 spent is still 14
        assertEq(guardV2.dailySpent(instanceId, dayIndex1), 14 ether);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          NEW: P0 — SCHEMA BOUNDARY VIOLATION TESTS
    // ═══════════════════════════════════════════════════════════

    function test_v1_4_bind_slippage_exceeds_schema() public {
        // Mint a second instance with slippageBps > schema.maxSlippageBps (1000)
        address renter3 = address(0x8);
        vm.deal(renter3, 100 ether);
        vm.startPrank(renter3);

        InstanceConfig.InstanceParams memory badParams = InstanceConfig
            .InstanceParams({
                slippageBps: 2000, // > 1000 schema max
                tradeLimit: 10 ether,
                dailyLimit: 15 ether,
                tokenGroupId: tokenGroupId,
                dexGroupId: dexGroupId,
                riskTier: 1
            });
        bytes memory paramsPacked2 = abi.encode(badParams);

        vm.expectRevert(InstanceConfig.SlippageExceedsSchema.selector);
        listingManager.rentToMintWithParams{value: 1 ether}(
            listingId,
            1,
            policyId,
            version,
            paramsPacked2
        );

        vm.stopPrank();
    }

    function test_v1_4_bind_daily_limit_exceeds_schema() public {
        address renter3 = address(0x8);
        vm.deal(renter3, 100 ether);
        vm.startPrank(renter3);

        InstanceConfig.InstanceParams memory badParams = InstanceConfig
            .InstanceParams({
                slippageBps: 200,
                tradeLimit: 10 ether,
                dailyLimit: 3000 ether, // > 2000 ether schema max
                tokenGroupId: tokenGroupId,
                dexGroupId: dexGroupId,
                riskTier: 1
            });
        bytes memory paramsPacked2 = abi.encode(badParams);

        vm.expectRevert(InstanceConfig.DailyLimitExceedsSchema.selector);
        listingManager.rentToMintWithParams{value: 1 ether}(
            listingId,
            1,
            policyId,
            version,
            paramsPacked2
        );

        vm.stopPrank();
    }

    function test_v1_4_bind_token_group_not_allowed() public {
        address renter3 = address(0x8);
        vm.deal(renter3, 100 ether);
        vm.startPrank(renter3);

        InstanceConfig.InstanceParams memory badParams = InstanceConfig
            .InstanceParams({
                slippageBps: 200,
                tradeLimit: 10 ether,
                dailyLimit: 15 ether,
                tokenGroupId: 999, // Not in schema.allowedTokenGroups
                dexGroupId: dexGroupId,
                riskTier: 1
            });
        bytes memory paramsPacked2 = abi.encode(badParams);

        vm.expectRevert(InstanceConfig.TokenGroupNotAllowed.selector);
        listingManager.rentToMintWithParams{value: 1 ether}(
            listingId,
            1,
            policyId,
            version,
            paramsPacked2
        );

        vm.stopPrank();
    }
}
