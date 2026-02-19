// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Ownable2Step,
    Ownable
} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {
    IERC165
} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {IPolicyGuard} from "./interfaces/IPolicyGuard.sol";
import {IPolicy} from "./interfaces/IPolicy.sol";
import {ICommittable} from "./interfaces/ICommittable.sol";
import {IERC4907} from "./interfaces/IERC4907.sol";
import {IInstanceInitializable} from "./interfaces/IInstanceInitializable.sol";
import {Action} from "./types/Action.sol";

/// @title PolicyGuardV4 — Composable Policy Engine (V3.0)
/// @notice Replaces hardcoded three-mode validation with a plugin registry.
///         Owner defines template policies (ceiling); renter configures within.
contract PolicyGuardV4 is IPolicyGuard, Ownable2Step {
    // ═══════════════════════════════════════════════════════
    //                       CONSTANTS
    // ═══════════════════════════════════════════════════════

    uint8 public constant MAX_POLICIES_PER_INSTANCE = 16;

    // ═══════════════════════════════════════════════════════
    //                       STORAGE
    // ═══════════════════════════════════════════════════════

    // --- Admin: Policy registry ---
    mapping(address => bool) public approvedPolicies;

    // --- Template: Owner-defined policy ceiling ---
    mapping(bytes32 => address[]) internal _templatePolicies;

    // --- Instance: Renter-configured policies ---
    mapping(uint256 => address[]) internal _instancePolicies;
    mapping(uint256 => bool) public hasCustomPolicies;

    // --- Instance config ---
    mapping(uint256 => bytes32) public instanceTemplateId;

    // --- Access control ---
    address public agentNFA;
    address public listingManager;

    // ═══════════════════════════════════════════════════════
    //                       EVENTS
    // ═══════════════════════════════════════════════════════

    event PolicyApproved(address indexed policy);
    event PolicyRevoked(address indexed policy);
    event TemplatePolicyAdded(
        bytes32 indexed templateId,
        address indexed policy
    );
    event TemplatePolicyRemoved(
        bytes32 indexed templateId,
        address indexed policy
    );
    event InstancePolicyAdded(
        uint256 indexed instanceId,
        address indexed policy
    );
    event InstancePolicyRemoved(
        uint256 indexed instanceId,
        address indexed policy
    );
    event InstanceBound(uint256 indexed instanceId, bytes32 indexed templateId);
    event CommitFailed(
        uint256 indexed instanceId,
        address indexed policy,
        bytes reason
    );

    // ═══════════════════════════════════════════════════════
    //                       ERRORS
    // ═══════════════════════════════════════════════════════

    error NotRenterOrOwner();
    error PolicyNotApproved(address policy);
    error TooManyPolicies();
    error PolicyIndexOutOfBounds();
    error CannotRemoveNonConfigurable();
    error DuplicatePolicy(address policy);
    error OnlyAgentNFA();
    error OnlyListingManager();

    // ═══════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    constructor() {}

    // ═══════════════════════════════════════════════════════
    //                   ADMIN: Access Control
    // ═══════════════════════════════════════════════════════

    /// @notice Set the AgentNFA contract address (for validate/commit calls)
    function setAgentNFA(address _nfa) external onlyOwner {
        agentNFA = _nfa;
    }

    /// @notice Set the ListingManager address (for bindInstance calls)
    function setListingManager(address _lm) external onlyOwner {
        listingManager = _lm;
    }

    // ═══════════════════════════════════════════════════════
    //                ADMIN: Policy Registry
    // ═══════════════════════════════════════════════════════

    /// @notice Approve a policy contract for use in templates/instances
    function approvePolicyContract(address policy) external onlyOwner {
        approvedPolicies[policy] = true;
        emit PolicyApproved(policy);
    }

    /// @notice Revoke a policy contract approval
    function revokePolicyContract(address policy) external onlyOwner {
        approvedPolicies[policy] = false;
        emit PolicyRevoked(policy);
    }

    // ═══════════════════════════════════════════════════════
    //             ADMIN: Template Management
    // ═══════════════════════════════════════════════════════

    /// @notice Add a policy to a template set
    function addTemplatePolicy(
        bytes32 templateId,
        address policy
    ) external onlyOwner {
        if (!approvedPolicies[policy]) revert PolicyNotApproved(policy);
        // H-3 fix: enforce cap on template policies
        if (_templatePolicies[templateId].length >= MAX_POLICIES_PER_INSTANCE)
            revert TooManyPolicies();
        _templatePolicies[templateId].push(policy);
        emit TemplatePolicyAdded(templateId, policy);
    }

    /// @notice Remove a policy from a template set by index (swap-and-pop)
    function removeTemplatePolicy(
        bytes32 templateId,
        uint256 index
    ) external onlyOwner {
        address[] storage tpl = _templatePolicies[templateId];
        if (index >= tpl.length) revert PolicyIndexOutOfBounds();
        address removed = tpl[index];
        tpl[index] = tpl[tpl.length - 1];
        tpl.pop();
        emit TemplatePolicyRemoved(templateId, removed);
    }

    // ═══════════════════════════════════════════════════════
    //             MINTER: Instance Binding
    // ═══════════════════════════════════════════════════════

    /// @notice Bind an instance to a template (called by ListingManager during mint)
    /// @dev Atomically initializes all template policies that support IInstanceInitializable
    function bindInstance(uint256 instanceId, bytes32 templateId) external {
        if (msg.sender != listingManager && msg.sender != owner())
            revert OnlyListingManager();
        instanceTemplateId[instanceId] = templateId;

        // Atomic policy initialization: close the fail-open gap
        address[] storage tplPolicies = _templatePolicies[templateId];
        for (uint256 i = 0; i < tplPolicies.length; i++) {
            // Try ERC-165 detection for IInstanceInitializable
            try
                IERC165(tplPolicies[i]).supportsInterface(
                    type(IInstanceInitializable).interfaceId
                )
            returns (bool supported) {
                if (supported) {
                    IInstanceInitializable(tplPolicies[i]).initInstance(
                        instanceId,
                        templateId
                    );
                }
            } catch {
                // Policy doesn't support ERC-165 or IInstanceInitializable — skip
            }
        }

        emit InstanceBound(instanceId, templateId);
    }

    // ═══════════════════════════════════════════════════════
    //           RENTER: Policy Configuration
    // ═══════════════════════════════════════════════════════

    /// @notice Add a policy to an instance (renter or owner)
    function addInstancePolicy(uint256 instanceId, address policy) external {
        _checkRenterOrOwner(instanceId);
        if (!approvedPolicies[policy]) revert PolicyNotApproved(policy);

        address[] storage policies = _instancePolicies[instanceId];

        // First custom policy: copy template set as baseline
        if (!hasCustomPolicies[instanceId]) {
            bytes32 tid = instanceTemplateId[instanceId];
            address[] storage tpl = _templatePolicies[tid];
            for (uint256 i = 0; i < tpl.length; i++) {
                policies.push(tpl[i]);
            }
            hasCustomPolicies[instanceId] = true;
        }

        if (policies.length >= MAX_POLICIES_PER_INSTANCE)
            revert TooManyPolicies();
        // M-5 fix: prevent duplicate policies (avoids double-counting in onCommit)
        for (uint256 i = 0; i < policies.length; i++) {
            if (policies[i] == policy) revert DuplicatePolicy(policy);
        }
        policies.push(policy);
        emit InstancePolicyAdded(instanceId, policy);
    }

    /// @notice Remove a policy from an instance by index (only renterConfigurable ones)
    function removeInstancePolicy(uint256 instanceId, uint256 index) external {
        _checkRenterOrOwner(instanceId);
        address[] storage policies = _instancePolicies[instanceId];
        if (index >= policies.length) revert PolicyIndexOutOfBounds();

        // Cannot remove non-configurable policies (e.g. ReceiverGuard)
        if (!IPolicy(policies[index]).renterConfigurable()) {
            revert CannotRemoveNonConfigurable();
        }

        address removed = policies[index];
        // Swap-and-pop
        policies[index] = policies[policies.length - 1];
        policies.pop();
        emit InstancePolicyRemoved(instanceId, removed);
    }

    // ═══════════════════════════════════════════════════════
    //                   CORE: Validate
    // ═══════════════════════════════════════════════════════

    /// @notice Validate an action against all active policies for the instance
    /// @inheritdoc IPolicyGuard
    function validate(
        address /* nfa */,
        uint256 tokenId,
        address /* agentAccount */,
        address caller,
        Action calldata action
    ) external view override returns (bool ok, string memory reason) {
        address[] storage policies = _getActivePolicies(tokenId);
        // C-1 fix: safe selector extraction — empty data (pure value transfer) yields bytes4(0)
        bytes4 selector = action.data.length >= 4
            ? bytes4(action.data[:4])
            : bytes4(0);

        for (uint256 i = 0; i < policies.length; i++) {
            (bool pOk, string memory pReason) = IPolicy(policies[i]).check(
                tokenId,
                caller,
                action.target,
                selector,
                action.data,
                action.value
            );
            if (!pOk) return (false, pReason);
        }
        return (true, "");
    }

    // ═══════════════════════════════════════════════════════
    //                    CORE: Commit
    // ═══════════════════════════════════════════════════════

    /// @notice Post-execution state update — calls onCommit() on committable policies
    /// @inheritdoc IPolicyGuard
    function commit(uint256 tokenId, Action calldata action) external override {
        if (msg.sender != agentNFA) revert OnlyAgentNFA();

        address[] storage policies = _getActivePolicies(tokenId);
        // C-1 fix: safe selector extraction
        bytes4 selector = action.data.length >= 4
            ? bytes4(action.data[:4])
            : bytes4(0);

        for (uint256 i = 0; i < policies.length; i++) {
            // H-1 fix: each onCommit() wrapped in its own try-catch so one
            // failure does not skip subsequent committable policies
            try
                IERC165(policies[i]).supportsInterface(
                    type(ICommittable).interfaceId
                )
            returns (bool supported) {
                if (supported) {
                    try
                        ICommittable(policies[i]).onCommit(
                            tokenId,
                            action.target,
                            selector,
                            action.data,
                            action.value
                        )
                    {} catch (bytes memory reason) {
                        // M-2 fix: emit event instead of silent failure
                        emit CommitFailed(tokenId, policies[i], reason);
                    }
                }
            } catch {
                // Policy doesn't implement ERC-165 / ICommittable — skip
            }
        }
    }

    // ═══════════════════════════════════════════════════════
    //                       VIEWS
    // ═══════════════════════════════════════════════════════

    /// @notice Get the active policy set for an instance
    function getActivePolicies(
        uint256 instanceId
    ) external view returns (address[] memory) {
        address[] storage policies = _getActivePolicies(instanceId);
        address[] memory result = new address[](policies.length);
        for (uint256 i = 0; i < policies.length; i++) {
            result[i] = policies[i];
        }
        return result;
    }

    /// @notice Get the template policy set
    function getTemplatePolicies(
        bytes32 templateId
    ) external view returns (address[] memory) {
        return _templatePolicies[templateId];
    }

    // ═══════════════════════════════════════════════════════
    //                     INTERNALS
    // ═══════════════════════════════════════════════════════

    /// @dev Resolve the active policy array for a given instance
    function _getActivePolicies(
        uint256 instanceId
    ) internal view returns (address[] storage) {
        if (hasCustomPolicies[instanceId]) {
            return _instancePolicies[instanceId];
        }
        bytes32 tid = instanceTemplateId[instanceId];
        return _templatePolicies[tid];
    }

    /// @dev Check that msg.sender is the renter (userOf) or contract owner
    function _checkRenterOrOwner(uint256 instanceId) internal view {
        if (msg.sender == owner()) return;
        address renter = IERC4907(agentNFA).userOf(instanceId);
        if (msg.sender != renter) revert NotRenterOrOwner();
    }
}
