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
import {IERC4907} from "../interfaces/IERC4907.sol";

/// @title DeFiGuardPolicyV2 — Global whitelist + Selector Packs + per-instance config
/// @notice Validates that actions target approved DeFi contracts using allowed functions.
///         Four-layer security:
///         1. Global blacklist (Owner) — highest priority, blocks known malicious contracts
///         2. Function selector validation — global selectors + pack-based selectors
///         3. Target whitelist: global defaults (Owner) + per-instance additions (Renter)
///         4. Selector Packs: Owner creates named packs, Renter enables/disables per-instance
///
/// @dev Upgrade from V1: adds SelectorPack system so renters can self-service enable
///      new DeFi capabilities (lending, staking) without owner intervention.
contract DeFiGuardPolicyV2 is IPolicy, ERC165 {
    // ═══════════════════════════════════════════════════════
    //                       STORAGE
    // ═══════════════════════════════════════════════════════

    // --- Global Whitelist (Owner) ---
    mapping(address => bool) public globalAllowed;
    address[] internal _globalAllowedList;

    // --- Global Blacklist (Owner) ---
    mapping(address => bool) public globalBlacklisted;
    address[] internal _globalBlacklistedList;

    // --- Global Allowed Selectors (Owner, always active) ---
    mapping(bytes4 => bool) public allowedSelectors;
    bytes4[] internal _allowedSelectorsList;

    // --- Per-instance Target Whitelist (Renter) ---
    mapping(uint256 => mapping(address => bool)) public instanceAllowed;
    mapping(uint256 => address[]) internal _instanceAllowedList;

    // --- Selector Packs (NEW in V2) ---
    struct SelectorPack {
        bytes4[] selectors;
        address[] targets; // Optional: pack can also include target addresses
        bool exists;
        bool renterEnabled; // Whether renter can toggle this pack on/off
    }

    mapping(bytes32 => SelectorPack) internal _packs;
    bytes32[] public packIds;

    // Per-instance: which packs are enabled
    mapping(uint256 => mapping(bytes32 => bool)) public instancePackEnabled;

    // Immutables
    address public immutable guard;
    address public agentNFA;

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

    // Pack events
    event PackCreated(
        bytes32 indexed packId,
        uint256 selectorCount,
        uint256 targetCount
    );
    event PackDeleted(bytes32 indexed packId);
    event PackConfigurableSet(bytes32 indexed packId, bool renterEnabled);
    event InstancePackEnabled(
        uint256 indexed instanceId,
        bytes32 indexed packId
    );
    event InstancePackDisabled(
        uint256 indexed instanceId,
        bytes32 indexed packId
    );
    event AgentNFAUpdated(address indexed oldNFA, address indexed newNFA);

    // ═══════════════════════════════════════════════════════
    //                       ERRORS
    // ═══════════════════════════════════════════════════════

    error OnlyOwner();
    error NotRenterOrOwner();
    error AlreadyAdded();
    error NotFound();
    error TargetBlacklisted();
    error PackNotFound();
    error PackAlreadyExists();
    error PackNotRenterConfigurable();

    // ═══════════════════════════════════════════════════════
    //                     CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    constructor(address _guard, address _nfa) {
        guard = _guard;
        agentNFA = _nfa;
    }

    function setAgentNFA(address _nfa) external {
        _onlyOwner();
        require(_nfa != address(0), "zero address");
        emit AgentNFAUpdated(agentNFA, _nfa);
        agentNFA = _nfa;
    }

    // ═══════════════════════════════════════════════════════
    //              OWNER: Global Whitelist
    // ═══════════════════════════════════════════════════════

    function addGlobalTarget(address target) external {
        _onlyOwner();
        if (globalAllowed[target]) revert AlreadyAdded();
        globalAllowed[target] = true;
        _globalAllowedList.push(target);
        emit GlobalTargetAdded(target);
    }

    function removeGlobalTarget(address target) external {
        _onlyOwner();
        if (!globalAllowed[target]) revert NotFound();
        globalAllowed[target] = false;
        _removeFromArray(_globalAllowedList, target);
        emit GlobalTargetRemoved(target);
    }

    function getGlobalTargets() external view returns (address[] memory) {
        return _globalAllowedList;
    }

    // ═══════════════════════════════════════════════════════
    //              OWNER: Global Blacklist
    // ═══════════════════════════════════════════════════════

    function addBlacklist(address target) external {
        _onlyOwner();
        if (globalBlacklisted[target]) revert AlreadyAdded();
        globalBlacklisted[target] = true;
        _globalBlacklistedList.push(target);
        emit GlobalBlacklistAdded(target);
    }

    function removeBlacklist(address target) external {
        _onlyOwner();
        if (!globalBlacklisted[target]) revert NotFound();
        globalBlacklisted[target] = false;
        _removeFromArray(_globalBlacklistedList, target);
        emit GlobalBlacklistRemoved(target);
    }

    function getBlacklist() external view returns (address[] memory) {
        return _globalBlacklistedList;
    }

    // ═══════════════════════════════════════════════════════
    //              OWNER: Global Allowed Selectors
    // ═══════════════════════════════════════════════════════

    function addSelector(bytes4 selector) external {
        _onlyOwner();
        if (allowedSelectors[selector]) revert AlreadyAdded();
        allowedSelectors[selector] = true;
        _allowedSelectorsList.push(selector);
        emit SelectorAdded(selector);
    }

    function removeSelector(bytes4 selector) external {
        _onlyOwner();
        if (!allowedSelectors[selector]) revert NotFound();
        allowedSelectors[selector] = false;
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

    function getAllowedSelectors() external view returns (bytes4[] memory) {
        return _allowedSelectorsList;
    }

    // ═══════════════════════════════════════════════════════
    //          OWNER: Selector Pack Management
    // ═══════════════════════════════════════════════════════

    /// @notice Create a named selector pack with optional target addresses
    /// @param packId Pack name hash (e.g. keccak256("LENDING"))
    /// @param selectors Function selectors in this pack
    /// @param targets Optional target addresses bundled with this pack
    /// @param renterEnabled Whether renters can toggle this pack
    function createPack(
        bytes32 packId,
        bytes4[] calldata selectors,
        address[] calldata targets,
        bool renterEnabled
    ) external {
        _onlyOwner();
        if (_packs[packId].exists) revert PackAlreadyExists();

        SelectorPack storage pack = _packs[packId];
        pack.exists = true;
        pack.renterEnabled = renterEnabled;

        for (uint256 i = 0; i < selectors.length; i++) {
            pack.selectors.push(selectors[i]);
        }
        for (uint256 i = 0; i < targets.length; i++) {
            pack.targets.push(targets[i]);
        }

        packIds.push(packId);
        emit PackCreated(packId, selectors.length, targets.length);
    }

    /// @notice Delete a pack (does not affect instances that had it enabled)
    function deletePack(bytes32 packId) external {
        _onlyOwner();
        if (!_packs[packId].exists) revert PackNotFound();
        delete _packs[packId];
        // Remove from packIds array
        for (uint256 i = 0; i < packIds.length; i++) {
            if (packIds[i] == packId) {
                packIds[i] = packIds[packIds.length - 1];
                packIds.pop();
                break;
            }
        }
        emit PackDeleted(packId);
    }

    /// @notice Set whether renters can toggle a pack
    function setPackConfigurable(bytes32 packId, bool renterEnabled) external {
        _onlyOwner();
        if (!_packs[packId].exists) revert PackNotFound();
        _packs[packId].renterEnabled = renterEnabled;
        emit PackConfigurableSet(packId, renterEnabled);
    }

    /// @notice Get pack details
    function getPack(
        bytes32 packId
    )
        external
        view
        returns (
            bytes4[] memory selectors,
            address[] memory targets,
            bool renterEnabled,
            bool exists
        )
    {
        SelectorPack storage pack = _packs[packId];
        return (pack.selectors, pack.targets, pack.renterEnabled, pack.exists);
    }

    /// @notice Get all pack IDs
    function getPackIds() external view returns (bytes32[] memory) {
        return packIds;
    }

    // ═══════════════════════════════════════════════════════
    //       RENTER: Per-instance Pack Enable/Disable
    // ═══════════════════════════════════════════════════════

    /// @notice Enable a selector pack for this instance
    function enablePack(uint256 instanceId, bytes32 packId) external {
        _checkRenterOrOwner(instanceId);
        if (!_packs[packId].exists) revert PackNotFound();
        if (!_packs[packId].renterEnabled) revert PackNotRenterConfigurable();
        instancePackEnabled[instanceId][packId] = true;
        emit InstancePackEnabled(instanceId, packId);
    }

    /// @notice Disable a selector pack for this instance
    function disablePack(uint256 instanceId, bytes32 packId) external {
        _checkRenterOrOwner(instanceId);
        if (!_packs[packId].exists) revert PackNotFound();
        instancePackEnabled[instanceId][packId] = false;
        emit InstancePackDisabled(instanceId, packId);
    }

    // ═══════════════════════════════════════════════════════
    //            RENTER: Per-instance Target Whitelist
    // ═══════════════════════════════════════════════════════

    function addInstanceTarget(uint256 instanceId, address target) external {
        _checkRenterOrOwner(instanceId);
        if (globalBlacklisted[target]) revert TargetBlacklisted();
        if (instanceAllowed[instanceId][target]) revert AlreadyAdded();
        instanceAllowed[instanceId][target] = true;
        _instanceAllowedList[instanceId].push(target);
        emit InstanceTargetAdded(instanceId, target);
    }

    function removeInstanceTarget(uint256 instanceId, address target) external {
        _checkRenterOrOwner(instanceId);
        if (!instanceAllowed[instanceId][target]) revert NotFound();
        instanceAllowed[instanceId][target] = false;
        _removeFromArray(_instanceAllowedList[instanceId], target);
        emit InstanceTargetRemoved(instanceId, target);
    }

    function getInstanceTargets(
        uint256 instanceId
    ) external view returns (address[] memory) {
        return _instanceAllowedList[instanceId];
    }

    // ═══════════════════════════════════════════════════════
    //                 IPolicy INTERFACE
    // ═══════════════════════════════════════════════════════

    /// @notice Four-layer validation:
    ///   1. Blacklist check (reject)
    ///   2. Selector check — global OR enabled packs (reject unknown functions)
    ///   3. approve/decreaseAllowance bypass (SpendingLimitPolicy handles these)
    ///   4. Target whitelist — global OR per-instance OR pack targets (approve)
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
        // Check global selectors first
        bool selectorOk = allowedSelectors[selector];

        // If not in global, check enabled packs
        if (!selectorOk) {
            for (uint256 i = 0; i < packIds.length; i++) {
                bytes32 pid = packIds[i];
                if (!instancePackEnabled[instanceId][pid]) continue;
                SelectorPack storage pack = _packs[pid];
                if (!pack.exists) continue;
                for (uint256 j = 0; j < pack.selectors.length; j++) {
                    if (pack.selectors[j] == selector) {
                        selectorOk = true;
                        break;
                    }
                }
                if (selectorOk) break;
            }
        }

        if (!selectorOk) {
            // Fail-close: no matching selector at all
            if (_allowedSelectorsList.length == 0 && packIds.length == 0) {
                return (false, "Selector whitelist not configured");
            }
            return (false, "Function not allowed");
        }

        // Layer 3: approve/decreaseAllowance bypass
        // These target token contracts, not DEX routers.
        // SpendingLimitPolicy handles approve security.
        if (selector == bytes4(0x095ea7b3) || selector == bytes4(0xa457c2d7)) {
            return (true, "");
        }

        // Layer 4: Target whitelist — global OR per-instance OR pack targets
        // Check global whitelist
        if (globalAllowed[target]) {
            return (true, "");
        }

        // Check per-instance whitelist
        if (instanceAllowed[instanceId][target]) {
            return (true, "");
        }

        // Check pack targets (new in V2)
        for (uint256 i = 0; i < packIds.length; i++) {
            bytes32 pid = packIds[i];
            if (!instancePackEnabled[instanceId][pid]) continue;
            SelectorPack storage pack = _packs[pid];
            if (!pack.exists) continue;
            for (uint256 j = 0; j < pack.targets.length; j++) {
                if (pack.targets[j] == target) {
                    return (true, "");
                }
            }
        }

        // Fail-close
        if (
            _globalAllowedList.length == 0 &&
            _instanceAllowedList[instanceId].length == 0
        ) {
            return (false, "Target whitelist not configured");
        }

        return (false, "Target not in whitelist");
    }

    function policyType() external pure override returns (bytes32) {
        return keccak256("defi_guard");
    }

    function renterConfigurable() external pure override returns (bool) {
        return true;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IPolicy).interfaceId ||
            super.supportsInterface(interfaceId);
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
