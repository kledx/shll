// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";
import {Action} from "./types/Action.sol";
import {IPolicyGuard} from "./interfaces/IPolicyGuard.sol";
import {IAgentNFA} from "./interfaces/IAgentNFA.sol";

import {CalldataDecoder} from "./libs/CalldataDecoder.sol";
import {PolicyKeys} from "./libs/PolicyKeys.sol";

/// @title PolicyGuard — On-chain firewall for AI Agent rental protocol
/// @notice Validates every renter-initiated action against allowlists and parameter constraints
/// @dev Core security invariant: validate() MUST be called by AgentNFA.execute() — not bypassable
contract PolicyGuard is IPolicyGuard, Ownable, Pausable {
    // ─── Allowlist storage ───
    mapping(address => bool) public targetAllowed;
    mapping(address => mapping(bytes4 => bool)) public selectorAllowed;
    mapping(address => bool) public tokenAllowed;
    mapping(address => mapping(address => bool)) public spenderAllowed; // token => spender => allowed

    // ─── Limits ───
    mapping(bytes32 => uint256) public limits;

    // ─── Events ───
    event TargetUpdated(address indexed target, bool allowed);
    event SelectorUpdated(
        address indexed target,
        bytes4 indexed selector,
        bool allowed
    );
    event TokenUpdated(address indexed token, bool allowed);
    event SpenderUpdated(
        address indexed token,
        address indexed spender,
        bool allowed
    );
    event LimitUpdated(bytes32 indexed key, uint256 value);

    constructor() {
        // Set sensible defaults
        limits[PolicyKeys.MAX_DEADLINE_WINDOW] = 1200; // 20 minutes
        limits[PolicyKeys.MAX_PATH_LENGTH] = 3;
        limits[PolicyKeys.MAX_SWAP_AMOUNT_IN] = type(uint256).max; // no limit by default
        limits[PolicyKeys.MAX_APPROVE_AMOUNT] = type(uint256).max; // no limit by default
        limits[PolicyKeys.MAX_REPAY_AMOUNT] = type(uint256).max; // no limit by default
    }

    // ═══════════════════════════════════════════════════════════
    //                    ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    function setTargetAllowed(address target, bool allowed) external onlyOwner {
        targetAllowed[target] = allowed;
        emit TargetUpdated(target, allowed);
    }

    function setSelectorAllowed(
        address target,
        bytes4 selector,
        bool allowed
    ) external onlyOwner {
        selectorAllowed[target][selector] = allowed;
        emit SelectorUpdated(target, selector, allowed);
    }

    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        tokenAllowed[token] = allowed;
        emit TokenUpdated(token, allowed);
    }

    function setSpenderAllowed(
        address token,
        address spender,
        bool allowed
    ) external onlyOwner {
        spenderAllowed[token][spender] = allowed;
        emit SpenderUpdated(token, spender, allowed);
    }

    function setLimit(bytes32 key, uint256 value) external onlyOwner {
        limits[key] = value;
        emit LimitUpdated(key, value);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════
    //                    VALIDATION (CORE)
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IPolicyGuard
    function validate(
        address nfa,
        uint256 tokenId,
        address agentAccount,
        address caller,
        Action calldata action
    ) external view whenNotPaused returns (bool ok, string memory reason) {
        // 1. Target must be in allowlist
        if (!targetAllowed[action.target]) {
            return (false, "Target not allowed");
        }

        // 2. Extract selector and check allowlist
        bytes4 selector = CalldataDecoder.extractSelector(action.data);
        if (!selectorAllowed[action.target][selector]) {
            return (false, "Selector not allowed");
        }

        // 3. Dispatch to parameter-level validation by selector
        if (selector == PolicyKeys.SWAP_EXACT_TOKENS) {
            return _validateSwap(agentAccount, action.data);
        } else if (selector == PolicyKeys.SWAP_EXACT_ETH) {
            return _validateSwapETH(agentAccount, action.data, action.value);
        } else if (selector == PolicyKeys.APPROVE) {
            return _validateApprove(action.target, action.data);
        } else if (selector == PolicyKeys.REPAY_BORROW_BEHALF) {
            return _validateRepay(nfa, tokenId, action.data);
        }

        // Selector is allowed but no specific parameter checks needed
        return (true, "");
    }

    // ═══════════════════════════════════════════════════════════
    //                 PARAMETER VALIDATORS
    // ═══════════════════════════════════════════════════════════

    /// @dev Validate swapExactTokensForTokens parameters
    function _validateSwap(
        address agentAccount,
        bytes calldata data
    ) internal view returns (bool, string memory) {
        (
            uint256 amountIn,
            ,
            address[] memory path,
            address to,
            uint256 deadline
        ) = CalldataDecoder.decodeSwap(data);

        // CRITICAL: swap output must go to AgentAccount, not renter's EOA
        if (to != agentAccount) {
            return (false, "Swap recipient must be AgentAccount");
        }

        // Deadline window check
        uint256 maxDeadline = block.timestamp +
            limits[PolicyKeys.MAX_DEADLINE_WINDOW];
        if (deadline > maxDeadline) {
            return (false, "Deadline too far in the future");
        }

        // Path length check
        if (path.length > limits[PolicyKeys.MAX_PATH_LENGTH]) {
            return (false, "Swap path too long");
        }

        // All tokens in path must be allowed
        for (uint256 i = 0; i < path.length; i++) {
            if (!tokenAllowed[path[i]]) {
                return (false, "Token in path not allowed");
            }
        }

        // Amount limit check
        uint256 maxAmount = limits[PolicyKeys.MAX_SWAP_AMOUNT_IN];
        if (maxAmount != type(uint256).max && amountIn > maxAmount) {
            return (false, "Swap amount exceeds limit");
        }

        return (true, "");
    }

    /// @dev Validate swapExactETHForTokens parameters
    function _validateSwapETH(
        address agentAccount,
        bytes calldata data,
        uint256 value
    ) internal view returns (bool, string memory) {
        (
            ,
            address[] memory path,
            address to,
            uint256 deadline
        ) = CalldataDecoder.decodeSwapETH(data);

        // recipient check
        if (to != agentAccount)
            return (false, "Swap recipient must be AgentAccount");

        // Deadline check
        if (
            deadline > block.timestamp + limits[PolicyKeys.MAX_DEADLINE_WINDOW]
        ) {
            return (false, "Deadline too far in the future");
        }

        // Path length check
        if (path.length > limits[PolicyKeys.MAX_PATH_LENGTH]) {
            return (false, "Swap path too long");
        }

        // Token allowlist check
        for (uint256 i = 0; i < path.length; i++) {
            if (!tokenAllowed[path[i]])
                return (false, "Token in path not allowed");
            // Native swap path MUST start with WBNB, but router enforces that.
            // PolicyGuard only cares if the tokens are allowed.
        }

        // Amount limit check (using msg.value from action)
        uint256 maxAmount = limits[PolicyKeys.MAX_SWAP_AMOUNT_IN];
        if (maxAmount != type(uint256).max && value > maxAmount) {
            return (false, "Swap amount exceeds limit");
        }

        return (true, "");
    }

    /// @dev Validate approve parameters
    function _validateApprove(
        address token,
        bytes calldata data
    ) internal view returns (bool, string memory) {
        (address spender, uint256 amount) = CalldataDecoder.decodeApprove(data);

        // Token must be in allowlist (target is the token contract)
        if (!tokenAllowed[token]) {
            return (false, "Token not allowed");
        }

        // Spender must be in allowlist for this token
        if (!spenderAllowed[token][spender]) {
            return (false, "Spender not allowed for this token");
        }

        // Reject infinite approval
        if (amount == type(uint256).max) {
            return (false, "Infinite approval not allowed");
        }

        // Amount limit check
        uint256 maxAmount = limits[PolicyKeys.MAX_APPROVE_AMOUNT];
        if (maxAmount != type(uint256).max && amount > maxAmount) {
            return (false, "Approve amount exceeds limit");
        }

        return (true, "");
    }

    /// @dev Validate repayBorrowBehalf parameters
    function _validateRepay(
        address nfa,
        uint256 tokenId,
        bytes calldata data
    ) internal view returns (bool, string memory) {
        (address borrower, uint256 repayAmount) = CalldataDecoder
            .decodeRepayBorrowBehalf(data);

        // borrower MUST be the current renter (userOf)
        address currentRenter = IAgentNFA(nfa).userOf(tokenId);
        if (borrower != currentRenter) {
            return (false, "Borrower must be current renter");
        }

        // Amount limit check
        uint256 maxAmount = limits[PolicyKeys.MAX_REPAY_AMOUNT];
        if (maxAmount != type(uint256).max && repayAmount > maxAmount) {
            return (false, "Repay amount exceeds limit");
        }

        return (true, "");
    }
}
