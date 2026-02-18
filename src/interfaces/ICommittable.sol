// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICommittable — Post-execution state update hook (V3.0)
/// @notice Policies that need to update state after execution (e.g. SpendingLimit
///         accumulates daily spend, Cooldown updates timestamp) implement this
///         interface in addition to IPolicy.
/// @dev PolicyGuardV4 detects this via ERC-165 supportsInterface() and calls
///      onCommit() only for policies that implement it.
interface ICommittable {
    /// @notice Called by PolicyGuardV4 after successful action execution
    /// @param instanceId The Agent NFA token ID
    /// @param target     The target contract of the executed action
    /// @param selector   The function selector
    /// @param callData   The full calldata
    /// @param value      The native value sent
    function onCommit(
        uint256 instanceId,
        address target,
        bytes4 selector,
        bytes calldata callData,
        uint256 value
    ) external;
}
