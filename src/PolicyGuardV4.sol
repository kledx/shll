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
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
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
    error EmptyTemplateId();
    error EmptyTemplatePolicies(bytes32 templateId);
    error ZeroAddress();

    // ═══════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ═══════════════════════════════════════════════════════

    constructor() {}

    // ═══════════════════════════════════════════════════════
    //                   ADMIN: Access Control
    // ═══════════════════════════════════════════════════════

    /// @notice Set the AgentNFA contract address (for validate/commit calls)
    function setAgentNFA(address _nfa) external onlyOwner {
        if (_nfa == address(0)) revert ZeroAddress();
        agentNFA = _nfa;
    }

    /// @notice Set the ListingManager address (for bindInstance calls)
    function setListingManager(address _lm) external onlyOwner {
        if (_lm == address(0)) revert ZeroAddress();
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
        address[] storage templatePolicies = _templatePolicies[templateId];
        if (templatePolicies.length >= MAX_POLICIES_PER_INSTANCE)
            revert TooManyPolicies();
        for (uint256 i = 0; i < templatePolicies.length; i++) {
            if (templatePolicies[i] == policy) revert DuplicatePolicy(policy);
        }
        templatePolicies.push(policy);
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
        if (templateId == bytes32(0)) revert EmptyTemplateId();
        if (_templatePolicies[templateId].length == 0)
            revert EmptyTemplatePolicies(templateId);
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
        bytes32 tid = instanceTemplateId[instanceId];
        if (tid == bytes32(0)) revert EmptyTemplateId();

        address[] storage tpl = _templatePolicies[tid];
        address[] storage custom = _instancePolicies[instanceId];
        if (tpl.length + custom.length >= MAX_POLICIES_PER_INSTANCE)
            revert TooManyPolicies();

        // Prevent duplicates across template baseline + custom additions.
        for (uint256 i = 0; i < tpl.length; i++) {
            if (tpl[i] == policy) revert DuplicatePolicy(policy);
        }
        for (uint256 i = 0; i < custom.length; i++) {
            if (custom[i] == policy) revert DuplicatePolicy(policy);
        }

        custom.push(policy);
        hasCustomPolicies[instanceId] = true;
        emit InstancePolicyAdded(instanceId, policy);
    }

    /// @notice Remove a policy from an instance by index (only renterConfigurable ones)
    function removeInstancePolicy(uint256 instanceId, uint256 index) external {
        _checkRenterOrOwner(instanceId);
        if (instanceTemplateId[instanceId] == bytes32(0)) revert EmptyTemplateId();
        address[] storage custom = _instancePolicies[instanceId];
        if (index >= custom.length) revert PolicyIndexOutOfBounds();

        // Cannot remove non-configurable policies (e.g. ReceiverGuard)
        if (!IPolicy(custom[index]).renterConfigurable()) {
            revert CannotRemoveNonConfigurable();
        }

        address removed = custom[index];
        // Swap-and-pop
        custom[index] = custom[custom.length - 1];
        custom.pop();
        if (custom.length == 0) hasCustomPolicies[instanceId] = false;
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
        bytes32 tid = instanceTemplateId[tokenId];
        if (tid == bytes32(0)) {
            return (false, "INSTANCE_NOT_BOUND");
        }
        address[] storage tpl = _templatePolicies[tid];
        address[] storage custom = _instancePolicies[tokenId];
        if (tpl.length == 0 && custom.length == 0) {
            return (false, "NO_ACTIVE_POLICIES");
        }
        // C-1 fix: safe selector extraction — empty data (pure value transfer) yields bytes4(0)
        bytes4 selector = action.data.length >= 4
            ? bytes4(action.data[:4])
            : bytes4(0);

        for (uint256 i = 0; i < tpl.length; i++) {
            (bool pOk, string memory pReason) = IPolicy(tpl[i]).check(
                tokenId,
                caller,
                action.target,
                selector,
                action.data,
                action.value
            );
            if (!pOk) return (false, pReason);
        }
        for (uint256 i = 0; i < custom.length; i++) {
            (bool pOk, string memory pReason) = IPolicy(custom[i]).check(
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

        bytes32 tid = instanceTemplateId[tokenId];
        address[] storage tpl = _templatePolicies[tid];
        address[] storage custom = _instancePolicies[tokenId];
        // C-1 fix: safe selector extraction
        bytes4 selector = action.data.length >= 4
            ? bytes4(action.data[:4])
            : bytes4(0);

        _commitPolicies(tokenId, tpl, action, selector);
        _commitPolicies(tokenId, custom, action, selector);
    }

    // ═══════════════════════════════════════════════════════
    //                       VIEWS
    // ═══════════════════════════════════════════════════════

    /// @notice Get the active policy set for an instance
    function getActivePolicies(
        uint256 instanceId
    ) external view returns (address[] memory) {
        bytes32 tid = instanceTemplateId[instanceId];
        address[] storage tpl = _templatePolicies[tid];
        address[] storage custom = _instancePolicies[instanceId];
        address[] memory result = new address[](tpl.length + custom.length);
        for (uint256 i = 0; i < tpl.length; i++) {
            result[i] = tpl[i];
        }
        for (uint256 i = 0; i < custom.length; i++) {
            result[tpl.length + i] = custom[i];
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

    function _commitPolicies(
        uint256 tokenId,
        address[] storage policies,
        Action calldata action,
        bytes4 selector
    ) internal {
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

    /// @dev Check that msg.sender is contract owner, instance owner, or renter (userOf)
    function _checkRenterOrOwner(uint256 instanceId) internal view {
        if (msg.sender == owner()) return;
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
