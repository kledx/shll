// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {IERC4907} from "../interfaces/IERC4907.sol";
import {CalldataDecoder} from "../libs/CalldataDecoder.sol";

/// @title TokenWhitelistPolicy — Only allow swaps involving whitelisted tokens
/// @notice Uses address mapping instead of bitmap for unlimited token support.
contract TokenWhitelistPolicy is IPolicy {
    // ─── Storage ───
    mapping(uint256 => mapping(address => bool)) public tokenAllowed;
    mapping(uint256 => address[]) internal _tokenList;

    address public immutable guard;
    address public immutable agentNFA;

    // ─── Selectors ───
    bytes4 private constant SWAP_EXACT_TOKENS = 0x38ed1739;
    bytes4 private constant SWAP_EXACT_ETH = 0x7ff36ab5;

    // ─── Events ───
    event TokenAdded(uint256 indexed instanceId, address indexed token);
    event TokenRemoved(uint256 indexed instanceId, address indexed token);

    // ─── Errors ───
    error NotRenterOrOwner();
    error TokenAlreadyAdded();

    constructor(address _guard, address _nfa) {
        guard = _guard;
        agentNFA = _nfa;
    }

    // ═══════════════════════════════════════════════════════
    //                   CONFIGURATION
    // ═══════════════════════════════════════════════════════

    function addToken(uint256 instanceId, address token) external {
        _checkRenterOrOwner(instanceId);
        if (tokenAllowed[instanceId][token]) revert TokenAlreadyAdded();
        tokenAllowed[instanceId][token] = true;
        _tokenList[instanceId].push(token);
        emit TokenAdded(instanceId, token);
    }

    function removeToken(uint256 instanceId, address token) external {
        _checkRenterOrOwner(instanceId);
        tokenAllowed[instanceId][token] = false;
        // M-4 fix: only emit event when token is actually found and removed
        address[] storage list = _tokenList[instanceId];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == token) {
                list[i] = list[list.length - 1];
                list.pop();
                emit TokenRemoved(instanceId, token);
                return;
            }
        }
    }

    /// @notice Get all whitelisted tokens for an instance
    function getTokenList(
        uint256 instanceId
    ) external view returns (address[] memory) {
        return _tokenList[instanceId];
    }

    // ═══════════════════════════════════════════════════════
    //                   IPolicy INTERFACE
    // ═══════════════════════════════════════════════════════

    function check(
        uint256 instanceId,
        address,
        address,
        bytes4 selector,
        bytes calldata callData,
        uint256
    ) external view override returns (bool ok, string memory reason) {
        // If no whitelist configured, allow all
        if (_tokenList[instanceId].length == 0) return (true, "");

        if (selector == SWAP_EXACT_TOKENS) {
            (, , address[] memory path, , ) = CalldataDecoder.decodeSwap(
                callData
            );
            return _checkPath(instanceId, path);
        } else if (selector == SWAP_EXACT_ETH) {
            (, address[] memory path, , ) = CalldataDecoder.decodeSwapETH(
                callData
            );
            return _checkPath(instanceId, path);
        }

        // Non-swap selectors pass through (e.g. approve)
        return (true, "");
    }

    function policyType() external pure override returns (bytes32) {
        return keccak256("token_whitelist");
    }

    function renterConfigurable() external pure override returns (bool) {
        return true;
    }

    // ═══════════════════════════════════════════════════════
    //                     INTERNALS
    // ═══════════════════════════════════════════════════════

    function _checkPath(
        uint256 instanceId,
        address[] memory path
    ) internal view returns (bool, string memory) {
        for (uint256 i = 0; i < path.length; i++) {
            if (!tokenAllowed[instanceId][path[i]]) {
                return (false, "Token not in whitelist");
            }
        }
        return (true, "");
    }

    function _checkRenterOrOwner(uint256 instanceId) internal view {
        address renter = IERC4907(agentNFA).userOf(instanceId);
        if (msg.sender != renter && msg.sender != Ownable(guard).owner()) {
            revert NotRenterOrOwner();
        }
    }
}
