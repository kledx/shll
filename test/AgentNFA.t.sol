// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {PolicyGuard} from "../src/PolicyGuard.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";

/// @title AgentNFA Tests — BAP-578 Metadata & Capability Pack Integration
contract AgentNFATest is Test {
    AgentNFA public nfa;
    PolicyGuard public guard;

    address constant OWNER = address(0x1111);
    address constant USER = address(0x2222);

    bytes32 constant POLICY_ID = keccak256("default_policy");
    string constant TOKEN_URI = "https://shll.run/metadata/1.json";

    // Sample capability pack
    string constant VAULT_URI = "https://shll.run/packs/hotpump_watchlist.json";
    bytes32 constant VAULT_HASH = keccak256("sample_pack_content");

    function setUp() public {
        guard = new PolicyGuard();
        nfa = new AgentNFA(address(guard));
    }

    // ═══════════════════════════════════════════════════════════
    //          MINT WITH VAULT URI/HASH TESTS
    // ═══════════════════════════════════════════════════════════

    /// @dev Test minting with complete BAP-578 metadata including vaultURI and vaultHash
    function test_mintAgentWithVaultURI() public {
        IBAP578.AgentMetadata memory metadata = IBAP578.AgentMetadata({
            persona: '{"role":"trader","style":"aggressive"}',
            experience: "Automated momentum trading specialist",
            voiceHash: "QmVoiceHash123",
            animationURI: "https://shll.run/animations/trader.mp4",
            vaultURI: VAULT_URI,
            vaultHash: VAULT_HASH
        });

        uint256 tokenId = nfa.mintAgent(OWNER, POLICY_ID, TOKEN_URI, metadata);

        assertEq(tokenId, 0, "First token should be ID 0");
        assertEq(nfa.ownerOf(tokenId), OWNER, "Owner should be set correctly");
        assertEq(nfa.tokenURI(tokenId), TOKEN_URI, "Token URI should match");
    }

    /// @dev Test retrieving agent metadata including vaultURI and vaultHash
    function test_getAgentMetadata() public {
        IBAP578.AgentMetadata memory metadata = IBAP578.AgentMetadata({
            persona: '{"role":"trader"}',
            experience: "Test agent",
            voiceHash: "QmVoice",
            animationURI: "https://example.com/anim.mp4",
            vaultURI: VAULT_URI,
            vaultHash: VAULT_HASH
        });

        uint256 tokenId = nfa.mintAgent(OWNER, POLICY_ID, TOKEN_URI, metadata);

        IBAP578.AgentMetadata memory retrieved = nfa.getAgentMetadata(tokenId);

        assertEq(retrieved.persona, metadata.persona, "Persona should match");
        assertEq(retrieved.experience, metadata.experience, "Experience should match");
        assertEq(retrieved.voiceHash, metadata.voiceHash, "VoiceHash should match");
        assertEq(retrieved.animationURI, metadata.animationURI, "AnimationURI should match");
        assertEq(retrieved.vaultURI, metadata.vaultURI, "VaultURI should match");
        assertEq(retrieved.vaultHash, metadata.vaultHash, "VaultHash should match");
    }

    /// @dev Test updating agent metadata (owner only)
    function test_updateAgentMetadata() public {
        IBAP578.AgentMetadata memory metadata = IBAP578.AgentMetadata({
            persona: '{"role":"trader"}',
            experience: "Test agent",
            voiceHash: "QmVoice",
            animationURI: "https://example.com/anim.mp4",
            vaultURI: VAULT_URI,
            vaultHash: VAULT_HASH
        });

        uint256 tokenId = nfa.mintAgent(OWNER, POLICY_ID, TOKEN_URI, metadata);

        // Update vaultURI to new capability pack
        string memory newVaultURI = "https://shll.run/packs/hotpump_v2.json";
        bytes32 newVaultHash = keccak256("new_pack_content");

        IBAP578.AgentMetadata memory updatedMetadata = IBAP578.AgentMetadata({
            persona: '{"role":"trader","style":"conservative"}',
            experience: "Updated agent with new strategy",
            voiceHash: "QmNewVoice",
            animationURI: "https://example.com/anim_v2.mp4",
            vaultURI: newVaultURI,
            vaultHash: newVaultHash
        });

        vm.prank(OWNER);
        nfa.updateAgentMetadata(tokenId, updatedMetadata);

        IBAP578.AgentMetadata memory retrieved = nfa.getAgentMetadata(tokenId);

        assertEq(retrieved.vaultURI, newVaultURI, "VaultURI should be updated");
        assertEq(retrieved.vaultHash, newVaultHash, "VaultHash should be updated");
        assertEq(retrieved.persona, updatedMetadata.persona, "Persona should be updated");
    }

    /// @dev Test that non-owner cannot update metadata
    function test_updateAgentMetadata_onlyOwner() public {
        IBAP578.AgentMetadata memory metadata = IBAP578.AgentMetadata({
            persona: '{"role":"trader"}',
            experience: "Test agent",
            voiceHash: "QmVoice",
            animationURI: "https://example.com/anim.mp4",
            vaultURI: VAULT_URI,
            vaultHash: VAULT_HASH
        });

        uint256 tokenId = nfa.mintAgent(OWNER, POLICY_ID, TOKEN_URI, metadata);

        IBAP578.AgentMetadata memory newMetadata = metadata;
        newMetadata.vaultURI = "https://malicious.com/pack.json";

        vm.prank(USER);
        vm.expectRevert();
        nfa.updateAgentMetadata(tokenId, newMetadata);
    }

    /// @dev Test vaultHash verification scenario
    function test_vaultHashVerification() public {
        // Simulate correct hash
        string memory packContent = '{"name":"HotPump","version":"1.0"}';
        bytes32 correctHash = keccak256(bytes(packContent));

        IBAP578.AgentMetadata memory metadata = IBAP578.AgentMetadata({
            persona: '{"role":"trader"}',
            experience: "Test agent",
            voiceHash: "QmVoice",
            animationURI: "https://example.com/anim.mp4",
            vaultURI: "https://shll.run/packs/test.json",
            vaultHash: correctHash
        });

        uint256 tokenId = nfa.mintAgent(OWNER, POLICY_ID, TOKEN_URI, metadata);

        IBAP578.AgentMetadata memory retrieved = nfa.getAgentMetadata(tokenId);

        // Verify hash matches
        bytes32 computedHash = keccak256(bytes(packContent));
        assertEq(retrieved.vaultHash, computedHash, "VaultHash should match computed hash");
    }

    /// @dev Test empty vaultURI (agent without capability pack)
    function test_emptyVaultURI() public {
        IBAP578.AgentMetadata memory metadata = IBAP578.AgentMetadata({
            persona: '{"role":"basic"}',
            experience: "Manual agent",
            voiceHash: "",
            animationURI: "",
            vaultURI: "",  // No capability pack
            vaultHash: bytes32(0)
        });

        uint256 tokenId = nfa.mintAgent(OWNER, POLICY_ID, TOKEN_URI, metadata);

        IBAP578.AgentMetadata memory retrieved = nfa.getAgentMetadata(tokenId);

        assertEq(retrieved.vaultURI, "", "VaultURI should be empty");
        assertEq(retrieved.vaultHash, bytes32(0), "VaultHash should be zero");
    }

    /// @dev Test getState includes agent metadata context
    function test_getState() public {
        IBAP578.AgentMetadata memory metadata = IBAP578.AgentMetadata({
            persona: '{"role":"trader"}',
            experience: "Test agent",
            voiceHash: "QmVoice",
            animationURI: "https://example.com/anim.mp4",
            vaultURI: VAULT_URI,
            vaultHash: VAULT_HASH
        });

        uint256 tokenId = nfa.mintAgent(OWNER, POLICY_ID, TOKEN_URI, metadata);

        IBAP578.State memory state = nfa.getState(tokenId);

        assertEq(uint256(state.status), uint256(IBAP578.Status.Active), "Status should be Active");
        assertEq(state.owner, OWNER, "Owner should match");
    }

    /// @dev Test multiple agents with different capability packs
    function test_multipleAgentsWithDifferentPacks() public {
        // Agent 1: HotPump pack
        IBAP578.AgentMetadata memory metadata1 = IBAP578.AgentMetadata({
            persona: '{"role":"trader","style":"aggressive"}',
            experience: "Momentum trader",
            voiceHash: "QmVoice1",
            animationURI: "https://shll.run/animations/trader.mp4",
            vaultURI: "https://shll.run/packs/hotpump.json",
            vaultHash: keccak256("hotpump_pack")
        });

        // Agent 2: DCA pack
        IBAP578.AgentMetadata memory metadata2 = IBAP578.AgentMetadata({
            persona: '{"role":"investor","style":"conservative"}',
            experience: "Dollar-cost averaging specialist",
            voiceHash: "QmVoice2",
            animationURI: "https://shll.run/animations/investor.mp4",
            vaultURI: "https://shll.run/packs/dca.json",
            vaultHash: keccak256("dca_pack")
        });

        uint256 tokenId1 = nfa.mintAgent(OWNER, POLICY_ID, TOKEN_URI, metadata1);
        uint256 tokenId2 = nfa.mintAgent(OWNER, POLICY_ID, TOKEN_URI, metadata2);

        IBAP578.AgentMetadata memory retrieved1 = nfa.getAgentMetadata(tokenId1);
        IBAP578.AgentMetadata memory retrieved2 = nfa.getAgentMetadata(tokenId2);

        assertEq(retrieved1.vaultURI, "https://shll.run/packs/hotpump.json");
        assertEq(retrieved2.vaultURI, "https://shll.run/packs/dca.json");
        assertTrue(retrieved1.vaultHash != retrieved2.vaultHash, "Different packs should have different hashes");
    }
}
