// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {IERC4907} from "../interfaces/IERC4907.sol";
import {CalldataDecoder} from "../libs/CalldataDecoder.sol";
import {IAgentNFATemplateView} from "../interfaces/IAgentNFATemplateView.sol";

/// @title TokenWhitelistPolicy
/// @notice Swap path token allowlist with template baseline + instance delta.
/// @dev Product semantics:
///      1) Template allowlist is always effective for instances.
///      2) Instance can add extra allowed tokens (incremental allow).
///      3) Instance can block tokens to tighten boundaries.
contract TokenWhitelistPolicy is IPolicy {
    // --- Storage ---
    mapping(uint256 => mapping(address => bool)) public tokenAllowed;
    mapping(uint256 => address[]) internal _tokenList;
    mapping(uint256 => bool) public hasCustomTokenList;

    mapping(uint256 => mapping(address => bool)) public tokenBlocked;
    mapping(uint256 => address[]) internal _blockedTokenList;

    address public immutable guard;
    address public immutable agentNFA;

    // --- Selectors: PancakeSwap V2 variants ---
    // Group A: 5-param layout (amount, amount, path, to, deadline)
    bytes4 private constant SWAP_EXACT_TOKENS = 0x38ed1739;
    bytes4 private constant SWAP_TOKENS_EXACT = 0x8803dbee;
    bytes4 private constant SWAP_TOKENS_EXACT_ETH = 0x4a25d94a;
    bytes4 private constant SWAP_EXACT_TOKENS_ETH = 0x791ac947;
    bytes4 private constant SWAP_EXACT_TOKENS_FEE = 0x5c11d795;
    // Group B: 4-param layout (amount, path, to, deadline)
    bytes4 private constant SWAP_EXACT_ETH = 0x7ff36ab5;
    bytes4 private constant SWAP_EXACT_ETH_FEE = 0xb6f9de95;

    // --- Events ---
    event TokenAdded(uint256 indexed instanceId, address indexed token);
    event TokenRemoved(uint256 indexed instanceId, address indexed token);
    event TokenBlocked(uint256 indexed instanceId, address indexed token);
    event TokenUnblocked(uint256 indexed instanceId, address indexed token);

    // --- Errors ---
    error NotRenterOrOwner();
    error TokenAlreadyAdded();
    error TokenAlreadyBlocked();
    error TokenBlockNotFound();

    constructor(address _guard, address _nfa) {
        guard = _guard;
        agentNFA = _nfa;
    }

    function addToken(uint256 instanceId, address token) external {
        _checkRenterOrOwner(instanceId);
        if (tokenAllowed[instanceId][token]) revert TokenAlreadyAdded();
        tokenAllowed[instanceId][token] = true;
        _tokenList[instanceId].push(token);
        if (_isInstance(instanceId)) hasCustomTokenList[instanceId] = true;
        emit TokenAdded(instanceId, token);
    }

    function removeToken(uint256 instanceId, address token) external {
        _checkRenterOrOwner(instanceId);
        tokenAllowed[instanceId][token] = false;
        _removeFromArray(_tokenList[instanceId], token);
        _refreshCustomFlag(instanceId);
        emit TokenRemoved(instanceId, token);
    }

    function getTokenList(
        uint256 instanceId
    ) external view returns (address[] memory) {
        return _tokenList[instanceId];
    }

    function blockToken(uint256 instanceId, address token) external {
        _checkRenterOrOwner(instanceId);
        if (tokenBlocked[instanceId][token]) revert TokenAlreadyBlocked();
        tokenBlocked[instanceId][token] = true;
        _blockedTokenList[instanceId].push(token);
        if (_isInstance(instanceId)) hasCustomTokenList[instanceId] = true;
        emit TokenBlocked(instanceId, token);
    }

    function unblockToken(uint256 instanceId, address token) external {
        _checkRenterOrOwner(instanceId);
        if (!tokenBlocked[instanceId][token]) revert TokenBlockNotFound();
        tokenBlocked[instanceId][token] = false;
        _removeFromArray(_blockedTokenList[instanceId], token);
        _refreshCustomFlag(instanceId);
        emit TokenUnblocked(instanceId, token);
    }

    function getBlockedTokenList(
        uint256 instanceId
    ) external view returns (address[] memory) {
        return _blockedTokenList[instanceId];
    }

    function check(
        uint256 instanceId,
        address,
        address,
        bytes4 selector,
        bytes calldata callData,
        uint256
    ) external view override returns (bool ok, string memory reason) {
        // Fail-open by product design: no allowlist config => policy passive.
        if (!_hasAnyAllowedTokens(instanceId)) return (true, "");

        if (
            selector == SWAP_EXACT_TOKENS ||
            selector == SWAP_TOKENS_EXACT ||
            selector == SWAP_TOKENS_EXACT_ETH ||
            selector == SWAP_EXACT_TOKENS_ETH ||
            selector == SWAP_EXACT_TOKENS_FEE
        ) {
            (, , address[] memory path, , ) = CalldataDecoder.decodeSwap(
                callData
            );
            return _checkPath(instanceId, path);
        } else if (
            selector == SWAP_EXACT_ETH || selector == SWAP_EXACT_ETH_FEE
        ) {
            (, address[] memory path, , ) = CalldataDecoder.decodeSwapETH(
                callData
            );
            return _checkPath(instanceId, path);
        }

        // Non-swap selectors pass through.
        return (true, "");
    }

    function policyType() external pure override returns (bytes32) {
        return keccak256("token_whitelist");
    }

    function renterConfigurable() external pure override returns (bool) {
        return true;
    }

    function _checkPath(
        uint256 instanceId,
        address[] memory path
    ) internal view returns (bool, string memory) {
        bool isInst = _isInstance(instanceId);
        uint256 templateId = isInst ? _templateIdOf(instanceId) : 0;

        for (uint256 i = 0; i < path.length; i++) {
            address token = path[i];
            if (tokenBlocked[instanceId][token]) {
                return (false, "Token blocked by instance");
            }

            bool allowed = tokenAllowed[instanceId][token];
            if (!allowed && isInst) {
                allowed = tokenAllowed[templateId][token];
            }
            if (!allowed) {
                return (false, "Token not in whitelist");
            }
        }
        return (true, "");
    }

    function _hasAnyAllowedTokens(uint256 instanceId) internal view returns (bool) {
        if (_tokenList[instanceId].length > 0) return true;
        if (_isInstance(instanceId)) {
            uint256 templateId = _templateIdOf(instanceId);
            if (_tokenList[templateId].length > 0) return true;
        }
        return false;
    }

    function _isInstance(uint256 instanceId) internal view returns (bool) {
        return IAgentNFATemplateView(agentNFA).isInstance(instanceId);
    }

    function _templateIdOf(uint256 instanceId) internal view returns (uint256) {
        return IAgentNFATemplateView(agentNFA).templateOf(instanceId);
    }

    function _refreshCustomFlag(uint256 instanceId) internal {
        if (!_isInstance(instanceId)) return;
        hasCustomTokenList[instanceId] =
            _tokenList[instanceId].length > 0 ||
            _blockedTokenList[instanceId].length > 0;
    }

    function _removeFromArray(address[] storage list, address item) internal {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == item) {
                list[i] = list[list.length - 1];
                list.pop();
                return;
            }
        }
    }

    function _checkRenterOrOwner(uint256 instanceId) internal view {
        if (msg.sender == Ownable(guard).owner()) return;
        address renter = IERC4907(agentNFA).userOf(instanceId);
        if (msg.sender == renter) return;
        if (agentNFA.code.length > 0) {
            (bool ownerOk, bytes memory ownerData) = agentNFA.staticcall(
                abi.encodeWithSelector(IERC721.ownerOf.selector, instanceId)
            );
            if (ownerOk && ownerData.length >= 32) {
                address tokenOwner = abi.decode(ownerData, (address));
                if (msg.sender == tokenOwner) return;
            }
        }
        revert NotRenterOrOwner();
    }
}
