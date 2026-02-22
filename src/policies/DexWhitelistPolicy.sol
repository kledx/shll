// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {IERC4907} from "../interfaces/IERC4907.sol";
import {IAgentNFATemplateView} from "../interfaces/IAgentNFATemplateView.sol";

/// @title DexWhitelistPolicy
/// @notice Target/spender allowlist with template baseline + instance delta.
/// @dev Product semantics:
///      1) Template allowlist is always effective for instances.
///      2) Instance can add extra allowed DEX addresses (incremental allow).
///      3) Instance can block DEX addresses to tighten boundaries.
contract DexWhitelistPolicy is IPolicy {
    // --- Storage ---
    mapping(uint256 => mapping(address => bool)) public dexAllowed;
    mapping(uint256 => address[]) internal _dexList;
    mapping(uint256 => bool) public hasCustomDexList;

    mapping(uint256 => mapping(address => bool)) public dexBlocked;
    mapping(uint256 => address[]) internal _blockedDexList;

    address public immutable guard;
    address public immutable agentNFA;

    // --- Events ---
    event DexAdded(uint256 indexed instanceId, address indexed dex);
    event DexRemoved(uint256 indexed instanceId, address indexed dex);
    event DexBlocked(uint256 indexed instanceId, address indexed dex);
    event DexUnblocked(uint256 indexed instanceId, address indexed dex);

    // --- Errors ---
    error NotRenterOrOwner();
    error DexAlreadyAdded();
    error DexAlreadyBlocked();
    error DexBlockNotFound();

    constructor(address _guard, address _nfa) {
        guard = _guard;
        agentNFA = _nfa;
    }

    function addDex(uint256 instanceId, address dex) external {
        _checkRenterOrOwner(instanceId);
        if (dexAllowed[instanceId][dex]) revert DexAlreadyAdded();
        dexAllowed[instanceId][dex] = true;
        _dexList[instanceId].push(dex);
        if (_isInstance(instanceId)) hasCustomDexList[instanceId] = true;
        emit DexAdded(instanceId, dex);
    }

    function removeDex(uint256 instanceId, address dex) external {
        _checkRenterOrOwner(instanceId);
        dexAllowed[instanceId][dex] = false;
        _removeFromArray(_dexList[instanceId], dex);
        _refreshCustomFlag(instanceId);
        emit DexRemoved(instanceId, dex);
    }

    function getDexList(
        uint256 instanceId
    ) external view returns (address[] memory) {
        return _dexList[instanceId];
    }

    function blockDex(uint256 instanceId, address dex) external {
        _checkRenterOrOwner(instanceId);
        if (dexBlocked[instanceId][dex]) revert DexAlreadyBlocked();
        dexBlocked[instanceId][dex] = true;
        _blockedDexList[instanceId].push(dex);
        if (_isInstance(instanceId)) hasCustomDexList[instanceId] = true;
        emit DexBlocked(instanceId, dex);
    }

    function unblockDex(uint256 instanceId, address dex) external {
        _checkRenterOrOwner(instanceId);
        if (!dexBlocked[instanceId][dex]) revert DexBlockNotFound();
        dexBlocked[instanceId][dex] = false;
        _removeFromArray(_blockedDexList[instanceId], dex);
        _refreshCustomFlag(instanceId);
        emit DexUnblocked(instanceId, dex);
    }

    function getBlockedDexList(
        uint256 instanceId
    ) external view returns (address[] memory) {
        return _blockedDexList[instanceId];
    }

    function check(
        uint256 instanceId,
        address,
        address target,
        bytes4 selector,
        bytes calldata data,
        uint256
    ) external view override returns (bool ok, string memory reason) {
        // approve/increaseAllowance/decreaseAllowance: enforce spender, not token contract.
        // All three share (address, uint256) layout — spender is at calldata offset [16:36].
        address candidate = target;
        if (
            (selector == bytes4(0x095ea7b3) ||  // approve
             selector == bytes4(0x39509351) ||  // increaseAllowance
             selector == bytes4(0xa457c2d7))    // decreaseAllowance
            && data.length >= 36
        ) {
            candidate = address(bytes20(data[16:36]));
        }

        if (dexBlocked[instanceId][candidate]) {
            return (false, "DEX blocked by instance");
        }

        // Fail-close: unconfigured DEX whitelist blocks all operations.
        // Previously fail-open, allowing unrestricted target access when no DEXes were whitelisted.
        if (!_hasAnyAllowedDex(instanceId))
            return (false, "DEX whitelist not configured");

        bool isInst = _isInstance(instanceId);
        uint256 templateId = isInst ? _templateIdOf(instanceId) : 0;
        bool allowed = dexAllowed[instanceId][candidate];
        if (!allowed && isInst) {
            allowed = dexAllowed[templateId][candidate];
        }
        if (!allowed) return (false, "DEX not whitelisted");
        return (true, "");
    }

    function policyType() external pure override returns (bytes32) {
        return keccak256("dex_whitelist");
    }

    function renterConfigurable() external pure override returns (bool) {
        return true;
    }

    function _hasAnyAllowedDex(uint256 instanceId) internal view returns (bool) {
        if (_dexList[instanceId].length > 0) return true;
        if (_isInstance(instanceId)) {
            uint256 templateId = _templateIdOf(instanceId);
            if (_dexList[templateId].length > 0) return true;
        }
        return false;
    }

    function _isInstance(uint256 instanceId) internal view returns (bool) {
        return IAgentNFATemplateView(agentNFA).isInstance(instanceId);
    }

    function _templateIdOf(uint256 instanceId) internal view returns (uint256) {
        return IAgentNFATemplateView(agentNFA).templateOf(instanceId);
    }

    function _refreshCustomFlag(uint256 instanceId) internal {
        if (!_isInstance(instanceId)) return;
        hasCustomDexList[instanceId] =
            _dexList[instanceId].length > 0 ||
            _blockedDexList[instanceId].length > 0;
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
}
