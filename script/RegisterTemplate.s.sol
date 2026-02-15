// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AgentNFA.sol";
import "../src/ListingManager.sol";

/// @title RegisterTemplate — Full flow: register template + cancel old listing + create template listing
/// @dev Usage: forge script script/RegisterTemplate.s.sol --rpc-url $RPC_URL --broadcast -vvv
///      Env: PRIVATE_KEY, AGENT_NFA, LISTING_MANAGER
contract RegisterTemplate is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address agentNfaAddr = vm.envAddress("AGENT_NFA");
        address listingMgrAddr = vm.envAddress("LISTING_MANAGER");

        AgentNFA nfa = AgentNFA(agentNfaAddr);
        ListingManager lm = ListingManager(listingMgrAddr);

        uint256 tokenId = 0;

        // Compute the existing listing ID (same hash logic as ListingManager)
        bytes32 oldListingId = keccak256(
            abi.encodePacked(agentNfaAddr, tokenId)
        );

        vm.startBroadcast(deployerKey);

        // Step 1: Register Agent #0 as template (freezes policyId + packHash)
        // ALREADY DONE: nfa.registerTemplate(tokenId, bytes32(uint256(1)), "swap-v1");
        console.log("Registered Agent #0 as template (SKIP - already done)");

        // Step 2: Cancel the existing classic listing
        lm.cancelListing(oldListingId);
        console.log("Canceled old classic listing");

        // Step 3: Approve ListingManager again (cancel may clear approval)
        nfa.approve(listingMgrAddr, tokenId);
        console.log("Approved ListingManager");

        // Step 4: Create template listing
        bytes32 listingId = lm.createTemplateListing(
            agentNfaAddr,
            tokenId,
            uint96(0.005 ether), // 0.005 BNB per day
            1 // Min 1 day
        );
        console.log("Created template listing:");
        console.logBytes32(listingId);

        vm.stopBroadcast();

        console.log("=== RegisterTemplate Complete ===");
    }
}
