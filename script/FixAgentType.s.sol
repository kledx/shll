// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

/// @title FixAgentType 鈥?Set agentType for existing tokens (requires V3.1 AgentNFA)
/// @dev Usage:
///   forge script script/FixAgentType.s.sol --rpc-url $RPC_URL --broadcast --gas-price 5000000000 -vvv
///
/// Required env vars:
///   PRIVATE_KEY   鈥?contract owner
///   AGENT_NFA     鈥?AgentNFA contract address (must be V3.1+ with setAgentType)
///   FIX_TOKEN_ID  鈥?token ID to fix (e.g. 1)
///   FIX_TYPE      鈥?agent type string (e.g. "llm_trader")

interface IAgentNFAV31 {
    function setAgentType(uint256 tokenId, bytes32 _agentType) external;
    function agentType(uint256 tokenId) external view returns (bytes32);
}

contract FixAgentType is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        IAgentNFAV31 nfa = IAgentNFAV31(vm.envAddress("AGENT_NFA"));
        uint256 tokenId = vm.envUint("FIX_TOKEN_ID");
        string memory typeStr = vm.envString("FIX_TYPE");
        bytes32 typeHash = keccak256(bytes(typeStr));

        console.log("Fixing agentType for token:", tokenId);
        console.log("Type string:", typeStr);
        console.log("Type hash:");
        console.logBytes32(typeHash);

        // Read current value
        bytes32 current = nfa.agentType(tokenId);
        console.log("Current agentType:");
        console.logBytes32(current);

        if (current == typeHash) {
            console.log("Already correct, skipping.");
            return;
        }

        vm.startBroadcast(deployerKey);
        nfa.setAgentType(tokenId, typeHash);
        vm.stopBroadcast();

        // Verify
        bytes32 updated = nfa.agentType(tokenId);
        console.log("Updated agentType:");
        console.logBytes32(updated);
        require(updated == typeHash, "setAgentType failed");
        console.log("SUCCESS: agentType updated");
    }
}


