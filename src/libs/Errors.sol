// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Errors — Unified custom errors for shll protocol
library Errors {
    // ─── General ───
    error Unauthorized();
    error ZeroAddress();

    // ─── AgentNFA ───
    error LeaseExpired();
    error PolicyViolation(string reason);
    error ExecutionFailed();
    error OnlyListingManager();
    error OnlyOwner();
    error OperatorExceedsLease();
    error SignatureExpired();
    error InvalidSigner();
    error InvalidNonce();
    error InvalidOperatorSubmitter();
    error AccountAlreadySet();

    // ─── BAP-578 Lifecycle ───
    error AgentPaused(uint256 tokenId);
    error AgentTerminated(uint256 tokenId);
    error InvalidLogicAddress();
    error TokenNotExist(uint256 tokenId);

    // ─── AgentAccount ───
    error OnlyNFA();
    error InsufficientBalance();
    error WithdrawToSelf();
    error InvalidWithdrawRecipient();

    // ─── PolicyGuard ───
    error TargetNotAllowed(address target);
    error SelectorNotAllowed(address target, bytes4 selector);
    error TokenNotAllowed(address token);
    error SpenderNotAllowed(address token, address spender);
    error SwapRecipientNotAccount(address to, address account);
    error DeadlineTooLong(uint256 deadline, uint256 maxDeadline);
    error PathTooLong(uint256 length, uint256 maxLength);
    error AmountExceedsLimit(uint256 amount, uint256 limit);
    error InfiniteApprovalNotAllowed();
    error BorrowerNotRenter(address borrower, address renter);
    error CalldataTooShort();

    // ─── ListingManager ───
    error ListingNotFound();
    error ListingAlreadyExists();
    error InsufficientPayment(uint256 required, uint256 sent);
    error MinDaysNotMet(uint32 requested, uint32 minimum);
    error AlreadyRented();
    error NotListingOwner();
    error CooldownNotMet(uint256 availableAt, uint256 currentTime);
    error RentingPaused();
    error GracePeriodActive(address lastRenter, uint256 graceEndsAt);
    error MaxDaysExceeded(uint32 requested, uint32 maximum);
}
