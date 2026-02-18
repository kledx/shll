// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPolicy — Composable policy plugin interface (V3.0)
/// @notice Each policy is a standalone contract that validates a single aspect
///         of an action (e.g. token whitelist, spending limit, cooldown).
interface IPolicy {
    /// @notice Validate whether an action is allowed under this policy
    /// @param instanceId The Agent NFA token ID
    /// @param caller     The address that initiated the execute call
    /// @param target     The target contract of the action
    /// @param selector   The function selector (first 4 bytes of calldata)
    /// @param callData   The full calldata of the action
    /// @param value      The native value sent with the action
    /// @return ok     True if the action passes this policy
    /// @return reason Human-readable rejection reason (empty if ok)
    function check(
        uint256 instanceId,
        address caller,
        address target,
        bytes4 selector,
        bytes calldata callData,
        uint256 value
    ) external view returns (bool ok, string memory reason);

    /// @notice Policy type identifier (e.g. keccak256("token_whitelist"))
    function policyType() external pure returns (bytes32);

    /// @notice Whether this policy can be removed by the renter
    /// @dev Policies like ReceiverGuard return false — owner sets, renter cannot remove
    function renterConfigurable() external pure returns (bool);
}
