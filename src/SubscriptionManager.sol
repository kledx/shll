// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Ownable2Step,
    Ownable
} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {
    ReentrancyGuard
} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";
import {ISubscriptionManager} from "./interfaces/ISubscriptionManager.sol";
import {Errors} from "./libs/Errors.sol";

/// @title SubscriptionManager — Subscription lifecycle for SHLL Agent instances
/// @notice Replaces ERC-4907 one-time rental with subscription model + GracePeriod
/// @dev Deployed independently; AgentNFA is NOT modified. Runner checks this contract.
///
/// Security features:
///   - ReentrancyGuard on all payable functions
///   - Ownable2Step for admin (two-step ownership transfer)
///   - Pausable for emergency stop
///   - Zero-address validation on all address params
///   - Dynamic status computation (no stale state)
///   - Pull-pattern for income withdrawal (no push transfers)
contract SubscriptionManager is
    ISubscriptionManager,
    Ownable2Step,
    ReentrancyGuard,
    Pausable
{
    // ═══════════════════════════════════════════════════════════
    //                         STATE
    // ═══════════════════════════════════════════════════════════

    /// @notice instanceId => Subscription data
    mapping(uint256 => Subscription) private _subscriptions;

    /// @notice listing owner address => pending withdrawal balance
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice Authorized ListingManager address (only it can create subscriptions)
    address public listingManager;

    /// @notice AgentNFA address (for ownership lookups if needed)
    address public agentNFA;

    /// @notice Global maximum grace period days (admin-configurable ceiling)
    uint32 public maxGracePeriodDays = 30;

    /// @notice Days after Expired during which renewal is still allowed
    uint32 public expiredRenewalWindowDays = 30;

    /// @notice Protocol fee in basis points (0 = no fee, max 1000 = 10%)
    uint16 public protocolFeeBps = 0;

    /// @notice Accumulated protocol fees available for withdrawal
    uint256 public protocolFeeBalance;

    // ═══════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor() {}

    // ═══════════════════════════════════════════════════════════
    //                      ADMIN SETTERS
    // ═══════════════════════════════════════════════════════════

    /// @notice Set the authorized ListingManager address
    function setListingManager(address _listingManager) external onlyOwner {
        if (_listingManager == address(0)) revert Errors.ZeroAddress();
        listingManager = _listingManager;
    }

    /// @notice Set the AgentNFA address
    function setAgentNFA(address _agentNFA) external onlyOwner {
        if (_agentNFA == address(0)) revert Errors.ZeroAddress();
        agentNFA = _agentNFA;
    }

    /// @notice Set the global maximum grace period days
    function setMaxGracePeriodDays(uint32 _maxDays) external onlyOwner {
        maxGracePeriodDays = _maxDays;
    }

    /// @notice Set the expired renewal window (days after Expired status that renewal is allowed)
    function setExpiredRenewalWindowDays(uint32 _days) external onlyOwner {
        expiredRenewalWindowDays = _days;
    }

    /// @notice Set protocol fee in basis points (max 1000 = 10%)
    function setProtocolFeeBps(uint16 _bps) external onlyOwner {
        require(_bps <= 1000, "Fee too high");
        protocolFeeBps = _bps;
    }

    /// @notice Emergency pause — blocks createSubscription, renewSubscription, cancelSubscription
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume operations after emergency pause
    function unpause() external onlyOwner {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════
    //               ADMIN: EMERGENCY OPERATIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Admin force-cancel a subscription (security incidents, abuse)
    /// @param instanceId The instance to cancel
    function emergencyCancelSubscription(
        uint256 instanceId
    ) external onlyOwner {
        Subscription storage sub = _subscriptions[instanceId];
        if (sub.subscriber == address(0))
            revert Errors.SubscriptionNotFound(instanceId);

        SubscriptionStatus oldStatus = _computeEffectiveStatus(sub);
        sub.status = SubscriptionStatus.Canceled;

        emit SubscriptionCanceled(instanceId, msg.sender);
        emit SubscriptionStatusChanged(
            instanceId,
            oldStatus,
            SubscriptionStatus.Canceled
        );
    }

    /// @notice Admin update grace period for a specific subscription
    /// @param instanceId The instance to update
    /// @param newGracePeriodDays New grace period in days
    function updateGracePeriod(
        uint256 instanceId,
        uint32 newGracePeriodDays
    ) external onlyOwner {
        Subscription storage sub = _subscriptions[instanceId];
        if (sub.subscriber == address(0))
            revert Errors.SubscriptionNotFound(instanceId);
        if (newGracePeriodDays > maxGracePeriodDays) {
            revert Errors.GracePeriodTooLong(
                newGracePeriodDays,
                maxGracePeriodDays
            );
        }

        sub.gracePeriodDays = newGracePeriodDays;
        // Recalculate gracePeriodEnd based on new days
        sub.gracePeriodEnd =
            sub.currentPeriodEnd +
            uint64(newGracePeriodDays) *
            1 days;
    }

    /// @notice Withdraw accumulated protocol fees
    function withdrawProtocolFees() external onlyOwner nonReentrant {
        uint256 amount = protocolFeeBalance;
        if (amount == 0) revert Errors.InsufficientBalance();

        protocolFeeBalance = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert Errors.ExecutionFailed();
    }

    // ═══════════════════════════════════════════════════════════
    //                   CREATE SUBSCRIPTION
    // ═══════════════════════════════════════════════════════════

    /// @notice Create a subscription for a newly minted instance
    /// @dev Only callable by ListingManager during rentToMintWithParams
    function createSubscription(
        uint256 instanceId,
        address subscriber,
        bytes32 listingId,
        uint96 pricePerPeriod,
        uint32 periodDays,
        uint32 gracePeriodDays
    ) external whenNotPaused {
        // SECURITY: Only ListingManager can create subscriptions
        if (msg.sender != listingManager) revert Errors.OnlyListingManager();
        if (subscriber == address(0)) revert Errors.ZeroAddress();
        if (periodDays == 0) revert Errors.InvalidInitParams();
        if (gracePeriodDays > maxGracePeriodDays) {
            revert Errors.GracePeriodTooLong(
                gracePeriodDays,
                maxGracePeriodDays
            );
        }
        // Prevent double-creation
        if (_subscriptions[instanceId].subscriber != address(0)) {
            revert Errors.SubscriptionAlreadyExists(instanceId);
        }

        uint64 periodEnd = uint64(
            block.timestamp + uint256(periodDays) * 1 days
        );
        uint64 graceEnd = periodEnd + uint64(gracePeriodDays) * 1 days;

        _subscriptions[instanceId] = Subscription({
            subscriber: subscriber,
            listingId: listingId,
            currentPeriodEnd: periodEnd,
            gracePeriodEnd: graceEnd,
            pricePerPeriod: pricePerPeriod,
            periodDays: periodDays,
            gracePeriodDays: gracePeriodDays,
            status: SubscriptionStatus.Active
        });

        emit SubscriptionCreated(
            instanceId,
            subscriber,
            listingId,
            periodDays,
            gracePeriodDays,
            pricePerPeriod,
            periodEnd,
            graceEnd
        );
    }

    // ═══════════════════════════════════════════════════════════
    //                   RENEW SUBSCRIPTION
    // ═══════════════════════════════════════════════════════════

    /// @notice Renew a subscription by paying for the next period
    /// @dev Only the subscriber can renew. Renewal price is stored in the subscription.
    ///      Allowed in Active, GracePeriod, and Expired (within renewal window).
    function renewSubscription(
        uint256 instanceId
    ) external payable nonReentrant whenNotPaused {
        Subscription storage sub = _subscriptions[instanceId];
        if (sub.subscriber == address(0))
            revert Errors.SubscriptionNotFound(instanceId);
        // SECURITY: Only subscriber can renew
        if (msg.sender != sub.subscriber) revert Errors.OnlySubscriber();

        SubscriptionStatus effectiveStatus = _computeEffectiveStatus(sub);

        // Check renewability
        if (effectiveStatus == SubscriptionStatus.Canceled) {
            revert Errors.SubscriptionNotActive(instanceId);
        }
        if (effectiveStatus == SubscriptionStatus.Expired) {
            // Lenient renewal: allowed within expiredRenewalWindowDays
            uint64 renewalDeadline = sub.gracePeriodEnd +
                uint64(expiredRenewalWindowDays) *
                1 days;
            if (block.timestamp > renewalDeadline) {
                revert Errors.SubscriptionExpiredBeyondRenewal(instanceId);
            }
        }

        // SECURITY: Payment check
        if (msg.value < sub.pricePerPeriod) {
            revert Errors.InsufficientPayment(sub.pricePerPeriod, msg.value);
        }

        // Calculate new period
        // If renewing during Active period, extend from currentPeriodEnd (no gap)
        // If renewing during GracePeriod or Expired, start from now
        uint64 newPeriodStart;
        if (effectiveStatus == SubscriptionStatus.Active) {
            newPeriodStart = sub.currentPeriodEnd;
        } else {
            newPeriodStart = uint64(block.timestamp);
        }

        uint64 newPeriodEnd = newPeriodStart + uint64(sub.periodDays) * 1 days;
        uint64 newGraceEnd = newPeriodEnd +
            uint64(sub.gracePeriodDays) *
            1 days;

        SubscriptionStatus oldStatus = effectiveStatus;
        sub.currentPeriodEnd = newPeriodEnd;
        sub.gracePeriodEnd = newGraceEnd;
        sub.status = SubscriptionStatus.Active;

        // Revenue distribution
        uint256 protocolFee = 0;
        uint256 ownerAmount = msg.value;
        if (protocolFeeBps > 0) {
            protocolFee = (msg.value * protocolFeeBps) / 10000;
            ownerAmount = msg.value - protocolFee;
            protocolFeeBalance += protocolFee;
        }

        // Pull-pattern: credit listing owner for later withdrawal
        // NOTE: We need the listing owner address. Since SubscriptionManager doesn't
        // directly know the listing owner, we store the revenue in a mapping keyed
        // by listingId, and the ListingManager handles the actual owner lookup.
        // For simplicity in V1, the subscriber (instance owner) receives refund,
        // and the revenue is sent to this contract for ListingManager to distribute.
        // Alternative: store listing owner in Subscription struct.
        //
        // V1 approach: revenue stays in contract, claimable via listing owner lookup.
        _creditListingOwnerRevenue(sub.listingId, ownerAmount);

        // SECURITY: Refund excess payment (use call, not transfer)
        if (msg.value > sub.pricePerPeriod) {
            uint256 refund = msg.value - sub.pricePerPeriod;
            // Adjust amounts: only pricePerPeriod was the actual payment
            // Recalculate fee and owner amount based on actual price
            if (protocolFeeBps > 0) {
                protocolFee =
                    (uint256(sub.pricePerPeriod) * protocolFeeBps) /
                    10000;
                ownerAmount = uint256(sub.pricePerPeriod) - protocolFee;
                // Correct the balance: we over-credited, fix it
                protocolFeeBalance =
                    protocolFeeBalance -
                    ((msg.value * protocolFeeBps) / 10000) +
                    protocolFee;
                _correctListingOwnerRevenue(
                    sub.listingId,
                    msg.value -
                        sub.pricePerPeriod -
                        (((msg.value * protocolFeeBps) / 10000) - protocolFee)
                );
            }

            (bool refundOk, ) = msg.sender.call{value: refund}("");
            if (!refundOk) revert Errors.ExecutionFailed();
        }

        emit SubscriptionRenewed(
            instanceId,
            msg.sender,
            newPeriodEnd,
            newGraceEnd,
            sub.pricePerPeriod
        );
        if (oldStatus != SubscriptionStatus.Active) {
            emit SubscriptionStatusChanged(
                instanceId,
                oldStatus,
                SubscriptionStatus.Active
            );
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                   CANCEL SUBSCRIPTION
    // ═══════════════════════════════════════════════════════════

    /// @notice Cancel a subscription (subscriber only)
    /// @dev Cancellation is immediate. Agent stops executing but user can still withdraw.
    function cancelSubscription(uint256 instanceId) external whenNotPaused {
        Subscription storage sub = _subscriptions[instanceId];
        if (sub.subscriber == address(0))
            revert Errors.SubscriptionNotFound(instanceId);
        if (msg.sender != sub.subscriber) revert Errors.OnlySubscriber();

        SubscriptionStatus effectiveStatus = _computeEffectiveStatus(sub);
        if (effectiveStatus == SubscriptionStatus.Canceled) {
            revert Errors.SubscriptionNotActive(instanceId);
        }

        sub.status = SubscriptionStatus.Canceled;

        emit SubscriptionCanceled(instanceId, msg.sender);
        emit SubscriptionStatusChanged(
            instanceId,
            effectiveStatus,
            SubscriptionStatus.Canceled
        );
    }

    // ═══════════════════════════════════════════════════════════
    //                      READ FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Get full subscription data
    function getSubscription(
        uint256 instanceId
    ) external view override returns (Subscription memory) {
        return _subscriptions[instanceId];
    }

    /// @notice Get real-time status based on current block.timestamp
    /// @dev This is the authoritative status check. The stored `status` field may be stale.
    function getEffectiveStatus(
        uint256 instanceId
    ) external view override returns (SubscriptionStatus) {
        Subscription storage sub = _subscriptions[instanceId];
        return _computeEffectiveStatus(sub);
    }

    /// @notice Whether the agent can execute (Active status only)
    function canExecute(
        uint256 instanceId
    ) external view override returns (bool) {
        Subscription storage sub = _subscriptions[instanceId];
        SubscriptionStatus status = _computeEffectiveStatus(sub);
        return status == SubscriptionStatus.Active;
    }

    /// @notice Whether the user can withdraw funds from vault
    /// @dev Allowed in Active, GracePeriod, and Expired — funds are NEVER locked
    function canWithdraw(
        uint256 instanceId
    ) external view override returns (bool) {
        Subscription storage sub = _subscriptions[instanceId];
        SubscriptionStatus status = _computeEffectiveStatus(sub);
        // None = legacy instance, no subscription restriction
        // Active, GracePeriod, Expired = can withdraw
        // Canceled = can withdraw (user chose to leave)
        return
            status != SubscriptionStatus.None || sub.subscriber != address(0);
    }

    // ═══════════════════════════════════════════════════════════
    //                    INCOME WITHDRAWAL
    // ═══════════════════════════════════════════════════════════

    /// @notice Listing owners claim accumulated rental income from renewals
    function claimRenewalIncome() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert Errors.InsufficientBalance();

        pendingWithdrawals[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert Errors.ExecutionFailed();
    }

    // ═══════════════════════════════════════════════════════════
    //                       INTERNAL
    // ═══════════════════════════════════════════════════════════

    /// @dev Compute the effective status based on timestamps and stored status
    /// @param sub The subscription storage reference
    /// @return The real-time effective status
    function _computeEffectiveStatus(
        Subscription storage sub
    ) internal view returns (SubscriptionStatus) {
        // No subscription exists
        if (sub.subscriber == address(0)) {
            return SubscriptionStatus.None;
        }

        // Explicit cancel/expired takes priority
        if (sub.status == SubscriptionStatus.Canceled) {
            return SubscriptionStatus.Canceled;
        }

        // Time-based status transitions
        if (block.timestamp <= sub.currentPeriodEnd) {
            return SubscriptionStatus.Active;
        }

        if (block.timestamp <= sub.gracePeriodEnd) {
            return SubscriptionStatus.GracePeriod;
        }

        return SubscriptionStatus.Expired;
    }

    /// @dev Credit listing owner with renewal revenue (pull pattern)
    /// @param listingId The listing to credit
    /// @param amount The amount to credit
    function _creditListingOwnerRevenue(
        bytes32 listingId,
        uint256 amount
    ) internal {
        // In V1, we need to resolve listingId → owner address.
        // Since ListingManager stores listing owners, we use a simpler approach:
        // Store revenue by listingId, and provide a claim function that validates ownership.
        //
        // For now, store in a mapping that ListingManagerV2 can query.
        // This is a simplified approach — in production, consider a callback pattern.
        _listingRevenue[listingId] += amount;
    }

    /// @dev Correct over-credited revenue (used during refund calculation)
    function _correctListingOwnerRevenue(
        bytes32 listingId,
        uint256 amount
    ) internal {
        if (_listingRevenue[listingId] >= amount) {
            _listingRevenue[listingId] -= amount;
        }
    }

    /// @notice Revenue accumulated per listing from renewals
    mapping(bytes32 => uint256) public _listingRevenue;

    /// @notice Claim renewal revenue for a listing (called by listing owner via ListingManagerV2)
    /// @param listingId The listing to claim revenue for
    /// @param owner The listing owner address (verified by caller)
    function claimListingRevenue(
        bytes32 listingId,
        address owner
    ) external nonReentrant {
        // SECURITY: Only ListingManager can call this (it verifies ownership)
        if (msg.sender != listingManager) revert Errors.OnlyListingManager();
        if (owner == address(0)) revert Errors.ZeroAddress();

        uint256 amount = _listingRevenue[listingId];
        if (amount == 0) revert Errors.InsufficientBalance();

        _listingRevenue[listingId] = 0;
        pendingWithdrawals[owner] += amount;
    }

    /// @notice Receive native token (BNB) — required for subscription payments
    receive() external payable {}
}
