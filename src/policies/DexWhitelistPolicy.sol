// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {IERC4907} from "../interfaces/IERC4907.sol";

/// @title DexWhitelistPolicy — Only allow interactions with approved DEX routers
contract DexWhitelistPolicy is IPolicy {
    // ─── Storage ───
    mapping(uint256 => mapping(address => bool)) public dexAllowed;
    mapping(uint256 => address[]) internal _dexList;

    address public immutable guard;
    address public immutable agentNFA;

    // ─── Events ───
    event DexAdded(uint256 indexed instanceId, address indexed dex);
    event DexRemoved(uint256 indexed instanceId, address indexed dex);

    // ─── Errors ───
    error NotRenterOrOwner();
    error DexAlreadyAdded();

    constructor(address _guard, address _nfa) {
        guard = _guard;
        agentNFA = _nfa;
    }

    // ═══════════════════════════════════════════════════════
    //                   CONFIGURATION
    // ═══════════════════════════════════════════════════════

    function addDex(uint256 instanceId, address dex) external {
        _checkRenterOrOwner(instanceId);
        if (dexAllowed[instanceId][dex]) revert DexAlreadyAdded();
        dexAllowed[instanceId][dex] = true;
        _dexList[instanceId].push(dex);
        emit DexAdded(instanceId, dex);
    }

    function removeDex(uint256 instanceId, address dex) external {
        _checkRenterOrOwner(instanceId);
        dexAllowed[instanceId][dex] = false;
        // M-4 fix: only emit event when dex is actually found and removed
        address[] storage list = _dexList[instanceId];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == dex) {
                list[i] = list[list.length - 1];
                list.pop();
                emit DexRemoved(instanceId, dex);
                return;
            }
        }
    }

    /// @notice Get all whitelisted DEXes for an instance
    function getDexList(
        uint256 instanceId
    ) external view returns (address[] memory) {
        return _dexList[instanceId];
    }

    // ═══════════════════════════════════════════════════════
    //                   IPolicy INTERFACE
    // ═══════════════════════════════════════════════════════

    function check(
        uint256 instanceId,
        address,
        address target,
        bytes4,
        bytes calldata,
        uint256
    ) external view override returns (bool ok, string memory reason) {
        // If no whitelist configured, allow all
        if (_dexList[instanceId].length == 0) return (true, "");

        if (!dexAllowed[instanceId][target]) {
            return (false, "DEX not whitelisted");
        }
        return (true, "");
    }

    function policyType() external pure override returns (bytes32) {
        return keccak256("dex_whitelist");
    }

    function renterConfigurable() external pure override returns (bool) {
        return true;
    }

    // ═══════════════════════════════════════════════════════
    //                    INTERNALS
    // ═══════════════════════════════════════════════════════

    function _checkRenterOrOwner(uint256 instanceId) internal view {
        address renter = IERC4907(agentNFA).userOf(instanceId);
        if (msg.sender != renter && msg.sender != Ownable(guard).owner()) {
            revert NotRenterOrOwner();
        }
    }
}
