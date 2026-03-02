// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IProtocolRegistry {
    function emergencyCall(
        address target,
        bytes calldata data
    ) external returns (bytes memory);
}

interface ISpendingLimitV2 {
    function instanceApproveLimit(uint256) external view returns (uint256);
    function templateApproveCeiling(bytes32) external view returns (uint256);
    function instanceTemplate(uint256) external view returns (bytes32);
    function setTemplateApproveCeiling(
        bytes32 templateId,
        uint256 maxApproveAmount
    ) external;
    function setApproveLimit(
        uint256 instanceId,
        uint256 maxApproveAmount
    ) external;
}

contract FixApproveLimit is Script {
    address constant REGISTRY = 0x1A5EA54a3beaf4fba75f73581cf6A945746E6DF1;
    address constant SPENDING_LIMIT =
        0xd942dEe00d65c8012E39037a7a77Bc50645e5338;
    uint256 constant TOKEN_ID = 6;
    // 1e30 = enough for any meme token approve (1 trillion tokens with 18 decimals)
    uint256 constant NEW_LIMIT = 1e30;

    function run() external {
        ISpendingLimitV2 sl = ISpendingLimitV2(SPENDING_LIMIT);
        IProtocolRegistry registry = IProtocolRegistry(REGISTRY);

        // Read the REAL templateId for token 6
        bytes32 tid = sl.instanceTemplate(TOKEN_ID);
        uint256 ceilingBefore = sl.templateApproveCeiling(tid);
        uint256 limitBefore = sl.instanceApproveLimit(TOKEN_ID);

        console.log("Template ID (hex):");
        console.logBytes32(tid);
        console.log("Template Approve Ceiling (before):", ceilingBefore);
        console.log("Instance Approve Limit (before):", limitBefore);

        vm.startBroadcast();

        // Step 1: Set ceiling on the CORRECT templateId
        if (ceilingBefore < NEW_LIMIT) {
            console.log("Setting templateApproveCeiling to:", NEW_LIMIT);
            registry.emergencyCall(
                SPENDING_LIMIT,
                abi.encodeCall(sl.setTemplateApproveCeiling, (tid, NEW_LIMIT))
            );
        }

        // Step 2: Set instance approve limit
        console.log("Setting instanceApproveLimit to:", NEW_LIMIT);
        registry.emergencyCall(
            SPENDING_LIMIT,
            abi.encodeCall(sl.setApproveLimit, (TOKEN_ID, NEW_LIMIT))
        );

        vm.stopBroadcast();

        console.log(
            "Template Approve Ceiling (after):",
            sl.templateApproveCeiling(tid)
        );
        console.log(
            "Instance Approve Limit (after):",
            sl.instanceApproveLimit(TOKEN_ID)
        );
    }
}
