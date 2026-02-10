// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Action} from "../types/Action.sol";

/// @title IAgentNFA — Agent Non-Fungible Asset interface
interface IAgentNFA {
    // ─── Events ───
    event AgentMinted(uint256 indexed tokenId, address indexed owner, address account, bytes32 policyId);
    event LeaseSet(uint256 indexed tokenId, address indexed user, uint64 expires);
    event PolicyUpdated(uint256 indexed tokenId, bytes32 oldPolicyId, bytes32 newPolicyId);
    event Executed(
        uint256 indexed tokenId,
        address indexed caller,
        address indexed account,
        address target,
        bytes4 selector,
        bool success,
        bytes result
    );

    // ─── Core functions ───
    function mintAgent(address to, bytes32 policyId, string calldata tokenURI) external returns (uint256 tokenId);

    function execute(uint256 tokenId, Action calldata action) external payable returns (bytes memory result);
    function executeBatch(uint256 tokenId, Action[] calldata actions)
        external
        payable
        returns (bytes[] memory results);

    // ─── ERC4907 ───
    function setUser(uint256 tokenId, address user, uint64 expires) external;
    function userOf(uint256 tokenId) external view returns (address);
    function userExpires(uint256 tokenId) external view returns (uint256);

    // ─── Views ───
    function accountOf(uint256 tokenId) external view returns (address);
    function policyIdOf(uint256 tokenId) external view returns (bytes32);
    function setPolicy(uint256 tokenId, bytes32 newPolicyId) external;
}
