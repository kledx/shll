// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title PolicyRegistry
 * @notice Registry for AI Agent policies and their parameter schemas.
 * @dev V1.4: Supports versioning and freezing of policies.
 */
contract PolicyRegistry is Ownable {
    struct PolicyRef {
        uint32 policyId;
        uint16 version;
    }

    struct ParamSchema {
        uint16 maxSlippageBps;
        uint96 maxTradeLimit;
        uint96 maxDailyLimit;
        uint32[] allowedTokenGroups;
        uint32[] allowedDexGroups;
        bool receiverMustBeVault;
        bool forbidInfiniteApprove;
    }

    struct ActionRule {
        uint256 moduleMask; // Bitmask of authorized execution modules
        bool exists;
    }

    /// @notice mapping(policyId => version => schema)
    mapping(uint32 => mapping(uint16 => ParamSchema)) private _schemas;

    /// @notice mapping(policyId => version => target => selector => rule)
    mapping(uint32 => mapping(uint16 => mapping(address => mapping(bytes4 => ActionRule))))
        private _actionRules;

    /// @notice mapping(policyId => version => frozen)
    mapping(uint32 => mapping(uint16 => bool)) public isFrozen;

    /// @notice mapping(policyId => version => exists)
    mapping(uint32 => mapping(uint16 => bool)) public policyExists;

    // --- Events ---
    event PolicyCreated(
        uint32 indexed policyId,
        uint16 indexed version,
        uint256 policyModules
    );
    event ActionRuleSet(
        uint32 indexed policyId,
        uint16 indexed version,
        address indexed target,
        bytes4 selector,
        uint256 moduleMask
    );
    event PolicyFrozen(uint32 indexed policyId, uint16 indexed version);

    error PolicyAlreadyFrozen();
    error PolicyDoesNotExist();

    modifier notFrozen(uint32 policyId, uint16 version) {
        if (isFrozen[policyId][version]) revert PolicyAlreadyFrozen();
        _;
    }

    constructor() Ownable() {}

    /**
     * @notice Create or update a policy version with its schema
     */
    function createPolicy(
        uint32 policyId,
        uint16 version,
        ParamSchema calldata schema,
        uint256 policyModules
    ) external onlyOwner notFrozen(policyId, version) {
        _schemas[policyId][version] = schema;
        policyExists[policyId][version] = true;
        emit PolicyCreated(policyId, version, policyModules);
    }

    /**
     * @notice Set action rules for a policy version
     */
    function setActionRule(
        uint32 policyId,
        uint16 version,
        address target,
        bytes4 selector,
        uint256 moduleMask
    ) external onlyOwner notFrozen(policyId, version) {
        if (!policyExists[policyId][version]) revert PolicyDoesNotExist();
        _actionRules[policyId][version][target][selector] = ActionRule({
            moduleMask: moduleMask,
            exists: true
        });
        emit ActionRuleSet(policyId, version, target, selector, moduleMask);
    }

    /**
     * @notice Freeze a policy version to make it immutable
     */
    function freezePolicy(uint32 policyId, uint16 version) external onlyOwner {
        if (!policyExists[policyId][version]) revert PolicyDoesNotExist();
        isFrozen[policyId][version] = true;
        emit PolicyFrozen(policyId, version);
    }

    // --- Views ---

    function getSchema(
        uint32 policyId,
        uint16 version
    ) external view returns (ParamSchema memory) {
        return _schemas[policyId][version];
    }

    function getActionRule(
        uint32 policyId,
        uint16 version,
        address target,
        bytes4 selector
    ) external view returns (ActionRule memory) {
        return _actionRules[policyId][version][target][selector];
    }
}
