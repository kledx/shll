// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Action} from "../types/Action.sol";
import {IBAP578} from "./IBAP578.sol";

/// @title IAgentNFA — Agent Non-Fungible Asset interface (BAP-578 + ERC-4907)
interface IAgentNFA {
    struct OperatorPermit {
        uint256 tokenId;
        address renter;
        address operator;
        uint64 expires;
        uint256 nonce;
        uint256 deadline;
    }

    // ─── Events ───
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

    // ─── V3.0 Events ───
    event AgentTypeSet(uint256 indexed tokenId, bytes32 agentType);
    event AgentInstancePaused(uint256 indexed tokenId);
    event AgentInstanceUnpaused(uint256 indexed tokenId);

    // ─── Core functions ───
    function mintAgent(
        address to,
        bytes32 policyId,
        bytes32 _agentType,
        string calldata uri,
        IBAP578.AgentMetadata calldata metadata
    ) external returns (uint256 tokenId);

    function execute(
        uint256 tokenId,
        Action calldata action
    ) external returns (bytes memory result);
    function executeBatch(
        uint256 tokenId,
        Action[] calldata actions
    ) external returns (bytes[] memory results);

    // ─── ERC4907 ───
    function setUser(uint256 tokenId, address user, uint64 expires) external;
    function userOf(uint256 tokenId) external view returns (address);
    function userExpires(uint256 tokenId) external view returns (uint256);
    function setOperator(
        uint256 tokenId,
        address operator,
        uint64 opExpires
    ) external;
    function setOperatorWithSig(
        OperatorPermit calldata permit,
        bytes calldata sig
    ) external;
    function clearOperator(uint256 tokenId) external;
    function operatorOf(uint256 tokenId) external view returns (address);
    function operatorExpiresOf(uint256 tokenId) external view returns (uint256);
    function operatorNonceOf(uint256 tokenId) external view returns (uint256);

    // ─── Views ───
    function accountOf(uint256 tokenId) external view returns (address);
    function policyIdOf(uint256 tokenId) external view returns (bytes32);
    function setPolicy(uint256 tokenId, bytes32 newPolicyId) external;
    function agentStatus(
        uint256 tokenId
    ) external view returns (IBAP578.Status);
    function logicAddressOf(uint256 tokenId) external view returns (address);

    // ─── V3.0: Agent Type ───
    function setAgentType(uint256 tokenId, bytes32 _agentType) external;
    function agentType(uint256 tokenId) external view returns (bytes32);

    // ─── V3.0: Circuit Breaker ───
    function pauseAgentInstance(uint256 tokenId) external;
    function unpauseAgentInstance(uint256 tokenId) external;
    function agentPaused(uint256 tokenId) external view returns (bool);

    //  V1.3: Template / Instance
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
    function registerTemplate(uint256 tokenId, bytes32 templateKey) external;
    function mintInstanceFromTemplate(
        address to,
        uint256 templateId,
        uint64 expires,
        bytes calldata initParams
    ) external returns (uint256 instanceId);
    function templateOf(uint256 tokenId) external view returns (uint256);
    function paramsHashOf(uint256 tokenId) external view returns (bytes32);
    function isTemplate(uint256 tokenId) external view returns (bool);
    function isInstance(uint256 tokenId) external view returns (bool);
    function templatePolicyId(uint256 tokenId) external view returns (bytes32);
    function templateKeyOf(uint256 tokenId) external view returns (bytes32);
    function nextTokenId() external view returns (uint256);
}
