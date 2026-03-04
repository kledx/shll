// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {
    SpendingLimitPolicyV2
} from "../../src/policies/SpendingLimitPolicyV2.sol";
import {ICommittable} from "../../src/interfaces/ICommittable.sol";
import {
    IInstanceInitializable
} from "../../src/interfaces/IInstanceInitializable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract SpendingLimitPolicyV2Test is Test {
    SpendingLimitPolicyV2 public policy;
    MockGuardV2 public mockGuard;

    address constant NFA = address(0xBBBB);
    address constant CALLER = address(0xCCCC);
    address constant RENTER = address(0x7777);
    address constant OWNER = address(0x1);

    address constant WBNB = address(0x1B0B);
    address constant USDT = address(0xD5D7);
    address constant CAKE = address(0xCA4E);
    address constant SCAM_TOKEN = address(0xDEAD);

    address constant PANCAKE_V2 = address(0xD99D);
    address constant PANCAKE_V3 = address(0xD93A);

    uint256 constant INSTANCE_ID = 42;
    bytes32 constant TEMPLATE_ID = keccak256("template_1");

    bytes4 constant APPROVE = 0x095ea7b3;
    bytes4 constant TRANSFER = 0xa9059cbb;
    bytes4 constant TRANSFER_FROM = 0x23b872dd;
    bytes4 constant INCREASE_ALLOWANCE = 0x39509351;
    bytes4 constant DECREASE_ALLOWANCE = 0xa457c2d7;
    bytes4 constant PERMIT = 0xd505accf;
    bytes4 constant DAI_PERMIT = 0x8fcbaf0c;

    bytes4 constant SWAP_EXACT_ETH = 0x7ff36ab5;
    bytes4 constant SWAP_EXACT_ETH_FEE = 0xb6f9de95;
    bytes4 constant SWAP_EXACT_TOKENS = 0x38ed1739;
    bytes4 constant EXACT_INPUT_SINGLE = 0x04e45aaf;
    bytes4 constant EXACT_INPUT = 0xb858183f;
    bytes4 constant WBNB_DEPOSIT = 0xd0e30db0;

    function setUp() public {
        vm.prank(OWNER);
        mockGuard = new MockGuardV2();

        vm.mockCall(
            NFA,
            abi.encodeWithSignature("userOf(uint256)", INSTANCE_ID),
            abi.encode(RENTER)
        );

        policy = new SpendingLimitPolicyV2(address(mockGuard), NFA);

        vm.startPrank(OWNER);
        // Template config
        policy.setTemplateCeiling(TEMPLATE_ID, 1 ether, 10 ether, 500);
        policy.setTemplateApproveCeiling(TEMPLATE_ID, 5 ether);
        policy.setApprovedSpender(PANCAKE_V2, true);
        policy.setApprovedSpender(PANCAKE_V3, true);
        policy.setTemplateTokenRestriction(TEMPLATE_ID, true);
        policy.addTemplateToken(TEMPLATE_ID, WBNB);
        policy.addTemplateToken(TEMPLATE_ID, USDT);

        // Register output patterns
        policy.setOutputPattern(
            SWAP_EXACT_ETH,
            SpendingLimitPolicyV2.OutputPattern.V2_PATH
        );
        policy.setOutputPattern(
            SWAP_EXACT_ETH_FEE,
            SpendingLimitPolicyV2.OutputPattern.V2_PATH
        );
        policy.setOutputPattern(
            EXACT_INPUT_SINGLE,
            SpendingLimitPolicyV2.OutputPattern.V3_SINGLE
        );
        policy.setOutputPattern(
            EXACT_INPUT,
            SpendingLimitPolicyV2.OutputPattern.V3_MULTI
        );
        // Register V2 5-param ERC20 swap pattern
        policy.setOutputPattern(
            SWAP_EXACT_TOKENS,
            SpendingLimitPolicyV2.OutputPattern.V2_PATH
        );
        vm.stopPrank();

        vm.prank(address(mockGuard));
        policy.initInstance(INSTANCE_ID, TEMPLATE_ID);
    }

    // ═══════════════════════════════════════════════════════
    //              HARD BLOCKS
    // ═══════════════════════════════════════════════════════

    function test_transfer_blocked() public view {
        bytes memory callData = abi.encodeWithSelector(
            TRANSFER,
            RENTER,
            1 ether
        );
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            USDT,
            TRANSFER,
            callData,
            0
        );
        assertFalse(ok);
    }

    function test_transferFrom_blocked() public view {
        bytes memory callData = abi.encodeWithSelector(
            TRANSFER_FROM,
            address(this),
            RENTER,
            1 ether
        );
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            USDT,
            TRANSFER_FROM,
            callData,
            0
        );
        assertFalse(ok);
    }

    function test_permit_blocked() public view {
        (bool ok, ) = policy.check(INSTANCE_ID, CALLER, USDT, PERMIT, "", 0);
        assertFalse(ok);
    }

    function test_daiPermit_blocked() public view {
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            USDT,
            DAI_PERMIT,
            "",
            0
        );
        assertFalse(ok);
    }

    function test_increaseAllowance_blocked() public view {
        bytes memory callData = abi.encodeWithSelector(
            INCREASE_ALLOWANCE,
            PANCAKE_V2,
            1 ether
        );
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            USDT,
            INCREASE_ALLOWANCE,
            callData,
            0
        );
        assertFalse(ok);
    }

    // ═══════════════════════════════════════════════════════
    //              APPROVE CONTROL
    // ═══════════════════════════════════════════════════════

    function test_approve_approvedSpender_passes() public view {
        bytes memory cd = abi.encodeWithSelector(APPROVE, PANCAKE_V2, 1 ether);
        (bool ok, ) = policy.check(INSTANCE_ID, CALLER, WBNB, APPROVE, cd, 0);
        assertTrue(ok);
    }

    function test_approve_unapprovedSpender_blocked() public view {
        bytes memory cd = abi.encodeWithSelector(
            APPROVE,
            address(0xEE11),
            1 ether
        );
        (bool ok, string memory r) = policy.check(
            INSTANCE_ID,
            CALLER,
            WBNB,
            APPROVE,
            cd,
            0
        );
        assertFalse(ok);
        assertEq(r, "Approve spender not allowed");
    }

    function test_approve_infinite_blocked() public view {
        bytes memory cd = abi.encodeWithSelector(
            APPROVE,
            PANCAKE_V2,
            type(uint256).max
        );
        (bool ok, ) = policy.check(INSTANCE_ID, CALLER, WBNB, APPROVE, cd, 0);
        assertFalse(ok);
    }

    function test_approve_exceedsLimit_blocked() public view {
        bytes memory cd = abi.encodeWithSelector(APPROVE, PANCAKE_V2, 6 ether);
        (bool ok, string memory r) = policy.check(
            INSTANCE_ID,
            CALLER,
            WBNB,
            APPROVE,
            cd,
            0
        );
        assertFalse(ok);
        assertEq(r, "Approve exceeds limit");
    }

    function test_decreaseAllowance_passes() public view {
        bytes memory cd = abi.encodeWithSelector(
            DECREASE_ALLOWANCE,
            PANCAKE_V2,
            1 ether
        );
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            WBNB,
            DECREASE_ALLOWANCE,
            cd,
            0
        );
        assertTrue(ok);
    }

    // ═══════════════════════════════════════════════════════
    //          TOKEN WHITELIST (approve-based)
    // ═══════════════════════════════════════════════════════

    function test_approve_whitelistedToken() public view {
        bytes memory cd = abi.encodeWithSelector(APPROVE, PANCAKE_V2, 1 ether);
        (bool ok, ) = policy.check(INSTANCE_ID, CALLER, WBNB, APPROVE, cd, 0);
        assertTrue(ok);
    }

    function test_approve_nonWhitelistedToken() public view {
        bytes memory cd = abi.encodeWithSelector(APPROVE, PANCAKE_V2, 1 ether);
        (bool ok, string memory r) = policy.check(
            INSTANCE_ID,
            CALLER,
            SCAM_TOKEN,
            APPROVE,
            cd,
            0
        );
        assertFalse(ok);
        assertEq(r, "Token not in whitelist");
    }

    function test_tokenRestriction_off() public {
        vm.prank(RENTER);
        policy.setTokenRestriction(INSTANCE_ID, false);

        bytes memory cd = abi.encodeWithSelector(APPROVE, PANCAKE_V2, 1 ether);
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            SCAM_TOKEN,
            APPROVE,
            cd,
            0
        );
        assertTrue(ok);
    }

    function test_renter_addToken() public {
        vm.prank(RENTER);
        policy.addToken(INSTANCE_ID, CAKE);

        bytes memory cd = abi.encodeWithSelector(APPROVE, PANCAKE_V2, 1 ether);
        (bool ok, ) = policy.check(INSTANCE_ID, CALLER, CAKE, APPROVE, cd, 0);
        assertTrue(ok);
    }

    function test_renter_removeToken_templateFallback() public {
        vm.prank(RENTER);
        policy.removeToken(INSTANCE_ID, WBNB);

        bytes memory cd = abi.encodeWithSelector(APPROVE, PANCAKE_V2, 1 ether);
        (bool ok, ) = policy.check(INSTANCE_ID, CALLER, WBNB, APPROVE, cd, 0);
        assertTrue(ok, "Template fallback should work");
    }

    function test_tokenList_copiedFromTemplate() public view {
        assertEq(policy.getTokenList(INSTANCE_ID).length, 2);
    }

    function test_duplicateToken_reverts() public {
        vm.prank(RENTER);
        vm.expectRevert(SpendingLimitPolicyV2.TokenAlreadyAdded.selector);
        policy.addToken(INSTANCE_ID, WBNB);
    }

    // ═══════════════════════════════════════════════════════
    //         S-1: ERC20 swap daily limit tracking (bug fix)
    // ═══════════════════════════════════════════════════════

    function test_S1_erc20Swap_trackedInDailyLimit() public {
        // Simulate ERC20 swap: swapExactTokensForTokens (value=0, amountIn from calldata)
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WBNB;
        bytes memory cd = abi.encodeWithSelector(
            SWAP_EXACT_TOKENS,
            4 ether, // amountIn
            0, // amountOutMin
            path,
            CALLER,
            block.timestamp + 300
        );
        vm.prank(address(mockGuard));
        policy.onCommit(INSTANCE_ID, PANCAKE_V2, SWAP_EXACT_TOKENS, cd, 0);

        (uint256 spent, ) = policy.dailyTracking(INSTANCE_ID);
        assertEq(spent, 4 ether);
    }

    function test_S1_erc20Swap_exceedsDailyLimit() public {
        // First swap: 8 ether amountIn → tracked
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WBNB;
        bytes memory commitCd = abi.encodeWithSelector(
            SWAP_EXACT_TOKENS,
            8 ether,
            0,
            path,
            CALLER,
            block.timestamp + 300
        );
        vm.prank(address(mockGuard));
        policy.onCommit(
            INSTANCE_ID,
            PANCAKE_V2,
            SWAP_EXACT_TOKENS,
            commitCd,
            0
        );

        // Second swap: 0.5 ether amountIn → should fail (8 + 0.5 > 1 ether maxPerTx ceiling=1 ETH)
        // Actually this should exceed per-tx: amountIn=0.5 is under 1 ETH maxPerTx
        // But 8 + 0.5 = 8.5 is under 10 ETH daily. Let's make it exceed the daily:
        bytes memory cd = abi.encodeWithSelector(
            SWAP_EXACT_TOKENS,
            0.5 ether, // amountIn — within per-tx (1 ETH)
            0,
            path,
            CALLER,
            block.timestamp + 300
        );
        // 8 + 0.5 = 8.5, under 10 ETH daily → should pass
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V2,
            SWAP_EXACT_TOKENS,
            cd,
            0
        );
        assertTrue(ok);

        // Commit the 0.5 swap, total = 8.5
        vm.prank(address(mockGuard));
        policy.onCommit(INSTANCE_ID, PANCAKE_V2, SWAP_EXACT_TOKENS, cd, 0);

        // Third swap: 0.5 ether amountIn → 8.5 + 0.5 = 9 → still ok
        vm.prank(address(mockGuard));
        policy.onCommit(INSTANCE_ID, PANCAKE_V2, SWAP_EXACT_TOKENS, cd, 0);

        // Now try 1 ether amountIn → 9 + 1 = 10 → at limit
        bytes memory bigCd = abi.encodeWithSelector(
            SWAP_EXACT_TOKENS,
            1 ether,
            0,
            path,
            CALLER,
            block.timestamp + 300
        );
        (bool ok2, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V2,
            SWAP_EXACT_TOKENS,
            bigCd,
            0
        );
        assertTrue(ok2); // 9 + 1 = 10, exactly at limit

        vm.prank(address(mockGuard));
        policy.onCommit(INSTANCE_ID, PANCAKE_V2, SWAP_EXACT_TOKENS, bigCd, 0);

        // Now any swap should exceed daily limit
        (bool ok3, string memory r) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V2,
            SWAP_EXACT_TOKENS,
            cd, // 0.5 ether → 10 + 0.5 > 10
            0
        );
        assertFalse(ok3);
        assertEq(r, "Daily limit reached");
    }

    function test_S1_approve_withinDailyLimit() public {
        bytes memory commitCd = abi.encodeWithSelector(
            APPROVE,
            PANCAKE_V2,
            5 ether
        );
        vm.prank(address(mockGuard));
        policy.onCommit(INSTANCE_ID, address(0), APPROVE, commitCd, 0);

        bytes memory cd = abi.encodeWithSelector(APPROVE, PANCAKE_V2, 4 ether);
        (bool ok, ) = policy.check(INSTANCE_ID, CALLER, WBNB, APPROVE, cd, 0);
        assertTrue(ok);
    }

    // ═══════════════════════════════════════════════════════
    //       S-2: Output token whitelist (registry-based)
    // ═══════════════════════════════════════════════════════

    function test_S2_v2_whitelistedOutput() public view {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = USDT;
        bytes memory cd = abi.encodeWithSelector(
            SWAP_EXACT_ETH,
            0,
            path,
            CALLER,
            block.timestamp + 300
        );
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V2,
            SWAP_EXACT_ETH,
            cd,
            0.5 ether
        );
        assertTrue(ok);
    }

    function test_S2_v2_nonWhitelistedOutput() public view {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = SCAM_TOKEN;
        bytes memory cd = abi.encodeWithSelector(
            SWAP_EXACT_ETH,
            0,
            path,
            CALLER,
            block.timestamp + 300
        );
        (bool ok, string memory r) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V2,
            SWAP_EXACT_ETH,
            cd,
            0.5 ether
        );
        assertFalse(ok);
        assertEq(r, "Output token not in whitelist");
    }

    function test_S2_v3_single_whitelistedOutput() public view {
        bytes memory cd = abi.encodeWithSelector(
            EXACT_INPUT_SINGLE,
            WBNB,
            USDT,
            uint24(500),
            CALLER,
            uint256(0.5 ether),
            uint256(0),
            uint160(0)
        );
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V3,
            EXACT_INPUT_SINGLE,
            cd,
            0.5 ether
        );
        assertTrue(ok);
    }

    function test_S2_v3_single_nonWhitelistedOutput() public view {
        bytes memory cd = abi.encodeWithSelector(
            EXACT_INPUT_SINGLE,
            WBNB,
            SCAM_TOKEN,
            uint24(500),
            CALLER,
            uint256(0.5 ether),
            uint256(0),
            uint160(0)
        );
        (bool ok, string memory r) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V3,
            EXACT_INPUT_SINGLE,
            cd,
            0.5 ether
        );
        assertFalse(ok);
        assertEq(r, "Output token not in whitelist");
    }

    function test_S2_wbnbDeposit_allowed() public view {
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            WBNB,
            WBNB_DEPOSIT,
            "",
            0.5 ether
        );
        assertTrue(ok);
    }

    function test_S2_unknownSelector_passThrough() public view {
        bytes4 unknown = 0x12345678;
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V2,
            unknown,
            "",
            0.5 ether
        );
        assertTrue(ok);
    }

    function test_S2_restrictionOff_noCheck() public {
        vm.prank(RENTER);
        policy.setTokenRestriction(INSTANCE_ID, false);

        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = SCAM_TOKEN;
        bytes memory cd = abi.encodeWithSelector(
            SWAP_EXACT_ETH,
            0,
            path,
            CALLER,
            block.timestamp + 300
        );
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V2,
            SWAP_EXACT_ETH,
            cd,
            0.5 ether
        );
        assertTrue(ok);
    }

    // ═══════════════════════════════════════════════════════
    //       Registry management
    // ═══════════════════════════════════════════════════════

    function test_registry_setAndGet() public view {
        (
            bytes4[] memory sels,
            SpendingLimitPolicyV2.OutputPattern[] memory pats
        ) = policy.getRegisteredSelectors();
        assertEq(sels.length, 5);
        assertEq(
            uint8(pats[0]),
            uint8(SpendingLimitPolicyV2.OutputPattern.V2_PATH)
        );
    }

    function test_registry_batchSet() public {
        bytes4[] memory newSels = new bytes4[](2);
        newSels[0] = 0xAAAAAAAA;
        newSels[1] = 0xBBBBBBBB;

        vm.prank(OWNER);
        policy.setOutputPatternBatch(
            newSels,
            SpendingLimitPolicyV2.OutputPattern.V2_PATH
        );

        assertEq(
            uint8(policy.selectorOutputPattern(0xAAAAAAAA)),
            uint8(SpendingLimitPolicyV2.OutputPattern.V2_PATH)
        );
        assertEq(
            uint8(policy.selectorOutputPattern(0xBBBBBBBB)),
            uint8(SpendingLimitPolicyV2.OutputPattern.V2_PATH)
        );
    }

    function test_registry_nonOwner_reverts() public {
        vm.prank(RENTER);
        vm.expectRevert("Only owner");
        policy.setOutputPattern(
            0xAAAAAAAA,
            SpendingLimitPolicyV2.OutputPattern.V2_PATH
        );
    }

    // ═══════════════════════════════════════════════════════
    //       S-3: Double init protection
    // ═══════════════════════════════════════════════════════

    function test_S3_doubleInit_reverts() public {
        vm.prank(address(mockGuard));
        vm.expectRevert(SpendingLimitPolicyV2.AlreadyInitialized.selector);
        policy.initInstance(INSTANCE_ID, TEMPLATE_ID);
    }

    // ═══════════════════════════════════════════════════════
    //              SPENDING LIMITS
    // ═══════════════════════════════════════════════════════

    function test_valueWithinLimit() public view {
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V2,
            SWAP_EXACT_ETH,
            "",
            0.5 ether
        );
        assertTrue(ok);
    }

    function test_valueExceedsPerTx() public view {
        (bool ok, string memory r) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V2,
            SWAP_EXACT_ETH,
            "",
            2 ether
        );
        assertFalse(ok);
        assertEq(r, "Exceeds per-tx limit");
    }

    function test_dailyLimit_tracked() public {
        vm.prank(address(mockGuard));
        policy.onCommit(INSTANCE_ID, address(0), SWAP_EXACT_ETH, "", 0.8 ether);

        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V2,
            SWAP_EXACT_ETH,
            "",
            0.8 ether
        );
        assertTrue(ok);
    }

    function test_dailyLimit_exceeded() public {
        vm.prank(address(mockGuard));
        policy.onCommit(INSTANCE_ID, address(0), SWAP_EXACT_ETH, "", 9.5 ether);

        (bool ok, string memory r) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V2,
            SWAP_EXACT_ETH,
            "",
            1 ether
        );
        assertFalse(ok);
        assertEq(r, "Daily limit reached");
    }

    function test_zeroValue_passes() public view {
        (bool ok, ) = policy.check(
            INSTANCE_ID,
            CALLER,
            PANCAKE_V2,
            EXACT_INPUT_SINGLE,
            "",
            0
        );
        assertTrue(ok);
    }

    // ═══════════════════════════════════════════════════════
    //              RENTER: setLimits
    // ═══════════════════════════════════════════════════════

    function test_setLimits_withinCeiling() public {
        vm.prank(RENTER);
        policy.setLimits(INSTANCE_ID, 0.5 ether, 5 ether, 300);

        (uint256 ptx, uint256 pd, uint256 sl) = policy.instanceLimits(
            INSTANCE_ID
        );
        assertEq(ptx, 0.5 ether);
        assertEq(pd, 5 ether);
        assertEq(sl, 300);
    }

    function test_setLimits_aboveCeiling() public {
        vm.prank(RENTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitPolicyV2.ExceedsCeiling.selector,
                "maxPerTx"
            )
        );
        policy.setLimits(INSTANCE_ID, 2 ether, 5 ether, 300);
    }

    // ═══════════════════════════════════════════════════════
    //              initInstance defaults
    // ═══════════════════════════════════════════════════════

    function test_initCopiesLimits() public view {
        (uint256 ptx, uint256 pd, ) = policy.instanceLimits(INSTANCE_ID);
        assertEq(ptx, 1 ether);
        assertEq(pd, 10 ether);
    }

    function test_initCopiesApproveLimit() public view {
        assertEq(policy.instanceApproveLimit(INSTANCE_ID), 5 ether);
    }

    function test_initCopiesTokenRestriction() public view {
        assertTrue(policy.tokenRestrictionEnabled(INSTANCE_ID));
    }

    // ═══════════════════════════════════════════════════════
    //              ACCESS CONTROL
    // ═══════════════════════════════════════════════════════

    function test_stranger_cannotSetLimits() public {
        vm.prank(address(0xFA));
        vm.expectRevert(SpendingLimitPolicyV2.NotRenterOrOwner.selector);
        policy.setLimits(INSTANCE_ID, 0.5 ether, 5 ether, 300);
    }

    function test_stranger_cannotSetTokenRestriction() public {
        vm.prank(address(0xFA));
        vm.expectRevert(SpendingLimitPolicyV2.NotRenterOrOwner.selector);
        policy.setTokenRestriction(INSTANCE_ID, false);
    }

    function test_stranger_cannotAddToken() public {
        vm.prank(address(0xFA));
        vm.expectRevert(SpendingLimitPolicyV2.NotRenterOrOwner.selector);
        policy.addToken(INSTANCE_ID, CAKE);
    }

    function test_onlyGuard_canCommit() public {
        vm.prank(RENTER);
        vm.expectRevert(SpendingLimitPolicyV2.OnlyGuard.selector);
        policy.onCommit(INSTANCE_ID, address(0), SWAP_EXACT_ETH, "", 1 ether);
    }

    function test_onlyGuard_canInit() public {
        vm.prank(RENTER);
        vm.expectRevert(SpendingLimitPolicyV2.OnlyGuard.selector);
        policy.initInstance(99, TEMPLATE_ID);
    }

    // ═══════════════════════════════════════════════════════
    //              METADATA
    // ═══════════════════════════════════════════════════════

    function test_policyType() public view {
        assertEq(policy.policyType(), keccak256("spending_limit"));
    }

    function test_renterConfigurable() public view {
        assertTrue(policy.renterConfigurable());
    }

    function test_supportsICommittable() public view {
        assertTrue(policy.supportsInterface(type(ICommittable).interfaceId));
    }

    function test_supportsIInstanceInitializable() public view {
        assertTrue(
            policy.supportsInterface(type(IInstanceInitializable).interfaceId)
        );
    }

    // ═══════════════════════════════════════════════════════
    //              ONCOMMIT tracking
    // ═══════════════════════════════════════════════════════

    function test_onCommit_zero_skips() public {
        vm.prank(address(mockGuard));
        policy.onCommit(INSTANCE_ID, address(0), bytes4(0x12345678), "", 0);
        (uint256 spent, ) = policy.dailyTracking(INSTANCE_ID);
        assertEq(spent, 0);
    }

    function test_onCommit_tracks() public {
        vm.prank(address(mockGuard));
        policy.onCommit(INSTANCE_ID, address(0), SWAP_EXACT_ETH, "", 0.5 ether);
        (uint256 spent, ) = policy.dailyTracking(INSTANCE_ID);
        assertEq(spent, 0.5 ether);
    }

    function test_onCommit_accumulates() public {
        vm.startPrank(address(mockGuard));
        policy.onCommit(INSTANCE_ID, address(0), SWAP_EXACT_ETH, "", 0.3 ether);
        policy.onCommit(INSTANCE_ID, address(0), SWAP_EXACT_ETH, "", 0.7 ether);
        vm.stopPrank();
        (uint256 spent, ) = policy.dailyTracking(INSTANCE_ID);
        assertEq(spent, 1 ether);
    }

    function test_onCommit_resetsOnNewDay() public {
        vm.prank(address(mockGuard));
        policy.onCommit(INSTANCE_ID, address(0), SWAP_EXACT_ETH, "", 5 ether);

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(mockGuard));
        policy.onCommit(INSTANCE_ID, address(0), SWAP_EXACT_ETH, "", 0.1 ether);

        (uint256 spent, ) = policy.dailyTracking(INSTANCE_ID);
        assertEq(spent, 0.1 ether);
    }
}

contract MockGuardV2 is Ownable {
    constructor() {}
}
