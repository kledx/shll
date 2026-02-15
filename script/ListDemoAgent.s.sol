// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AgentNFA.sol";
import "../src/ListingManager.sol";
import "../src/interfaces/IBAP578.sol";

/// @notice Mint one demo agent, register as template, and create template listing.
/// @dev All params are provided via env vars. See script/demo-agent.env.example.
contract ListDemoAgent is Script {
    struct DemoConfig {
        uint256 privateKey;
        address owner;
        address agentNFA;
        address listingManager;
        bytes32 policyId;
        string tokenURI;
        string persona;
        string experience;
        string voiceHash;
        string animationURI;
        string vaultURI;
        bytes32 vaultHash;
        uint96 pricePerDay;
        uint32 minDays;
    }

    function _loadConfig() internal view returns (DemoConfig memory cfg) {
        uint256 pricePerDayRaw = vm.envUint("DEMO_PRICE_PER_DAY_WEI");
        uint256 minDaysRaw = vm.envUint("DEMO_MIN_DAYS");
        if (pricePerDayRaw > type(uint96).max) revert("pricePerDay too large");
        if (minDaysRaw > type(uint32).max) revert("minDays too large");

        cfg.privateKey = vm.envUint("PRIVATE_KEY");
        cfg.owner = vm.envAddress("DEMO_OWNER");
        cfg.agentNFA = vm.envAddress("AGENT_NFA");
        cfg.listingManager = vm.envAddress("LISTING_MANAGER");
        cfg.policyId = vm.envBytes32("DEMO_POLICY_ID");
        cfg.tokenURI = vm.envString("DEMO_TOKEN_URI");
        cfg.persona = vm.envString("DEMO_PERSONA_JSON");
        cfg.experience = vm.envString("DEMO_EXPERIENCE");
        cfg.voiceHash = vm.envOr("DEMO_VOICE_HASH", string(""));
        cfg.animationURI = vm.envOr("DEMO_ANIMATION_URI", string(""));
        cfg.vaultURI = vm.envString("DEMO_VAULT_URI");
        cfg.vaultHash = vm.envBytes32("DEMO_VAULT_HASH");
        // forge-lint: disable-next-line(unsafe-typecast)
        cfg.pricePerDay = uint96(pricePerDayRaw);
        // forge-lint: disable-next-line(unsafe-typecast)
        cfg.minDays = uint32(minDaysRaw);
    }

    function run() external {
        DemoConfig memory cfg = _loadConfig();
        address deployer = vm.addr(cfg.privateKey);
        AgentNFA agentNFA = AgentNFA(cfg.agentNFA);
        ListingManager listingManager = ListingManager(cfg.listingManager);

        vm.startBroadcast(cfg.privateKey);

        IBAP578.AgentMetadata memory metadata = IBAP578.AgentMetadata({
            persona: cfg.persona,
            experience: cfg.experience,
            voiceHash: cfg.voiceHash,
            animationURI: cfg.animationURI,
            vaultURI: cfg.vaultURI,
            vaultHash: cfg.vaultHash
        });

        uint256 tokenId = agentNFA.mintAgent(
            cfg.owner,
            cfg.policyId,
            cfg.tokenURI,
            metadata
        );
        console.log("Minted demo agent tokenId:", tokenId);
        console.log("Mint owner:", cfg.owner);

        // createListing requires msg.sender to be token owner.
        if (cfg.owner != deployer) {
            revert(
                "DEMO_OWNER must be vm.addr(PRIVATE_KEY) when using this script"
            );
        }

        // Multi-tenant only: register template first, then create template listing.
        agentNFA.registerTemplate(tokenId, cfg.vaultHash, cfg.vaultURI);
        console.log("Registered template tokenId:", tokenId);

        agentNFA.approve(address(listingManager), tokenId);
        bytes32 listingId = listingManager.createTemplateListing(
            address(agentNFA),
            tokenId,
            cfg.pricePerDay,
            cfg.minDays
        );

        console.log("Created listing for tokenId:", tokenId);
        console.log("Listing pricePerDay(wei):", uint256(cfg.pricePerDay));
        console.log("Listing minDays:", uint256(cfg.minDays));
        console.logBytes32(listingId);

        vm.stopBroadcast();
    }
}
