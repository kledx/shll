// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    ERC165
} from "openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {ICommittable} from "../interfaces/ICommittable.sol";
import {IERC4907} from "../interfaces/IERC4907.sol";

/// @title CooldownPolicy — Enforce minimum interval between executions
/// @notice Implements ICommittable to update lastExecution timestamp after each run.
contract CooldownPolicy is IPolicy, ICommittable, ERC165 {
    // ─── Storage ───
    mapping(uint256 => uint256) public cooldownSeconds;
    mapping(uint256 => uint256) public lastExecution;

    address public immutable guard;
    address public immutable agentNFA;

    // ─── Events ───
    event CooldownSet(uint256 indexed instanceId, uint256 seconds_);
    event ExecutionRecorded(uint256 indexed instanceId, uint256 timestamp);

    // ─── Errors ───
    error NotRenterOrOwner();
    error OnlyGuard();

    constructor(address _guard, address _nfa) {
        guard = _guard;
        agentNFA = _nfa;
    }

    // ═══════════════════════════════════════════════════════
    //                   CONFIGURATION
    // ═══════════════════════════════════════════════════════

    /// @notice Renter sets cooldown period
    function setCooldown(uint256 instanceId, uint256 seconds_) external {
        _checkRenterOrOwner(instanceId);
        cooldownSeconds[instanceId] = seconds_;
        emit CooldownSet(instanceId, seconds_);
    }

    // ═══════════════════════════════════════════════════════
    //                   IPolicy INTERFACE
    // ═══════════════════════════════════════════════════════

    function check(
        uint256 instanceId,
        address,
        address,
        bytes4,
        bytes calldata,
        uint256
    ) external view override returns (bool ok, string memory reason) {
        uint256 cd = cooldownSeconds[instanceId];
        if (cd == 0) return (true, "");

        uint256 elapsed = block.timestamp - lastExecution[instanceId];
        if (elapsed < cd) {
            return (false, "Cooldown active");
        }
        return (true, "");
    }

    function policyType() external pure override returns (bytes32) {
        return keccak256("cooldown");
    }

    function renterConfigurable() external pure override returns (bool) {
        return true;
    }

    // ═══════════════════════════════════════════════════════
    //               ICommittable INTERFACE
    // ═══════════════════════════════════════════════════════

    function onCommit(
        uint256 instanceId,
        address,
        bytes4,
        bytes calldata,
        uint256
    ) external override {
        if (msg.sender != guard) revert OnlyGuard();
        lastExecution[instanceId] = block.timestamp;
        emit ExecutionRecorded(instanceId, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════
    //                    ERC-165
    // ═══════════════════════════════════════════════════════

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(ICommittable).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ═══════════════════════════════════════════════════════
    //                    INTERNALS
    // ═══════════════════════════════════════════════════════

    function _checkRenterOrOwner(uint256 instanceId) internal view {
        address renter = IERC4907(agentNFA).userOf(instanceId);
        if (msg.sender != renter && msg.sender != Ownable(guard).owner()) {
            revert NotRenterOrOwner();
        }
    }
}
