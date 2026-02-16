// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title GroupRegistry
 * @notice Manages shared groups of addresses (tokens, DEX routers, etc.)
 */
contract GroupRegistry is Ownable {
    /// @notice mapping(groupId => address => allowed)
    mapping(uint32 => mapping(address => bool)) private _members;

    /// @notice mapping(groupId => count)
    mapping(uint32 => uint32) public groupSize;

    event GroupMemberSet(
        uint32 indexed groupId,
        address indexed member,
        bool allowed
    );

    constructor() Ownable() {}

    /**
     * @notice Add or remove a member from a group
     */
    function setGroupMember(
        uint32 groupId,
        address member,
        bool allowed
    ) external onlyOwner {
        bool current = _members[groupId][member];
        if (current != allowed) {
            _members[groupId][member] = allowed;
            if (allowed) {
                groupSize[groupId]++;
            } else {
                groupSize[groupId]--;
            }
            emit GroupMemberSet(groupId, member, allowed);
        }
    }

    /**
     * @notice Check if an address is in a group
     */
    function isInGroup(
        uint32 groupId,
        address member
    ) external view returns (bool) {
        return _members[groupId][member];
    }
}
