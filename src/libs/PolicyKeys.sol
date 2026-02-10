// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PolicyKeys — Limit key constants for PolicyGuard
library PolicyKeys {
    // ─── Swap limits ───
    bytes32 constant MAX_DEADLINE_WINDOW = keccak256("MAX_DEADLINE_WINDOW");
    bytes32 constant MAX_PATH_LENGTH = keccak256("MAX_PATH_LENGTH");
    bytes32 constant MAX_SWAP_AMOUNT_IN = keccak256("MAX_SWAP_AMOUNT_IN");

    // ─── Approve limits ───
    bytes32 constant MAX_APPROVE_AMOUNT = keccak256("MAX_APPROVE_AMOUNT");

    // ─── Repay limits ───
    bytes32 constant MAX_REPAY_AMOUNT = keccak256("MAX_REPAY_AMOUNT");

    // ─── Known selectors ───
    bytes4 constant SWAP_EXACT_TOKENS = 0x38ed1739; // swapExactTokensForTokens
    bytes4 constant APPROVE = 0x095ea7b3;            // approve(address,uint256)
    bytes4 constant REPAY_BORROW_BEHALF = 0x2608f818; // repayBorrowBehalf(address,uint256)
}
