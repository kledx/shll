// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ListingManagerV2} from "../src/ListingManagerV2.sol";
import {IAgentNFA} from "../src/interfaces/IAgentNFA.sol";
import {ISubscriptionManager} from "../src/interfaces/ISubscriptionManager.sol";

/// @title UpgradeListingManagerV3 — Deploy ListingManagerV2 with migrateLease + 10-year lease
/// @notice Deploys new ListingManagerV2, wires it, recreates listing, and switches NFA + SubManager.
///
///   forge script script/UpgradeListingManagerV3.s.sol \
///     --account deployer --rpc-url https://bsc-dataseed1.binance.org \
///     --broadcast --gas-price 3000000000 --skip-simulation -vvv
contract UpgradeListingManagerV3 is Script {
    // ── Mainnet addresses ──
    address constant NFA = 0x71cE46099E4b2a2434111C009A7E9CFd69747c8E;
    address constant GUARD = 0x25d17eA0e3Bcb8CA08a2BFE917E817AFc05dbBB3;
    address constant SUB_MANAGER = 0x66487D5509005825C85EB3AAE06c3Ec443eF7359;

    // ── Listing to recreate (meme_trader, FREE 7-day trial) ──
    uint256 constant TEMPLATE_TOKEN_ID = 14;
    uint96 constant PRICE_PER_DAY = 0; // FREE
    uint32 constant MIN_DAYS = 7;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy new ListingManagerV2
        ListingManagerV2 newLM = new ListingManagerV2();
        console.log("[1/6] New ListingManagerV2:", address(newLM));

        // 2. Wire contracts
        newLM.setAgentNFA(NFA);
        newLM.setPolicyGuard(GUARD);
        newLM.setSubscriptionManager(SUB_MANAGER);
        console.log("[2/6] Wired: NFA + Guard + SubManager");

        // 3. Recreate the default listing
        bytes32 listingId = newLM.createTemplateListing(
            NFA,
            TEMPLATE_TOKEN_ID,
            PRICE_PER_DAY,
            MIN_DAYS
        );
        console.log("[3/6] Listing created:", vm.toString(listingId));

        // 4. Switch NFA to use new ListingManager
        (bool ok1,) = NFA.call(
            abi.encodeWithSignature("setListingManager(address)", address(newLM))
        );
        require(ok1, "NFA.setListingManager failed");
        console.log("[4/6] NFA.setListingManager -> new LM");

        // 5. Switch SubscriptionManager to use new ListingManager
        //    Required so migrateLease can call createSubscription for new tokens
        (bool ok2,) = SUB_MANAGER.call(
            abi.encodeWithSignature("setListingManager(address)", address(newLM))
        );
        require(ok2, "SubManager.setListingManager failed");
        console.log("[5/6] SubManager.setListingManager -> new LM");

        vm.stopBroadcast();

        // 5. Summary
        console.log("");
        console.log("========================================================");
        console.log("  UPGRADE COMPLETE");
        console.log("========================================================");
        console.log(string.concat("NEW_LISTING_MANAGER_V2=", vm.toString(address(newLM))));
        console.log(string.concat("LISTING_ID=", vm.toString(listingId)));
        console.log("");
        console.log("New mints now use 10-year ERC-4907 lease.");
        console.log("Existing users can call migrateLease() to get a new instance.");
        console.log("========================================================");
    }
}
