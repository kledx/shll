// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyGuardV3} from "../src/PolicyGuardV3.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";

/**
 * @title SetupAndListV15
 * @notice All-in-one post-deploy setup: wire contracts, create policy,
 *         set action rules + groups, mint template agent, and create listing.
 *
 * Usage:
 *   forge script script/SetupAndListV15.s.sol --rpc-url $RPC_URL --broadcast --gas-price 5000000000 -vvv
 *
 * Required env vars (from .env):
 *   PRIVATE_KEY, POLICY_GUARD_V3, AGENT_NFA, LISTING_MANAGER
 *   ROUTER_ADDRESS, USDT_ADDRESS, WBNB_ADDRESS
 */
contract SetupAndListV15 is Script {
    // Policy constants
    uint32 constant POLICY_ID = 1;
    uint16 constant VERSION = 1;
    uint32 constant TOKEN_GROUP_ID = 100;
    uint32 constant DEX_GROUP_ID = 200;

    // Loaded addresses (set in run, used in helpers)
    PolicyGuardV3 guard;
    AgentNFA nfa;
    ListingManager listing;
    address routerAddr;
    address usdtAddr;
    address wbnbAddr;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        guard = PolicyGuardV3(vm.envAddress("POLICY_GUARD_V3"));
        nfa = AgentNFA(vm.envAddress("AGENT_NFA"));
        listing = ListingManager(vm.envAddress("LISTING_MANAGER"));
        routerAddr = vm.envAddress("ROUTER_ADDRESS");
        usdtAddr = vm.envAddress("USDT_ADDRESS");
        wbnbAddr = vm.envAddress("WBNB_ADDRESS");

        vm.startBroadcast(deployerKey);

        _wireContracts();
        _createPolicy();
        _setActionRules();
        _setGroups();
        uint256 tokenId = _mintTemplateAgent(deployer);
        _createListing(tokenId);

        vm.stopBroadcast();

        console.log("");
        console.log("========== V1.5 SETUP COMPLETE ==========");
        console.log("PolicyGuardV3  :", address(guard));
        console.log("AgentNFA       :", address(nfa));
        console.log("ListingManager :", address(listing));
        console.log("Template Agent :", tokenId);
        console.log("Price/Day      : 0.005 BNB");
        console.log("==========================================");
    }

    function _wireContracts() internal {
        nfa.setListingManager(address(listing));
        guard.setAllowedCaller(address(nfa));
        guard.setMinter(address(listing));
        listing.setInstanceConfig(address(guard));
        console.log("Contracts wired");
    }

    function _createPolicy() internal {
        uint32[] memory tokenGroups = new uint32[](1);
        tokenGroups[0] = TOKEN_GROUP_ID;
        uint32[] memory dexGroups = new uint32[](1);
        dexGroups[0] = DEX_GROUP_ID;

        PolicyGuardV3.ParamSchema memory schema = PolicyGuardV3.ParamSchema({
            maxSlippageBps: 1000,
            maxTradeLimit: 100 ether,
            maxDailyLimit: 200 ether,
            allowedTokenGroups: tokenGroups,
            allowedDexGroups: dexGroups,
            receiverMustBeVault: true,
            forbidInfiniteApprove: true,
            allowExplorerMode: true,
            explorerMaxTradeLimit: 10 ether,
            explorerMaxDailyLimit: 25 ether,
            allowParamsUpdate: true
        });
        guard.createPolicy(POLICY_ID, VERSION, schema, 7);
        console.log("Policy created (id=1, v=1, modules=7)");
    }

    function _setActionRules() internal {
        guard.setActionRule(
            POLICY_ID,
            VERSION,
            routerAddr,
            PolicyKeys.SWAP_EXACT_TOKENS,
            5
        );
        guard.setActionRule(
            POLICY_ID,
            VERSION,
            routerAddr,
            PolicyKeys.SWAP_EXACT_ETH,
            5
        );
        guard.setActionRule(
            POLICY_ID,
            VERSION,
            usdtAddr,
            PolicyKeys.APPROVE,
            2
        );
        guard.setActionRule(
            POLICY_ID,
            VERSION,
            wbnbAddr,
            PolicyKeys.APPROVE,
            2
        );
        console.log("Action rules set");
    }

    function _setGroups() internal {
        guard.setGroupMember(TOKEN_GROUP_ID, usdtAddr, true);
        guard.setGroupMember(TOKEN_GROUP_ID, wbnbAddr, true);
        guard.setGroupMember(DEX_GROUP_ID, routerAddr, true);
        console.log("Groups set (USDT, WBNB, Router)");
    }

    function _mintTemplateAgent(address owner) internal returns (uint256) {
        IBAP578.AgentMetadata memory metadata = IBAP578.AgentMetadata({
            persona: '{"name":"SHLL Swap Agent","role":"Trader","description":"Policy-guarded DEX swap agent on BSC Testnet"}',
            experience: "Autonomous DEX trader with PolicyGuardV3 firewall",
            voiceHash: "",
            animationURI: "",
            vaultURI: "swap-v1",
            vaultHash: bytes32(uint256(1))
        });

        uint256 tokenId = nfa.mintAgent(
            owner,
            bytes32(uint256(POLICY_ID)),
            bytes32(0), // agentType (V3.0)
            "https://shll.run/api/metadata/0",
            metadata
        );
        console.log("Minted template agent tokenId:", tokenId);
        return tokenId;
    }

    function _createListing(uint256 tokenId) internal {
        nfa.registerTemplate(tokenId, bytes32(uint256(1)), "swap-v1");
        console.log("Registered as template");

        nfa.approve(address(listing), tokenId);

        bytes32 listingId = listing.createTemplateListing(
            address(nfa),
            tokenId,
            uint96(0.005 ether),
            1
        );
        console.log("Created template listing:");
        console.logBytes32(listingId);
    }
}
