// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IAgentNFA} from "./interfaces/IAgentNFA.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Errors} from "./libs/Errors.sol";

/// @title ListingManager — Agent rental marketplace
/// @notice Handles listing, renting, extending, and canceling Agent NFA rentals
contract ListingManager is Ownable, ReentrancyGuard {
    struct Listing {
        address nfa;         // AgentNFA contract
        uint256 tokenId;     // NFA token ID
        address owner;       // who listed it
        uint96 pricePerDay;  // rental price per day in native currency
        uint32 minDays;      // minimum rental duration
        bool active;
    }

    /// @notice listingId => Listing
    mapping(bytes32 => Listing) public listings;

    /// @notice Accumulated rental income per listing owner
    mapping(address => uint256) public pendingWithdrawals;

    // ─── Events ───
    event ListingCreated(bytes32 indexed listingId, address indexed nfa, uint256 indexed tokenId, uint96 pricePerDay, uint32 minDays);
    event ListingCanceled(bytes32 indexed listingId);
    event AgentRented(bytes32 indexed listingId, address indexed renter, uint64 expires, uint256 totalPaid);
    event LeaseExtended(bytes32 indexed listingId, address indexed renter, uint64 newExpires, uint256 totalPaid);
    event WithdrawalClaimed(address indexed owner, uint256 amount);

    constructor() {}

    // ═══════════════════════════════════════════════════════════
    //                    LISTING
    // ═══════════════════════════════════════════════════════════

    /// @notice Create a new listing for an Agent NFA
    function createListing(address nfa, uint256 tokenId, uint96 pricePerDay, uint32 minDays)
        external
        returns (bytes32 listingId)
    {
        // Caller must be the NFA owner
        if (IERC721(nfa).ownerOf(tokenId) != msg.sender) revert Errors.NotListingOwner();

        listingId = keccak256(abi.encodePacked(nfa, tokenId));

        // Check not already listed
        if (listings[listingId].active) revert Errors.ListingAlreadyExists();

        listings[listingId] = Listing({
            nfa: nfa,
            tokenId: tokenId,
            owner: msg.sender,
            pricePerDay: pricePerDay,
            minDays: minDays,
            active: true
        });

        emit ListingCreated(listingId, nfa, tokenId, pricePerDay, minDays);
    }

    /// @notice Cancel a listing
    function cancelListing(bytes32 listingId) external {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        if (listing.owner != msg.sender) revert Errors.NotListingOwner();

        listing.active = false;
        emit ListingCanceled(listingId);
    }

    // ═══════════════════════════════════════════════════════════
    //                    RENT
    // ═══════════════════════════════════════════════════════════

    /// @notice Rent an Agent NFA by paying the rental fee
    function rent(bytes32 listingId, uint32 daysToRent)
        external
        payable
        nonReentrant
        returns (uint64 expires)
    {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        if (daysToRent < listing.minDays) revert Errors.MinDaysNotMet(daysToRent, listing.minDays);

        // Check not already rented (userOf should be address(0))
        address currentUser = IAgentNFA(listing.nfa).userOf(listing.tokenId);
        if (currentUser != address(0)) revert Errors.AlreadyRented();

        // Calculate payment
        uint256 totalCost = uint256(listing.pricePerDay) * uint256(daysToRent);
        if (msg.value < totalCost) revert Errors.InsufficientPayment(totalCost, msg.value);

        // Set the user (renter) via AgentNFA
        expires = uint64(block.timestamp + uint256(daysToRent) * 1 days);
        IAgentNFA(listing.nfa).setUser(listing.tokenId, msg.sender, expires);

        // Track rental income for owner
        pendingWithdrawals[listing.owner] += totalCost;

        // Refund excess payment
        if (msg.value > totalCost) {
            (bool ok,) = msg.sender.call{value: msg.value - totalCost}("");
            if (!ok) revert Errors.ExecutionFailed();
        }

        emit AgentRented(listingId, msg.sender, expires, totalCost);
    }

    /// @notice Extend an existing rental
    function extend(bytes32 listingId, uint32 daysToExtend)
        external
        payable
        nonReentrant
        returns (uint64 newExpires)
    {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();

        // Caller must be current renter
        address currentUser = IAgentNFA(listing.nfa).userOf(listing.tokenId);
        if (currentUser != msg.sender) revert Errors.Unauthorized();

        uint256 totalCost = uint256(listing.pricePerDay) * uint256(daysToExtend);
        if (msg.value < totalCost) revert Errors.InsufficientPayment(totalCost, msg.value);

        // Extend from current expiry
        uint256 currentExpiry = IAgentNFA(listing.nfa).userExpires(listing.tokenId);
        newExpires = uint64(currentExpiry + uint256(daysToExtend) * 1 days);
        IAgentNFA(listing.nfa).setUser(listing.tokenId, msg.sender, newExpires);

        pendingWithdrawals[listing.owner] += totalCost;

        if (msg.value > totalCost) {
            (bool ok,) = msg.sender.call{value: msg.value - totalCost}("");
            if (!ok) revert Errors.ExecutionFailed();
        }

        emit LeaseExtended(listingId, msg.sender, newExpires, totalCost);
    }

    // ═══════════════════════════════════════════════════════════
    //                    WITHDRAW
    // ═══════════════════════════════════════════════════════════

    /// @notice Owner claims accumulated rental income
    function claimRentalIncome() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert Errors.InsufficientBalance();

        pendingWithdrawals[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert Errors.ExecutionFailed();

        emit WithdrawalClaimed(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════
    //                    VIEWS
    // ═══════════════════════════════════════════════════════════

    /// @notice Compute listing ID from NFA address and tokenId
    function getListingId(address nfa, uint256 tokenId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(nfa, tokenId));
    }
}
