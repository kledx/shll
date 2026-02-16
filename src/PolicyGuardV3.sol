// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    IERC721
} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IPolicyGuard} from "./interfaces/IPolicyGuard.sol";
import {IERC4907} from "./interfaces/IERC4907.sol";
import {Action} from "./types/Action.sol";
import {CalldataDecoder} from "./libs/CalldataDecoder.sol";
import {PolicyKeys} from "./libs/PolicyKeys.sol";

/**
 * @title PolicyGuardV3
 * @notice V1.5 unified firewall — merges PolicyRegistry + GroupRegistry + InstanceConfig.
 *         Adds mutable instance params, token permission bitmap, and execution modes.
 * @dev Implements IPolicyGuard for backward compat with AgentNFA.
 */
contract PolicyGuardV3 is IPolicyGuard, Ownable {
    // ═══════════════════════════════════════════════════════════
    //                        TYPES
    // ═══════════════════════════════════════════════════════════

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

    struct ParamSchema {
        // --- Base limits (same as V1.4) ---
        uint16 maxSlippageBps;
        uint96 maxTradeLimit;
        uint96 maxDailyLimit;
        uint32[] allowedTokenGroups;
        uint32[] allowedDexGroups;
        bool receiverMustBeVault;
        bool forbidInfiniteApprove;
        // --- V1.5 additions ---
        bool allowExplorerMode;
        uint96 explorerMaxTradeLimit;
        uint96 explorerMaxDailyLimit;
        bool allowParamsUpdate;
    }

    struct ActionRule {
        uint256 moduleMask;
        bool exists;
    }

    enum ExecutionMode {
        STRICT, // Default: token+dex whitelist + full limits
        MANUAL, // Owner/renter direct: skip token whitelist, keep receiver=vault
        EXPLORER // Agent auto: skip token whitelist, enforce lower limits
    }

    // ═══════════════════════════════════════════════════════════
    //                    MODULE CONSTANTS
    // ═══════════════════════════════════════════════════════════

    uint256 public constant MODULE_SWAP = 1 << 0;
    uint256 public constant MODULE_APPROVE = 1 << 1;
    uint256 public constant MODULE_SPEND_LIMIT = 1 << 2;

    // ═══════════════════════════════════════════════════════════
    //                    STORAGE: POLICY REGISTRY
    // ═══════════════════════════════════════════════════════════

    /// @notice mapping(policyId => version => schema)
    mapping(uint32 => mapping(uint16 => ParamSchema)) private _schemas;

    /// @notice mapping(policyId => version => target => selector => rule)
    mapping(uint32 => mapping(uint16 => mapping(address => mapping(bytes4 => ActionRule))))
        private _actionRules;

    /// @notice mapping(policyId => version => frozen)
    mapping(uint32 => mapping(uint16 => bool)) public isFrozen;

    /// @notice mapping(policyId => version => exists)
    mapping(uint32 => mapping(uint16 => bool)) public policyExists;

    // ═══════════════════════════════════════════════════════════
    //                    STORAGE: GROUP REGISTRY
    // ═══════════════════════════════════════════════════════════

    /// @notice mapping(groupId => address => allowed)
    mapping(uint32 => mapping(address => bool)) private _groupMembers;

    /// @notice mapping(groupId => count)
    mapping(uint32 => uint32) public groupSize;

    // ═══════════════════════════════════════════════════════════
    //                    STORAGE: INSTANCE CONFIG (MUTABLE)
    // ═══════════════════════════════════════════════════════════

    /// @notice mapping(instanceId => PolicyRef)
    mapping(uint256 => PolicyRef) public instancePolicyRef;

    /// @notice mapping(instanceId => packed params bytes)
    mapping(uint256 => bytes) public paramsPacked;

    /// @notice mapping(instanceId => hash of params for verification)
    mapping(uint256 => bytes32) public paramsHash;

    /// @notice mapping(instanceId => version counter for param updates)
    mapping(uint256 => uint32) public paramsVersion;

    // ═══════════════════════════════════════════════════════════
    //                    STORAGE: EXECUTION MODES
    // ═══════════════════════════════════════════════════════════

    /// @notice mapping(instanceId => ExecutionMode)
    mapping(uint256 => ExecutionMode) public executionMode;

    // ═══════════════════════════════════════════════════════════
    //                    STORAGE: TOKEN PERMISSION BITMAP
    // ═══════════════════════════════════════════════════════════

    /// @notice mapping(instanceId => bitmap of permitted tokens)
    mapping(uint256 => uint256) public tokenPermissions;

    /// @notice mapping(policyId => version => allowed bitmap mask)
    mapping(uint32 => mapping(uint16 => uint256)) public schemaAllowedBits;

    // ═══════════════════════════════════════════════════════════
    //                    STORAGE: SPEND LIMIT
    // ═══════════════════════════════════════════════════════════

    /// @notice mapping(instanceId => dayIndex => spent amount)
    mapping(uint256 => mapping(uint32 => uint256)) public dailySpent;

    // ═══════════════════════════════════════════════════════════
    //                    STORAGE: ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════

    /// @notice Global target blocklist
    mapping(address => bool) public isBlocked;

    /// @notice Authorized caller for validate/commit (AgentNFA)
    address public allowedCaller;

    /// @notice Authorized minter for bindConfig (ListingManager)
    address public minter;

    // ═══════════════════════════════════════════════════════════
    //                        EVENTS
    // ═══════════════════════════════════════════════════════════

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
    event GroupMemberSet(
        uint32 indexed groupId,
        address indexed member,
        bool allowed
    );
    event InstanceConfigBound(
        uint256 indexed instanceId,
        uint32 indexed policyId,
        uint16 indexed version,
        bytes32 paramsHash
    );
    event ParamsUpdated(
        uint256 indexed instanceId,
        uint32 newVersion,
        bytes32 paramsHash
    );
    event PermissionGranted(uint256 indexed instanceId, uint256 permissionBit);
    event PermissionRevoked(uint256 indexed instanceId, uint256 permissionBit);
    event ExecutionModeChanged(uint256 indexed instanceId, ExecutionMode mode);
    event TargetBlocked(address indexed target, bool blocked);
    event Spent(uint256 indexed instanceId, uint256 amount, uint32 dayIndex);
    event AllowedCallerUpdated(address indexed newCaller);
    event MinterUpdated(address indexed newMinter);

    // ═══════════════════════════════════════════════════════════
    //                        ERRORS
    // ═══════════════════════════════════════════════════════════

    error PolicyAlreadyFrozen();
    error PolicyDoesNotExist();
    error OnlyMinter();
    error OnlyRenter();
    error AlreadyBound();
    error NotBound();
    error PolicyNotFound();
    error SlippageExceedsSchema();
    error TradeLimitExceedsSchema();
    error DailyLimitExceedsSchema();
    error TokenGroupNotAllowed();
    error DexGroupNotAllowed();
    error ExplorerNotAllowed();
    error ExplorerTradeLimitTooHigh();
    error ExplorerDailyLimitTooHigh();
    error ParamsUpdateNotAllowed();
    error BitNotAllowed();

    // ═══════════════════════════════════════════════════════════
    //                    MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier notFrozen(uint32 policyId, uint16 version) {
        if (isFrozen[policyId][version]) revert PolicyAlreadyFrozen();
        _;
    }

    modifier onlyMinter() {
        if (msg.sender != minter) revert OnlyMinter();
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //                    CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor() Ownable() {}

    // ═══════════════════════════════════════════════════════════
    //                    ADMIN: ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════

    function setAllowedCaller(address _caller) external onlyOwner {
        allowedCaller = _caller;
        emit AllowedCallerUpdated(_caller);
    }

    function setMinter(address _minter) external onlyOwner {
        minter = _minter;
        emit MinterUpdated(_minter);
    }

    function setTargetBlocked(address target, bool blocked) external onlyOwner {
        isBlocked[target] = blocked;
        emit TargetBlocked(target, blocked);
    }

    // ═══════════════════════════════════════════════════════════
    //                    ADMIN: POLICY MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    /// @notice Create or update a policy version with its schema
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

    /// @notice Set action rules for a policy version
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

    /// @notice Freeze a policy version to make it immutable
    function freezePolicy(uint32 policyId, uint16 version) external onlyOwner {
        if (!policyExists[policyId][version]) revert PolicyDoesNotExist();
        isFrozen[policyId][version] = true;
        emit PolicyFrozen(policyId, version);
    }

    /// @notice Set the allowed bitmap mask for a policy
    function setSchemaAllowedBits(
        uint32 policyId,
        uint16 version,
        uint256 allowedBits
    ) external onlyOwner {
        if (!policyExists[policyId][version]) revert PolicyDoesNotExist();
        schemaAllowedBits[policyId][version] = allowedBits;
    }

    // ═══════════════════════════════════════════════════════════
    //                    ADMIN: GROUP MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    /// @notice Add or remove a member from a group
    function setGroupMember(
        uint32 groupId,
        address member,
        bool allowed
    ) external onlyOwner {
        bool current = _groupMembers[groupId][member];
        if (current != allowed) {
            _groupMembers[groupId][member] = allowed;
            if (allowed) {
                groupSize[groupId]++;
            } else {
                groupSize[groupId]--;
            }
            emit GroupMemberSet(groupId, member, allowed);
        }
    }

    /// @notice Batch set group members
    function setGroupMembers(
        uint32 groupId,
        address[] calldata members,
        bool allowed
    ) external onlyOwner {
        for (uint256 i = 0; i < members.length; i++) {
            bool current = _groupMembers[groupId][members[i]];
            if (current != allowed) {
                _groupMembers[groupId][members[i]] = allowed;
                if (allowed) {
                    groupSize[groupId]++;
                } else {
                    groupSize[groupId]--;
                }
                emit GroupMemberSet(groupId, members[i], allowed);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                    MINTER: INSTANCE CONFIG
    // ═══════════════════════════════════════════════════════════

    /// @notice Bind configuration to an instance at mint time (ListingManager only)
    function bindConfig(
        uint256 instanceId,
        uint32 policyId,
        uint16 version,
        bytes calldata _paramsPacked
    ) external onlyMinter {
        if (instancePolicyRef[instanceId].policyId != 0) revert AlreadyBound();
        if (!policyExists[policyId][version]) revert PolicyNotFound();

        // Validate params against schema boundary
        InstanceParams memory p = abi.decode(_paramsPacked, (InstanceParams));
        ParamSchema storage s = _schemas[policyId][version];
        _validateParamsAgainstSchema(p, s);

        // Store
        instancePolicyRef[instanceId] = PolicyRef(policyId, version);
        paramsPacked[instanceId] = _paramsPacked;
        bytes32 pHash = keccak256(_paramsPacked);
        paramsHash[instanceId] = pHash;
        paramsVersion[instanceId] = 1;

        emit InstanceConfigBound(instanceId, policyId, version, pHash);
    }

    // ═══════════════════════════════════════════════════════════
    //                    USER: MUTABLE PARAMS
    // ═══════════════════════════════════════════════════════════

    /// @notice Renter updates instance params within Schema bounds
    function updateParams(
        uint256 instanceId,
        bytes calldata newParamsPacked
    ) external {
        // Only the current renter can update
        address renter = IERC4907(allowedCaller).userOf(instanceId);
        if (renter == address(0)) {
            // If no renter (owner-operated), check owner
            if (msg.sender != IERC721(allowedCaller).ownerOf(instanceId))
                revert OnlyRenter();
        } else {
            if (msg.sender != renter) revert OnlyRenter();
        }

        PolicyRef memory ref = instancePolicyRef[instanceId];
        if (ref.policyId == 0) revert NotBound();

        ParamSchema storage s = _schemas[ref.policyId][ref.version];
        if (!s.allowParamsUpdate) revert ParamsUpdateNotAllowed();

        // Validate new params against schema
        InstanceParams memory p = abi.decode(newParamsPacked, (InstanceParams));
        _validateParamsAgainstSchema(p, s);

        // Write + version bump
        paramsPacked[instanceId] = newParamsPacked;
        bytes32 pHash = keccak256(newParamsPacked);
        paramsHash[instanceId] = pHash;
        paramsVersion[instanceId]++;

        emit ParamsUpdated(instanceId, paramsVersion[instanceId], pHash);
    }

    // ═══════════════════════════════════════════════════════════
    //                    USER: TOKEN PERMISSION BITMAP
    // ═══════════════════════════════════════════════════════════

    /// @notice Grant token trading permission via bitmap
    function grantTokenPermission(
        uint256 instanceId,
        uint256 permissionBit
    ) external {
        _checkRenterOrOwner(instanceId);

        PolicyRef memory ref = instancePolicyRef[instanceId];
        uint256 allowed = schemaAllowedBits[ref.policyId][ref.version];
        if ((allowed & permissionBit) != permissionBit) revert BitNotAllowed();

        tokenPermissions[instanceId] |= permissionBit;
        emit PermissionGranted(instanceId, permissionBit);
    }

    /// @notice Revoke token trading permission via bitmap
    function revokeTokenPermission(
        uint256 instanceId,
        uint256 permissionBit
    ) external {
        _checkRenterOrOwner(instanceId);
        tokenPermissions[instanceId] &= ~permissionBit;
        emit PermissionRevoked(instanceId, permissionBit);
    }

    // ═══════════════════════════════════════════════════════════
    //                    USER: EXECUTION MODE
    // ═══════════════════════════════════════════════════════════

    /// @notice Switch execution mode for an instance
    function setExecutionMode(uint256 instanceId, ExecutionMode mode) external {
        _checkRenterOrOwner(instanceId);

        if (mode == ExecutionMode.EXPLORER) {
            PolicyRef memory ref = instancePolicyRef[instanceId];
            ParamSchema storage s = _schemas[ref.policyId][ref.version];
            if (!s.allowExplorerMode) revert ExplorerNotAllowed();

            InstanceParams memory p = abi.decode(
                paramsPacked[instanceId],
                (InstanceParams)
            );
            if (p.tradeLimit > s.explorerMaxTradeLimit)
                revert ExplorerTradeLimitTooHigh();
            if (p.dailyLimit > s.explorerMaxDailyLimit)
                revert ExplorerDailyLimitTooHigh();
        }

        executionMode[instanceId] = mode;
        emit ExecutionModeChanged(instanceId, mode);
    }

    // ═══════════════════════════════════════════════════════════
    //                    CORE: VALIDATE (IPolicyGuard)
    // ═══════════════════════════════════════════════════════════

    function validate(
        address nfa,
        uint256 tokenId,
        address agentAccount,
        address caller,
        Action calldata action
    ) external view override returns (bool ok, string memory reason) {
        // Phase 0: Global blocklist
        if (isBlocked[action.target]) return (false, "Target blocked globally");

        // Load instance config
        PolicyRef memory ref = instancePolicyRef[tokenId];
        if (ref.policyId == 0) return (false, "Instance policy not configured");

        // Check action rule exists
        bytes4 selector = CalldataDecoder.extractSelector(action.data);
        ActionRule memory rule = _actionRules[ref.policyId][ref.version][
            action.target
        ][selector];
        if (!rule.exists) return (false, "Action not allowed by policy");

        // Mode dispatch — respects instance's executionMode for ALL callers
        ExecutionMode mode = executionMode[tokenId];

        if (mode == ExecutionMode.MANUAL) {
            // MANUAL mode: only owner/renter can execute
            address tokenOwner = IERC721(nfa).ownerOf(tokenId);
            address renter = IERC4907(nfa).userOf(tokenId);
            if (caller != tokenOwner && caller != renter)
                return (false, "MANUAL mode: only owner/renter");
            return _validateManual(tokenId, agentAccount, action, rule, ref);
        }

        if (mode == ExecutionMode.EXPLORER) {
            return _validateExplorer(tokenId, agentAccount, action, rule, ref);
        }

        // Default: STRICT
        return _validateStrict(tokenId, agentAccount, action, rule, ref);
    }

    // ═══════════════════════════════════════════════════════════
    //                    CORE: COMMIT (IPolicyGuard)
    // ═══════════════════════════════════════════════════════════

    function commit(uint256 tokenId, Action calldata action) external {
        require(msg.sender == allowedCaller, "Unauthorized: not allowedCaller");

        PolicyRef memory ref = instancePolicyRef[tokenId];
        if (ref.policyId == 0) return;

        ActionRule memory rule = _actionRules[ref.policyId][ref.version][
            action.target
        ][CalldataDecoder.extractSelector(action.data)];

        if ((rule.moduleMask & MODULE_SPEND_LIMIT) != 0) {
            uint256 spentAmt = _parseSpentAmount(action.data, action.value);
            uint32 dayIndex = uint32(block.timestamp / 1 days);
            dailySpent[tokenId][dayIndex] += spentAmt;
            emit Spent(tokenId, spentAmt, dayIndex);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //             INTERNAL: VALIDATE MODES
    // ═══════════════════════════════════════════════════════════

    /// @dev STRICT mode: full token+dex group check, all limits
    function _validateStrict(
        uint256 tokenId,
        address agentAccount,
        Action calldata action,
        ActionRule memory rule,
        PolicyRef memory ref
    ) internal view returns (bool, string memory) {
        bytes memory packed = paramsPacked[tokenId];
        InstanceParams memory params = abi.decode(packed, (InstanceParams));

        // Swap check
        if ((rule.moduleMask & MODULE_SWAP) != 0) {
            (bool ok, string memory reason) = _checkSwapStrict(
                agentAccount,
                action.target,
                action.data,
                action.value,
                params,
                ref
            );
            if (!ok) return (false, reason);
        }

        // Approve check
        if ((rule.moduleMask & MODULE_APPROVE) != 0) {
            (bool ok, string memory reason) = _checkApproveStrict(
                action.target,
                action.data,
                params,
                ref
            );
            if (!ok) return (false, reason);
        }

        // SpendLimit check
        if ((rule.moduleMask & MODULE_SPEND_LIMIT) != 0) {
            (bool ok, string memory reason) = _checkSpendLimit(
                tokenId,
                action.data,
                action.value,
                params
            );
            if (!ok) return (false, reason);
        }

        return (true, "");
    }

    /// @dev MANUAL mode: skip token group check, keep receiver=vault + forbid infinite approve
    function _validateManual(
        uint256 tokenId,
        address agentAccount,
        Action calldata action,
        ActionRule memory rule,
        PolicyRef memory ref
    ) internal view returns (bool, string memory) {
        bytes memory packed = paramsPacked[tokenId];
        InstanceParams memory params = abi.decode(packed, (InstanceParams));

        // Swap: skip token group, keep receiver=vault + tradeLimit
        if ((rule.moduleMask & MODULE_SWAP) != 0) {
            bytes4 sel = CalldataDecoder.extractSelector(action.data);
            uint256 amountIn;
            address to;

            if (sel == PolicyKeys.SWAP_EXACT_TOKENS) {
                (amountIn, , , to, ) = CalldataDecoder.decodeSwap(action.data);
            } else if (sel == PolicyKeys.SWAP_EXACT_ETH) {
                (, , to, ) = CalldataDecoder.decodeSwapETH(action.data);
                amountIn = action.value;
            } else {
                return (false, "Unknown swap selector");
            }

            if (to != agentAccount)
                return (false, "Swap recipient must be vault");
            if (amountIn > params.tradeLimit)
                return (false, "AmountIn exceeds trade limit");
        }

        // Approve: skip token group, keep forbid infinite + tradeLimit cap
        if ((rule.moduleMask & MODULE_APPROVE) != 0) {
            (, uint256 amount) = CalldataDecoder.decodeApprove(action.data);
            if (amount == type(uint256).max)
                return (false, "Infinite approve forbidden");
            if (amount > params.tradeLimit)
                return (false, "Approve amount exceeds trade limit");
        }

        // No dailyLimit check in MANUAL mode
        return (true, "");
    }

    /// @dev EXPLORER mode: skip token group, keep dex group, enforce explorer-specific lower limits
    function _validateExplorer(
        uint256 tokenId,
        address agentAccount,
        Action calldata action,
        ActionRule memory rule,
        PolicyRef memory ref
    ) internal view returns (bool, string memory) {
        InstanceParams memory params = abi.decode(
            paramsPacked[tokenId],
            (InstanceParams)
        );

        // Compute effective limits (capped by schema explorer limits)
        (uint96 effTradeLimit, uint96 effDailyLimit) = _explorerLimits(
            params,
            ref
        );

        // Swap check
        if ((rule.moduleMask & MODULE_SWAP) != 0) {
            (bool ok, string memory reason) = _checkSwapExplorer(
                agentAccount,
                action.target,
                action.data,
                action.value,
                params.dexGroupId,
                effTradeLimit
            );
            if (!ok) return (false, reason);
        }

        // Approve check
        if ((rule.moduleMask & MODULE_APPROVE) != 0) {
            (bool ok, string memory reason) = _checkApproveExplorer(
                action.data,
                params.dexGroupId,
                effTradeLimit
            );
            if (!ok) return (false, reason);
        }

        // SpendLimit with explorer caps
        if ((rule.moduleMask & MODULE_SPEND_LIMIT) != 0) {
            uint256 spentAmt = _parseSpentAmount(action.data, action.value);
            uint32 dayIndex = uint32(block.timestamp / 1 days);
            if (dailySpent[tokenId][dayIndex] + spentAmt > effDailyLimit) {
                return (false, "Daily spend limit exceeded (explorer)");
            }
        }

        return (true, "");
    }

    function _explorerLimits(
        InstanceParams memory params,
        PolicyRef memory ref
    ) internal view returns (uint96 effTradeLimit, uint96 effDailyLimit) {
        ParamSchema storage schema = _schemas[ref.policyId][ref.version];
        effTradeLimit = params.tradeLimit > schema.explorerMaxTradeLimit
            ? schema.explorerMaxTradeLimit
            : params.tradeLimit;
        effDailyLimit = params.dailyLimit > schema.explorerMaxDailyLimit
            ? schema.explorerMaxDailyLimit
            : params.dailyLimit;
    }

    function _checkSwapExplorer(
        address agentAccount,
        address target,
        bytes calldata data,
        uint256 nativeValue,
        uint32 dexGroupId,
        uint96 effTradeLimit
    ) internal view returns (bool, string memory) {
        if (!_groupMembers[dexGroupId][target])
            return (false, "Router not in allowed DEX group");

        bytes4 sel = CalldataDecoder.extractSelector(data);
        uint256 amountIn;
        uint256 amountOutMin;
        address to;

        if (sel == PolicyKeys.SWAP_EXACT_TOKENS) {
            (amountIn, amountOutMin, , to, ) = CalldataDecoder.decodeSwap(data);
        } else if (sel == PolicyKeys.SWAP_EXACT_ETH) {
            (amountOutMin, , to, ) = CalldataDecoder.decodeSwapETH(data);
            amountIn = nativeValue;
        } else {
            return (false, "Unknown swap selector");
        }

        if (to != agentAccount) return (false, "Swap recipient must be vault");
        if (amountIn > effTradeLimit)
            return (false, "AmountIn exceeds explorer trade limit");
        if (amountOutMin == 0) return (false, "amountOutMin must be > 0");
        return (true, "");
    }

    function _checkApproveExplorer(
        bytes calldata data,
        uint32 dexGroupId,
        uint96 effTradeLimit
    ) internal view returns (bool, string memory) {
        (address spender, uint256 amount) = CalldataDecoder.decodeApprove(data);
        if (amount == type(uint256).max)
            return (false, "Infinite approve forbidden");
        if (amount > effTradeLimit)
            return (false, "Approve amount exceeds explorer trade limit");
        if (!_groupMembers[dexGroupId][spender])
            return (false, "Spender not in allowed DEX group");
        return (true, "");
    }

    // ═══════════════════════════════════════════════════════════
    //             INTERNAL: CHECK MODULES (STRICT MODE)
    // ═══════════════════════════════════════════════════════════

    function _checkSwapStrict(
        address agentAccount,
        address target,
        bytes calldata data,
        uint256 nativeValue,
        InstanceParams memory params,
        PolicyRef memory ref
    ) internal view returns (bool, string memory) {
        ParamSchema storage schema = _schemas[ref.policyId][ref.version];

        if (params.tradeLimit > schema.maxTradeLimit)
            return (false, "Trade limit exceeds schema");

        if (!_groupMembers[params.dexGroupId][target])
            return (false, "Router not in allowed DEX group");

        bytes4 sel = CalldataDecoder.extractSelector(data);
        uint256 amountIn;
        uint256 amountOutMin;
        address[] memory path;
        address to;

        if (sel == PolicyKeys.SWAP_EXACT_TOKENS) {
            (amountIn, amountOutMin, path, to, ) = CalldataDecoder.decodeSwap(
                data
            );
        } else if (sel == PolicyKeys.SWAP_EXACT_ETH) {
            (amountOutMin, path, to, ) = CalldataDecoder.decodeSwapETH(data);
            amountIn = nativeValue;
        } else {
            return (false, "Unknown swap selector");
        }

        if (to != agentAccount) return (false, "Swap recipient must be vault");
        if (amountIn > params.tradeLimit)
            return (false, "AmountIn exceeds trade limit");
        if (amountOutMin == 0) return (false, "amountOutMin must be > 0");

        for (uint i = 0; i < path.length; i++) {
            if (!_groupMembers[params.tokenGroupId][path[i]])
                return (false, "Token not in allowed group");
        }
        return (true, "");
    }

    function _checkApproveStrict(
        address token,
        bytes calldata data,
        InstanceParams memory params,
        PolicyRef memory ref
    ) internal view returns (bool, string memory) {
        ParamSchema storage schema = _schemas[ref.policyId][ref.version];

        if (params.tradeLimit > schema.maxTradeLimit)
            return (false, "Approve limit exceeds schema");

        (address spender, uint256 amount) = CalldataDecoder.decodeApprove(data);
        if (amount == type(uint256).max)
            return (false, "Infinite approve forbidden");
        if (amount > params.tradeLimit)
            return (false, "Approve amount exceeds trade limit");
        if (!_groupMembers[params.dexGroupId][spender])
            return (false, "Spender not in allowed group");
        if (!_groupMembers[params.tokenGroupId][token])
            return (false, "Token not in allowed group");
        return (true, "");
    }

    function _checkSpendLimit(
        uint256 tokenId,
        bytes calldata data,
        uint256 nativeValue,
        InstanceParams memory params
    ) internal view returns (bool, string memory) {
        uint256 spentAmt = _parseSpentAmount(data, nativeValue);
        uint32 dayIndex = uint32(block.timestamp / 1 days);
        if (dailySpent[tokenId][dayIndex] + spentAmt > params.dailyLimit) {
            return (false, "Daily spend limit exceeded");
        }
        return (true, "");
    }

    // ═══════════════════════════════════════════════════════════
    //             INTERNAL: HELPERS
    // ═══════════════════════════════════════════════════════════

    /// @dev Extract the spent amount from calldata for daily limit tracking.
    ///      Supports swapExactTokensForTokens (amountIn from calldata)
    ///      and swapExactETHForTokens (amountIn from msg.value/action.value).
    function _parseSpentAmount(
        bytes calldata data,
        uint256 nativeValue
    ) internal pure returns (uint256) {
        bytes4 sel = CalldataDecoder.extractSelector(data);
        if (sel == PolicyKeys.SWAP_EXACT_TOKENS) {
            (uint256 amountIn, , , , ) = CalldataDecoder.decodeSwap(data);
            return amountIn;
        }
        if (sel == PolicyKeys.SWAP_EXACT_ETH) {
            return nativeValue;
        }
        return 0;
    }

    function _validateParamsAgainstSchema(
        InstanceParams memory p,
        ParamSchema storage s
    ) internal view {
        if (p.slippageBps > s.maxSlippageBps) revert SlippageExceedsSchema();
        if (p.tradeLimit > s.maxTradeLimit) revert TradeLimitExceedsSchema();
        if (p.dailyLimit > s.maxDailyLimit) revert DailyLimitExceedsSchema();
        if (!_contains(s.allowedTokenGroups, p.tokenGroupId))
            revert TokenGroupNotAllowed();
        if (!_contains(s.allowedDexGroups, p.dexGroupId))
            revert DexGroupNotAllowed();
    }

    function _checkRenterOrOwner(uint256 instanceId) internal view {
        address renter = IERC4907(allowedCaller).userOf(instanceId);
        if (renter != address(0)) {
            if (msg.sender != renter) revert OnlyRenter();
        } else {
            if (msg.sender != IERC721(allowedCaller).ownerOf(instanceId))
                revert OnlyRenter();
        }
    }

    function _contains(
        uint32[] storage arr,
        uint32 value
    ) internal view returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == value) return true;
        }
        return false;
    }

    // ═══════════════════════════════════════════════════════════
    //                        VIEWS
    // ═══════════════════════════════════════════════════════════

    /// @notice Get instance params (backward compat with InstanceConfig interface)
    function getInstanceParams(
        uint256 instanceId
    ) external view returns (PolicyRef memory ref, bytes memory params) {
        return (instancePolicyRef[instanceId], paramsPacked[instanceId]);
    }

    /// @notice Get policy schema
    function getSchema(
        uint32 policyId,
        uint16 version
    ) external view returns (ParamSchema memory) {
        return _schemas[policyId][version];
    }

    /// @notice Get action rule
    function getActionRule(
        uint32 policyId,
        uint16 version,
        address target,
        bytes4 selector
    ) external view returns (ActionRule memory) {
        return _actionRules[policyId][version][target][selector];
    }

    /// @notice Check if address is in a group
    function isInGroup(
        uint32 groupId,
        address member
    ) external view returns (bool) {
        return _groupMembers[groupId][member];
    }
}
