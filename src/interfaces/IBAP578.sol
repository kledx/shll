// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBAP578 — Non-Fungible Agent (NFA) Token Standard
/// @dev See https://github.com/bnb-chain/BEPs/blob/master/BAPs/BAP-578.md
interface IBAP578 {
    // ─── Enums ───
    enum Status {
        Active,
        Paused,
        Terminated
    }

    // ─── Structs ───
    struct AgentMetadata {
        string persona; // JSON-encoded character traits, style, tone
        string experience; // Agent's role/purpose summary
        string voiceHash; // Audio profile reference
        string animationURI; // Animation/avatar URI
        string vaultURI; // Extended data storage URI
        bytes32 vaultHash; // Vault content verification hash
    }

    struct State {
        uint256 balance;
        Status status;
        address owner;
        address logicAddress;
        uint256 lastActionTimestamp;
    }

    // ─── Events ───
    event ActionExecuted(address indexed agent, bytes result);
    event LogicUpgraded(
        address indexed agent,
        address oldLogic,
        address newLogic
    );
    event AgentFunded(
        address indexed agent,
        address indexed funder,
        uint256 amount
    );
    event StatusChanged(address indexed agent, Status newStatus);
    event MetadataUpdated(uint256 indexed tokenId, string metadataURI);

    // ─── Core Functions ───
    function executeAction(uint256 tokenId, bytes calldata data) external;
    function setLogicAddress(uint256 tokenId, address newLogic) external;
    function fundAgent(uint256 tokenId) external payable;
    function getState(uint256 tokenId) external view returns (State memory);
    function getAgentMetadata(
        uint256 tokenId
    ) external view returns (AgentMetadata memory);
    function updateAgentMetadata(
        uint256 tokenId,
        AgentMetadata calldata metadata
    ) external;

    // ─── Lifecycle Management ───
    function pauseAgent(uint256 tokenId) external;
    function unpauseAgent(uint256 tokenId) external;
    function terminate(uint256 tokenId) external;
}
