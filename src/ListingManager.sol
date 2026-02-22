// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Ownable2Step,
    Ownable
} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {
    ReentrancyGuard
} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {
    IERC721
} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IAgentNFA} from "./interfaces/IAgentNFA.sol";
import {IPolicyGuard} from "./interfaces/IPolicyGuard.sol";
import {Errors} from "./libs/Errors.sol";

/// @title ListingManager
/// @notice Manages template listings and rent-to-mint instances
contract ListingManager is Ownable2Step, ReentrancyGuard {
    struct Listing {
        address nfa;
        uint256 tokenId;
        address owner;
        uint96 pricePerDay;
        uint32 minDays;
        bool active;
    }

    struct ListingConfig {
        uint32 maxDays; // 0 = unlimited
    }

    /// @notice listingId => Listing
    mapping(bytes32 => Listing) public listings;

    /// @notice list of all listing IDs
    bytes32[] public allListingIds;

    /// @notice listingId => config
    mapping(bytes32 => ListingConfig) public listingConfigs;

    /// @notice owner => accumulated income
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice listingId => paused flag
    mapping(bytes32 => bool) public rentingPaused;

    /// @notice policy guard for instance binding
    address public policyGuard;

    /// @notice V-001 fix: only the trusted AgentNFA can be listed
    address public agentNFA;

    event TemplateListingCreated(
        bytes32 indexed listingId,
        address indexed nfa,
        uint256 indexed tokenId,
        uint96 pricePerDay,
        uint32 minDays
    );
    event ListingCanceled(bytes32 indexed listingId);
    event ListingOwnerSynced(
        bytes32 indexed listingId,
        address oldOwner,
        address newOwner
    );
    event InstanceRented(
        bytes32 indexed listingId,
        address indexed renter,
        uint256 indexed instanceTokenId,
        address instanceAccount,
        uint64 expires,
        uint256 totalPaid
    );
    event WithdrawalClaimed(address indexed owner, uint256 amount);
    event ListingConfigUpdated(bytes32 indexed listingId, uint32 maxDays);
    event RentingPaused(bytes32 indexed listingId);
    event RentingResumed(bytes32 indexed listingId);

    constructor() {}

    function setPolicyGuard(address _policyGuard) external onlyOwner {
        if (_policyGuard == address(0)) revert Errors.ZeroAddress();
        policyGuard = _policyGuard;
    }

    /// @notice V-001 fix: set the trusted AgentNFA address
    function setAgentNFA(address _nfa) external onlyOwner {
        if (_nfa == address(0)) revert Errors.ZeroAddress();
        agentNFA = _nfa;
    }

    /// @notice Creates a template listing used by rent-to-mint
    function createTemplateListing(
        address nfa,
        uint256 tokenId,
        uint96 pricePerDay,
        uint32 minDays
    ) external returns (bytes32 listingId) {
        // V-001 fix: only the trusted AgentNFA can be listed
        if (nfa != agentNFA) revert Errors.Unauthorized();
        if (IERC721(nfa).ownerOf(tokenId) != msg.sender)
            revert Errors.NotListingOwner();
        if (!IAgentNFA(nfa).isTemplate(tokenId))
            revert Errors.NotTemplate(tokenId);

        listingId = keccak256(abi.encodePacked(nfa, tokenId));
        if (listings[listingId].active) revert Errors.ListingAlreadyExists();

        listings[listingId] = Listing({
            nfa: nfa,
            tokenId: tokenId,
            owner: msg.sender,
            pricePerDay: pricePerDay,
            minDays: minDays,
            active: true
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

    function cancelListing(bytes32 listingId) external {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        address currentOwner = _syncListingOwner(listing);
        if (currentOwner != msg.sender) revert Errors.NotListingOwner();

        listing.active = false;
        emit ListingCanceled(listingId);
    }

    /// @notice Rents by minting a dedicated instance for the renter
    function rentToMintWithParams(
        bytes32 listingId,
        uint32 daysToRent,
        uint32,
        uint16,
        bytes calldata paramsPacked
    ) external payable nonReentrant returns (uint256 instanceId) {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        _syncListingOwner(listing);
        if (rentingPaused[listingId]) revert Errors.RentingPaused();
        if (daysToRent < listing.minDays)
            revert Errors.MinDaysNotMet(daysToRent, listing.minDays);
        if (policyGuard == address(0)) revert Errors.ExecutionFailed();

        ListingConfig storage cfg = listingConfigs[listingId];
        if (cfg.maxDays > 0 && daysToRent > cfg.maxDays) {
            revert Errors.MaxDaysExceeded(daysToRent, cfg.maxDays);
        }

        uint256 totalCost = uint256(listing.pricePerDay) * uint256(daysToRent);
        if (msg.value < totalCost)
            revert Errors.InsufficientPayment(totalCost, msg.value);

        uint64 expires = uint64(block.timestamp + uint256(daysToRent) * 1 days);
        instanceId = IAgentNFA(listing.nfa).mintInstanceFromTemplate(
            msg.sender,
            listing.tokenId,
            expires,
            paramsPacked
        );

        bytes32 templateKey = IAgentNFA(listing.nfa).templateKeyOf(
            listing.tokenId
        );
        if (templateKey == bytes32(0)) revert Errors.InvalidInitParams();
        IPolicyGuard(policyGuard).bindInstance(instanceId, templateKey);

        pendingWithdrawals[listing.owner] += totalCost;

        if (msg.value > totalCost) {
            (bool okRef, ) = msg.sender.call{value: msg.value - totalCost}("");
            if (!okRef) revert Errors.ExecutionFailed();
        }

        address instanceAccountAddr = IAgentNFA(listing.nfa).accountOf(
            instanceId
        );
        emit InstanceRented(
            listingId,
            msg.sender,
            instanceId,
            instanceAccountAddr,
            expires,
            totalCost
        );
    }

    function claimRentalIncome() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert Errors.InsufficientBalance();

        pendingWithdrawals[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert Errors.ExecutionFailed();

        emit WithdrawalClaimed(msg.sender, amount);
    }

    function setListingConfig(bytes32 listingId, uint32 maxDays) external {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        address currentOwner = _syncListingOwner(listing);
        if (currentOwner != msg.sender) revert Errors.NotListingOwner();

        listingConfigs[listingId] = ListingConfig(maxDays);
        emit ListingConfigUpdated(listingId, maxDays);
    }

    function pauseRenting(bytes32 listingId) external {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        address currentOwner = _syncListingOwner(listing);
        if (currentOwner != msg.sender) revert Errors.NotListingOwner();

        rentingPaused[listingId] = true;
        emit RentingPaused(listingId);
    }

    function resumeRenting(bytes32 listingId) external {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert Errors.ListingNotFound();
        address currentOwner = _syncListingOwner(listing);
        if (currentOwner != msg.sender) revert Errors.NotListingOwner();

        rentingPaused[listingId] = false;
        emit RentingResumed(listingId);
    }

    function getListingId(
        address nfa,
        uint256 tokenId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(nfa, tokenId));
    }

    function getListingCount() external view returns (uint256) {
        return allListingIds.length;
    }

    function getListingByIndex(uint256 index) external view returns (bytes32) {
        return allListingIds[index];
    }

    function _syncListingOwner(
        Listing storage listing
    ) internal returns (address currentOwner) {
        currentOwner = IERC721(listing.nfa).ownerOf(listing.tokenId);
        if (currentOwner != listing.owner) {
            address oldOwner = listing.owner;
            listing.owner = currentOwner;
            bytes32 listingId = keccak256(
                abi.encodePacked(listing.nfa, listing.tokenId)
            );
            emit ListingOwnerSynced(listingId, oldOwner, currentOwner);
        }
    }
}
