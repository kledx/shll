// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPolicy} from "../interfaces/IPolicy.sol";
import {CalldataDecoder} from "../libs/CalldataDecoder.sol";

/// @title ReceiverGuardPolicy — Ensure swap output goes back to the Agent's vault
/// @notice This is a non-configurable safety policy. Owner sets, renter cannot remove.
contract ReceiverGuardPolicy is IPolicy {
    // ─── Storage ───
    address public immutable agentNFA;

    // ─── Selectors ───
    bytes4 private constant SWAP_EXACT_TOKENS = 0x38ed1739;
    bytes4 private constant SWAP_EXACT_ETH = 0x7ff36ab5;

    constructor(address _nfa) {
        agentNFA = _nfa;
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
        address recipient;

        if (selector == SWAP_EXACT_TOKENS) {
            (, , , recipient, ) = CalldataDecoder.decodeSwap(callData);
        } else if (selector == SWAP_EXACT_ETH) {
            (, , recipient, ) = CalldataDecoder.decodeSwapETH(callData);
        } else {
            // Non-swap actions pass through
            return (true, "");
        }

        // Vault = accountOf(instanceId)
        address vault = IAgentNFAView(agentNFA).accountOf(instanceId);
        if (recipient != vault) {
            return (false, "Receiver must be vault");
        }
        return (true, "");
    }

    function policyType() external pure override returns (bytes32) {
        return keccak256("receiver_guard");
    }

    function renterConfigurable() external pure override returns (bool) {
        return false; // Owner sets, renter cannot remove
    }
}

/// @dev Minimal interface to avoid full IAgentNFA import
interface IAgentNFAView {
    function accountOf(uint256 tokenId) external view returns (address);
}
