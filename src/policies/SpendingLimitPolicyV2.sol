// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    IERC721
} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {
    ERC165
} from "openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {ICommittable} from "../interfaces/ICommittable.sol";
import {IERC4907} from "../interfaces/IERC4907.sol";
import {IInstanceInitializable} from "../interfaces/IInstanceInitializable.sol";
import {CalldataDecoder} from "../libs/CalldataDecoder.sol";

/// @title SpendingLimitPolicyV2 — DEX-agnostic spending limits with approve-based token control
/// @notice Merges SpendingLimitPolicy V1 + TokenWhitelistPolicy.
///   - Spending: tracked via msg.value + approve amounts (no DEX calldata parsing)
///   - Token whitelist: enforced at approve-time AND swap output-time
///   - Output token extraction: registry-based (Owner registers selector → pattern)
///
/// @dev OutputPattern registry:
///   - UNKNOWN (0): don't extract output token, pass through
///   - V2_PATH (1): swapExactETHForTokens-style, output = address[] path[last]
///   - V3_SINGLE (2): exactInputSingle-style, output = struct.tokenOut at offset 32
///   - V3_MULTI (3): exactInput-style, output = packed bytes path last 20 bytes
contract SpendingLimitPolicyV2 is
    IPolicy,
    ICommittable,
    IInstanceInitializable,
    ERC165
{
    // ─── Types ───
    struct Limits {
        uint256 maxPerTx;
        uint256 maxPerDay;
        // maxSlippageBps: stored for UI/Runner soft policy, NOT enforced on-chain.
        uint256 maxSlippageBps;
    }

    struct DailyTracking {
        uint256 spentToday;
        uint32 dayIndex; // block.timestamp / 86400
    }

    /// @notice Output token extraction patterns for BNB swap functions
    enum OutputPattern {
        UNKNOWN, // 0: unknown selector, don't check output token
        V2_PATH, // 1: (uint, uint, address[] path, address, uint) → path[last]
        V3_SINGLE, // 2: struct { tokenIn, tokenOut, ... } → tokenOut at offset 32
        V3_MULTI // 3: struct { bytes path, ... } → packed path last 20 bytes
    }

    // ─── Storage: Spending Limits ───
    mapping(bytes32 => Limits) public templateCeiling;
    mapping(uint256 => Limits) public instanceLimits;
    mapping(uint256 => DailyTracking) public dailyTracking;
    mapping(uint256 => bytes32) public instanceTemplate;

    // ─── Storage: Approve Control ───
    mapping(bytes32 => uint256) public templateApproveCeiling;
    mapping(uint256 => uint256) public instanceApproveLimit;
    mapping(address => bool) public approvedSpender;

    // ─── Storage: Token Whitelist ───
    mapping(bytes32 => bool) public templateTokenRestriction;
    mapping(bytes32 => mapping(address => bool)) public templateAllowedToken;
    mapping(bytes32 => address[]) internal _templateAllowedTokenList;

    mapping(uint256 => bool) public tokenRestrictionEnabled;
    mapping(uint256 => mapping(address => bool)) public allowedToken;
    mapping(uint256 => address[]) internal _allowedTokenList;
    mapping(uint256 => bool) public hasCustomTokenConfig;

    // ─── Storage: Output Pattern Registry ───
    /// @notice Selector → OutputPattern mapping (Owner configures)
    mapping(bytes4 => OutputPattern) public selectorOutputPattern;
    /// @notice List of registered selectors for enumeration
    bytes4[] internal _registeredSelectors;

    // ─── Immutables ───
    address public immutable guard;
    address public agentNFA;

    // ─── Selectors: Safety (hardcoded, not DEX-specific) ───
    bytes4 private constant APPROVE = 0x095ea7b3;
    bytes4 private constant INCREASE_ALLOWANCE = 0x39509351;
    bytes4 private constant DECREASE_ALLOWANCE = 0xa457c2d7;
    bytes4 private constant PERMIT = 0xd505accf;
    bytes4 private constant DAI_PERMIT = 0x8fcbaf0c;
    bytes4 private constant TRANSFER = 0xa9059cbb;
    bytes4 private constant TRANSFER_FROM = 0x23b872dd;

    // WBNB deposit — always allowed with value
    bytes4 private constant WBNB_DEPOSIT = 0xd0e30db0;

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
    event TemplateApproveCeilingSet(
        bytes32 indexed templateId,
        uint256 maxApproveAmount
    );
    event InstanceApproveLimitSet(
        uint256 indexed instanceId,
        uint256 maxApproveAmount
    );
    event ApprovedSpenderSet(address indexed spender, bool allowed);
    event TemplateTokenRestrictionSet(bytes32 indexed templateId, bool enabled);
    event TemplateTokenAdded(bytes32 indexed templateId, address indexed token);
    event TemplateTokenRemoved(
        bytes32 indexed templateId,
        address indexed token
    );
    event TokenRestrictionSet(uint256 indexed instanceId, bool enabled);
    event TokenAdded(uint256 indexed instanceId, address indexed token);
    event TokenRemoved(uint256 indexed instanceId, address indexed token);
    event OutputPatternSet(bytes4 indexed selector, OutputPattern pattern);
    event AgentNFAUpdated(address indexed oldNFA, address indexed newNFA);

    // ─── Errors ───
    error NotRenterOrOwner();
    error ExceedsCeiling(string field);
    error OnlyGuard();
    error TokenAlreadyAdded();
    error TokenNotFound();
    error AlreadyInitialized();

    constructor(address _guard, address _nfa) {
        guard = _guard;
        agentNFA = _nfa;
    }

    /// @notice Update the AgentNFA reference (owner-only)
    /// @param _nfa New AgentNFA address
    function setAgentNFA(address _nfa) external {
        _onlyOwner();
        require(_nfa != address(0), "zero address");
        emit AgentNFAUpdated(agentNFA, _nfa);
        agentNFA = _nfa;
    }

    // ═══════════════════════════════════════════════════════
    //                   ADMIN: Ceiling
    // ═══════════════════════════════════════════════════════

    function setTemplateCeiling(
        bytes32 templateId,
        uint256 maxPerTx,
        uint256 maxPerDay,
        uint256 maxSlippageBps
    ) external {
        _onlyOwner();
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

    function setTemplateApproveCeiling(
        bytes32 templateId,
        uint256 maxApproveAmount
    ) external {
        _onlyOwner();
        templateApproveCeiling[templateId] = maxApproveAmount;
        emit TemplateApproveCeilingSet(templateId, maxApproveAmount);
    }

    function setApprovedSpender(address spender, bool allowed) external {
        _onlyOwner();
        approvedSpender[spender] = allowed;
        emit ApprovedSpenderSet(spender, allowed);
    }

    function getTemplateCeiling(
        bytes32 templateId
    ) external view returns (Limits memory) {
        return templateCeiling[templateId];
    }

    // ═══════════════════════════════════════════════════════
    //       ADMIN: Output Pattern Registry
    // ═══════════════════════════════════════════════════════

    /// @notice Owner registers a swap selector with its output token extraction pattern
    /// @param selector The function selector (e.g. 0x7ff36ab5 for swapExactETHForTokens)
    /// @param pattern The extraction pattern to use (V2_PATH, V3_SINGLE, V3_MULTI)
    function setOutputPattern(bytes4 selector, OutputPattern pattern) external {
        _onlyOwner();
        // Track for enumeration if new
        if (
            selectorOutputPattern[selector] == OutputPattern.UNKNOWN &&
            pattern != OutputPattern.UNKNOWN
        ) {
            _registeredSelectors.push(selector);
        }
        selectorOutputPattern[selector] = pattern;
        emit OutputPatternSet(selector, pattern);
    }

    /// @notice Batch register multiple selectors with the same pattern
    function setOutputPatternBatch(
        bytes4[] calldata selectors,
        OutputPattern pattern
    ) external {
        _onlyOwner();
        for (uint256 i = 0; i < selectors.length; i++) {
            if (
                selectorOutputPattern[selectors[i]] == OutputPattern.UNKNOWN &&
                pattern != OutputPattern.UNKNOWN
            ) {
                _registeredSelectors.push(selectors[i]);
            }
            selectorOutputPattern[selectors[i]] = pattern;
            emit OutputPatternSet(selectors[i], pattern);
        }
    }

    /// @notice Get all registered selectors and their patterns
    function getRegisteredSelectors()
        external
        view
        returns (bytes4[] memory selectors, OutputPattern[] memory patterns)
    {
        selectors = _registeredSelectors;
        patterns = new OutputPattern[](selectors.length);
        for (uint256 i = 0; i < selectors.length; i++) {
            patterns[i] = selectorOutputPattern[selectors[i]];
        }
    }

    // ═══════════════════════════════════════════════════════
    //            ADMIN: Template Token Whitelist
    // ═══════════════════════════════════════════════════════

    function setTemplateTokenRestriction(
        bytes32 templateId,
        bool enabled
    ) external {
        _onlyOwner();
        templateTokenRestriction[templateId] = enabled;
        emit TemplateTokenRestrictionSet(templateId, enabled);
    }

    function addTemplateToken(bytes32 templateId, address token) external {
        _onlyOwner();
        if (templateAllowedToken[templateId][token]) revert TokenAlreadyAdded();
        templateAllowedToken[templateId][token] = true;
        _templateAllowedTokenList[templateId].push(token);
        emit TemplateTokenAdded(templateId, token);
    }

    function removeTemplateToken(bytes32 templateId, address token) external {
        _onlyOwner();
        if (!templateAllowedToken[templateId][token]) revert TokenNotFound();
        templateAllowedToken[templateId][token] = false;
        _removeFromArray(_templateAllowedTokenList[templateId], token);
        emit TemplateTokenRemoved(templateId, token);
    }

    function getTemplateTokenList(
        bytes32 templateId
    ) external view returns (address[] memory) {
        return _templateAllowedTokenList[templateId];
    }

    // ═══════════════════════════════════════════════════════
    //         INSTANCE INIT (called by PolicyGuardV4)
    // ═══════════════════════════════════════════════════════

    function initInstance(
        uint256 instanceId,
        bytes32 templateKey
    ) external override {
        if (msg.sender != guard) revert OnlyGuard();
        if (instanceTemplate[instanceId] != bytes32(0))
            revert AlreadyInitialized();

        instanceTemplate[instanceId] = templateKey;
        instanceLimits[instanceId] = templateCeiling[templateKey];
        instanceApproveLimit[instanceId] = templateApproveCeiling[templateKey];

        tokenRestrictionEnabled[instanceId] = templateTokenRestriction[
            templateKey
        ];
        address[] storage tplTokens = _templateAllowedTokenList[templateKey];
        for (uint256 i = 0; i < tplTokens.length; i++) {
            allowedToken[instanceId][tplTokens[i]] = true;
            _allowedTokenList[instanceId].push(tplTokens[i]);
        }
    }

    // ═══════════════════════════════════════════════════════
    //                 RENTER: Set Limits
    // ═══════════════════════════════════════════════════════

    function setLimits(
        uint256 instanceId,
        uint256 maxPerTx,
        uint256 maxPerDay,
        uint256 maxSlippageBps
    ) external {
        _checkRenterOrOwner(instanceId);

        bytes32 tid = instanceTemplate[instanceId];
        Limits storage ceiling = templateCeiling[tid];
        require(
            ceiling.maxPerTx > 0 || ceiling.maxPerDay > 0,
            "Ceiling not configured"
        );

        if (ceiling.maxPerTx > 0) {
            if (maxPerTx == 0 || maxPerTx > ceiling.maxPerTx)
                revert ExceedsCeiling("maxPerTx");
        }
        if (ceiling.maxPerDay > 0) {
            if (maxPerDay == 0 || maxPerDay > ceiling.maxPerDay)
                revert ExceedsCeiling("maxPerDay");
        }
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

    /// @notice Renter sets instance approve limit (must be <= ceiling)
    /// @dev Setting to 0 disables all ERC20 approve operations
    function setApproveLimit(
        uint256 instanceId,
        uint256 maxApproveAmount
    ) external {
        _checkRenterOrOwner(instanceId);
        bytes32 tid = instanceTemplate[instanceId];
        uint256 ceiling = templateApproveCeiling[tid];
        require(ceiling > 0, "Approve ceiling not configured");
        if (maxApproveAmount > ceiling)
            revert ExceedsCeiling("maxApproveAmount");
        instanceApproveLimit[instanceId] = maxApproveAmount;
        emit InstanceApproveLimitSet(instanceId, maxApproveAmount);
    }

    // ═══════════════════════════════════════════════════════
    //          RENTER: Token Whitelist Control
    // ═══════════════════════════════════════════════════════

    function setTokenRestriction(uint256 instanceId, bool enabled) external {
        _checkRenterOrOwner(instanceId);
        tokenRestrictionEnabled[instanceId] = enabled;
        hasCustomTokenConfig[instanceId] = true;
        emit TokenRestrictionSet(instanceId, enabled);
    }

    function addToken(uint256 instanceId, address token) external {
        _checkRenterOrOwner(instanceId);
        if (allowedToken[instanceId][token]) revert TokenAlreadyAdded();
        allowedToken[instanceId][token] = true;
        _allowedTokenList[instanceId].push(token);
        hasCustomTokenConfig[instanceId] = true;
        emit TokenAdded(instanceId, token);
    }

    function removeToken(uint256 instanceId, address token) external {
        _checkRenterOrOwner(instanceId);
        if (!allowedToken[instanceId][token]) revert TokenNotFound();
        allowedToken[instanceId][token] = false;
        _removeFromArray(_allowedTokenList[instanceId], token);
        emit TokenRemoved(instanceId, token);
    }

    function getTokenList(
        uint256 instanceId
    ) external view returns (address[] memory) {
        return _allowedTokenList[instanceId];
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
        // ── Layer 1: Hard blocks (transfer, permit) ──
        if (selector == TRANSFER || selector == TRANSFER_FROM) {
            return (false, "Direct ERC20 transfer blocked");
        }
        if (selector == PERMIT || selector == DAI_PERMIT) {
            return (false, "Permit not allowed");
        }
        if (selector == INCREASE_ALLOWANCE) {
            return (false, "Use approve instead of increaseAllowance");
        }

        // ── Layer 2: Approve control ──
        if (selector == APPROVE) {
            (address spender, uint256 amount) = CalldataDecoder.decodeApprove(
                callData
            );
            if (!approvedSpender[spender]) {
                return (false, "Approve spender not allowed");
            }
            if (amount == type(uint256).max) {
                return (false, "Infinite approval not allowed");
            }
            uint256 maxApprove = instanceApproveLimit[instanceId];
            if (maxApprove == 0) {
                return (false, "Approve limit not configured");
            }
            if (amount > maxApprove) {
                return (false, "Approve exceeds limit");
            }

            // Token whitelist: target = ERC20 contract being approved
            if (tokenRestrictionEnabled[instanceId]) {
                if (!_isTokenAllowed(instanceId, target)) {
                    return (false, "Token not in whitelist");
                }
            }

            // Note: approve amounts are NOT checked against daily BNB limit.
            // Approve ceiling (instanceApproveLimit) already gates approve amounts.
            // Daily limit only tracks native BNB spending (msg.value).

            return (true, "");
        }

        // ── Layer 3: decreaseAllowance (safe) ──
        if (selector == DECREASE_ALLOWANCE) {
            (address spender, ) = CalldataDecoder.decodeApprove(callData);
            if (!approvedSpender[spender]) {
                return (false, "Approve spender not allowed");
            }
            return (true, "");
        }

        // ── Layer 4: Token whitelist for BNB swaps (registry-based) ──
        if (tokenRestrictionEnabled[instanceId] && value > 0) {
            if (selector != WBNB_DEPOSIT) {
                address outputToken = _extractOutputToken(selector, callData);
                if (outputToken != address(0)) {
                    if (!_isTokenAllowed(instanceId, outputToken)) {
                        return (false, "Output token not in whitelist");
                    }
                }
            }
        }

        // ── Layer 5: Spending limits (native BNB + ERC20 swaps) ──
        uint256 spend = _extractSpendAmount(selector, callData, value);
        Limits storage limits = instanceLimits[instanceId];

        if (limits.maxPerTx == 0 && limits.maxPerDay == 0) {
            if (spend > 0) {
                return (false, "Spending limits not configured");
            }
            return (true, "");
        }

        if (limits.maxPerTx > 0 && spend > limits.maxPerTx) {
            return (false, "Exceeds per-tx limit");
        }

        if (limits.maxPerDay > 0 && spend > 0) {
            DailyTracking storage dt = dailyTracking[instanceId];
            uint32 today = uint32(block.timestamp / 86400);
            uint256 spent = (dt.dayIndex == today) ? dt.spentToday : 0;
            if (spent + spend > limits.maxPerDay) {
                return (false, "Daily limit reached");
            }
        }

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

    /// @notice Track spending after successful execution
    /// @dev Tracks both native BNB value AND ERC20 swap amountIn toward daily limit.
    function onCommit(
        uint256 instanceId,
        address,
        bytes4 selector,
        bytes calldata callData,
        uint256 value
    ) external override {
        if (msg.sender != guard) revert OnlyGuard();

        uint256 spend = _extractSpendAmount(selector, callData, value);
        if (spend == 0) return;

        DailyTracking storage dt = dailyTracking[instanceId];
        uint32 today = uint32(block.timestamp / 86400);

        if (dt.dayIndex != today) {
            dt.spentToday = spend;
            dt.dayIndex = today;
        } else {
            dt.spentToday += spend;
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

    function _isTokenAllowed(
        uint256 instanceId,
        address token
    ) internal view returns (bool) {
        if (allowedToken[instanceId][token]) return true;
        bytes32 tid = instanceTemplate[instanceId];
        return templateAllowedToken[tid][token];
    }

    /// @notice Extract the effective spend amount from a transaction
    /// @dev For native BNB swaps: returns msg.value
    ///      For ERC20 swaps (V2 5-param): extracts amountIn from calldata
    ///      For V3 swaps: extracts amountIn from struct
    ///      For non-swap operations: returns 0
    /// @return spend The effective spend amount in token-native units
    function _extractSpendAmount(
        bytes4 selector,
        bytes calldata callData,
        uint256 value
    ) internal view returns (uint256 spend) {
        // Native BNB swaps: value is the spend
        if (value > 0) return value;

        // ERC20 swaps: extract amountIn from calldata
        OutputPattern pattern = selectorOutputPattern[selector];

        if (pattern == OutputPattern.V2_PATH) {
            // 5-param layout: (amountIn, amountOutMin, path, to, deadline)
            if (callData.length >= 196) {
                (uint256 amountIn, , , , ) = CalldataDecoder.decodeSwap(
                    callData
                );
                return amountIn;
            }
            return 0;
        }

        if (pattern == OutputPattern.V3_SINGLE) {
            // exactInputSingle struct:
            //   tokenIn(0), tokenOut(32), fee(64), recipient(96),
            //   deadline(128), amountIn(160), amountOutMin(192), sqrtPrice(224)
            // amountIn at struct offset 160 → calldata offset 4+160=164
            if (callData.length >= 196) {
                return uint256(bytes32(callData[164:196]));
            }
            return 0;
        }

        if (pattern == OutputPattern.V3_MULTI) {
            // exactInput struct:
            //   bytes path (dynamic, offset pointer at 0),
            //   address recipient (32), uint256 deadline (64),
            //   uint256 amountIn (96), uint256 amountOutMin (128)
            // amountIn at struct offset 96 → calldata offset 4+96=100
            if (callData.length >= 132) {
                return uint256(bytes32(callData[100:132]));
            }
            return 0;
        }

        // Unknown selector or non-swap operation: no spend to track
        return 0;
    }

    /// @notice Extract output token from swap calldata using registered pattern
    /// @return output The output token address, or address(0) if unknown
    function _extractOutputToken(
        bytes4 selector,
        bytes calldata data
    ) internal view returns (address output) {
        OutputPattern pattern = selectorOutputPattern[selector];

        if (pattern == OutputPattern.V2_PATH) {
            // ABI: (uint256 amountOutMin, address[] path, address to, uint256 deadline)
            // Output token = path[last]
            if (data.length >= 164) {
                (, address[] memory path, , ) = CalldataDecoder.decodeSwapETH(
                    data
                );
                if (path.length > 0) {
                    return path[path.length - 1];
                }
            }
            return address(0);
        }

        if (pattern == OutputPattern.V3_SINGLE) {
            // ABI: struct { tokenIn, tokenOut, fee, recipient, amountIn, amountOutMin, sqrtPriceLimit }
            // tokenOut at offset: 4 (selector) + 32 (tokenIn) = 36
            if (data.length >= 68) {
                return address(uint160(uint256(bytes32(data[36:68]))));
            }
            return address(0);
        }

        if (pattern == OutputPattern.V3_MULTI) {
            // ABI: struct { bytes path, address recipient, uint256 amountIn, uint256 amountOutMin }
            // path is packed: token(20) + fee(3) + token(20) + fee(3) + ...
            // Output token = last 20 bytes of path
            if (data.length >= 68) {
                uint256 pathOffset = uint256(bytes32(data[4:36]));
                uint256 pathLenPos = 4 + pathOffset;
                if (data.length > pathLenPos + 32) {
                    uint256 pathLen = uint256(
                        bytes32(data[pathLenPos:pathLenPos + 32])
                    );
                    uint256 pathDataStart = pathLenPos + 32;
                    if (
                        pathLen >= 20 && data.length >= pathDataStart + pathLen
                    ) {
                        bytes calldata pathData = data[
                            pathDataStart:pathDataStart + pathLen
                        ];
                        // Last 20 bytes of packed path = output token
                        return
                            address(uint160(bytes20(pathData[pathLen - 20:])));
                    }
                }
            }
            return address(0);
        }

        // UNKNOWN pattern: return zero → pass through
        return address(0);
    }

    function _onlyOwner() internal view {
        require(msg.sender == Ownable(guard).owner(), "Only owner");
    }

    function _checkRenterOrOwner(uint256 instanceId) internal view {
        if (msg.sender == Ownable(guard).owner()) return;
        address renter = IERC4907(agentNFA).userOf(instanceId);
        if (msg.sender == renter) return;
        if (agentNFA.code.length > 0) {
            (bool ownerOk, bytes memory ownerData) = agentNFA.staticcall(
                abi.encodeWithSelector(IERC721.ownerOf.selector, instanceId)
            );
            if (ownerOk && ownerData.length >= 32) {
                address tokenOwner = abi.decode(ownerData, (address));
                if (msg.sender == tokenOwner) return;
            }
        }
        revert NotRenterOrOwner();
    }

    function _removeFromArray(address[] storage list, address item) internal {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == item) {
                list[i] = list[list.length - 1];
                list.pop();
                return;
            }
        }
    }
}
