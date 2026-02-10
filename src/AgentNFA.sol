// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";
import {IERC4907} from "./interfaces/IERC4907.sol";

import {IPolicyGuard} from "./interfaces/IPolicyGuard.sol";
import {IAgentAccount} from "./interfaces/IAgentAccount.sol";
import {AgentAccount} from "./AgentAccount.sol";
import {Action} from "./types/Action.sol";
import {Errors} from "./libs/Errors.sol";

/// @title AgentNFA — Non-Fungible Agent with ERC-4907 rental capability
/// @notice Identity layer: mint agents, manage rentals, route execution through PolicyGuard
contract AgentNFA is ERC721, ERC721URIStorage, IERC4907, Ownable, Pausable {
    // ─── State ───
    uint256 private _nextTokenId;

    /// @notice tokenId => AgentAccount address
    mapping(uint256 => address) private _accountOf;

    /// @notice tokenId => policy template id
    mapping(uint256 => bytes32) private _policyIdOf;

    /// @notice ERC-4907: tokenId => user (renter)
    mapping(uint256 => address) private _users;

    /// @notice ERC-4907: tokenId => user expiry timestamp
    mapping(uint256 => uint64) private _userExpires;

    /// @notice The PolicyGuard contract
    address public policyGuard;

    /// @notice The ListingManager contract (only it can call setUser)
    address public listingManager;

    // ─── Events (from IAgentNFA) ───
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

    constructor(address _policyGuard) ERC721("ShellAgent", "SHLL") {
        if (_policyGuard == address(0)) revert Errors.ZeroAddress();
        policyGuard = _policyGuard;
    }

    // ═══════════════════════════════════════════════════════════
    //                    ADMIN
    // ═══════════════════════════════════════════════════════════

    function setListingManager(address _listingManager) external onlyOwner {
        listingManager = _listingManager;
    }

    function setPolicyGuard(address _policyGuard) external onlyOwner {
        policyGuard = _policyGuard;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════
    //                    MINT
    // ═══════════════════════════════════════════════════════════

    /// @notice Mint a new Agent NFA with a dedicated AgentAccount
    function mintAgent(address to, bytes32 policyId, string calldata uri)
        external
        onlyOwner
        returns (uint256 tokenId)
    {
        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);

        // Deploy a dedicated AgentAccount for this NFA
        AgentAccount account = new AgentAccount(address(this), tokenId);
        _accountOf[tokenId] = address(account);
        _policyIdOf[tokenId] = policyId;

        emit AgentMinted(tokenId, to, address(account), policyId);
    }

    // ═══════════════════════════════════════════════════════════
    //                    ERC-4907 (RENTAL)
    // ═══════════════════════════════════════════════════════════

    /// @notice Set the user (renter) for an NFA — only callable by ListingManager
    function setUser(uint256 tokenId, address user, uint64 expires) external override {
        // Only ListingManager or owner can set user
        if (msg.sender != listingManager && msg.sender != owner()) {
            revert Errors.OnlyListingManager();
        }
        _users[tokenId] = user;
        _userExpires[tokenId] = expires;
        emit UpdateUser(tokenId, user, expires);
        emit LeaseSet(tokenId, user, expires);
    }

    /// @notice Get current user (returns address(0) if expired)
    function userOf(uint256 tokenId) public view override returns (address) {
        if (uint256(_userExpires[tokenId]) >= block.timestamp) {
            return _users[tokenId];
        }
        return address(0);
    }

    /// @notice Get user expiry timestamp
    function userExpires(uint256 tokenId) public view override returns (uint256) {
        return _userExpires[tokenId];
    }

    // ═══════════════════════════════════════════════════════════
    //                    EXECUTE (CORE)
    // ═══════════════════════════════════════════════════════════

    /// @notice Execute a single action through the Agent
    function execute(uint256 tokenId, Action calldata action)
        external
        payable
        whenNotPaused
        returns (bytes memory result)
    {
        address account = _accountOf[tokenId];
        _checkExecutePermission(tokenId, account, action);

        (bool success, bytes memory out) =
            IAgentAccount(account).executeCall(action.target, action.value, action.data);

        bytes4 selector = action.data.length >= 4 ? bytes4(action.data[:4]) : bytes4(0);
        emit Executed(tokenId, msg.sender, account, action.target, selector, success, out);

        if (!success) revert Errors.ExecutionFailed();
        return out;
    }

    /// @notice Execute multiple actions in a batch
    function executeBatch(uint256 tokenId, Action[] calldata actions)
        external
        payable
        whenNotPaused
        returns (bytes[] memory results)
    {
        address account = _accountOf[tokenId];
        results = new bytes[](actions.length);

        for (uint256 i = 0; i < actions.length; i++) {
            _checkExecutePermission(tokenId, account, actions[i]);

            (bool success, bytes memory out) =
                IAgentAccount(account).executeCall(actions[i].target, actions[i].value, actions[i].data);

            bytes4 selector = actions[i].data.length >= 4 ? bytes4(actions[i].data[:4]) : bytes4(0);
            emit Executed(tokenId, msg.sender, account, actions[i].target, selector, success, out);

            if (!success) revert Errors.ExecutionFailed();
            results[i] = out;
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                    POLICY
    // ═══════════════════════════════════════════════════════════

    /// @notice Update the policy template for an NFA (owner only)
    function setPolicy(uint256 tokenId, bytes32 newPolicyId) external {
        if (msg.sender != ownerOf(tokenId)) revert Errors.OnlyOwner();
        bytes32 oldPolicyId = _policyIdOf[tokenId];
        _policyIdOf[tokenId] = newPolicyId;
        emit PolicyUpdated(tokenId, oldPolicyId, newPolicyId);
    }

    // ═══════════════════════════════════════════════════════════
    //                    VIEWS
    // ═══════════════════════════════════════════════════════════

    function accountOf(uint256 tokenId) external view returns (address) {
        return _accountOf[tokenId];
    }

    function policyIdOf(uint256 tokenId) external view returns (bytes32) {
        return _policyIdOf[tokenId];
    }

    // ═══════════════════════════════════════════════════════════
    //                    INTERNAL
    // ═══════════════════════════════════════════════════════════

    /// @dev Check execute permission and run PolicyGuard for renters
    function _checkExecutePermission(uint256 tokenId, address account, Action calldata action) internal view {
        address tokenOwner = ownerOf(tokenId);
        address renter = userOf(tokenId);

        if (msg.sender == tokenOwner) {
            // Owner can execute without PolicyGuard check
            return;
        }

        if (msg.sender == renter) {
            // Renter must be within lease period (userOf returns 0 if expired)
            // Already handled by userOf() returning address(0)
            if (renter == address(0)) revert Errors.LeaseExpired();

            // Renter MUST pass PolicyGuard validation
            (bool ok, string memory reason) =
                IPolicyGuard(policyGuard).validate(address(this), tokenId, account, msg.sender, action);
            if (!ok) revert Errors.PolicyViolation(reason);
            return;
        }

        revert Errors.Unauthorized();
    }

    // ─── ERC721 overrides (OZ v4 requires these) ───
    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
