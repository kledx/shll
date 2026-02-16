// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IPolicyGuard} from "./interfaces/IPolicyGuard.sol";
import {Action} from "./types/Action.sol";
import {PolicyRegistry} from "./PolicyRegistry.sol";
import {GroupRegistry} from "./GroupRegistry.sol";
import {InstanceConfig} from "./InstanceConfig.sol";
import {CalldataDecoder} from "./libs/CalldataDecoder.sol";
import {PolicyKeys} from "./libs/PolicyKeys.sol";

/**
 * @title PolicyGuardV2
 * @notice V1.4 fireguard orchestrator.
 */
contract PolicyGuardV2 is IPolicyGuard, Ownable {
    PolicyRegistry public immutable policyRegistry;
    GroupRegistry public immutable groupRegistry;
    InstanceConfig public immutable instanceConfig;

    uint256 public constant MODULE_SWAP = 1 << 0;
    uint256 public constant MODULE_APPROVE = 1 << 1;
    uint256 public constant MODULE_SPEND_LIMIT = 1 << 2;

    mapping(address => bool) public isBlocked;
    mapping(uint256 => mapping(uint32 => uint256)) public dailySpent;

    /// @notice Authorized caller for commit (AgentNFA contract)
    address public allowedCaller;

    event TargetBlocked(address indexed target, bool blocked);
    event Spent(uint256 indexed instanceId, uint256 amount, uint32 dayIndex);
    event AllowedCallerUpdated(address indexed newCaller);

    constructor(
        address _policyRegistry,
        address _groupRegistry,
        address _instanceConfig
    ) Ownable() {
        policyRegistry = PolicyRegistry(_policyRegistry);
        groupRegistry = GroupRegistry(_groupRegistry);
        instanceConfig = InstanceConfig(_instanceConfig);
    }

    function setAllowedCaller(address _caller) external onlyOwner {
        allowedCaller = _caller;
        emit AllowedCallerUpdated(_caller);
    }

    function setTargetBlocked(address target, bool blocked) external onlyOwner {
        isBlocked[target] = blocked;
        emit TargetBlocked(target, blocked);
    }

    function validate(
        address,
        uint256 tokenId,
        address agentAccount,
        address,
        Action calldata action
    ) external view override returns (bool ok, string memory reason) {
        if (isBlocked[action.target]) return (false, "Target blocked globally");

        (
            InstanceConfig.PolicyRef memory ref,
            bytes memory paramsPacked
        ) = instanceConfig.getInstanceParams(tokenId);
        if (ref.policyId == 0) return (false, "Instance policy not configured");

        PolicyRegistry.ActionRule memory rule = policyRegistry.getActionRule(
            ref.policyId,
            ref.version,
            action.target,
            CalldataDecoder.extractSelector(action.data)
        );
        if (!rule.exists) return (false, "Action not allowed by policy");

        // Swap check
        if ((rule.moduleMask & MODULE_SWAP) != 0) {
            (ok, reason) = _checkSwap(
                agentAccount,
                action.target,
                action.data,
                paramsPacked,
                ref.policyId,
                ref.version
            );
            if (!ok) return (false, reason);
        }

        // Approve check
        if ((rule.moduleMask & MODULE_APPROVE) != 0) {
            (ok, reason) = _checkApprove(
                action.target,
                action.data,
                paramsPacked,
                ref.policyId,
                ref.version
            );
            if (!ok) return (false, reason);
        }

        // SpendLimit check
        if ((rule.moduleMask & MODULE_SPEND_LIMIT) != 0) {
            (ok, reason) = _checkSpendLimit(tokenId, action.data, paramsPacked);
            if (!ok) return (false, reason);
        }

        return (true, "");
    }

    function _checkSwap(
        address agentAccount,
        address target,
        bytes calldata data,
        bytes memory paramsPacked,
        uint32 policyId,
        uint16 version
    ) internal view returns (bool, string memory) {
        InstanceConfig.InstanceParams memory params = abi.decode(
            paramsPacked,
            (InstanceConfig.InstanceParams)
        );
        PolicyRegistry.ParamSchema memory schema = policyRegistry.getSchema(
            policyId,
            version
        );

        if (params.tradeLimit > schema.maxTradeLimit)
            return (false, "Trade limit exceeds schema");

        // M-2 fix: Check router is in dexGroup
        if (!groupRegistry.isInGroup(params.dexGroupId, target))
            return (false, "Router not in allowed DEX group");

        (
            uint256 amountIn,
            uint256 amountOutMin,
            address[] memory path,
            address to,

        ) = CalldataDecoder.decodeSwap(data);
        if (to != agentAccount) return (false, "Swap recipient must be vault");
        if (amountIn > params.tradeLimit)
            return (false, "AmountIn exceeds trade limit");
        if (amountOutMin == 0) return (false, "amountOutMin must be > 0");

        for (uint i = 0; i < path.length; i++) {
            if (!groupRegistry.isInGroup(params.tokenGroupId, path[i]))
                return (false, "Token not in allowed group");
        }
        return (true, "");
    }

    function _checkApprove(
        address token,
        bytes calldata data,
        bytes memory paramsPacked,
        uint32 policyId,
        uint16 version
    ) internal view returns (bool, string memory) {
        InstanceConfig.InstanceParams memory params = abi.decode(
            paramsPacked,
            (InstanceConfig.InstanceParams)
        );
        PolicyRegistry.ParamSchema memory schema = policyRegistry.getSchema(
            policyId,
            version
        );

        if (params.tradeLimit > schema.maxTradeLimit)
            return (false, "Approve limit exceeds schema");

        (address spender, uint256 amount) = CalldataDecoder.decodeApprove(data);
        if (amount == type(uint256).max)
            return (false, "Infinite approve forbidden");
        if (amount > params.tradeLimit)
            return (false, "Approve amount exceeds trade limit");
        if (!groupRegistry.isInGroup(params.dexGroupId, spender))
            return (false, "Spender not in allowed group");
        if (!groupRegistry.isInGroup(params.tokenGroupId, token))
            return (false, "Token not in allowed group");
        return (true, "");
    }

    function _checkSpendLimit(
        uint256 tokenId,
        bytes calldata data,
        bytes memory paramsPacked
    ) internal view returns (bool, string memory) {
        InstanceConfig.InstanceParams memory params = abi.decode(
            paramsPacked,
            (InstanceConfig.InstanceParams)
        );
        uint256 spentAmt = _parseSpentAmount(data);
        uint32 dayIndex = uint32(block.timestamp / 1 days);
        if (dailySpent[tokenId][dayIndex] + spentAmt > params.dailyLimit) {
            return (false, "Daily spend limit exceeded");
        }
        return (true, "");
    }

    /// @notice Post-execution commit for spend tracking. Only callable by AgentNFA.
    function commit(uint256 tokenId, Action calldata action) external {
        // H-1 fix: Only the authorized caller (AgentNFA) can update spend state
        if (msg.sender != allowedCaller) return;

        (InstanceConfig.PolicyRef memory ref, ) = instanceConfig
            .getInstanceParams(tokenId);
        if (ref.policyId == 0) return;

        PolicyRegistry.ActionRule memory rule = policyRegistry.getActionRule(
            ref.policyId,
            ref.version,
            action.target,
            CalldataDecoder.extractSelector(action.data)
        );

        if ((rule.moduleMask & MODULE_SPEND_LIMIT) != 0) {
            uint256 spentAmt = _parseSpentAmount(action.data);
            uint32 dayIndex = uint32(block.timestamp / 1 days);
            dailySpent[tokenId][dayIndex] += spentAmt;
            emit Spent(tokenId, spentAmt, dayIndex);
        }
    }

    function _parseSpentAmount(
        bytes calldata data
    ) internal pure returns (uint256) {
        bytes4 selector = CalldataDecoder.extractSelector(data);
        if (selector == PolicyKeys.SWAP_EXACT_TOKENS) {
            (uint256 amountIn, , , , ) = CalldataDecoder.decodeSwap(data);
            return amountIn;
        }
        return 0;
    }
}
