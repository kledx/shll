// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISubscriptionManager — Subscription lifecycle interface for SHLL Agent instances
/// @notice Manages Active → GracePeriod → Expired → (optional renewal) lifecycle
interface ISubscriptionManager {
    // ─── Types ───

    enum SubscriptionStatus {
        None, // No subscription exists (legacy ERC-4907 instance)
        Active, // Agent can execute
        GracePeriod, // Expired but within grace window (can renew/withdraw, cannot execute)
        Expired, // Grace period ended (can withdraw, may renew within renewal window)
        Canceled // User or admin canceled
    }

    struct Subscription {
        address subscriber; // Instance owner (renter)
        bytes32 listingId; // Associated listing
        uint64 currentPeriodEnd; // Current subscription period end timestamp
        uint64 gracePeriodEnd; // Grace period end timestamp
        uint96 pricePerPeriod; // Renewal price in native token (BNB)
        uint32 periodDays; // Subscription period length in days
        uint32 gracePeriodDays; // Grace period length in days (configurable per listing)
        SubscriptionStatus status; // Stored status (may be stale — use getEffectiveStatus)
    }

    // ─── Events ───

    event SubscriptionCreated(
        uint256 indexed instanceId,
        address indexed subscriber,
        bytes32 indexed listingId,
        uint32 periodDays,
        uint32 gracePeriodDays,
        uint96 pricePerPeriod,
        uint64 currentPeriodEnd,
        uint64 gracePeriodEnd
    );

    event SubscriptionRenewed(
        uint256 indexed instanceId,
        address indexed subscriber,
        uint64 newPeriodEnd,
        uint64 newGracePeriodEnd,
        uint256 amountPaid
    );

    event SubscriptionCanceled(
        uint256 indexed instanceId,
        address indexed canceledBy
    );

    event SubscriptionStatusChanged(
        uint256 indexed instanceId,
        SubscriptionStatus oldStatus,
        SubscriptionStatus newStatus
    );

    // ─── Read ───

    /// @notice Get full subscription data for an instance
    function getSubscription(
        uint256 instanceId
    ) external view returns (Subscription memory);

    /// @notice Get real-time status based on block.timestamp (may differ from stored status)
    function getEffectiveStatus(
        uint256 instanceId
    ) external view returns (SubscriptionStatus);

    /// @notice Whether the agent can execute actions (Active only)
    function canExecute(uint256 instanceId) external view returns (bool);

    /// @notice Whether the user can withdraw funds (Active, GracePeriod, Expired)
    function canWithdraw(uint256 instanceId) external view returns (bool);

    // ─── Write ───

    /// @notice Create a subscription for a newly minted instance (ListingManager only)
    function createSubscription(
        uint256 instanceId,
        address subscriber,
        bytes32 listingId,
        uint96 pricePerPeriod,
        uint32 periodDays,
        uint32 gracePeriodDays
    ) external;

    /// @notice Renew an existing subscription (subscriber only, payable)
    function renewSubscription(uint256 instanceId) external payable;

    /// @notice Cancel a subscription (subscriber only)
    function cancelSubscription(uint256 instanceId) external;
}
