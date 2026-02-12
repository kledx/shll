// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyGuard} from "../src/PolicyGuard.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";

/// @title ApplyPolicy — Configure PolicyGuard allowlists and limits from JSON config
/// @dev Usage: forge script script/ApplyPolicy.s.sol --rpc-url $RPC_URL --broadcast
///      Reads config from configs/<network>.json via vm.readFile()
contract ApplyPolicy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address guardAddr = vm.envAddress("POLICY_GUARD");
        string memory configPath = vm.envString("CONFIG_PATH"); // e.g. "configs/bsc.mainnet.json"

        string memory json = vm.readFile(configPath);

        vm.startBroadcast(deployerKey);

        PolicyGuard guard = PolicyGuard(guardAddr);

        // Parse and apply router
        address router = vm.parseJsonAddress(json, ".router.address");
        guard.setTargetAllowed(router, true);
        guard.setSelectorAllowed(router, PolicyKeys.SWAP_EXACT_TOKENS, true);
        guard.setSelectorAllowed(router, PolicyKeys.SWAP_EXACT_ETH, true);
        console.log("Router whitelisted:", router);

        // Parse and apply tokens
        address wbnb = vm.parseJsonAddress(json, ".tokens.WBNB");
        address usdt = vm.parseJsonAddress(json, ".tokens.USDT");
        guard.setTokenAllowed(wbnb, true);
        guard.setTokenAllowed(usdt, true);
        guard.setTargetAllowed(usdt, true);
        guard.setSelectorAllowed(usdt, PolicyKeys.APPROVE, true);
        guard.setSpenderAllowed(usdt, router, true);
        guard.setSpenderAllowed(wbnb, router, true);
        console.log("WBNB whitelisted:", wbnb);
        console.log("USDT whitelisted:", usdt);

        // Parse and apply Venus vToken
        address vUsdt = vm.parseJsonAddress(json, ".venus.vUSDT");
        guard.setTargetAllowed(vUsdt, true);
        guard.setSelectorAllowed(vUsdt, PolicyKeys.REPAY_BORROW_BEHALF, true);
        console.log("vUSDT whitelisted:", vUsdt);

        // Parse and apply limits
        uint256 maxDeadline = vm.parseJsonUint(
            json,
            ".policyDefaults.maxDeadlineWindow"
        );
        uint256 maxPath = vm.parseJsonUint(
            json,
            ".policyDefaults.maxPathLength"
        );
        guard.setLimit(PolicyKeys.MAX_DEADLINE_WINDOW, maxDeadline);
        guard.setLimit(PolicyKeys.MAX_PATH_LENGTH, maxPath);
        console.log("Limits applied");

        vm.stopBroadcast();
    }
}
