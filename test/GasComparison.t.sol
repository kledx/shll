// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {ListingManager} from "../src/ListingManager.sol";

// V1.4 stack
import {PolicyGuardV2} from "../src/PolicyGuardV2.sol";
import {PolicyRegistry} from "../src/PolicyRegistry.sol";
import {GroupRegistry} from "../src/GroupRegistry.sol";
import {InstanceConfig} from "../src/InstanceConfig.sol";

// V1.5 merged
import {PolicyGuardV3} from "../src/PolicyGuardV3.sol";

import {IBAP578} from "../src/interfaces/IBAP578.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";
import {Action} from "../src/types/Action.sol";

/**
 * @title GasComparison
 * @notice Measures gas cost of validate() for V2 (4-contract) vs V3 (merged).
 *         Run with: forge test --match-contract GasComparison -vvv --gas-report
 */
contract GasComparisonTest is Test {
    // ─── V2 stack ───
    PolicyGuardV2 public guardV2;
    PolicyRegistry public registry;
    GroupRegistry public groupRegistry;
    InstanceConfig public config;
    AgentNFA public nfaV2;
    ListingManager public lmV2;

    // ─── V3 stack ───
    PolicyGuardV3 public guardV3;
    AgentNFA public nfaV3;
    ListingManager public lmV3;

    // ─── Shared ───
    address public owner = address(0x1);
    address public renter = address(0x2);
    address public router = address(0x3);
    address public usdt = address(0x4);
    address public wbnb = address(0x5);

    uint32 public policyId = 1;
    uint16 public version = 1;
    uint32 public tokenGroupId = 100;
    uint32 public dexGroupId = 200;

    uint256 public instanceV2;
    uint256 public instanceV3;

    function setUp() public {
        vm.startPrank(owner);

        // ──────── Deploy V2 stack ────────
        registry = new PolicyRegistry();
        groupRegistry = new GroupRegistry();
        config = new InstanceConfig();
        guardV2 = new PolicyGuardV2(
            address(registry),
            address(groupRegistry),
            address(config)
        );
        nfaV2 = new AgentNFA(address(guardV2));
        lmV2 = new ListingManager();
        nfaV2.setListingManager(address(lmV2));
        config.setMinter(address(lmV2));
        config.setPolicyRegistry(address(registry));
        lmV2.setInstanceConfig(address(config));
        guardV2.setAllowedCaller(address(nfaV2));

        // V2 policy
        PolicyRegistry.ParamSchema memory schemaV2 = PolicyRegistry
            .ParamSchema({
                maxSlippageBps: 1000,
                maxTradeLimit: 1000 ether,
                maxDailyLimit: 2000 ether,
                allowedTokenGroups: new uint32[](1),
                allowedDexGroups: new uint32[](1),
                receiverMustBeVault: true,
                forbidInfiniteApprove: true
            });
        schemaV2.allowedTokenGroups[0] = tokenGroupId;
        schemaV2.allowedDexGroups[0] = dexGroupId;
        registry.createPolicy(policyId, version, schemaV2, 7);
        registry.setActionRule(
            policyId,
            version,
            router,
            PolicyKeys.SWAP_EXACT_TOKENS,
            5
        );
        groupRegistry.setGroupMember(tokenGroupId, usdt, true);
        groupRegistry.setGroupMember(tokenGroupId, wbnb, true);
        groupRegistry.setGroupMember(dexGroupId, router, true);

        // ──────── Deploy V3 stack ────────
        guardV3 = new PolicyGuardV3();
        nfaV3 = new AgentNFA(address(guardV3));
        lmV3 = new ListingManager();
        nfaV3.setListingManager(address(lmV3));
        lmV3.setInstanceConfig(address(guardV3));
        guardV3.setAllowedCaller(address(nfaV3));
        guardV3.setMinter(address(lmV3));

        // V3 policy
        uint32[] memory tg = new uint32[](1);
        tg[0] = tokenGroupId;
        uint32[] memory dg = new uint32[](1);
        dg[0] = dexGroupId;
        PolicyGuardV3.ParamSchema memory schemaV3 = PolicyGuardV3.ParamSchema({
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
            allowParamsUpdate: false
        });
        guardV3.createPolicy(policyId, version, schemaV3, 7);
        guardV3.setActionRule(
            policyId,
            version,
            router,
            PolicyKeys.SWAP_EXACT_TOKENS,
            5
        );
        guardV3.setGroupMember(tokenGroupId, usdt, true);
        guardV3.setGroupMember(tokenGroupId, wbnb, true);
        guardV3.setGroupMember(dexGroupId, router, true);

        // ──────── Template + Listing (shared metadata) ────────
        IBAP578.AgentMetadata memory meta = IBAP578.AgentMetadata({
            persona: "Agent",
            experience: "AI",
            voiceHash: "v1",
            animationURI: "ipfs://a",
            vaultURI: "ipfs://v",
            vaultHash: bytes32(0)
        });

        // V2 template
        uint256 tplV2 = nfaV2.mintAgent(owner, bytes32(0), "ipfs://t", meta);
        nfaV2.registerTemplate(tplV2, bytes32("p"), "ipfs://p");
        lmV2.createTemplateListing(address(nfaV2), tplV2, 1 ether, 1);
        bytes32 lidV2 = lmV2.getListingId(address(nfaV2), tplV2);

        // V3 template
        uint256 tplV3 = nfaV3.mintAgent(owner, bytes32(0), "ipfs://t", meta);
        nfaV3.registerTemplate(tplV3, bytes32("p"), "ipfs://p");
        lmV3.createTemplateListing(address(nfaV3), tplV3, 1 ether, 1);
        bytes32 lidV3 = lmV3.getListingId(address(nfaV3), tplV3);

        vm.stopPrank();

        // ──────── Rent instances ────────
        vm.deal(renter, 200 ether);
        vm.startPrank(renter);

        InstanceConfig.InstanceParams memory pV2 = InstanceConfig
            .InstanceParams({
                slippageBps: 200,
                tradeLimit: 10 ether,
                dailyLimit: 15 ether,
                tokenGroupId: tokenGroupId,
                dexGroupId: dexGroupId,
                riskTier: 1
            });
        instanceV2 = lmV2.rentToMintWithParams{value: 1 ether}(
            lidV2,
            1,
            policyId,
            version,
            abi.encode(pV2)
        );

        PolicyGuardV3.InstanceParams memory pV3 = PolicyGuardV3.InstanceParams({
            slippageBps: 200,
            tradeLimit: 10 ether,
            dailyLimit: 15 ether,
            tokenGroupId: tokenGroupId,
            dexGroupId: dexGroupId,
            riskTier: 1
        });
        instanceV3 = lmV3.rentToMintWithParams{value: 1 ether}(
            lidV3,
            1,
            policyId,
            version,
            abi.encode(pV3)
        );

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //          GAS MEASUREMENT: V2 vs V3 — SWAP VALIDATE+EXECUTE
    // ═══════════════════════════════════════════════════════════

    function test_gas_v2_swap_execute() public {
        address account = nfaV2.accountOf(instanceV2);
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

        vm.mockCall(router, data, abi.encode(new uint256[](2)));
        vm.prank(renter);

        uint256 gasBefore = gasleft();
        nfaV2.execute(instanceV2, Action(router, 0, data));
        uint256 gasUsed = gasBefore - gasleft();

        console.log("V2 swap execute gas:", gasUsed);
    }

    function test_gas_v3_swap_execute() public {
        address account = nfaV3.accountOf(instanceV3);
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

        vm.mockCall(router, data, abi.encode(new uint256[](2)));
        vm.prank(renter);

        uint256 gasBefore = gasleft();
        nfaV3.execute(instanceV3, Action(router, 0, data));
        uint256 gasUsed = gasBefore - gasleft();

        console.log("V3 swap execute gas:", gasUsed);
    }

    // ═══════════════════════════════════════════════════════════
    //          GAS MEASUREMENT: V2 vs V3 — APPROVE VALIDATE+EXECUTE
    // ═══════════════════════════════════════════════════════════

    function test_gas_v2_approve_execute() public {
        vm.startPrank(owner);
        registry.setActionRule(policyId, version, usdt, PolicyKeys.APPROVE, 2);
        vm.stopPrank();

        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            router,
            5 ether
        );
        vm.mockCall(usdt, data, abi.encode(true));
        vm.prank(renter);

        uint256 gasBefore = gasleft();
        nfaV2.execute(instanceV2, Action(usdt, 0, data));
        uint256 gasUsed = gasBefore - gasleft();

        console.log("V2 approve execute gas:", gasUsed);
    }

    function test_gas_v3_approve_execute() public {
        vm.startPrank(owner);
        guardV3.setActionRule(policyId, version, usdt, PolicyKeys.APPROVE, 2);
        vm.stopPrank();

        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            router,
            5 ether
        );
        vm.mockCall(usdt, data, abi.encode(true));
        vm.prank(renter);

        uint256 gasBefore = gasleft();
        nfaV3.execute(instanceV3, Action(usdt, 0, data));
        uint256 gasUsed = gasBefore - gasleft();

        console.log("V3 approve execute gas:", gasUsed);
    }
}
