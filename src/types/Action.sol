// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Unified action data structure for AgentNFA execute calls
struct Action {
    address target; // target contract (router / token / vToken)
    uint256 value;  // native value (MVP: usually 0)
    bytes data;     // calldata (selector + params)
}
