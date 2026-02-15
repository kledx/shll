// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AgentNFA.sol";
import "../src/interfaces/IBAP578.sol";

/// @notice Update capability pack metadata for an existing agent token.
/// @dev Keeps persona/experience/voiceHash/animationURI unchanged, only updates vaultURI/vaultHash.
contract UpdateAgentPack is Script {
    struct UpdateConfig {
        uint256 privateKey;
        address agentNFA;
        uint256 tokenId;
        string vaultURI;
        bytes32 vaultHash;
    }

    function _loadConfig() internal view returns (UpdateConfig memory cfg) {
        cfg.privateKey = vm.envUint("PRIVATE_KEY");
        cfg.agentNFA = vm.envAddress("AGENT_NFA");
        cfg.tokenId = vm.envUint("UPDATE_TOKEN_ID");
        cfg.vaultURI = vm.envString("UPDATE_VAULT_URI");
        cfg.vaultHash = vm.envBytes32("UPDATE_VAULT_HASH");
    }

    function run() external {
        UpdateConfig memory cfg = _loadConfig();
        AgentNFA agentNFA = AgentNFA(cfg.agentNFA);

        IBAP578.AgentMetadata memory current = agentNFA.getAgentMetadata(cfg.tokenId);
        IBAP578.AgentMetadata memory updated = IBAP578.AgentMetadata({
            persona: current.persona,
            experience: current.experience,
            voiceHash: current.voiceHash,
            animationURI: current.animationURI,
            vaultURI: cfg.vaultURI,
            vaultHash: cfg.vaultHash
        });

        vm.startBroadcast(cfg.privateKey);
        agentNFA.updateAgentMetadata(cfg.tokenId, updated);
        vm.stopBroadcast();

        console.log("Updated agent pack metadata:");
        console.log("tokenId:", cfg.tokenId);
        console.log("vaultURI:", cfg.vaultURI);
        console.logBytes32(cfg.vaultHash);
    }
}

