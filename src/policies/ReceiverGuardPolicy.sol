// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPolicy} from "../interfaces/IPolicy.sol";
import {CalldataDecoder} from "../libs/CalldataDecoder.sol";

/// @title ReceiverGuardPolicy — Ensure swap output goes back to the Agent's vault
/// @notice This is a non-configurable safety policy. Owner sets, renter cannot remove.
contract ReceiverGuardPolicy is IPolicy {
    // ─── Storage ───
    address public immutable agentNFA;

    // --- Selectors: All PancakeSwap V2 Router swap variants ---
    // Group A: same decode layout as swapExactTokensForTokens (5 params: amount, amount, path, to, deadline)
    bytes4 private constant SWAP_EXACT_TOKENS = 0x38ed1739; // swapExactTokensForTokens
    bytes4 private constant SWAP_TOKENS_EXACT = 0x8803dbee; // swapTokensForExactTokens
    bytes4 private constant SWAP_TOKENS_EXACT_ETH = 0x4a25d94a; // swapTokensForExactETH
    bytes4 private constant SWAP_EXACT_TOKENS_ETH = 0x791ac947; // swapExactTokensForETHSupportingFeeOnTransferTokens
    bytes4 private constant SWAP_EXACT_TOKENS_FEE = 0x5c11d795; // swapExactTokensForTokensSupportingFeeOnTransferTokens
    // Group B: same decode layout as swapExactETHForTokens (4 params: amount, path, to, deadline)
    bytes4 private constant SWAP_EXACT_ETH = 0x7ff36ab5; // swapExactETHForTokens
    bytes4 private constant SWAP_EXACT_ETH_FEE = 0xb6f9de95; // swapExactETHForTokensSupportingFeeOnTransferTokens

    constructor(address _nfa) {
        agentNFA = _nfa;
    }

    // ═══════════════════════════════════════════════════════
    //                   IPolicy INTERFACE
    // ═══════════════════════════════════════════════════════

    function check(
        uint256 instanceId,
        address,
        address target,
        bytes4 selector,
        bytes calldata callData,
        uint256 value
    ) external view override returns (bool ok, string memory reason) {
        // H-3 fix: Block empty-calldata native value transfers to non-vault addresses.
        // Previously, non-swap selectors were unconditionally passed through, allowing
        // an operator to drain native currency via execute(target=attacker, value=balance, data="").
        if (selector == bytes4(0) && value > 0) {
            address vault = IAgentNFAView(agentNFA).accountOf(instanceId);
            if (target != vault) {
                return (false, "Native transfer must target vault");
            }
            return (true, "");
        }

        address recipient;

        // Group A: 5-param swap decode (swapExactTokensForTokens layout)
        if (
            selector == SWAP_EXACT_TOKENS ||
            selector == SWAP_TOKENS_EXACT ||
            selector == SWAP_TOKENS_EXACT_ETH ||
            selector == SWAP_EXACT_TOKENS_ETH ||
            selector == SWAP_EXACT_TOKENS_FEE
        ) {
            (, , , recipient, ) = CalldataDecoder.decodeSwap(callData);
        } else if (
            selector == SWAP_EXACT_ETH || selector == SWAP_EXACT_ETH_FEE
        ) {
            (, , recipient, ) = CalldataDecoder.decodeSwapETH(callData);
        } else {
            // Non-swap actions: if carrying native value, must target vault.
            // Prevents sending ETH to arbitrary contracts via non-swap function calls.
            if (value > 0) {
                if (target != IAgentNFAView(agentNFA).accountOf(instanceId)) {
                    return (false, "Value transfer must target vault");
                }
            }
            return (true, "");
        }

        // Vault = accountOf(instanceId)
        if (recipient != IAgentNFAView(agentNFA).accountOf(instanceId)) {
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
