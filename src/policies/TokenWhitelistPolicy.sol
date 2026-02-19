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

    // --- Selectors: All PancakeSwap V2 Router swap variants ---
    // Group A: 5-param layout (amount, amount, path, to, deadline)
    bytes4 private constant SWAP_EXACT_TOKENS = 0x38ed1739; // swapExactTokensForTokens
    bytes4 private constant SWAP_TOKENS_EXACT = 0x8803dbee; // swapTokensForExactTokens
    bytes4 private constant SWAP_TOKENS_EXACT_ETH = 0x4a25d94a; // swapTokensForExactETH
    bytes4 private constant SWAP_EXACT_TOKENS_ETH = 0x791ac947; // swapExactTokensForETHSupportingFeeOnTransferTokens
    bytes4 private constant SWAP_EXACT_TOKENS_FEE = 0x5c11d795; // swapExactTokensForTokensSupportingFeeOnTransferTokens
    // Group B: 4-param layout (amount, path, to, deadline)
    bytes4 private constant SWAP_EXACT_ETH = 0x7ff36ab5; // swapExactETHForTokens
    bytes4 private constant SWAP_EXACT_ETH_FEE = 0xb6f9de95; // swapExactETHForTokensSupportingFeeOnTransferTokens

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
        // SECURITY WARNING (H-2): Fail-open by design — empty whitelist = all tokens allowed.
        // Deployer MUST configure token whitelist per-instance after setup.
        if (_tokenList[instanceId].length == 0) return (true, "");

        // Group A: 5-param swap decode (swapExactTokensForTokens layout)
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
