// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IInstanceInitializable — Atomic policy initialization for new instances
/// @notice Policies implementing this interface will be auto-initialized during
///         PolicyGuardV4.bindInstance(), ensuring fail-close defaults from template.
interface IInstanceInitializable {
    /// @notice Initialize instance-level policy config from template defaults
    /// @dev Called by PolicyGuardV4.bindInstance() for each template policy.
    ///      MUST only accept calls from the guard contract.
    /// @param instanceId The newly minted instance token ID
    /// @param templateKey The template key to copy defaults from
    function initInstance(uint256 instanceId, bytes32 templateKey) external;
}
