// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAgentAccount} from "./interfaces/IAgentAccount.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Errors} from "./libs/Errors.sol";

/// @title AgentAccount — Isolated vault for each AI Agent NFA
/// @notice Each NFA token has one AgentAccount that holds its funds
/// @dev Renter deposits funds and executes DeFi via NFA; only owner can withdraw vault assets
contract AgentAccount is IAgentAccount, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The AgentNFA contract that controls this account
    address public immutable nfa;

    /// @notice The token ID this account is bound to
    uint256 public immutable tokenId;

    // ─── Events ───
    event Deposited(address indexed token, address indexed from, uint256 amount);
    event WithdrawnToken(address indexed token, address indexed to, uint256 amount);
    event WithdrawnNative(address indexed to, uint256 amount);
    event CallExecuted(address indexed target, uint256 value, bool success);

    constructor(address _nfa, uint256 _tokenId) {
        if (_nfa == address(0)) revert Errors.ZeroAddress();
        nfa = _nfa;
        tokenId = _tokenId;
    }

    /// @notice Receive native currency (BNB)
    receive() external payable {}

    // ═══════════════════════════════════════════════════════════
    //                    DEPOSIT
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IAgentAccount
    function depositToken(address token, uint256 amount) external nonReentrant {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(token, msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════
    //                    WITHDRAW
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IAgentAccount
    function withdrawToken(address token, uint256 amount, address to) external nonReentrant {
        _checkWithdrawPermission(to);
        IERC20(token).safeTransfer(to, amount);
        emit WithdrawnToken(token, to, amount);
    }

    /// @inheritdoc IAgentAccount
    function withdrawNative(uint256 amount, address to) external nonReentrant {
        _checkWithdrawPermission(to);
        if (amount > address(this).balance) revert Errors.InsufficientBalance();
        (bool success,) = to.call{value: amount}("");
        if (!success) revert Errors.ExecutionFailed();
        emit WithdrawnNative(to, amount);
    }

    // ═══════════════════════════════════════════════════════════
    //                    EXECUTE (NFA only)
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IAgentAccount
    function executeCall(address target, uint256 value, bytes calldata data)
        external
        nonReentrant
        returns (bool ok, bytes memory result)
    {
        if (msg.sender != nfa) revert Errors.OnlyNFA();
        (ok, result) = target.call{value: value}(data);
        emit CallExecuted(target, value, ok);
    }

    // ═══════════════════════════════════════════════════════════
    //                    INTERNAL
    // ═══════════════════════════════════════════════════════════

    /// @dev Check that msg.sender is owner and recipient is owner
    function _checkWithdrawPermission(address to) internal view {
        address owner = IERC721(nfa).ownerOf(tokenId);
        if (msg.sender != owner) revert Errors.Unauthorized();
        if (to != owner) revert Errors.InvalidWithdrawRecipient();
    }
}
