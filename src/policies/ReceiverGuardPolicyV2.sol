// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPolicy} from "../interfaces/IPolicy.sol";
import {
    ERC165
} from "openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title ReceiverGuardPolicyV2 — Configurable swap-recipient guard
/// @notice Ensures swap output always returns to the Agent's vault.
///         Owner registers (selector → decode pattern) so adding new DEXes
///         never requires contract redeployment.
/// @dev Decode patterns:
///   1 = V2_5PARAM: 5-param swap (amount, amount, path, to, deadline) → to at word 3
///   2 = V2_4PARAM: 4-param swap (amount, path, to, deadline)         → to at word 2
///   3 = V3_STRUCT_RECIPIENT_W3: struct with recipient at word 3      → e.g. exactInputSingle
///   4 = V3_STRUCT_RECIPIENT_W1: struct with recipient at word 1      → e.g. exactInput
///   0 = UNKNOWN: not a swap → if value > 0, target must be vault
contract ReceiverGuardPolicyV2 is IPolicy, ERC165 {
    address public agentNFA;
    address public immutable guard;

    // selector → decode pattern (0 = unknown, 1-4 = see above)
    mapping(bytes4 => uint8) public selectorPattern;

    event PatternSet(bytes4 indexed selector, uint8 pattern);
    event PatternBatchSet(bytes4[] selectors, uint8 pattern);
    event AgentNFAUpdated(address indexed oldNFA, address indexed newNFA);

    error OnlyOwner();

    constructor(address _nfa, address _guard) {
        agentNFA = _nfa;
        guard = _guard;

        // Pre-register PancakeSwap V2 selectors
        // Group A: V2_5PARAM (to at word 3)
        selectorPattern[0x38ed1739] = 1; // swapExactTokensForTokens
        selectorPattern[0x8803dbee] = 1; // swapTokensForExactTokens
        selectorPattern[0x4a25d94a] = 1; // swapTokensForExactETH
        selectorPattern[0x791ac947] = 1; // swapExactTokensForETHSupportingFeeOnTransferTokens
        selectorPattern[0x5c11d795] = 1; // swapExactTokensForTokensSupportingFeeOnTransferTokens

        // Group B: V2_4PARAM (to at word 2)
        selectorPattern[0x7ff36ab5] = 2; // swapExactETHForTokens
        selectorPattern[0xb6f9de95] = 2; // swapExactETHForTokensSupportingFeeOnTransferTokens

        // PancakeSwap V3: V3_STRUCT_RECIPIENT_W3 (recipient at word 3)
        selectorPattern[0x04e45aaf] = 3; // exactInputSingle
    }

    // ═══════════════════════════════════════════════════════
    //                    ADMIN
    // ═══════════════════════════════════════════════════════

    function setAgentNFA(address _nfa) external {
        _onlyOwner();
        require(_nfa != address(0), "zero address");
        emit AgentNFAUpdated(agentNFA, _nfa);
        agentNFA = _nfa;
    }

    function setPattern(bytes4 selector, uint8 pattern) external {
        _onlyOwner();
        selectorPattern[selector] = pattern;
        emit PatternSet(selector, pattern);
    }

    function setPatternBatch(
        bytes4[] calldata selectors,
        uint8 pattern
    ) external {
        _onlyOwner();
        for (uint256 i = 0; i < selectors.length; i++) {
            selectorPattern[selectors[i]] = pattern;
        }
        emit PatternBatchSet(selectors, pattern);
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
        // H-3: Block empty-calldata native transfers to non-vault
        if (selector == bytes4(0) && value > 0) {
            address vault = IAgentNFAView(agentNFA).accountOf(instanceId);
            if (target != vault) {
                return (false, "Native transfer must target vault");
            }
            return (true, "");
        }

        uint8 pattern = selectorPattern[selector];

        if (pattern == 0) {
            // Unknown selector: if carrying BNB, target must be vault
            if (value > 0) {
                if (target != IAgentNFAView(agentNFA).accountOf(instanceId)) {
                    return (false, "Value transfer must target vault");
                }
            }
            return (true, "");
        }

        // Extract recipient based on registered decode pattern
        // NOTE: callData includes the 4-byte selector, so real param data starts at offset 4
        address recipient;

        if (pattern == 1) {
            // V2_5PARAM: (amount, amount, path, to, deadline) → to at word 3
            // offset = 4 (selector) + 3*32 = 100
            recipient = address(uint160(uint256(bytes32(callData[100:132]))));
        } else if (pattern == 2) {
            // V2_4PARAM: (amount, path, to, deadline) → to at word 2
            // offset = 4 (selector) + 2*32 = 68
            recipient = address(uint160(uint256(bytes32(callData[68:100]))));
        } else if (pattern == 3) {
            // V3_STRUCT_RECIPIENT_W3: struct with recipient at word 3
            // e.g. exactInputSingle({tokenIn, tokenOut, fee, recipient, ...})
            // offset = 4 (selector) + 3*32 = 100
            recipient = address(uint160(uint256(bytes32(callData[100:132]))));
        } else if (pattern == 4) {
            // V3_STRUCT_RECIPIENT_W1: struct with dynamic bytes as first field
            // e.g. exactInput({bytes path, address recipient, ...})
            // ABI: word0 = offset to tuple, tuple.word0 = offset to bytes, tuple.word1 = recipient
            // offset = 4 (selector) + 2*32 = 68
            recipient = address(uint160(uint256(bytes32(callData[68:100]))));
        } else {
            return (true, ""); // Fallback: allow (unknown pattern registered)
        }

        // Verify recipient is the vault
        if (recipient != IAgentNFAView(agentNFA).accountOf(instanceId)) {
            return (false, "Receiver must be vault");
        }
        return (true, "");
    }

    function policyType() external pure override returns (bytes32) {
        return keccak256("receiver_guard");
    }

    function renterConfigurable() external pure override returns (bool) {
        return false;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IPolicy).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function _onlyOwner() internal view {
        require(msg.sender == Ownable(guard).owner(), "Only owner");
    }
}

interface IAgentNFAView {
    function accountOf(uint256 tokenId) external view returns (address);
}
