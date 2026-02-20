// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentNFATemplateView
/// @notice Read-only view for template/instance relationships
interface IAgentNFATemplateView {
    function isInstance(uint256 tokenId) external view returns (bool);

    function templateOf(uint256 tokenId) external view returns (uint256);
}
