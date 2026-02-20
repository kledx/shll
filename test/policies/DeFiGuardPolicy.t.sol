// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeFiGuardPolicy} from "../../src/policies/DeFiGuardPolicy.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title DeFiGuardPolicy Tests — 3-layer DeFi security validation
contract DeFiGuardPolicyTest is Test {
    DeFiGuardPolicy public policy;

    // Mock contracts
    address constant GUARD = address(0xAAAA);
    address constant NFA = address(0xBBBB);
    address constant CALLER = address(0xCCCC);
    address constant RENTER = address(0x7777);
    address constant OWNER = address(0x1);

    // DeFi targets
    address constant PANCAKE_ROUTER = address(0xD99D);
    address constant BISWAP_ROUTER = address(0xB15A);
    address constant EVIL_CONTRACT = address(0xDEAD);

    uint256 constant INSTANCE_ID = 42;

    // Common selectors
    bytes4 constant SWAP_EXACT_ETH = 0x7ff36ab5;
    bytes4 constant SWAP_EXACT_TOKENS = 0x38ed1739;
    bytes4 constant APPROVE = 0x095ea7b3;
    bytes4 constant TRANSFER = 0xa9059cbb;
    bytes4 constant UNKNOWN_SELECTOR = 0xdeadbeef;

    function setUp() public {
        // Deploy mock guard with OWNER as Ownable owner
        vm.prank(OWNER);
        MockGuard mockGuard = new MockGuard();

        // Mock NFA for userOf() calls
        vm.mockCall(
            NFA,
            abi.encodeWithSignature("userOf(uint256)", INSTANCE_ID),
            abi.encode(RENTER)
        );

        // Deploy policy
        policy = new DeFiGuardPolicy(address(mockGuard), NFA);

        // Configure defaults as owner
        vm.startPrank(OWNER);
        policy.addGlobalTarget(PANCAKE_ROUTER);
        policy.addSelector(SWAP_EXACT_ETH);
        policy.addSelector(SWAP_EXACT_TOKENS);
        policy.addSelector(APPROVE);
        policy.addSelector(TRANSFER);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    //            LAYER 3: Global Whitelist Tests
    // ═══════════════════════════════════════════════════════

    function test_globalWhitelisted_passes() public view {
        (bool ok, string memory reason) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_ROUTER,
            SWAP_EXACT_ETH,
            "",
            1 ether
        );
        assertTrue(ok, "Global whitelisted target should pass");
        assertEq(reason, "");
    }

    function test_nonWhitelisted_fails() public view {
        (bool ok, string memory reason) = policy.check(
            INSTANCE_ID,
            CALLER,
            BISWAP_ROUTER,
            SWAP_EXACT_TOKENS,
            "",
            0
        );
        assertFalse(ok, "Non-whitelisted target should fail");
        assertEq(reason, "Target not in whitelist");
    }

    function test_ownerCanAddGlobalTarget() public {
        vm.prank(OWNER);
        policy.addGlobalTarget(BISWAP_ROUTER);

        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            BISWAP_ROUTER,
            SWAP_EXACT_TOKENS,
            "",
            0
        );
        assertTrue(ok, "Newly added global target should pass");
    }

    function test_ownerCanRemoveGlobalTarget() public {
        vm.prank(OWNER);
        policy.removeGlobalTarget(PANCAKE_ROUTER);

        // After removing all targets, whitelist is unconfigured -> fail-close
        (bool ok, string memory reason) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_ROUTER,
            SWAP_EXACT_ETH,
            "",
            1 ether
        );
        assertFalse(ok, "Empty whitelist should reject");
        assertEq(reason, "Target whitelist not configured");
    }

    function test_removeGlobalTarget_nonWhitelisted_rejected() public view {
        // With 1 global target, non-whitelisted should still be rejected
        (bool ok, string memory reason) = policy.check(
            INSTANCE_ID,
            CALLER,
            BISWAP_ROUTER,
            SWAP_EXACT_TOKENS,
            "",
            0
        );
        assertFalse(
            ok,
            "Non-whitelisted target should fail when whitelist is active"
        );
        assertEq(reason, "Target not in whitelist");
    }

    function test_getGlobalTargets_returnsAll() public view {
        address[] memory targets = policy.getGlobalTargets();
        assertEq(targets.length, 1);
        assertEq(targets[0], PANCAKE_ROUTER);
    }

    // ═══════════════════════════════════════════════════════
    //            LAYER 1: Blacklist Tests
    // ═══════════════════════════════════════════════════════

    function test_blacklisted_rejected() public {
        // Add to both global whitelist AND blacklist — blacklist wins
        vm.startPrank(OWNER);
        policy.addGlobalTarget(EVIL_CONTRACT);
        policy.addBlacklist(EVIL_CONTRACT);
        vm.stopPrank();

        (bool ok, string memory reason) = policy.check(
            INSTANCE_ID,
            CALLER,
            EVIL_CONTRACT,
            SWAP_EXACT_ETH,
            "",
            0
        );
        assertFalse(ok, "Blacklisted target should be rejected");
        assertEq(reason, "Target is blacklisted");
    }

    function test_blacklist_overrides_globalWhitelist() public {
        // Blacklist PancakeSwap Router — should override global whitelist
        vm.prank(OWNER);
        policy.addBlacklist(PANCAKE_ROUTER);

        (bool ok, string memory reason) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_ROUTER,
            SWAP_EXACT_ETH,
            "",
            1 ether
        );
        assertFalse(
            ok,
            "Blacklisted target should be rejected even if globally whitelisted"
        );
        assertEq(reason, "Target is blacklisted");
    }

    function test_blacklist_overrides_instanceWhitelist() public {
        // Renter adds target, then owner blacklists it
        vm.prank(RENTER);
        policy.addInstanceTarget(INSTANCE_ID, BISWAP_ROUTER);

        vm.prank(OWNER);
        policy.addBlacklist(BISWAP_ROUTER);

        (bool ok, string memory reason) = policy.check(
            INSTANCE_ID,
            CALLER,
            BISWAP_ROUTER,
            SWAP_EXACT_TOKENS,
            "",
            0
        );
        assertFalse(ok, "Blacklist should override instance whitelist");
        assertEq(reason, "Target is blacklisted");
    }

    function test_ownerCanRemoveBlacklist() public {
        vm.startPrank(OWNER);
        policy.addBlacklist(PANCAKE_ROUTER);
        policy.removeBlacklist(PANCAKE_ROUTER);
        vm.stopPrank();

        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_ROUTER,
            SWAP_EXACT_ETH,
            "",
            1 ether
        );
        assertTrue(ok, "Removed from blacklist should work again");
    }

    function test_getBlacklist_returnsAll() public {
        vm.startPrank(OWNER);
        policy.addBlacklist(EVIL_CONTRACT);
        vm.stopPrank();

        address[] memory list = policy.getBlacklist();
        assertEq(list.length, 1);
        assertEq(list[0], EVIL_CONTRACT);
    }

    // ═══════════════════════════════════════════════════════
    //            LAYER 2: Selector Validation Tests
    // ═══════════════════════════════════════════════════════

    function test_unknownSelector_rejected() public view {
        (bool ok, string memory reason) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_ROUTER,
            UNKNOWN_SELECTOR,
            "",
            0
        );
        assertFalse(ok, "Unknown selector should be rejected");
        assertEq(reason, "Function not allowed");
    }

    function test_zeroSelector_rejected_unless_explicitly_whitelisted() public view {
        (bool ok, string memory reason) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_ROUTER,
            bytes4(0),
            "",
            1 ether
        );
        assertFalse(ok, "Zero selector should be rejected by default");
        assertEq(reason, "Function not allowed");
    }

    function test_ownerCanAddSelector() public {
        bytes4 newSelector = 0x12345678;
        vm.prank(OWNER);
        policy.addSelector(newSelector);

        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_ROUTER,
            newSelector,
            "",
            0
        );
        assertTrue(ok, "Newly added selector should pass");
    }

    function test_ownerCanRemoveSelector() public {
        vm.prank(OWNER);
        policy.removeSelector(SWAP_EXACT_ETH);

        (bool ok, string memory reason) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_ROUTER,
            SWAP_EXACT_ETH,
            "",
            1 ether
        );
        assertFalse(ok, "Removed selector should fail");
        assertEq(reason, "Function not allowed");
    }

    function test_noSelectors_rejectsAll() public {
        // Remove all selectors — should reject any function
        vm.startPrank(OWNER);
        policy.removeSelector(SWAP_EXACT_ETH);
        policy.removeSelector(SWAP_EXACT_TOKENS);
        policy.removeSelector(APPROVE);
        policy.removeSelector(TRANSFER);
        vm.stopPrank();

        (bool ok, string memory reason) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_ROUTER,
            UNKNOWN_SELECTOR,
            "",
            0
        );
        assertFalse(ok, "No selectors configured should reject all");
        assertEq(reason, "Selector whitelist not configured");
    }

    function test_getAllowedSelectors_returnsAll() public view {
        bytes4[] memory selectors = policy.getAllowedSelectors();
        assertEq(selectors.length, 4);
    }

    // ═══════════════════════════════════════════════════════
    //         RENTER: Per-Instance Whitelist Tests
    // ═══════════════════════════════════════════════════════

    function test_renterCanAddInstanceTarget() public {
        vm.prank(RENTER);
        policy.addInstanceTarget(INSTANCE_ID, BISWAP_ROUTER);

        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            BISWAP_ROUTER,
            SWAP_EXACT_TOKENS,
            "",
            0
        );
        assertTrue(ok, "Renter-added instance target should pass");
    }

    function test_renterCanRemoveInstanceTarget() public {
        vm.prank(RENTER);
        policy.addInstanceTarget(INSTANCE_ID, BISWAP_ROUTER);

        vm.prank(RENTER);
        policy.removeInstanceTarget(INSTANCE_ID, BISWAP_ROUTER);

        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            BISWAP_ROUTER,
            SWAP_EXACT_TOKENS,
            "",
            0
        );
        assertFalse(ok, "Removed instance target should fail");
    }

    function test_instanceTarget_doesNotAffectOtherInstances() public {
        vm.prank(RENTER);
        policy.addInstanceTarget(INSTANCE_ID, BISWAP_ROUTER);

        // Different instance should not have BISWAP_ROUTER
        uint256 otherInstance = 99;
        (bool ok, ) = policy.check(
            otherInstance,
            CALLER,
            BISWAP_ROUTER,
            SWAP_EXACT_TOKENS,
            "",
            0
        );
        assertFalse(ok, "Instance target should not leak to other instances");
    }

    function test_renterCannotAddBlacklistedTarget() public {
        vm.prank(OWNER);
        policy.addBlacklist(EVIL_CONTRACT);

        vm.prank(RENTER);
        vm.expectRevert(DeFiGuardPolicy.TargetBlacklisted.selector);
        policy.addInstanceTarget(INSTANCE_ID, EVIL_CONTRACT);
    }

    function test_ownerCanAddInstanceTarget() public {
        vm.prank(OWNER);
        policy.addInstanceTarget(INSTANCE_ID, BISWAP_ROUTER);

        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            BISWAP_ROUTER,
            SWAP_EXACT_TOKENS,
            "",
            0
        );
        assertTrue(ok, "Owner-added instance target should pass");
    }

    function test_getInstanceTargets_returnsAll() public {
        vm.startPrank(RENTER);
        policy.addInstanceTarget(INSTANCE_ID, BISWAP_ROUTER);
        vm.stopPrank();

        address[] memory targets = policy.getInstanceTargets(INSTANCE_ID);
        assertEq(targets.length, 1);
        assertEq(targets[0], BISWAP_ROUTER);
    }

    // ═══════════════════════════════════════════════════════
    //              Empty Config Tests
    // ═══════════════════════════════════════════════════════

    function test_noWhitelists_rejectsAll() public {
        // Remove global whitelist (instance whitelist is empty by default)
        vm.prank(OWNER);
        policy.removeGlobalTarget(PANCAKE_ROUTER);

        // Selectors remain configured, so failure reason should come from whitelist layer
        (bool ok, string memory reason) = policy.check(
            INSTANCE_ID,
            CALLER,
            BISWAP_ROUTER,
            SWAP_EXACT_TOKENS,
            "",
            0
        );
        assertFalse(ok, "No whitelists configured should reject all targets");
        assertEq(reason, "Target whitelist not configured");
    }

    // ═══════════════════════════════════════════════════════
    //              Access Control Tests
    // ═══════════════════════════════════════════════════════

    function test_nonOwnerCannotAddGlobalTarget() public {
        vm.prank(RENTER);
        vm.expectRevert(DeFiGuardPolicy.OnlyOwner.selector);
        policy.addGlobalTarget(BISWAP_ROUTER);
    }

    function test_nonOwnerCannotAddBlacklist() public {
        vm.prank(RENTER);
        vm.expectRevert(DeFiGuardPolicy.OnlyOwner.selector);
        policy.addBlacklist(EVIL_CONTRACT);
    }

    function test_nonOwnerCannotAddSelector() public {
        vm.prank(RENTER);
        vm.expectRevert(DeFiGuardPolicy.OnlyOwner.selector);
        policy.addSelector(0x12345678);
    }

    function test_nonRenterCannotAddInstanceTarget() public {
        address stranger = address(0xFAFAFA);
        vm.prank(stranger);
        vm.expectRevert(DeFiGuardPolicy.NotRenterOrOwner.selector);
        policy.addInstanceTarget(INSTANCE_ID, BISWAP_ROUTER);
    }

    // ═══════════════════════════════════════════════════════
    //              Duplicate / Not Found Tests
    // ═══════════════════════════════════════════════════════

    function test_cannotAddDuplicateGlobalTarget() public {
        vm.prank(OWNER);
        vm.expectRevert(DeFiGuardPolicy.AlreadyAdded.selector);
        policy.addGlobalTarget(PANCAKE_ROUTER);
    }

    function test_cannotRemoveNonexistentGlobalTarget() public {
        vm.prank(OWNER);
        vm.expectRevert(DeFiGuardPolicy.NotFound.selector);
        policy.removeGlobalTarget(BISWAP_ROUTER);
    }

    function test_cannotAddDuplicateInstanceTarget() public {
        vm.prank(RENTER);
        policy.addInstanceTarget(INSTANCE_ID, BISWAP_ROUTER);

        vm.prank(RENTER);
        vm.expectRevert(DeFiGuardPolicy.AlreadyAdded.selector);
        policy.addInstanceTarget(INSTANCE_ID, BISWAP_ROUTER);
    }

    // ═══════════════════════════════════════════════════════
    //              IPolicy Metadata Tests
    // ═══════════════════════════════════════════════════════

    function test_policyType() public view {
        assertEq(policy.policyType(), keccak256("defi_guard"));
    }

    function test_renterConfigurable() public view {
        assertTrue(policy.renterConfigurable());
    }
}

/// @dev Minimal mock guard that delegates Ownable.owner() to the deployer
contract MockGuard is Ownable {
    constructor() {}
}
