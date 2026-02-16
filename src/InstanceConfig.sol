// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {PolicyRegistry} from "./PolicyRegistry.sol";

/**
 * @title InstanceConfig
 * @notice Stores immutable configuration for AI Agent instances (NFA tokenIds).
 * @dev V1.4: Validates instance params against policy schema at bind time.
 */
contract InstanceConfig is Ownable {
    struct PolicyRef {
        uint32 policyId;
        uint16 version;
    }

    struct InstanceParams {
        uint16 slippageBps;
        uint96 tradeLimit;
        uint96 dailyLimit;
        uint32 tokenGroupId;
        uint32 dexGroupId;
        uint8 riskTier;
    }

    /// @notice mapping(instanceId => PolicyRef)
    mapping(uint256 => PolicyRef) public instancePolicyRef;

    /// @notice mapping(instanceId => params)
    mapping(uint256 => bytes) public paramsPacked;

    /// @notice mapping(instanceId => paramsHash)
    mapping(uint256 => bytes32) public paramsHash;

    /// @notice Authorized minter (ListingManager)
    address public minter;

    /// @notice Reference to PolicyRegistry for schema validation
    PolicyRegistry public policyRegistry;

    event InstanceConfigBound(
        uint256 indexed instanceId,
        uint32 indexed policyId,
        uint16 indexed version,
        bytes32 paramsHash
    );
    event MinterUpdated(address indexed newMinter);
    event PolicyRegistryUpdated(address indexed newRegistry);

    error OnlyMinter();
    error AlreadyBound();
    error PolicyNotFound();
    error SlippageExceedsSchema();
    error TradeLimitExceedsSchema();
    error DailyLimitExceedsSchema();
    error TokenGroupNotAllowed();
    error DexGroupNotAllowed();

    modifier onlyMinter() {
        if (msg.sender != minter) revert OnlyMinter();
        _;
    }

    constructor() Ownable() {}

    function setMinter(address _minter) external onlyOwner {
        minter = _minter;
        emit MinterUpdated(_minter);
    }

    function setPolicyRegistry(address _registry) external onlyOwner {
        policyRegistry = PolicyRegistry(_registry);
        emit PolicyRegistryUpdated(_registry);
    }

    /**
     * @notice Bind configuration to an instance at mint time.
     * @dev Validates all params against the policy schema before writing.
     */
    function bindConfig(
        uint256 instanceId,
        uint32 policyId,
        uint16 version,
        bytes calldata _paramsPacked
    ) external onlyMinter {
        if (instancePolicyRef[instanceId].policyId != 0) revert AlreadyBound();

        // P0 fix: Validate params against schema boundary
        if (address(policyRegistry) != address(0)) {
            if (!policyRegistry.policyExists(policyId, version))
                revert PolicyNotFound();

            InstanceParams memory p = abi.decode(
                _paramsPacked,
                (InstanceParams)
            );
            PolicyRegistry.ParamSchema memory s = policyRegistry.getSchema(
                policyId,
                version
            );

            // Validate each param is within schema bounds
            if (p.slippageBps > s.maxSlippageBps)
                revert SlippageExceedsSchema();
            if (p.tradeLimit > s.maxTradeLimit)
                revert TradeLimitExceedsSchema();
            if (p.dailyLimit > s.maxDailyLimit)
                revert DailyLimitExceedsSchema();

            // Validate groupIds are in schema's allowed lists
            if (!_contains(s.allowedTokenGroups, p.tokenGroupId))
                revert TokenGroupNotAllowed();
            if (!_contains(s.allowedDexGroups, p.dexGroupId))
                revert DexGroupNotAllowed();
        }

        instancePolicyRef[instanceId] = PolicyRef(policyId, version);
        paramsPacked[instanceId] = _paramsPacked;
        bytes32 pHash = keccak256(_paramsPacked);
        paramsHash[instanceId] = pHash;

        emit InstanceConfigBound(instanceId, policyId, version, pHash);
    }

    // --- Internal ---

    function _contains(
        uint32[] memory arr,
        uint32 value
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == value) return true;
        }
        return false;
    }

    // --- Views ---

    function getInstanceParams(
        uint256 instanceId
    ) external view returns (PolicyRef memory ref, bytes memory params) {
        return (instancePolicyRef[instanceId], paramsPacked[instanceId]);
    }
}
