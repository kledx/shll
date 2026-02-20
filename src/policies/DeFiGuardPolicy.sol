// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {IERC4907} from "../interfaces/IERC4907.sol";

/// @title DeFiGuardPolicy — Global whitelist + per-instance renter config + blacklist
/// @notice Validates that actions target approved DeFi contracts using allowed functions.
///         Three-layer security:
///         1. Global blacklist (Owner) — highest priority, blocks known malicious contracts
///         2. Function selector filter (Owner) — only known DeFi ops (swap, approve, etc.)
///         3. Target whitelist: global defaults (Owner) + per-instance additions (Renter)
contract DeFiGuardPolicy is IPolicy {
    // ═══════════════════════════════════════════════════════
    //                       STORAGE
    // ═══════════════════════════════════════════════════════

    /// @notice Global default whitelist — all instances inherit (e.g. PancakeSwap Router)
    mapping(address => bool) public globalAllowed;
    address[] internal _globalAllowedList;

    /// @notice Global blacklist — overrides everything (known malicious contracts)
    mapping(address => bool) public globalBlacklisted;
    address[] internal _globalBlacklistedList;

    /// @notice Allowed function selectors (e.g. swap, approve, transfer)
    mapping(bytes4 => bool) public allowedSelectors;
    bytes4[] internal _allowedSelectorsList;

    /// @notice Per-instance whitelist — renter can add extra targets
    mapping(uint256 => mapping(address => bool)) public instanceAllowed;
    mapping(uint256 => address[]) internal _instanceAllowedList;

    address public immutable guard;
    address public immutable agentNFA;

    // ═══════════════════════════════════════════════════════
    //                       EVENTS
    // ═══════════════════════════════════════════════════════

    event GlobalTargetAdded(address indexed target);
    event GlobalTargetRemoved(address indexed target);
    event GlobalBlacklistAdded(address indexed target);
    event GlobalBlacklistRemoved(address indexed target);
    event SelectorAdded(bytes4 indexed selector);
    event SelectorRemoved(bytes4 indexed selector);
    event InstanceTargetAdded(
        uint256 indexed instanceId,
        address indexed target
    );
    event InstanceTargetRemoved(
        uint256 indexed instanceId,
        address indexed target
    );

    // ═══════════════════════════════════════════════════════
    //                       ERRORS
    // ═══════════════════════════════════════════════════════

    error OnlyOwner();
    error NotRenterOrOwner();
    error AlreadyAdded();
    error NotFound();
    error TargetBlacklisted();

    // ═══════════════════════════════════════════════════════
    //                     CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    constructor(address _guard, address _nfa) {
        guard = _guard;
        agentNFA = _nfa;
    }

    // ═══════════════════════════════════════════════════════
    //              OWNER: Global Whitelist
    // ═══════════════════════════════════════════════════════

    /// @notice Add a target to the global whitelist (all instances inherit)
    function addGlobalTarget(address target) external {
        _onlyOwner();
        if (globalAllowed[target]) revert AlreadyAdded();
        globalAllowed[target] = true;
        _globalAllowedList.push(target);
        emit GlobalTargetAdded(target);
    }

    /// @notice Remove a target from the global whitelist
    function removeGlobalTarget(address target) external {
        _onlyOwner();
        if (!globalAllowed[target]) revert NotFound();
        globalAllowed[target] = false;
        _removeFromArray(_globalAllowedList, target);
        emit GlobalTargetRemoved(target);
    }

    /// @notice Get all global whitelisted targets
    function getGlobalTargets() external view returns (address[] memory) {
        return _globalAllowedList;
    }

    // ═══════════════════════════════════════════════════════
    //              OWNER: Global Blacklist
    // ═══════════════════════════════════════════════════════

    /// @notice Add a target to the global blacklist (overrides everything)
    function addBlacklist(address target) external {
        _onlyOwner();
        if (globalBlacklisted[target]) revert AlreadyAdded();
        globalBlacklisted[target] = true;
        _globalBlacklistedList.push(target);
        emit GlobalBlacklistAdded(target);
    }

    /// @notice Remove a target from the global blacklist
    function removeBlacklist(address target) external {
        _onlyOwner();
        if (!globalBlacklisted[target]) revert NotFound();
        globalBlacklisted[target] = false;
        _removeFromArray(_globalBlacklistedList, target);
        emit GlobalBlacklistRemoved(target);
    }

    /// @notice Get all blacklisted targets
    function getBlacklist() external view returns (address[] memory) {
        return _globalBlacklistedList;
    }

    // ═══════════════════════════════════════════════════════
    //              OWNER: Allowed Selectors
    // ═══════════════════════════════════════════════════════

    /// @notice Add an allowed function selector
    function addSelector(bytes4 selector) external {
        _onlyOwner();
        if (allowedSelectors[selector]) revert AlreadyAdded();
        allowedSelectors[selector] = true;
        _allowedSelectorsList.push(selector);
        emit SelectorAdded(selector);
    }

    /// @notice Remove an allowed function selector
    function removeSelector(bytes4 selector) external {
        _onlyOwner();
        if (!allowedSelectors[selector]) revert NotFound();
        allowedSelectors[selector] = false;
        // Remove from list
        bytes4[] storage list = _allowedSelectorsList;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == selector) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        emit SelectorRemoved(selector);
    }

    /// @notice Get all allowed selectors
    function getAllowedSelectors() external view returns (bytes4[] memory) {
        return _allowedSelectorsList;
    }

    // ═══════════════════════════════════════════════════════
    //            RENTER: Per-instance Whitelist
    // ═══════════════════════════════════════════════════════

    /// @notice Renter adds a target to their instance whitelist
    function addInstanceTarget(uint256 instanceId, address target) external {
        _checkRenterOrOwner(instanceId);
        if (globalBlacklisted[target]) revert TargetBlacklisted();
        if (instanceAllowed[instanceId][target]) revert AlreadyAdded();
        instanceAllowed[instanceId][target] = true;
        _instanceAllowedList[instanceId].push(target);
        emit InstanceTargetAdded(instanceId, target);
    }

    /// @notice Renter removes a target from their instance whitelist
    function removeInstanceTarget(uint256 instanceId, address target) external {
        _checkRenterOrOwner(instanceId);
        if (!instanceAllowed[instanceId][target]) revert NotFound();
        instanceAllowed[instanceId][target] = false;
        _removeFromArray(_instanceAllowedList[instanceId], target);
        emit InstanceTargetRemoved(instanceId, target);
    }

    /// @notice Get all instance-level whitelisted targets
    function getInstanceTargets(
        uint256 instanceId
    ) external view returns (address[] memory) {
        return _instanceAllowedList[instanceId];
    }

    // ═══════════════════════════════════════════════════════
    //                 IPolicy INTERFACE
    // ═══════════════════════════════════════════════════════

    /// @notice Three-layer validation:
    ///   1. Blacklist check (reject)
    ///   2. Selector check (reject unknown functions)
    ///   3. Whitelist check: global OR per-instance (approve)
    function check(
        uint256 instanceId,
        address,
        address target,
        bytes4 selector,
        bytes calldata,
        uint256
    ) external view override returns (bool ok, string memory reason) {
        // Layer 1: Blacklist — highest priority
        if (globalBlacklisted[target]) {
            return (false, "Target is blacklisted");
        }

        // Layer 2: Selector validation
        // Fail-close: unconfigured selector allowlist blocks all calls.
        if (_allowedSelectorsList.length == 0) {
            return (false, "Selector whitelist not configured");
        }
        if (!allowedSelectors[selector]) {
            return (false, "Function not allowed");
        }

        // Layer 3: Whitelist — global OR per-instance
        // Fail-close: unconfigured target whitelist blocks all calls.
        if (
            _globalAllowedList.length == 0 &&
            _instanceAllowedList[instanceId].length == 0
        ) {
            return (false, "Target whitelist not configured");
        }

        // Check global whitelist
        if (globalAllowed[target]) {
            return (true, "");
        }

        // Check per-instance whitelist
        if (instanceAllowed[instanceId][target]) {
            return (true, "");
        }

        return (false, "Target not in whitelist");
    }

    function policyType() external pure override returns (bytes32) {
        return keccak256("defi_guard");
    }

    function renterConfigurable() external pure override returns (bool) {
        return true;
    }

    // ═══════════════════════════════════════════════════════
    //                     INTERNALS
    // ═══════════════════════════════════════════════════════

    function _onlyOwner() internal view {
        if (msg.sender != Ownable(guard).owner()) revert OnlyOwner();
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
