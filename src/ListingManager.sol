// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    ReentrancyGuard
} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IAgentNFA} from "./interfaces/IAgentNFA.sol";
import {
    IERC721
} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Errors} from "./libs/Errors.sol";

/// @title ListingManager — Agent rental marketplace
/// @notice Handles listing, renting, extending, and canceling Agent NFA rentals
/// @dev Production-grade: per-listing gracePeriod, maxDays, pauseRenting
///      V1.3: Template listings + Rent-to-Mint flow
contract ListingManager is Ownable, ReentrancyGuard {
    struct Listing {
        address nfa; // AgentNFA contract
        uint256 tokenId; // NFA token ID
        address owner; // who listed it
        uint96 pricePerDay; // rental price per day in native currency
        uint32 minDays; // minimum rental duration
        bool active;
        bool isTemplate; // V1.3: true = Rent-to-Mint, false = classic rent
    }

    /// @notice Per-listing rental configuration
    struct ListingConfig {
        uint32 maxDays; // max rental duration per rent (0 = unlimited)
        uint32 gracePeriod; // seconds after lease expiry for last renter priority
    }

    /// @notice listingId => Listing
    mapping(bytes32 => Listing) public listings;

    /// @notice All listing IDs for enumeration
    bytes32[] public allListingIds;

    /// @notice listingId => ListingConfig
    mapping(bytes32 => ListingConfig) public listingConfigs;

    /// @notice Accumulated rental income per listing owner
    mapping(address => uint256) public pendingWithdrawals;

    // ─── Rental Guard State ───
    /// @notice listingId => timestamp when the last lease ends
    mapping(bytes32 => uint256) public lastLeaseEnd;

    /// @notice listingId => address of the last renter (for grace period)
    mapping(bytes32 => address) public lastRenter;

    /// @notice listingId => owner has paused renting
    mapping(bytes32 => bool) public rentingPaused;

    // ─── Events ───
    event ListingCreated(
        bytes32 indexed listingId,
        address indexed nfa,
        uint256 indexed tokenId,
        uint96 pricePerDay,
        uint32 minDays
    );
    event ListingCanceled(bytes32 indexed listingId);
    event AgentRented(
        bytes32 indexed listingId,
        address indexed renter,
        uint64 expires,
        uint256 totalPaid
    );
    event LeaseExtended(
        bytes32 indexed listingId,
        address indexed renter,
        uint64 newExpires,
        uint256 totalPaid
    );
    event WithdrawalClaimed(address indexed owner, uint256 amount);
    event ListingConfigUpdated(
        bytes32 indexed listingId,
        uint32 maxDays,
        uint32 gracePeriod
    );
    event RentingPaused(bytes32 indexed listingId);
    event RentingResumed(bytes32 indexed listingId);

    // ─── V1.3: Rent-to-Mint events ───
    event TemplateListingCreated(
        bytes32 indexed listingId,
        address indexed nfa,
        uint256 indexed tokenId,
        uint96 pricePerDay,
        uint32 minDays
    );
    event InstanceRented(
        bytes32 indexed listingId,
        address indexed renter,
        uint256 instanceId,
        uint64 expires,
        uint256 totalPaid
    );

    constructor() {}

    // ═══════════════════════════════════════════════════════════
    //                    LISTING
    // ═══════════════════════════════════════════════════════════

    /// @notice Create a new listing for an Agent NFA (classic rent — exclusive access)
    function createListing(
        address nfa,
        uint256 tokenId,
        uint96 pricePerDay,
        uint32 minDays
    ) external returns (bytes32 listingId) {
        // Caller must be the NFA owner
        if (IERC721(nfa).ownerOf(tokenId) != msg.sender)
            revert Errors.NotListingOwner();

        listingId = keccak256(abi.encodePacked(nfa, tokenId));

        // Check not already listed
        if (listings[listingId].active) revert Errors.ListingAlreadyExists();

        listings[listingId] = Listing({
            nfa: nfa,
            tokenId: tokenId,
            owner: msg.sender,
            pricePerDay: pricePerDay,
            minDays: minDays,
            active: true,
            isTemplate: false
        });

        allListingIds.push(listingId);

        emit ListingCreated(listingId, nfa, tokenId, pricePerDay, minDays);
    }

    // ═══════════════════════════════════════════════════════════
    //                    V1.3: TEMPLATE LISTING
    // ═══════════════════════════════════════════════════════════

    /// @notice Create a template listing — enables Rent-to-Mint for this agent
    /// @dev The tokenId must already be registered as a template via AgentNFA.registerTemplate()
    /// @param nfa The AgentNFA contract address
    /// @param tokenId The template tokenId (must be registered)
    /// @param pricePerDay Rental price per day in native currency
    /// @param minDays Minimum rental duration in days
    function createTemplateListing(
        address nfa,
        uint256 tokenId,
        uint96 pricePerDay,
        uint32 minDays
    ) external returns (bytes32 listingId) {
        // Caller must be the NFA owner
        if (IERC721(nfa).ownerOf(tokenId) != msg.sender)
            revert Errors.NotListingOwner();

        // SECURITY: Token must be registered as template first
        if (!IAgentNFA(nfa).isTemplate(tokenId))
            revert Errors.NotTemplate(tokenId);

        listingId = keccak256(abi.encodePacked(nfa, tokenId));

        // Check not already listed
        if (listings[listingId].active) revert Errors.ListingAlreadyExists();

        listings[listingId] = Listing({
            nfa: nfa,
            tokenId: tokenId,
            owner: msg.sender,
            pricePerDay: pricePerDay,
            minDays: minDays,
            active: true,
            isTemplate: true
        });

        allListingIds.push(listingId);

        emit TemplateListingCreated(
            listingId,
            nfa,
            tokenId,
            pricePerDay,
            minDays
        );
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
    //                    RENT (Classic — exclusive access)
    // ═══════════════════════════════════════════════════════════

    /// @notice Rent an Agent NFA by paying the rental fee
    /// @dev Does NOT work for template listings — use rentToMint() instead
    function rent(
        bytes32 listingId,
        uint32 daysToRent
    ) external payable nonReentrant returns (uint64 expires) {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        // SECURITY: template listings cannot use classic rent
        if (listing.isTemplate) revert Errors.IsTemplateListing();
        if (rentingPaused[listingId]) revert Errors.RentingPaused();
        if (daysToRent < listing.minDays)
            revert Errors.MinDaysNotMet(daysToRent, listing.minDays);

        // Check maxDays limit
        ListingConfig storage cfg = listingConfigs[listingId];
        if (cfg.maxDays > 0 && daysToRent > cfg.maxDays) {
            revert Errors.MaxDaysExceeded(daysToRent, cfg.maxDays);
        }

        // Check not already rented (userOf should be address(0))
        address currentUser = IAgentNFA(listing.nfa).userOf(listing.tokenId);
        if (currentUser != address(0)) revert Errors.AlreadyRented();

        // Grace period: after lease expiry, last renter has priority for gracePeriod seconds
        uint256 _lastEnd = lastLeaseEnd[listingId];
        if (
            cfg.gracePeriod > 0 &&
            _lastEnd > 0 &&
            block.timestamp < _lastEnd + cfg.gracePeriod
        ) {
            if (msg.sender != lastRenter[listingId]) {
                revert Errors.GracePeriodActive(
                    lastRenter[listingId],
                    _lastEnd + cfg.gracePeriod
                );
            }
        }

        // Calculate payment
        uint256 totalCost = uint256(listing.pricePerDay) * uint256(daysToRent);
        if (msg.value < totalCost)
            revert Errors.InsufficientPayment(totalCost, msg.value);

        // Set the user (renter) via AgentNFA
        expires = uint64(block.timestamp + uint256(daysToRent) * 1 days);
        IAgentNFA(listing.nfa).setUser(listing.tokenId, msg.sender, expires);

        // Track rental state for grace period
        lastRenter[listingId] = msg.sender;
        lastLeaseEnd[listingId] = expires;

        // Track rental income for owner
        pendingWithdrawals[listing.owner] += totalCost;

        // Refund excess payment
        if (msg.value > totalCost) {
            (bool ok, ) = msg.sender.call{value: msg.value - totalCost}("");
            if (!ok) revert Errors.ExecutionFailed();
        }

        emit AgentRented(listingId, msg.sender, expires, totalCost);
    }

    // ═══════════════════════════════════════════════════════════
    //                    V1.3: RENT-TO-MINT
    // ═══════════════════════════════════════════════════════════

    /// @notice Rent-to-Mint: mint a new Instance from a Template listing
    /// @dev Anyone can call this for a template listing. Each call mints a NEW instance.
    ///      Multiple users can rent the same template simultaneously.
    /// @param listingId The template listing ID
    /// @param daysToRent Number of days to rent the instance
    /// @param initParams Arbitrary initialization parameters (stored as hash on-chain)
    /// @return instanceId The newly minted instance tokenId
    function rentToMint(
        bytes32 listingId,
        uint32 daysToRent,
        bytes calldata initParams
    ) external payable nonReentrant returns (uint256 instanceId) {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        // SECURITY: only template listings allow rentToMint
        if (!listing.isTemplate) revert Errors.TemplateListingRequired();
        if (rentingPaused[listingId]) revert Errors.RentingPaused();
        if (daysToRent < listing.minDays)
            revert Errors.MinDaysNotMet(daysToRent, listing.minDays);

        // Check maxDays limit
        ListingConfig storage cfg = listingConfigs[listingId];
        if (cfg.maxDays > 0 && daysToRent > cfg.maxDays) {
            revert Errors.MaxDaysExceeded(daysToRent, cfg.maxDays);
        }

        // SECURITY: validate initParams is not empty (empty params likely a user error)
        if (initParams.length == 0) revert Errors.InvalidInitParams();

        // Calculate payment
        uint256 totalCost = uint256(listing.pricePerDay) * uint256(daysToRent);
        if (msg.value < totalCost)
            revert Errors.InsufficientPayment(totalCost, msg.value);

        // Compute expiry
        uint64 expires = uint64(block.timestamp + uint256(daysToRent) * 1 days);

        // Mint instance via AgentNFA — instance is minted to the renter (owner = renter)
        instanceId = IAgentNFA(listing.nfa).mintInstanceFromTemplate(
            msg.sender,
            listing.tokenId,
            expires,
            initParams
        );

        // Track rental income for template owner
        pendingWithdrawals[listing.owner] += totalCost;

        // Refund excess payment
        if (msg.value > totalCost) {
            (bool ok, ) = msg.sender.call{value: msg.value - totalCost}("");
            if (!ok) revert Errors.ExecutionFailed();
        }

        emit InstanceRented(
            listingId,
            msg.sender,
            instanceId,
            expires,
            totalCost
        );
    }

    /// @notice Extend an existing rental
    function extend(
        bytes32 listingId,
        uint32 daysToExtend
    ) external payable nonReentrant returns (uint64 newExpires) {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        if (listing.isTemplate) revert Errors.IsTemplateListing();

        // Caller must be current renter
        address currentUser = IAgentNFA(listing.nfa).userOf(listing.tokenId);
        if (currentUser != msg.sender) revert Errors.Unauthorized();

        uint256 totalCost = uint256(listing.pricePerDay) *
            uint256(daysToExtend);
        if (msg.value < totalCost)
            revert Errors.InsufficientPayment(totalCost, msg.value);

        // Extend from current expiry
        uint256 currentExpiry = IAgentNFA(listing.nfa).userExpires(
            listing.tokenId
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        newExpires = uint64(currentExpiry + uint256(daysToExtend) * 1 days);
        IAgentNFA(listing.nfa).setUser(listing.tokenId, msg.sender, newExpires);

        // Update lease end for grace period tracking
        lastLeaseEnd[listingId] = newExpires;

        pendingWithdrawals[listing.owner] += totalCost;

        if (msg.value > totalCost) {
            (bool ok, ) = msg.sender.call{value: msg.value - totalCost}("");
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
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert Errors.ExecutionFailed();

        emit WithdrawalClaimed(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════
    //                    LISTING CONFIG
    // ═══════════════════════════════════════════════════════════

    /// @notice Set per-listing configuration (maxDays, gracePeriod)
    function setListingConfig(
        bytes32 listingId,
        uint32 maxDays,
        uint32 gracePeriod
    ) external {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        if (listing.owner != msg.sender) revert Errors.NotListingOwner();
        listingConfigs[listingId] = ListingConfig(maxDays, gracePeriod);
        emit ListingConfigUpdated(listingId, maxDays, gracePeriod);
    }

    /// @notice Owner pauses renting for a specific listing
    function pauseRenting(bytes32 listingId) external {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        if (listing.owner != msg.sender) revert Errors.NotListingOwner();
        rentingPaused[listingId] = true;
        emit RentingPaused(listingId);
    }

    /// @notice Owner resumes renting for a specific listing
    function resumeRenting(bytes32 listingId) external {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        if (listing.owner != msg.sender) revert Errors.NotListingOwner();
        rentingPaused[listingId] = false;
        emit RentingResumed(listingId);
    }

    // ═══════════════════════════════════════════════════════════
    //                    VIEWS
    // ═══════════════════════════════════════════════════════════

    /// @notice Compute listing ID from NFA address and tokenId
    function getListingId(
        address nfa,
        uint256 tokenId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(nfa, tokenId));
    }

    /// @notice Total number of listings ever created
    function getListingCount() external view returns (uint256) {
        return allListingIds.length;
    }

    /// @notice Get listing ID by index
    function getListingByIndex(uint256 index) external view returns (bytes32) {
        return allListingIds[index];
    }
}
