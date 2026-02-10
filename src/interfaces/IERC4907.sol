// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC4907 — NFT rental standard interface
/// @dev See https://eips.ethereum.org/EIPS/eip-4907
interface IERC4907 {
    /// @notice Emitted when the `user` of an NFT or the `expires` is changed
    event UpdateUser(uint256 indexed tokenId, address indexed user, uint64 expires);

    /// @notice Set the user and expires of an NFT
    /// @param tokenId The NFT to set user for
    /// @param user The new user of the NFT
    /// @param expires UNIX timestamp — the user expires at
    function setUser(uint256 tokenId, address user, uint64 expires) external;

    /// @notice Get the user address of an NFT
    /// @param tokenId The NFT to get the user address for
    /// @return The user address for this NFT
    function userOf(uint256 tokenId) external view returns (address);

    /// @notice Get the user expires of an NFT
    /// @param tokenId The NFT to get the user expires for
    /// @return The user expires for this NFT
    function userExpires(uint256 tokenId) external view returns (uint256);
}
