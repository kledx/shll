// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {
    SpendingLimitPolicyV2
} from "../../src/policies/SpendingLimitPolicyV2.sol";
import {PolicyGuardV4 as PolicyGuard} from "../../src/PolicyGuardV4.sol";

// This test runs against a BSC mainnet fork to verify the deployed V2 policy.
// It checks E2E interaction with PancakeSwap Router and real limits.
contract E2EMainnetV2Test is Test {
    SpendingLimitPolicyV2 public policy =
        SpendingLimitPolicyV2(0xd942dEe00d65c8012E39037a7a77Bc50645e5338);
    PolicyGuard public guard =
        PolicyGuard(0x25d17eA0e3Bcb8CA08a2BFE917E817AFc05dbBB3);

    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // PancakeSwap V2 Router

    uint256 testInstanceId = 999999;
    bytes32 testTemplateId = keccak256("test_template");

    function setUp() public {
        vm.createSelectFork("https://bsc-dataseed.binance.org");

        // Impersonate owner to set up the template defaults since we can't test real instances easily without minting
        address owner = guard.owner();
        vm.startPrank(owner);
        policy.setTemplateCeiling(testTemplateId, 1 ether, 10 ether, 500);
        policy.setTemplateApproveCeiling(testTemplateId, 100 ether);
        policy.setTemplateTokenRestriction(testTemplateId, true);
        policy.addTemplateToken(testTemplateId, WBNB);
        policy.addTemplateToken(testTemplateId, USDT);
        vm.stopPrank();

        // Impersonate guard to init instance
        address guardAddr = address(guard);
        vm.prank(guardAddr);
        policy.initInstance(testInstanceId, testTemplateId);
    }

    function test_mainnet_approve_WBNB_router() public {
        // Approve WBNB for router
        bytes memory callData = abi.encodeWithSignature(
            "approve(address,uint256)",
            ROUTER,
            5 ether
        );

        (bool ok, string memory reason) = policy.check(
            testInstanceId,
            address(0),
            WBNB,
            bytes4(0x095ea7b3), // approve
            callData,
            0
        );
        assertTrue(ok, "Should allow approving WBNB to router");
        assertEq(reason, "", "Reason should be empty");
    }

    function test_mainnet_approve_nonWhitelistedToken_blocked() public {
        address randomToken = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56; // BUSD (not added to whitelist)
        bytes memory callData = abi.encodeWithSignature(
            "approve(address,uint256)",
            ROUTER,
            5 ether
        );

        (bool ok, string memory reason) = policy.check(
            testInstanceId,
            address(0),
            randomToken,
            bytes4(0x095ea7b3), // approve
            callData,
            0
        );
        assertFalse(ok, "Should block approving non-whitelisted BUSD");
        assertEq(reason, "Token not in whitelist", "Reason mismatch");
    }

    function test_mainnet_approve_exceedsLimit_blocked() public {
        bytes memory callData = abi.encodeWithSignature(
            "approve(address,uint256)",
            ROUTER,
            101 ether
        );

        (bool ok, string memory reason) = policy.check(
            testInstanceId,
            address(0),
            USDT,
            bytes4(0x095ea7b3), // approve
            callData,
            0
        );
        assertFalse(ok, "Should block approve exceeding 100 ether ceiling");
        assertEq(reason, "Approve exceeds limit", "Reason mismatch");
    }

    function test_mainnet_swap_withinLimits() public {
        // Mock a swap call with 0.5 BNB attached
        bytes memory callData = abi.encodeWithSignature(
            "swapExactETHForTokens(uint256,address[],address,uint256)",
            0,
            new address[](2),
            address(this),
            block.timestamp
        );

        (bool ok, string memory reason) = policy.check(
            testInstanceId,
            address(0),
            ROUTER,
            bytes4(0x7ff36ab5), // swapExactETHForTokens
            callData,
            0.5 ether // value attached
        );
        assertTrue(ok, "Should allow 0.5 BNB swap");
        assertEq(reason, "", "Reason should be empty");
    }

    function test_mainnet_swap_exceedsPerTx_blocked() public {
        bytes memory callData = abi.encodeWithSignature(
            "swapExactETHForTokens(uint256,address[],address,uint256)",
            0,
            new address[](2),
            address(this),
            block.timestamp
        );

        (bool ok, string memory reason) = policy.check(
            testInstanceId,
            address(0),
            ROUTER,
            bytes4(0x7ff36ab5), // swapExactETHForTokens
            callData,
            2 ether // value attached (ceiling is 1 ether per tx)
        );
        assertFalse(ok, "Should block 2 BNB swap (exceeds 1 ether ceiling)");
        assertEq(reason, "Exceeds per-tx limit", "Reason mismatch");
    }
}
