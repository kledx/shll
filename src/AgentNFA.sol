// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {
    ERC721URIStorage
} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";
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
    Ownable,
    Pausable
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

    constructor(address _policyGuard) ERC721("ShellAgent", "SHLL") {
        if (_policyGuard == address(0)) revert Errors.ZeroAddress();
        policyGuard = _policyGuard;
    }

    // ═══════════════════════════════════════════════════════════
    //                    ADMIN
    // ═══════════════════════════════════════════════════════════

    function setListingManager(address _listingManager) external onlyOwner {
        listingManager = _listingManager;
    }

    function setPolicyGuard(address _policyGuard) external onlyOwner {
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
    function mintAgent(
        address to,
        bytes32 policyId,
        string calldata uri,
        IBAP578.AgentMetadata calldata metadata
    ) external onlyOwner returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);

        // Deploy a dedicated AgentAccount for this NFA
        AgentAccount account = new AgentAccount(address(this), tokenId);
        _accountOf[tokenId] = address(account);
        _policyIdOf[tokenId] = policyId;

        // BAP-578: initialize metadata and status
        _metadata[tokenId] = metadata;
        _agentStatus[tokenId] = IBAP578.Status.Active;

        emit AgentMinted(tokenId, to, address(account), policyId);
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
        _operators[tokenId] = operator;
        _operatorExpires[tokenId] = opExpires;
        emit OperatorSet(tokenId, operator, opExpires);
    }

    /// @notice Get current operator (returns address(0) if expired)
    function operatorOf(uint256 tokenId) public view returns (address) {
        if (uint256(_operatorExpires[tokenId]) >= block.timestamp) {
            return _operators[tokenId];
        }
        return address(0);
    }

    // ═══════════════════════════════════════════════════════════
    //                    EXECUTE (CORE)
    // ═══════════════════════════════════════════════════════════

    /// @notice Execute a single action through the Agent (SHLL native interface)
    function execute(
        uint256 tokenId,
        Action calldata action
    ) external payable whenNotPaused returns (bytes memory result) {
        return _executeInternal(tokenId, action);
    }

    /// @notice Execute multiple actions in a batch
    function executeBatch(
        uint256 tokenId,
        Action[] calldata actions
    ) external payable whenNotPaused returns (bytes[] memory results) {
        _checkAgentActive(tokenId);
        address account = _accountOf[tokenId];
        results = new bytes[](actions.length);

        for (uint256 i = 0; i < actions.length; i++) {
            _checkExecutePermission(tokenId, account, actions[i]);

            (bool success, bytes memory out) = IAgentAccount(account)
                .executeCall(
                    actions[i].target,
                    actions[i].value,
                    actions[i].data
                );

            bytes4 selector = _extractSelector(actions[i].data);
            emit Executed(
                tokenId,
                msg.sender,
                account,
                actions[i].target,
                selector,
                success,
                out
            );

            if (!success) revert Errors.ExecutionFailed();
            results[i] = out;
        }

        _lastActionTimestamp[tokenId] = block.timestamp;
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
    ) external override(IBAP578) {
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

    /// @notice Pause a specific agent (owner only)
    function pauseAgent(uint256 tokenId) external override(IBAP578) {
        if (msg.sender != ownerOf(tokenId)) revert Errors.OnlyOwner();
        if (_agentStatus[tokenId] == IBAP578.Status.Terminated)
            revert Errors.AgentTerminated(tokenId);
        _agentStatus[tokenId] = IBAP578.Status.Paused;
        emit StatusChanged(_accountOf[tokenId], IBAP578.Status.Paused);
    }

    /// @notice Unpause a specific agent (owner only)
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
    function setPolicy(uint256 tokenId, bytes32 newPolicyId) external {
        if (msg.sender != ownerOf(tokenId)) revert Errors.OnlyOwner();
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

        _lastActionTimestamp[tokenId] = block.timestamp;
        return out;
    }

    /// @dev Check that the agent is not paused or terminated
    function _checkAgentActive(uint256 tokenId) internal view {
        IBAP578.Status status = _agentStatus[tokenId];
        if (status == IBAP578.Status.Paused) revert Errors.AgentPaused(tokenId);
        if (status == IBAP578.Status.Terminated)
            revert Errors.AgentTerminated(tokenId);
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
    function _checkExecutePermission(
        uint256 tokenId,
        address account,
        Action memory action
    ) internal view {
        address tokenOwner = ownerOf(tokenId);
        address renter = userOf(tokenId);

        if (msg.sender == tokenOwner) {
            // Owner can execute without PolicyGuard check
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

    // ─── ERC721 overrides (OZ v4 requires these) ───
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
