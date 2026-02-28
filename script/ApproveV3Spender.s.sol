// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

interface ISpendingLimitPolicyV2 {
    function approvedSpender(address) external view returns (bool);
    function setApprovedSpender(address spender, bool allowed) external;
}

/// @notice Approve PancakeSwap V3 SmartRouter as spender in SpendingLimitPolicyV2.
/// Usage:
///   forge script script/ApproveV3Spender.s.sol \
///     --rpc-url https://bsc-dataseed1.binance.org --account deployer --broadcast -vvv
contract ApproveV3Spender is Script {
    address constant SPENDING_LIMIT_V2 =
        0xd942dEe00d65c8012E39037a7a77Bc50645e5338;
    address constant PANCAKE_V3_SMART_ROUTER =
        0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    function run() external {
        ISpendingLimitPolicyV2 sl = ISpendingLimitPolicyV2(SPENDING_LIMIT_V2);

        // 1. Check current status
        bool before = sl.approvedSpender(PANCAKE_V3_SMART_ROUTER);
        console.log("V3 SmartRouter approved BEFORE:", before);

        if (before) {
            console.log("Already approved, nothing to do.");
            return;
        }

        // 2. Approve
        vm.startBroadcast();
        sl.setApprovedSpender(PANCAKE_V3_SMART_ROUTER, true);
        vm.stopBroadcast();

        // 3. Verify
        bool after_ = sl.approvedSpender(PANCAKE_V3_SMART_ROUTER);
        console.log("V3 SmartRouter approved AFTER:", after_);
    }
}
