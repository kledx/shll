// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentAccount — Agent vault / execution account interface
interface IAgentAccount {
    /// @notice Execute a low-level call to a target contract
    /// @dev Only callable by the bound AgentNFA contract
    function executeCall(address target, uint256 value, bytes calldata data)
        external
        returns (bool ok, bytes memory result);

    /// @notice Deposit ERC20 tokens into the account
    function depositToken(address token, uint256 amount) external;

    /// @notice Withdraw ERC20 tokens (only owner or current renter to their own address)
    function withdrawToken(address token, uint256 amount, address to) external;

    /// @notice Withdraw native currency (only owner or current renter to their own address)
    function withdrawNative(uint256 amount, address to) external;
}
