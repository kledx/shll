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
    error AccountAlreadySet();

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
}
