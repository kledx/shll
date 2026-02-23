// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {AgentAccount} from "../src/AgentAccount.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";
import {ListingManagerV2} from "../src/ListingManagerV2.sol";
import {SubscriptionManager} from "../src/SubscriptionManager.sol";
import {ISubscriptionManager} from "../src/interfaces/ISubscriptionManager.sol";
import {Errors} from "../src/libs/Errors.sol";
import {Action} from "../src/types/Action.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";
import {DexWhitelistPolicy} from "../src/policies/DexWhitelistPolicy.sol";

/// @title Subscription Test Suite
/// @notice Full lifecycle tests for SubscriptionManager + ListingManagerV2
contract SubscriptionTest is Test {
    AgentNFA public nfa;
    PolicyGuardV4 public guard;
    ListingManagerV2 public listing;
    SubscriptionManager public subManager;
    DexWhitelistPolicy public dexWL;

    address owner = address(this);
    address renter = address(0xBEEF);
    address evil = address(0xDEAD);

    uint256 templateId;
    bytes32 listingId;

    IBAP578.AgentMetadata emptyMetadata;

    function setUp() public {
        emptyMetadata = IBAP578.AgentMetadata({
            persona: "",
            experience: "",
            voiceHash: "",
            animationURI: "",
            vaultURI: "",
            vaultHash: bytes32(0)
        });

        // Deploy contracts
        guard = new PolicyGuardV4();
        nfa = new AgentNFA(address(guard));
        listing = new ListingManagerV2();
        subManager = new SubscriptionManager();
        dexWL = new DexWhitelistPolicy(address(guard), address(nfa));

        // Wire up
        nfa.setListingManager(address(listing));
        guard.setAgentNFA(address(nfa));
        guard.setListingManager(address(listing));
        listing.setPolicyGuard(address(guard));
        listing.setAgentNFA(address(nfa));
        listing.setSubscriptionManager(address(subManager));
        subManager.setListingManager(address(listing));
        subManager.setAgentNFA(address(nfa));

        // Mint template
        templateId = nfa.mintAgent(
            owner,
            bytes32("default"),
            nfa.TYPE_LLM_TRADER(),
            "ipfs://template",
            emptyMetadata
        );
        nfa.registerTemplate(templateId, bytes32("default-template"));
        guard.approvePolicyContract(address(dexWL));
        guard.addTemplatePolicy(bytes32("default-template"), address(dexWL));

        // Create listing
        listingId = listing.createTemplateListing(
            address(nfa),
            templateId,
            0.1 ether,
            1
        );

        // Fund renter
        vm.deal(renter, 100 ether);
    }

    // ═══════════════════════════════════════════════════════════
    //              HELPER: Rent an instance
    // ═══════════════════════════════════════════════════════════

    function _rentInstance(
        uint32 daysToRent
    ) internal returns (uint256 instanceId) {
        uint256 cost = uint256(0.1 ether) * uint256(daysToRent);
        vm.prank(renter);
        instanceId = listing.rentToMintWithParams{value: cost}(
            listingId,
            daysToRent,
            0,
            0,
            ""
        );
    }

    // ═══════════════════════════════════════════════════════════
    //              1. CREATE ON RENT
    // ═══════════════════════════════════════════════════════════

    function test_subscription_createOnRent() public {
        uint256 instanceId = _rentInstance(7);

        ISubscriptionManager.Subscription memory sub = subManager
            .getSubscription(instanceId);
        assertEq(sub.subscriber, renter);
        assertEq(sub.periodDays, 7);
        assertEq(uint256(sub.pricePerPeriod), 0.7 ether); // 0.1 * 7
        assertTrue(sub.currentPeriodEnd > block.timestamp);
        assertTrue(sub.gracePeriodEnd > sub.currentPeriodEnd);

        ISubscriptionManager.SubscriptionStatus status = subManager
            .getEffectiveStatus(instanceId);
        assertTrue(status == ISubscriptionManager.SubscriptionStatus.Active);
    }

    // ═══════════════════════════════════════════════════════════
    //              2. ACTIVE CAN EXECUTE
    // ═══════════════════════════════════════════════════════════

    function test_subscription_activeCanExecute() public {
        uint256 instanceId = _rentInstance(7);

        assertTrue(subManager.canExecute(instanceId));
        assertTrue(subManager.canWithdraw(instanceId));
    }

    // ═══════════════════════════════════════════════════════════
    //              3. GRACE PERIOD TRANSITION
    // ═══════════════════════════════════════════════════════════

    function test_subscription_gracePeriodTransition() public {
        uint256 instanceId = _rentInstance(7);

        // Fast forward past period end
        vm.warp(block.timestamp + 8 days);

        ISubscriptionManager.SubscriptionStatus status = subManager
            .getEffectiveStatus(instanceId);
        assertTrue(
            status == ISubscriptionManager.SubscriptionStatus.GracePeriod
        );
    }

    // ═══════════════════════════════════════════════════════════
    //              4. GRACE PERIOD CANNOT EXECUTE
    // ═══════════════════════════════════════════════════════════

    function test_subscription_gracePeriodCannotExecute() public {
        uint256 instanceId = _rentInstance(7);

        vm.warp(block.timestamp + 8 days); // Into grace period

        assertFalse(subManager.canExecute(instanceId));
    }

    // ═══════════════════════════════════════════════════════════
    //              5. GRACE PERIOD CAN WITHDRAW
    // ═══════════════════════════════════════════════════════════

    function test_subscription_gracePeriodCanWithdraw() public {
        uint256 instanceId = _rentInstance(7);

        vm.warp(block.timestamp + 8 days);

        assertTrue(subManager.canWithdraw(instanceId));
    }

    // ═══════════════════════════════════════════════════════════
    //              6. GRACE PERIOD RENEW → ACTIVE
    // ═══════════════════════════════════════════════════════════

    function test_subscription_gracePeriodRenew() public {
        uint256 instanceId = _rentInstance(7);

        vm.warp(block.timestamp + 8 days);
        assertTrue(
            subManager.getEffectiveStatus(instanceId) ==
                ISubscriptionManager.SubscriptionStatus.GracePeriod
        );

        // Renew
        vm.prank(renter);
        subManager.renewSubscription{value: 0.7 ether}(instanceId);

        assertTrue(
            subManager.getEffectiveStatus(instanceId) ==
                ISubscriptionManager.SubscriptionStatus.Active
        );
        assertTrue(subManager.canExecute(instanceId));
    }

    // ═══════════════════════════════════════════════════════════
    //              7. EXPIRED TRANSITION
    // ═══════════════════════════════════════════════════════════

    function test_subscription_expiredTransition() public {
        uint256 instanceId = _rentInstance(7);

        // Past grace period (7 day period + 7 day default grace)
        vm.warp(block.timestamp + 15 days);

        ISubscriptionManager.SubscriptionStatus status = subManager
            .getEffectiveStatus(instanceId);
        assertTrue(status == ISubscriptionManager.SubscriptionStatus.Expired);
        assertFalse(subManager.canExecute(instanceId));
    }

    // ═══════════════════════════════════════════════════════════
    //              8. EXPIRED RENEW WITHIN 30 DAYS
    // ═══════════════════════════════════════════════════════════

    function test_subscription_expiredRenewWithin30Days() public {
        uint256 instanceId = _rentInstance(7);

        // Past grace period but within 30-day renewal window
        vm.warp(block.timestamp + 20 days); // 7 period + 7 grace + 6 into expired

        assertTrue(
            subManager.getEffectiveStatus(instanceId) ==
                ISubscriptionManager.SubscriptionStatus.Expired
        );

        vm.prank(renter);
        subManager.renewSubscription{value: 0.7 ether}(instanceId);

        assertTrue(
            subManager.getEffectiveStatus(instanceId) ==
                ISubscriptionManager.SubscriptionStatus.Active
        );
    }

    // ═══════════════════════════════════════════════════════════
    //              9. EXPIRED BEYOND 30 DAYS CANNOT RENEW
    // ═══════════════════════════════════════════════════════════

    function test_subscription_expiredRenewBeyond30Days() public {
        uint256 instanceId = _rentInstance(7);

        // Past 30-day renewal window: 7 period + 7 grace + 31 expired
        vm.warp(block.timestamp + 45 days);

        assertTrue(
            subManager.getEffectiveStatus(instanceId) ==
                ISubscriptionManager.SubscriptionStatus.Expired
        );

        vm.prank(renter);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.SubscriptionExpiredBeyondRenewal.selector,
                instanceId
            )
        );
        subManager.renewSubscription{value: 0.7 ether}(instanceId);
    }

    // ═══════════════════════════════════════════════════════════
    //              10. CANCEL SUBSCRIPTION
    // ═══════════════════════════════════════════════════════════

    function test_subscription_cancelSubscription() public {
        uint256 instanceId = _rentInstance(7);

        vm.prank(renter);
        subManager.cancelSubscription(instanceId);

        assertTrue(
            subManager.getEffectiveStatus(instanceId) ==
                ISubscriptionManager.SubscriptionStatus.Canceled
        );
        assertFalse(subManager.canExecute(instanceId));
    }

    // ═══════════════════════════════════════════════════════════
    //              11. ONLY SUBSCRIBER CAN RENEW
    // ═══════════════════════════════════════════════════════════

    function test_subscription_onlySubscriberCanRenew() public {
        uint256 instanceId = _rentInstance(7);

        vm.warp(block.timestamp + 8 days);

        vm.deal(evil, 1 ether);
        vm.prank(evil);
        vm.expectRevert(Errors.OnlySubscriber.selector);
        subManager.renewSubscription{value: 0.7 ether}(instanceId);
    }

    // ═══════════════════════════════════════════════════════════
    //              12. ONLY SUBSCRIBER CAN CANCEL
    // ═══════════════════════════════════════════════════════════

    function test_subscription_onlySubscriberCanCancel() public {
        uint256 instanceId = _rentInstance(7);

        vm.prank(evil);
        vm.expectRevert(Errors.OnlySubscriber.selector);
        subManager.cancelSubscription(instanceId);
    }

    // ═══════════════════════════════════════════════════════════
    //              13. INSUFFICIENT PAYMENT
    // ═══════════════════════════════════════════════════════════

    function test_subscription_insufficientPayment() public {
        uint256 instanceId = _rentInstance(7);

        vm.warp(block.timestamp + 8 days);

        vm.prank(renter);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InsufficientPayment.selector,
                0.7 ether,
                0.1 ether
            )
        );
        subManager.renewSubscription{value: 0.1 ether}(instanceId);
    }

    // ═══════════════════════════════════════════════════════════
    //              14. CONFIGURABLE GRACE PERIOD
    // ═══════════════════════════════════════════════════════════

    function test_subscription_configurableGracePeriod() public {
        // Set 14-day grace period for this listing
        listing.setListingConfig(listingId, 0, 14);

        uint256 instanceId = _rentInstance(7);

        ISubscriptionManager.Subscription memory sub = subManager
            .getSubscription(instanceId);
        assertEq(sub.gracePeriodDays, 14);
        assertEq(sub.gracePeriodEnd, sub.currentPeriodEnd + 14 days);

        // At day 8, should be in grace period
        vm.warp(block.timestamp + 8 days);
        assertTrue(
            subManager.getEffectiveStatus(instanceId) ==
                ISubscriptionManager.SubscriptionStatus.GracePeriod
        );

        // At day 20, still grace period (14 day grace)
        vm.warp(block.timestamp + 12 days); // total = 20 days
        assertTrue(
            subManager.getEffectiveStatus(instanceId) ==
                ISubscriptionManager.SubscriptionStatus.GracePeriod
        );

        // At day 22, expired
        vm.warp(block.timestamp + 2 days); // total = 22 days > 7 + 14
        assertTrue(
            subManager.getEffectiveStatus(instanceId) ==
                ISubscriptionManager.SubscriptionStatus.Expired
        );
    }

    // ═══════════════════════════════════════════════════════════
    //              15. ADMIN EMERGENCY CANCEL
    // ═══════════════════════════════════════════════════════════

    function test_subscription_adminEmergencyCancel() public {
        uint256 instanceId = _rentInstance(7);

        // Admin (owner of SubscriptionManager) force-cancels
        subManager.emergencyCancelSubscription(instanceId);

        assertTrue(
            subManager.getEffectiveStatus(instanceId) ==
                ISubscriptionManager.SubscriptionStatus.Canceled
        );
        assertFalse(subManager.canExecute(instanceId));
    }

    // ═══════════════════════════════════════════════════════════
    //              16. PAUSE BLOCKS ALL OPERATIONS
    // ═══════════════════════════════════════════════════════════

    function test_subscription_pauseBlocksOperations() public {
        uint256 instanceId = _rentInstance(7);

        // Admin pauses
        subManager.pause();

        // Cannot renew
        vm.prank(renter);
        vm.expectRevert(); // EnforcedPause
        subManager.renewSubscription{value: 0.7 ether}(instanceId);

        // Cannot cancel
        vm.prank(renter);
        vm.expectRevert(); // EnforcedPause
        subManager.cancelSubscription(instanceId);

        // Unpause restores functionality
        subManager.unpause();

        vm.prank(renter);
        subManager.cancelSubscription(instanceId);
        assertTrue(
            subManager.getEffectiveStatus(instanceId) ==
                ISubscriptionManager.SubscriptionStatus.Canceled
        );
    }

    // ═══════════════════════════════════════════════════════════
    //              SECURITY TESTS
    // ═══════════════════════════════════════════════════════════

    function test_security_onlyListingManagerCanCreate() public {
        vm.prank(evil);
        vm.expectRevert(Errors.OnlyListingManager.selector);
        subManager.createSubscription(
            999,
            evil,
            bytes32("fake"),
            1 ether,
            30,
            7
        );
    }

    function test_security_cannotDoubleCreate() public {
        uint256 instanceId = _rentInstance(7);

        // Try to create again (simulating from listing manager)
        vm.prank(address(listing));
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.SubscriptionAlreadyExists.selector,
                instanceId
            )
        );
        subManager.createSubscription(
            instanceId,
            renter,
            listingId,
            0.7 ether,
            7,
            7
        );
    }

    function test_security_zeroAddressRejected() public {
        vm.prank(address(listing));
        vm.expectRevert(Errors.ZeroAddress.selector);
        subManager.createSubscription(
            999,
            address(0),
            listingId,
            0.7 ether,
            7,
            7
        );
    }

    function test_security_gracePeriodTooLong() public {
        vm.prank(address(listing));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.GracePeriodTooLong.selector, 31, 30)
        );
        subManager.createSubscription(999, renter, listingId, 0.7 ether, 7, 31);
    }

    function test_security_nonexistentSubscription() public {
        vm.prank(renter);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.SubscriptionNotFound.selector, 999)
        );
        subManager.renewSubscription{value: 1 ether}(999);
    }

    function test_security_renewActiveExtendsFromEnd() public {
        uint256 instanceId = _rentInstance(7);

        ISubscriptionManager.Subscription memory subBefore = subManager
            .getSubscription(instanceId);

        // Renew during active period (should extend from currentPeriodEnd, not now)
        vm.prank(renter);
        subManager.renewSubscription{value: 0.7 ether}(instanceId);

        ISubscriptionManager.Subscription memory subAfter = subManager
            .getSubscription(instanceId);

        // New period should start from old period end (no gap, no overlap)
        assertEq(
            subAfter.currentPeriodEnd,
            subBefore.currentPeriodEnd + 7 days
        );
    }

    function test_security_canceledCannotRenew() public {
        uint256 instanceId = _rentInstance(7);

        vm.prank(renter);
        subManager.cancelSubscription(instanceId);

        vm.prank(renter);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.SubscriptionNotActive.selector,
                instanceId
            )
        );
        subManager.renewSubscription{value: 0.7 ether}(instanceId);
    }

    // ═══════════════════════════════════════════════════════════
    //              LEGACY COMPATIBILITY
    // ═══════════════════════════════════════════════════════════

    function test_legacy_noSubscriptionReturnsNone() public view {
        // Token 999 has no subscription
        ISubscriptionManager.SubscriptionStatus status = subManager
            .getEffectiveStatus(999);
        assertTrue(status == ISubscriptionManager.SubscriptionStatus.None);

        // canExecute should return false for None (no subscription = not our concern)
        assertFalse(subManager.canExecute(999));
    }

    // Allow this contract to receive ETH
    receive() external payable {}

    // Allow this contract to receive ERC721
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
