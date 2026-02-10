// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Action} from "../types/Action.sol";

/// @title IPolicyGuard — On-chain firewall interface
interface IPolicyGuard {
    /// @notice Validate an action against the policy rules
    /// @param nfa The AgentNFA contract address
    /// @param tokenId The NFA token ID
    /// @param agentAccount The AgentAccount address (explicit, no msg.sender inference)
    /// @param caller The address that initiated the execute call (owner or renter)
    /// @param action The action to validate
    /// @return ok Whether the action is allowed
    /// @return reason Human-readable reason if not allowed
    function validate(
        address nfa,
        uint256 tokenId,
        address agentAccount,
        address caller,
        Action calldata action
    ) external view returns (bool ok, string memory reason);
}
