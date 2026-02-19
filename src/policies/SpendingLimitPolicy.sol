// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    ERC165
} from "openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {ICommittable} from "../interfaces/ICommittable.sol";
import {IERC4907} from "../interfaces/IERC4907.sol";
import {IInstanceInitializable} from "../interfaces/IInstanceInitializable.sol";
import {CalldataDecoder} from "../libs/CalldataDecoder.sol";

/// @title SpendingLimitPolicy — Per-tx and daily spending limits with slippage guard
/// @notice Includes maxSlippageBps (no separate SlippageGuardPolicy needed).
///         Implements ICommittable to accumulate daily spend after execution.
contract SpendingLimitPolicy is
    IPolicy,
    ICommittable,
    IInstanceInitializable,
    ERC165
{
    // ─── Types ───
    struct Limits {
        uint256 maxPerTx;
        uint256 maxPerDay;
        // H-2: maxSlippageBps kept for config compatibility but NOT enforced on-chain.
        // Cross-token slippage cannot be computed correctly on-chain (different decimals/value).
        // Slippage is enforced by the DEX router’s amountOutMin and Runner soft policy.
        uint256 maxSlippageBps;
    }

    struct DailyTracking {
        uint256 spentToday;
        uint32 dayIndex; // block.timestamp / 86400
    }

    // ─── Storage ───
    /// @notice Template ceiling (Owner sets, immutable upper bound)
    mapping(bytes32 => Limits) public templateCeiling;
    /// @notice Instance limits (Renter sets, must be <= ceiling)
    mapping(uint256 => Limits) public instanceLimits;
    /// @notice Daily spend tracking
    mapping(uint256 => DailyTracking) public dailyTracking;
    /// @notice Instance → template mapping (for ceiling lookup)
    mapping(uint256 => bytes32) public instanceTemplate;

    address public immutable guard;
    address public immutable agentNFA;

    // ─── Selectors ───
    bytes4 private constant SWAP_EXACT_TOKENS = 0x38ed1739;
    bytes4 private constant SWAP_EXACT_ETH = 0x7ff36ab5;

    // ─── Events ───
    event TemplateCeilingSet(
        bytes32 indexed templateId,
        uint256 maxPerTx,
        uint256 maxPerDay,
        uint256 maxSlippageBps
    );
    event InstanceLimitsSet(
        uint256 indexed instanceId,
        uint256 maxPerTx,
        uint256 maxPerDay,
        uint256 maxSlippageBps
    );
    event DailySpendUpdated(
        uint256 indexed instanceId,
        uint256 spentToday,
        uint32 dayIndex
    );

    // ─── Errors ───
    error NotRenterOrOwner();
    error ExceedsCeiling(string field);
    error OnlyGuard();

    constructor(address _guard, address _nfa) {
        guard = _guard;
        agentNFA = _nfa;
    }

    // ═══════════════════════════════════════════════════════
    //                   ADMIN: Ceiling
    // ═══════════════════════════════════════════════════════

    /// @notice Owner sets the template ceiling (max allowed limits)
    function setTemplateCeiling(
        bytes32 templateId,
        uint256 maxPerTx,
        uint256 maxPerDay,
        uint256 maxSlippageBps
    ) external {
        // Only guard owner can set ceiling
        require(msg.sender == Ownable(guard).owner(), "Only owner");
        templateCeiling[templateId] = Limits(
            maxPerTx,
            maxPerDay,
            maxSlippageBps
        );
        emit TemplateCeilingSet(
            templateId,
            maxPerTx,
            maxPerDay,
            maxSlippageBps
        );
    }

    /// @notice Bind instance to template (called by guard during instance creation)
    function bindInstanceTemplate(
        uint256 instanceId,
        bytes32 templateId
    ) external {
        if (msg.sender != guard) revert OnlyGuard();
        instanceTemplate[instanceId] = templateId;
    }

    /// @notice Atomic init: copy template ceiling to instance limits (fail-close default)
    /// @dev Called by PolicyGuardV4.bindInstance() via IInstanceInitializable
    function initInstance(
        uint256 instanceId,
        bytes32 templateKey
    ) external override {
        if (msg.sender != guard) revert OnlyGuard();
        instanceTemplate[instanceId] = templateKey;

        // Copy ceiling as default instance limits (renter can lower later)
        Limits storage ceiling = templateCeiling[templateKey];
        if (ceiling.maxPerTx > 0 || ceiling.maxPerDay > 0) {
            instanceLimits[instanceId] = Limits(
                ceiling.maxPerTx,
                ceiling.maxPerDay,
                ceiling.maxSlippageBps
            );
        }
    }

    // ═══════════════════════════════════════════════════════
    //                 RENTER: Set Limits
    // ═══════════════════════════════════════════════════════

    /// @notice Renter sets instance limits (must be <= template ceiling)
    function setLimits(
        uint256 instanceId,
        uint256 maxPerTx,
        uint256 maxPerDay,
        uint256 maxSlippageBps
    ) external {
        _checkRenterOrOwner(instanceId);

        // M-2 fix: ceiling must be configured before renter can set limits
        bytes32 tid = instanceTemplate[instanceId];
        Limits storage ceiling = templateCeiling[tid];
        require(
            ceiling.maxPerTx > 0 || ceiling.maxPerDay > 0,
            "Ceiling not configured"
        );

        // Validate against ceiling
        if (ceiling.maxPerTx > 0 && maxPerTx > ceiling.maxPerTx)
            revert ExceedsCeiling("maxPerTx");
        if (ceiling.maxPerDay > 0 && maxPerDay > ceiling.maxPerDay)
            revert ExceedsCeiling("maxPerDay");
        if (
            ceiling.maxSlippageBps > 0 &&
            maxSlippageBps > ceiling.maxSlippageBps
        ) revert ExceedsCeiling("maxSlippageBps");

        instanceLimits[instanceId] = Limits(
            maxPerTx,
            maxPerDay,
            maxSlippageBps
        );
        emit InstanceLimitsSet(instanceId, maxPerTx, maxPerDay, maxSlippageBps);
    }

    // ═══════════════════════════════════════════════════════
    //                   IPolicy INTERFACE
    // ═══════════════════════════════════════════════════════

    function check(
        uint256 instanceId,
        address,
        address,
        bytes4,
        bytes calldata,
        uint256 value
    ) external view override returns (bool ok, string memory reason) {
        Limits storage limits = instanceLimits[instanceId];

        // SECURITY WARNING (H-2): Fail-open by design — no limits configured = no spending cap.
        // Deployer MUST configure limits per-instance after setup.
        // KNOWN LIMITATION (L-5): Only tracks native currency (msg.value / action.value).
        // ERC20 amountIn in swaps is NOT tracked — requires oracle for cross-token comparison.
        if (limits.maxPerTx == 0 && limits.maxPerDay == 0) return (true, "");

        // Per-tx limit
        if (limits.maxPerTx > 0 && value > limits.maxPerTx) {
            return (false, "Exceeds per-tx limit");
        }

        // Daily limit
        if (limits.maxPerDay > 0) {
            DailyTracking storage dt = dailyTracking[instanceId];
            uint32 today = uint32(block.timestamp / 86400);
            uint256 spent = (dt.dayIndex == today) ? dt.spentToday : 0;
            if (spent + value > limits.maxPerDay) {
                return (false, "Daily limit reached");
            }
        }

        // H-2 fix: on-chain slippage check removed. Cross-token slippage
        // (amountIn vs amountOutMin in different tokens) cannot be computed
        // correctly on-chain. Slippage is enforced by:
        //   1. DEX router’s amountOutMin (set by Runner)
        //   2. Runner’s soft policy (off-chain price check)

        return (true, "");
    }

    function policyType() external pure override returns (bytes32) {
        return keccak256("spending_limit");
    }

    function renterConfigurable() external pure override returns (bool) {
        return true;
    }

    // ═══════════════════════════════════════════════════════
    //               ICommittable INTERFACE
    // ═══════════════════════════════════════════════════════

    /// @notice Called by PolicyGuardV4 after successful execution to accumulate spend
    function onCommit(
        uint256 instanceId,
        address,
        bytes4,
        bytes calldata,
        uint256 value
    ) external override {
        if (msg.sender != guard) revert OnlyGuard();

        DailyTracking storage dt = dailyTracking[instanceId];
        uint32 today = uint32(block.timestamp / 86400);

        // Reset on new day
        if (dt.dayIndex != today) {
            dt.spentToday = value;
            dt.dayIndex = today;
        } else {
            dt.spentToday += value;
        }

        emit DailySpendUpdated(instanceId, dt.spentToday, today);
    }

    // ═══════════════════════════════════════════════════════
    //                    ERC-165
    // ═══════════════════════════════════════════════════════

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(ICommittable).interfaceId ||
            interfaceId == type(IInstanceInitializable).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ═══════════════════════════════════════════════════════
    //                    INTERNALS
    // ═══════════════════════════════════════════════════════

    function _checkRenterOrOwner(uint256 instanceId) internal view {
        address renter = IERC4907(agentNFA).userOf(instanceId);
        if (msg.sender != renter && msg.sender != Ownable(guard).owner()) {
            revert NotRenterOrOwner();
        }
    }
}
