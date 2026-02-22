// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {
    ERC721URIStorage
} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {
    Ownable2Step,
    Ownable
} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";
import {
    EIP712
} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {
    ECDSA
} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {IERC4907} from "./interfaces/IERC4907.sol";
import {IBAP578} from "./interfaces/IBAP578.sol";

import {IPolicyGuard} from "./interfaces/IPolicyGuard.sol";
import {IAgentAccount} from "./interfaces/IAgentAccount.sol";
import {AgentAccount} from "./AgentAccount.sol";
import {Action} from "./types/Action.sol";
import {Errors} from "./libs/Errors.sol";

/// @title AgentNFA — Non-Fungible Agent with BAP-578 identity + ERC-4907 rental
/// @notice Identity layer: mint agents, manage rentals, route execution through PolicyGuard
/// @dev Implements BAP-578 (NFA standard) + ERC-4907 (rental) on top of ERC-721
contract AgentNFA is
    ERC721,
    ERC721URIStorage,
    IERC4907,
    IBAP578,
    Ownable2Step,
    Pausable,
    EIP712
{
    // ─── State ───
    uint256 private _nextTokenId;

    /// @notice tokenId => AgentAccount address
    mapping(uint256 => address) private _accountOf;

    /// @notice tokenId => policy template id
    mapping(uint256 => bytes32) private _policyIdOf;

    /// @notice ERC-4907: tokenId => user (renter)
    mapping(uint256 => address) private _users;

    /// @notice ERC-4907: tokenId => user expiry timestamp
    mapping(uint256 => uint64) private _userExpires;

    /// @notice BAP-578: tokenId => AgentMetadata
    mapping(uint256 => IBAP578.AgentMetadata) private _metadata;

    /// @notice BAP-578: tokenId => agent status (Active/Paused/Terminated)
    mapping(uint256 => IBAP578.Status) private _agentStatus;

    /// @notice BAP-578: tokenId => logic contract address
    mapping(uint256 => address) private _logicAddress;

    /// @notice BAP-578: tokenId => last action execution timestamp
    mapping(uint256 => uint256) private _lastActionTimestamp;

    /// @notice The PolicyGuard contract
    address public policyGuard;

    /// @notice The ListingManager contract (only it can call setUser)
    address public listingManager;

    /// @notice tokenId => authorized operator address
    mapping(uint256 => address) private _operators;

    /// @notice tokenId => operator authorization expiry
    mapping(uint256 => uint64) private _operatorExpires;

    /// @notice tokenId => operator permit nonce (for anti-replay)
    mapping(uint256 => uint256) private _operatorNonces;

    // ─── V1.3: Template -> Instance ───

    /// @notice instanceId => templateId
    mapping(uint256 => uint256) private _templateOf;

    /// @notice instanceId => true if this token is an instance (explicit flag)
    mapping(uint256 => bool) private _isInstance;

    /// @notice templateId => true if registered as template
    mapping(uint256 => bool) private _isTemplate;

    /// @notice templateId => immutable policyId snapshot (frozen at registration)
    mapping(uint256 => bytes32) private _templatePolicyId;

    /// @notice instanceId => keccak256(initParams) for reproducibility
    mapping(uint256 => bytes32) private _paramsHashOf;

    /// @notice templateId => templateKey (frozen at registerTemplate)
    mapping(uint256 => bytes32) public templateKeyOf;

    // ─── V3.0: Agent Type ───

    /// @notice tokenId => agent type identifier
    mapping(uint256 => bytes32) public agentType;

    /// @notice Agent type constants
    /// ╔═══════════════════════════════════════════════════════╗
    /// ║  SYNC REQUIRED: When adding a new type here, also    ║
    /// ║  add it to shll-indexer KNOWN_TYPES array:           ║
    /// ║  → repos/shll-indexer/src/AgentNFA.ts                ║
    /// ╚═══════════════════════════════════════════════════════╝
    bytes32 public constant TYPE_LLM_TRADER = keccak256("llm_trader");

    // ─── V3.1+ Reserved Slots: REMOVED to meet EIP-170 (24KB) ───
    // Re-add in V3.1 upgrade: learningModule, memoryRegistry, vaultPermissionManager

    /// @notice BAP-578 4.7: Circuit Breaker (per-instance pause)
    mapping(uint256 => bool) public agentPaused;

    bytes32 private constant OPERATOR_PERMIT_TYPEHASH =
        keccak256(
            "OperatorPermit(uint256 tokenId,address renter,address operator,uint64 expires,uint256 nonce,uint256 deadline)"
        );

    struct OperatorPermit {
        uint256 tokenId;
        address renter;
        address operator;
        uint64 expires;
        uint256 nonce;
        uint256 deadline;
    }

    // ─── Events (from IAgentNFA) ───
    event AgentMinted(
        uint256 indexed tokenId,
        address indexed owner,
        address account,
        bytes32 policyId
    );
    event LeaseSet(
        uint256 indexed tokenId,
        address indexed user,
        uint64 expires
    );
    event PolicyUpdated(
        uint256 indexed tokenId,
        bytes32 oldPolicyId,
        bytes32 newPolicyId
    );
    event Executed(
        uint256 indexed tokenId,
        address indexed caller,
        address indexed account,
        address target,
        bytes4 selector,
        bool success,
        bytes result
    );
    event OperatorSet(
        uint256 indexed tokenId,
        address indexed operator,
        uint64 expires
    );
    event OperatorCleared(uint256 indexed tokenId, address indexed caller);

    // ─── V1.3: Template / Instance events ───
    event TemplateListed(
        uint256 indexed templateId,
        address indexed owner,
        bytes32 templateKey,
        bytes32 policyId
    );
    event InstanceMinted(
        uint256 indexed templateId,
        uint256 indexed instanceId,
        address indexed renter,
        address vault,
        uint64 expires,
        bytes32 paramsHash
    );

    // ─── V3.0 Events ───
    event AgentTypeSet(uint256 indexed tokenId, bytes32 agentType);
    event AgentInstancePaused(uint256 indexed tokenId);
    event AgentInstanceUnpaused(uint256 indexed tokenId);

    constructor(
        address _policyGuard
    ) ERC721("ShellAgent", "SHLL") EIP712("SHLL AgentNFA", "1") {
        if (_policyGuard == address(0)) revert Errors.ZeroAddress();
        policyGuard = _policyGuard;
    }

    // ═══════════════════════════════════════════════════════════
    //                    ADMIN
    // ═══════════════════════════════════════════════════════════

    function setListingManager(address _listingManager) external onlyOwner {
        if (_listingManager == address(0)) revert Errors.ZeroAddress();
        listingManager = _listingManager;
    }

    function setPolicyGuard(address _policyGuard) external onlyOwner {
        if (_policyGuard == address(0)) revert Errors.ZeroAddress();
        policyGuard = _policyGuard;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════
    //                    MINT
    // ═══════════════════════════════════════════════════════════

    /// @notice Mint a new Agent NFA with BAP-578 metadata and a dedicated AgentAccount
    /// @dev V3.0: Added _agentType parameter for agent categorization
    function mintAgent(
        address to,
        bytes32 policyId,
        bytes32 _agentType,
        string calldata uri,
        IBAP578.AgentMetadata calldata metadata
    ) external onlyOwner returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _mint(to, tokenId);
        _setTokenURI(tokenId, uri);

        // Deploy a dedicated AgentAccount for this NFA
        AgentAccount account = new AgentAccount(address(this), tokenId);
        _accountOf[tokenId] = address(account);
        _policyIdOf[tokenId] = policyId;

        // V3.0: Set agent type
        agentType[tokenId] = _agentType;

        // BAP-578: initialize metadata and status
        _metadata[tokenId] = metadata;
        _agentStatus[tokenId] = IBAP578.Status.Active;

        emit AgentMinted(tokenId, to, address(account), policyId);
        emit AgentTypeSet(tokenId, _agentType);
    }

    /// @notice Admin-only: set or update the agent type for an existing token
    /// @dev Used to fix instances minted before V3.1 or to correct misconfigurations
    /// @param tokenId The agent tokenId to update
    /// @param _agentType The new agent type hash (e.g. TYPE_LLM_TRADER)
    function setAgentType(
        uint256 tokenId,
        bytes32 _agentType
    ) external onlyOwner {
        _requireMinted(tokenId);
        agentType[tokenId] = _agentType;
        emit AgentTypeSet(tokenId, _agentType);
    }

    // ═══════════════════════════════════════════════════════════
    //                    V1.3: TEMPLATE REGISTRATION
    // ═══════════════════════════════════════════════════════════

    /// @notice Register an existing Agent as a Template (owner only)
    /// @dev Freezes the current policyId — immutable after registration
    /// @param tokenId The agent tokenId to register as template
    /// @param templateKey Identifier for PolicyGuard template policy lookup
    function registerTemplate(uint256 tokenId, bytes32 templateKey) external {
        _requireMinted(tokenId);
        if (msg.sender != ownerOf(tokenId)) revert Errors.OnlyOwner();
        if (templateKey == bytes32(0)) revert Errors.InvalidInitParams();
        if (_isTemplate[tokenId]) revert Errors.AlreadyTemplate(tokenId);
        // An instance cannot be registered as a template
        if (_isInstance[tokenId]) revert Errors.NotTemplate(tokenId);
        // M-4: Template must have agentType set for runner/indexer compatibility
        if (agentType[tokenId] == bytes32(0)) revert Errors.InvalidInitParams();

        _isTemplate[tokenId] = true;
        // Freeze current policyId — cannot be changed after this point
        _templatePolicyId[tokenId] = _policyIdOf[tokenId];
        // Store templateKey for PolicyGuardV4 binding lookup
        templateKeyOf[tokenId] = templateKey;

        emit TemplateListed(
            tokenId,
            msg.sender,
            templateKey,
            _policyIdOf[tokenId]
        );
    }

    // ═══════════════════════════════════════════════════════════
    //                    V1.3: RENT-TO-MINT (INSTANCE CREATION)
    // ═══════════════════════════════════════════════════════════

    /// @notice Mint a new Instance from a Template — only callable by ListingManager
    /// @dev Creates a new tokenId with its own AgentAccount vault.
    ///      The instance inherits the template's frozen policyId.
    ///      Instance is minted directly to the renter (owner = renter).
    /// @param to The renter address who will own the instance
    /// @param templateId The template tokenId to instantiate from
    /// @param expires The lease expiry timestamp
    /// @param initParams Arbitrary instance initialization parameters
    /// @return instanceId The newly minted instance tokenId
    function mintInstanceFromTemplate(
        address to,
        uint256 templateId,
        uint64 expires,
        bytes calldata initParams
    ) external returns (uint256 instanceId) {
        // SECURITY: only ListingManager can call this
        if (msg.sender != listingManager) revert Errors.OnlyListingManager();
        // SECURITY: template must be registered
        if (!_isTemplate[templateId]) revert Errors.NotTemplate(templateId);
        // SECURITY: renter address must be valid
        if (to == address(0)) revert Errors.ZeroAddress();

        // Mint new tokenId
        instanceId = _nextTokenId++;
        _safeMint(to, instanceId);

        // Deploy a dedicated AgentAccount for this instance
        AgentAccount account = new AgentAccount(address(this), instanceId);
        _accountOf[instanceId] = address(account);

        // Inherit template's frozen policyId (immutable reference)
        _policyIdOf[instanceId] = _templatePolicyId[templateId];

        // Record template relationship
        _templateOf[instanceId] = templateId;
        _isInstance[instanceId] = true;

        // Store params hash for reproducibility
        bytes32 paramsHash = keccak256(initParams);
        _paramsHashOf[instanceId] = paramsHash;

        // Set renter as user with expiry (ERC-4907 semantics)
        _users[instanceId] = to;
        _userExpires[instanceId] = expires;

        // Initialize as Active
        _agentStatus[instanceId] = IBAP578.Status.Active;

        // V3.1: Inherit agent type from template
        bytes32 inheritedType = agentType[templateId];
        if (inheritedType != bytes32(0)) {
            agentType[instanceId] = inheritedType;
        }

        emit InstanceMinted(
            templateId,
            instanceId,
            to,
            address(account),
            expires,
            paramsHash
        );
        emit AgentMinted(
            instanceId,
            to,
            address(account),
            _policyIdOf[instanceId]
        );
        // V3.1: Emit type event for indexer
        if (inheritedType != bytes32(0)) {
            emit AgentTypeSet(instanceId, inheritedType);
        }
        emit UpdateUser(instanceId, to, expires);
        emit LeaseSet(instanceId, to, expires);
    }

    // ═══════════════════════════════════════════════════════════
    //                    ERC-4907 (RENTAL)
    // ═══════════════════════════════════════════════════════════

    /// @notice Set the user (renter) for an NFA — only callable by ListingManager
    function setUser(
        uint256 tokenId,
        address user,
        uint64 expires
    ) external override(IERC4907) {
        // Only ListingManager or owner can set user
        if (msg.sender != listingManager && msg.sender != owner()) {
            revert Errors.OnlyListingManager();
        }
        _requireMinted(tokenId);
        _users[tokenId] = user;
        _userExpires[tokenId] = expires;
        emit UpdateUser(tokenId, user, expires);
        emit LeaseSet(tokenId, user, expires);
    }

    /// @notice Get current user (returns address(0) if expired)
    function userOf(
        uint256 tokenId
    ) public view override(IERC4907) returns (address) {
        if (uint256(_userExpires[tokenId]) >= block.timestamp) {
            return _users[tokenId];
        }
        return address(0);
    }

    /// @notice Get user expiry timestamp
    function userExpires(
        uint256 tokenId
    ) public view override(IERC4907) returns (uint256) {
        return _userExpires[tokenId];
    }

    // ═══════════════════════════════════════════════════════════
    //                    OPERATOR (RUNTIME)
    // ═══════════════════════════════════════════════════════════

    /// @notice Renter authorizes an operator to execute on their behalf
    /// @param tokenId The agent token ID
    /// @param operator The operator address (e.g. runner wallet)
    /// @param opExpires Operator expiry (must not exceed rent expiry)
    function setOperator(
        uint256 tokenId,
        address operator,
        uint64 opExpires
    ) external {
        address renter = userOf(tokenId);
        if (msg.sender != renter) revert Errors.Unauthorized();
        if (opExpires > _userExpires[tokenId])
            revert Errors.OperatorExceedsLease();
        _setOperator(tokenId, operator, opExpires);
    }

    /// @notice Set operator via EIP-712 renter signature (runner pays gas)
    function setOperatorWithSig(
        OperatorPermit calldata permit,
        bytes calldata sig
    ) external {
        if (block.timestamp > permit.deadline) revert Errors.SignatureExpired();
        if (msg.sender != permit.operator)
            revert Errors.InvalidOperatorSubmitter();

        address renter = userOf(permit.tokenId);
        if (renter == address(0) || renter != permit.renter)
            revert Errors.Unauthorized();
        if (permit.expires > _userExpires[permit.tokenId])
            revert Errors.OperatorExceedsLease();

        uint256 expectedNonce = _operatorNonces[permit.tokenId];
        if (permit.nonce != expectedNonce) revert Errors.InvalidNonce();

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    OPERATOR_PERMIT_TYPEHASH,
                    permit.tokenId,
                    permit.renter,
                    permit.operator,
                    permit.expires,
                    permit.nonce,
                    permit.deadline
                )
            )
        );
        address signer = ECDSA.recover(digest, sig);
        if (signer != permit.renter) revert Errors.InvalidSigner();

        _operatorNonces[permit.tokenId] = expectedNonce + 1;
        _setOperator(permit.tokenId, permit.operator, permit.expires);
    }

    /// @notice Clear the current operator authorization
    function clearOperator(uint256 tokenId) external {
        address tokenOwner = ownerOf(tokenId);
        address renter = userOf(tokenId);
        if (msg.sender != tokenOwner && msg.sender != renter)
            revert Errors.Unauthorized();
        _setOperator(tokenId, address(0), 0);
        emit OperatorCleared(tokenId, msg.sender);
    }

    /// @notice Get current operator (returns address(0) if expired)
    function operatorOf(uint256 tokenId) public view returns (address) {
        if (uint256(_operatorExpires[tokenId]) >= block.timestamp) {
            return _operators[tokenId];
        }
        return address(0);
    }

    function operatorExpiresOf(
        uint256 tokenId
    ) external view returns (uint256) {
        return _operatorExpires[tokenId];
    }

    function operatorNonceOf(uint256 tokenId) external view returns (uint256) {
        return _operatorNonces[tokenId];
    }

    // ═══════════════════════════════════════════════════════════
    //                    EXECUTE (CORE)
    // ═══════════════════════════════════════════════════════════

    /// @notice Execute a single action through the Agent (SHLL native interface)
    /// @dev H-1 fix: removed payable — action.value comes from AgentAccount balance, not msg.value
    function execute(
        uint256 tokenId,
        Action calldata action
    ) external whenNotPaused returns (bytes memory result) {
        return _executeInternal(tokenId, action);
    }

    /// @notice Execute multiple actions in a batch
    /// @dev H-1 fix: removed payable — action.value comes from AgentAccount balance, not msg.value
    function executeBatch(
        uint256 tokenId,
        Action[] calldata actions
    ) external whenNotPaused returns (bytes[] memory results) {
        results = new bytes[](actions.length);
        for (uint256 i = 0; i < actions.length; i++) {
            results[i] = _executeInternal(tokenId, actions[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                    BAP-578: EXECUTE ACTION
    // ═══════════════════════════════════════════════════════════

    /// @notice BAP-578 standard execution entry point
    /// @param tokenId The agent token ID
    /// @param data ABI-encoded Action struct (target, value, calldata)
    function executeAction(
        uint256 tokenId,
        bytes calldata data
    ) external override(IBAP578) whenNotPaused {
        Action memory action = abi.decode(data, (Action));
        _executeInternal(tokenId, action);

        address account = _accountOf[tokenId];
        emit ActionExecuted(account, data);
    }

    // ═══════════════════════════════════════════════════════════
    //                    BAP-578: FUND AGENT
    // ═══════════════════════════════════════════════════════════

    /// @notice Fund an agent by forwarding BNB to its AgentAccount
    function fundAgent(uint256 tokenId) external payable override(IBAP578) {
        _requireMinted(tokenId);
        address account = _accountOf[tokenId];
        (bool success, ) = account.call{value: msg.value}("");
        if (!success) revert Errors.ExecutionFailed();
        emit AgentFunded(account, msg.sender, msg.value);
    }

    // ═══════════════════════════════════════════════════════════
    //                    BAP-578: LIFECYCLE
    // ═══════════════════════════════════════════════════════════

    /// @notice Pause a specific agent (owner only) — BAP-578 lifecycle
    function pauseAgent(uint256 tokenId) external override(IBAP578) {
        if (msg.sender != ownerOf(tokenId)) revert Errors.OnlyOwner();
        if (_agentStatus[tokenId] == IBAP578.Status.Terminated)
            revert Errors.AgentTerminated(tokenId);
        _agentStatus[tokenId] = IBAP578.Status.Paused;
        emit StatusChanged(_accountOf[tokenId], IBAP578.Status.Paused);
    }

    /// @notice Unpause a specific agent (owner only) — BAP-578 lifecycle
    function unpauseAgent(uint256 tokenId) external override(IBAP578) {
        if (msg.sender != ownerOf(tokenId)) revert Errors.OnlyOwner();
        if (_agentStatus[tokenId] == IBAP578.Status.Terminated)
            revert Errors.AgentTerminated(tokenId);
        _agentStatus[tokenId] = IBAP578.Status.Active;
        emit StatusChanged(_accountOf[tokenId], IBAP578.Status.Active);
    }

    /// @notice Permanently terminate an agent (owner only, irreversible)
    function terminate(uint256 tokenId) external override(IBAP578) {
        if (msg.sender != ownerOf(tokenId)) revert Errors.OnlyOwner();
        _agentStatus[tokenId] = IBAP578.Status.Terminated;
        emit StatusChanged(_accountOf[tokenId], IBAP578.Status.Terminated);
    }

    // ═══════════════════════════════════════════════════════════
    //       V3.0: Per-Instance Pause (Circuit Breaker)
    // ═══════════════════════════════════════════════════════════

    /// @notice Pause a specific agent instance (owner or renter)
    function pauseAgentInstance(uint256 tokenId) external {
        _requireOwnerOrRenter(tokenId);
        agentPaused[tokenId] = true;
        emit AgentInstancePaused(tokenId);
    }

    /// @notice Unpause a specific agent instance (owner or renter)
    function unpauseAgentInstance(uint256 tokenId) external {
        _requireOwnerOrRenter(tokenId);
        agentPaused[tokenId] = false;
        emit AgentInstanceUnpaused(tokenId);
    }

    // ═══════════════════════════════════════════════════════════
    //                    BAP-578: LOGIC ADDRESS
    // ═══════════════════════════════════════════════════════════

    /// @notice Set the logic contract address for an agent (owner only)
    function setLogicAddress(
        uint256 tokenId,
        address newLogic
    ) external override(IBAP578) {
        if (msg.sender != ownerOf(tokenId)) revert Errors.OnlyOwner();
        // Logic address must be zero (clear) or a contract
        if (newLogic != address(0) && newLogic.code.length == 0) {
            revert Errors.InvalidLogicAddress();
        }
        address oldLogic = _logicAddress[tokenId];
        _logicAddress[tokenId] = newLogic;
        emit LogicUpgraded(_accountOf[tokenId], oldLogic, newLogic);
    }

    // ═══════════════════════════════════════════════════════════
    //                    BAP-578: METADATA
    // ═══════════════════════════════════════════════════════════

    /// @notice Get the BAP-578 metadata for an agent
    function getAgentMetadata(
        uint256 tokenId
    ) external view override(IBAP578) returns (IBAP578.AgentMetadata memory) {
        _requireMinted(tokenId);
        return _metadata[tokenId];
    }

    /// @notice Update the BAP-578 metadata for an agent (owner only)
    function updateAgentMetadata(
        uint256 tokenId,
        IBAP578.AgentMetadata calldata metadata
    ) external override(IBAP578) {
        if (msg.sender != ownerOf(tokenId)) revert Errors.OnlyOwner();
        _metadata[tokenId] = metadata;
        emit MetadataUpdated(tokenId, tokenURI(tokenId));
    }

    /// @notice Update the Token URI for an agent (Owner only)
    /// @dev Useful if metadata API domain changes
    function setTokenURI(
        uint256 tokenId,
        string calldata uri
    ) external onlyOwner {
        _setTokenURI(tokenId, uri);
        emit MetadataUpdated(tokenId, uri);
    }

    /// @notice Get the BAP-578 state for an agent
    function getState(
        uint256 tokenId
    ) external view override(IBAP578) returns (IBAP578.State memory) {
        _requireMinted(tokenId);
        address account = _accountOf[tokenId];
        return
            IBAP578.State({
                balance: account.balance,
                status: _agentStatus[tokenId],
                owner: ownerOf(tokenId),
                logicAddress: _logicAddress[tokenId],
                lastActionTimestamp: _lastActionTimestamp[tokenId]
            });
    }

    // ═══════════════════════════════════════════════════════════
    //                    POLICY
    // ═══════════════════════════════════════════════════════════

    /// @notice Update the policy template for an NFA (owner only)
    /// @dev SECURITY: Templates cannot change policy after registerTemplate() is called
    function setPolicy(uint256 tokenId, bytes32 newPolicyId) external {
        if (msg.sender != ownerOf(tokenId)) revert Errors.OnlyOwner();
        // SECURITY: prevent template owner from changing policy after registration
        // This protects all instances that inherited this template's policy
        if (_isTemplate[tokenId]) revert Errors.AlreadyTemplate(tokenId);
        bytes32 oldPolicyId = _policyIdOf[tokenId];
        _policyIdOf[tokenId] = newPolicyId;
        emit PolicyUpdated(tokenId, oldPolicyId, newPolicyId);
    }

    // ═══════════════════════════════════════════════════════════
    //                    VIEWS
    // ═══════════════════════════════════════════════════════════

    function accountOf(uint256 tokenId) external view returns (address) {
        return _accountOf[tokenId];
    }

    function policyIdOf(uint256 tokenId) external view returns (bytes32) {
        return _policyIdOf[tokenId];
    }

    function agentStatus(
        uint256 tokenId
    ) external view returns (IBAP578.Status) {
        return _agentStatus[tokenId];
    }

    function logicAddressOf(uint256 tokenId) external view returns (address) {
        return _logicAddress[tokenId];
    }

    // ─── V1.3: Template / Instance Views ───

    /// @notice Get the next tokenId (useful for off-chain indexing)
    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }

    /// @notice Check if a tokenId is registered as a template
    function isTemplate(uint256 tokenId) external view returns (bool) {
        return _isTemplate[tokenId];
    }

    /// @notice Check if a tokenId is a rented instance (minted from a template)
    function isInstance(uint256 tokenId) external view returns (bool) {
        return _isInstance[tokenId];
    }

    /// @notice Get the template policyId (frozen at registration)
    function templatePolicyId(uint256 tokenId) external view returns (bytes32) {
        return _templatePolicyId[tokenId];
    }

    /// @notice Get the templateId for an instance (0 = not an instance)
    function templateOf(uint256 tokenId) external view returns (uint256) {
        return _templateOf[tokenId];
    }

    /// @notice Get the init params hash for an instance
    function paramsHashOf(uint256 tokenId) external view returns (bytes32) {
        return _paramsHashOf[tokenId];
    }

    // ═══════════════════════════════════════════════════════════
    //          V3.1+ Reserved API: REMOVED (EIP-170 limit)
    //          Re-add: enableLearning, setMemoryRegistry,
    //                  setVaultPermissionManager
    // ═══════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════
    //                    INTERNAL
    // ═══════════════════════════════════════════════════════════

    /// @dev Shared internal execution logic for execute() and executeAction()
    function _executeInternal(
        uint256 tokenId,
        Action memory action
    ) internal returns (bytes memory result) {
        _checkAgentActive(tokenId);
        address account = _accountOf[tokenId];
        _checkExecutePermission(tokenId, account, action);

        (bool success, bytes memory out) = IAgentAccount(account).executeCall(
            action.target,
            action.value,
            action.data
        );

        bytes4 selector = _extractSelector(action.data);
        emit Executed(
            tokenId,
            msg.sender,
            account,
            action.target,
            selector,
            success,
            out
        );

        if (!success) revert Errors.ExecutionFailed();

        // V1.4 + M-NEW-2 fix: Post-execution state update via typed call
        if (policyGuard != address(0)) {
            try IPolicyGuard(policyGuard).commit(tokenId, action) {} catch {}
        }

        _lastActionTimestamp[tokenId] = block.timestamp;
        return out;
    }

    /// @dev Check that the agent is not paused or terminated
    /// @dev V3.0: Also checks per-instance pause (Circuit Breaker)
    function _checkAgentActive(uint256 tokenId) internal view {
        // V3.0: Per-instance pause (Circuit Breaker)
        if (agentPaused[tokenId]) revert Errors.AgentPaused(tokenId);
        // BAP-578 lifecycle status
        IBAP578.Status status = _agentStatus[tokenId];
        if (status == IBAP578.Status.Paused) revert Errors.AgentPaused(tokenId);
        if (status == IBAP578.Status.Terminated)
            revert Errors.AgentTerminated(tokenId);
    }

    /// @dev Require msg.sender to be owner or renter of the token
    function _requireOwnerOrRenter(uint256 tokenId) internal view {
        address tokenOwner = ownerOf(tokenId);
        address renter = userOf(tokenId);
        if (msg.sender != tokenOwner && msg.sender != renter) {
            revert Errors.Unauthorized();
        }
    }

    /// @dev Extract the 4-byte selector from calldata bytes (works with both memory and calldata)
    function _extractSelector(
        bytes memory data
    ) internal pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(data, 32))
        }
    }

    /// @dev Check execute permission and run PolicyGuard for renters
    /// @dev DESIGN NOTE: For non-Instance tokens (templates & standalone agents),
    ///      the owner bypasses PolicyGuard validation entirely. This is BY DESIGN —
    ///      owners have full control over their own vault without policy constraints.
    ///      Only Instance owners (Rent-to-Mint) and renters/operators are subject
    ///      to PolicyGuard validation.
    function _checkExecutePermission(
        uint256 tokenId,
        address account,
        Action memory action
    ) internal view {
        address tokenOwner = ownerOf(tokenId);
        address renter = userOf(tokenId);

        if (msg.sender == tokenOwner) {
            // Instance owners (Rent-to-Mint) MUST pass PolicyGuard
            if (_isInstance[tokenId]) {
                (bool ok, string memory reason) = IPolicyGuard(policyGuard)
                    .validate(
                        address(this),
                        tokenId,
                        account,
                        msg.sender,
                        action
                    );
                if (!ok) revert Errors.PolicyViolation(reason);
            }
            return;
        }

        if (msg.sender == renter || msg.sender == operatorOf(tokenId)) {
            // Renter or operator must be within lease period
            if (renter == address(0)) revert Errors.LeaseExpired();

            // Renter/Operator MUST pass PolicyGuard validation
            (bool ok, string memory reason) = IPolicyGuard(policyGuard)
                .validate(address(this), tokenId, account, msg.sender, action);
            if (!ok) revert Errors.PolicyViolation(reason);
            return;
        }

        revert Errors.Unauthorized();
    }

    function _setOperator(
        uint256 tokenId,
        address operator,
        uint64 opExpires
    ) internal {
        _operators[tokenId] = operator;
        _operatorExpires[tokenId] = opExpires;
        emit OperatorSet(tokenId, operator, opExpires);
    }

    // ─── ERC721 overrides (OZ v4 requires these) ───

    /// @dev ERC-4907 compliant: clear rental state + operator on transfer/burn.
    ///      Prevents stale renter/operator from retaining vault access after ownership change.
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 firstTokenId,
        uint256 batchSize
    ) internal override {
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);

        // Skip on mint (from == 0) and self-transfer
        if (from != address(0) && from != to) {
            // Clear ERC-4907 renter
            if (_users[firstTokenId] != address(0)) {
                delete _users[firstTokenId];
                delete _userExpires[firstTokenId];
                emit UpdateUser(firstTokenId, address(0), 0);
            }
            // Clear operator authorization
            if (_operators[firstTokenId] != address(0)) {
                delete _operators[firstTokenId];
                delete _operatorExpires[firstTokenId];
                emit OperatorCleared(firstTokenId, from);
                emit OperatorSet(firstTokenId, address(0), 0);
            }
        }
    }

    function _burn(
        uint256 tokenId
    ) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return
            interfaceId == type(IBAP578).interfaceId ||
            interfaceId == type(IERC4907).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
