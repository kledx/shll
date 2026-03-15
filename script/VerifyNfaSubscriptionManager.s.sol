// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IAgentNFAVerify {
    function subscriptionManager() external view returns (address);
}

interface ISubscriptionManagerVerify {
    function getEffectiveStatus(uint256 instanceId) external view returns (uint8);
}

contract VerifyNfaSubscriptionManager is Script {
    address constant NFA = 0x71cE46099E4b2a2434111C009A7E9CFd69747c8E;
    address constant EXPECTED_SUB_MANAGER = 0x66487D5509005825C85EB3AAE06c3Ec443eF7359;
    uint256 constant CHECK_INSTANCE_ID = 29;

    function run() external view {
        address current = IAgentNFAVerify(NFA).subscriptionManager();
        uint8 status = ISubscriptionManagerVerify(EXPECTED_SUB_MANAGER).getEffectiveStatus(CHECK_INSTANCE_ID);

        console.log("NFA:", NFA);
        console.log("Bound subscriptionManager:", current);
        console.log("Expected subscriptionManager:", EXPECTED_SUB_MANAGER);
        console.log("token29 status on expected manager:", uint256(status));

        require(current == EXPECTED_SUB_MANAGER, "NFA still bound to wrong SubscriptionManager");
        require(status == 1, "token29 is not Active on expected SubscriptionManager");
    }
}
