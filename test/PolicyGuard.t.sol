// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PolicyGuard} from "../src/PolicyGuard.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";
import {Action} from "../src/types/Action.sol";

/// @title PolicyGuard Tests — Core security validation
contract PolicyGuardTest is Test {
    PolicyGuard public guard;

    address constant ROUTER = address(0x1111);
    address constant USDT = address(0x2222);
    address constant WBNB = address(0x3333);
    address constant V_USDT = address(0x4444);
    address constant NFA = address(0x5555);
    address constant ACCOUNT = address(0x6666);
    address constant RENTER = address(0x7777);
    address constant EVIL = address(0x9999);

    uint256 constant TOKEN_ID = 1;

    function setUp() public {
        guard = new PolicyGuard();

        // Setup allowlists
        guard.setTargetAllowed(ROUTER, true);
        guard.setTargetAllowed(USDT, true);
        guard.setTargetAllowed(V_USDT, true);

        guard.setSelectorAllowed(ROUTER, PolicyKeys.SWAP_EXACT_TOKENS, true);
        guard.setSelectorAllowed(USDT, PolicyKeys.APPROVE, true);
        guard.setSelectorAllowed(V_USDT, PolicyKeys.REPAY_BORROW_BEHALF, true);

        guard.setTokenAllowed(USDT, true);
        guard.setTokenAllowed(WBNB, true);
        guard.setSpenderAllowed(USDT, ROUTER, true);

        // Set limits
        guard.setLimit(PolicyKeys.MAX_DEADLINE_WINDOW, 1200);
        guard.setLimit(PolicyKeys.MAX_PATH_LENGTH, 3);
        guard.setLimit(PolicyKeys.MAX_SWAP_AMOUNT_IN, 1000 ether);
        guard.setLimit(PolicyKeys.MAX_APPROVE_AMOUNT, 500 ether);
        guard.setLimit(PolicyKeys.MAX_REPAY_AMOUNT, 500 ether);
    }

    // ═══════════════════════════════════════════════════════════
    //                 SWAP TESTS
    // ═══════════════════════════════════════════════════════════

    function test_swap_valid() public view {
        Action memory action = _buildSwapAction(100 ether, 90 ether, ACCOUNT, block.timestamp + 600);
        (bool ok, ) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertTrue(ok, "Valid swap should pass");
    }

    function test_swap_recipientNotAccount() public view {
        // CRITICAL: swap output to renter's address instead of account
        Action memory action = _buildSwapAction(100 ether, 90 ether, RENTER, block.timestamp + 600);
        (bool ok, string memory reason) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertFalse(ok, "Swap to non-account should fail");
        assertEq(reason, "Swap recipient must be AgentAccount");
    }

    function test_swap_deadlineTooLong() public view {
        Action memory action = _buildSwapAction(100 ether, 90 ether, ACCOUNT, block.timestamp + 9999);
        (bool ok, string memory reason) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertFalse(ok);
        assertEq(reason, "Deadline too far in the future");
    }

    function test_swap_pathTooLong() public view {
        address[] memory path = new address[](4);
        path[0] = USDT; path[1] = WBNB; path[2] = USDT; path[3] = WBNB;
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            100 ether, 90 ether, path, ACCOUNT, block.timestamp + 600
        );
        Action memory action = Action(ROUTER, 0, data);
        (bool ok, string memory reason) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertFalse(ok);
        assertEq(reason, "Swap path too long");
    }

    function test_swap_tokenNotAllowed() public view {
        address[] memory path = new address[](2);
        path[0] = USDT; path[1] = address(0xDEAD); // not in allowlist
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            100 ether, 90 ether, path, ACCOUNT, block.timestamp + 600
        );
        Action memory action = Action(ROUTER, 0, data);
        (bool ok, string memory reason) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertFalse(ok);
        assertEq(reason, "Token in path not allowed");
    }

    function test_swap_amountExceedsLimit() public view {
        Action memory action = _buildSwapAction(2000 ether, 1800 ether, ACCOUNT, block.timestamp + 600);
        (bool ok, string memory reason) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertFalse(ok);
        assertEq(reason, "Swap amount exceeds limit");
    }

    // ═══════════════════════════════════════════════════════════
    //                 APPROVE TESTS
    // ═══════════════════════════════════════════════════════════

    function test_approve_valid() public view {
        Action memory action = _buildApproveAction(USDT, ROUTER, 100 ether);
        (bool ok, ) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertTrue(ok, "Valid approve should pass");
    }

    function test_approve_infiniteNotAllowed() public view {
        Action memory action = _buildApproveAction(USDT, ROUTER, type(uint256).max);
        (bool ok, string memory reason) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertFalse(ok);
        assertEq(reason, "Infinite approval not allowed");
    }

    function test_approve_spenderNotAllowed() public view {
        Action memory action = _buildApproveAction(USDT, EVIL, 100 ether);
        (bool ok, string memory reason) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertFalse(ok);
        assertEq(reason, "Spender not allowed for this token");
    }

    function test_approve_amountExceedsLimit() public view {
        Action memory action = _buildApproveAction(USDT, ROUTER, 600 ether);
        (bool ok, string memory reason) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertFalse(ok);
        assertEq(reason, "Approve amount exceeds limit");
    }

    // ═══════════════════════════════════════════════════════════
    //                 REPAY TESTS
    // ═══════════════════════════════════════════════════════════

    function test_repay_valid() public {
        // Mock userOf to return RENTER
        vm.mockCall(NFA, abi.encodeWithSignature("userOf(uint256)", TOKEN_ID), abi.encode(RENTER));
        Action memory action = _buildRepayAction(V_USDT, RENTER, 100 ether);
        (bool ok, ) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertTrue(ok, "Valid repay should pass");
    }

    function test_repay_borrowerNotRenter() public {
        vm.mockCall(NFA, abi.encodeWithSignature("userOf(uint256)", TOKEN_ID), abi.encode(RENTER));
        // Try to repay for someone else
        Action memory action = _buildRepayAction(V_USDT, EVIL, 100 ether);
        (bool ok, string memory reason) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertFalse(ok);
        assertEq(reason, "Borrower must be current renter");
    }

    function test_repay_amountExceedsLimit() public {
        vm.mockCall(NFA, abi.encodeWithSignature("userOf(uint256)", TOKEN_ID), abi.encode(RENTER));
        Action memory action = _buildRepayAction(V_USDT, RENTER, 600 ether);
        (bool ok, string memory reason) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertFalse(ok);
        assertEq(reason, "Repay amount exceeds limit");
    }

    // ═══════════════════════════════════════════════════════════
    //                 GENERAL TESTS
    // ═══════════════════════════════════════════════════════════

    function test_targetNotAllowed() public view {
        Action memory action = _buildSwapAction(100 ether, 90 ether, ACCOUNT, block.timestamp + 600);
        action.target = EVIL;
        (bool ok, string memory reason) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertFalse(ok);
        assertEq(reason, "Target not allowed");
    }

    function test_selectorNotAllowed() public view {
        // Use swap selector on USDT target (where only approve is allowed)
        bytes memory data = abi.encodeWithSelector(PolicyKeys.SWAP_EXACT_TOKENS, uint256(0));
        Action memory action = Action(USDT, 0, data);
        (bool ok, string memory reason) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertFalse(ok);
        assertEq(reason, "Selector not allowed");
    }

    function test_pausedReverts() public {
        guard.pause();
        Action memory action = _buildSwapAction(100 ether, 90 ether, ACCOUNT, block.timestamp + 600);
        vm.expectRevert();
        guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
    }

    // ═══════════════════════════════════════════════════════════
    //                 ADMIN TESTS
    // ═══════════════════════════════════════════════════════════

    function test_onlyOwnerCanSetTarget() public {
        vm.prank(RENTER);
        vm.expectRevert();
        guard.setTargetAllowed(EVIL, true);
    }

    function test_onlyOwnerCanSetLimit() public {
        vm.prank(RENTER);
        vm.expectRevert();
        guard.setLimit(PolicyKeys.MAX_DEADLINE_WINDOW, 9999);
    }

    // ═══════════════════════════════════════════════════════════
    //                 HELPERS
    // ═══════════════════════════════════════════════════════════

    function _buildSwapAction(uint256 amountIn, uint256 amountOutMin, address to, uint256 deadline)
        internal
        pure
        returns (Action memory)
    {
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WBNB;
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            amountIn, amountOutMin, path, to, deadline
        );
        return Action(ROUTER, 0, data);
    }

    function _buildApproveAction(address token, address spender, uint256 amount)
        internal
        pure
        returns (Action memory)
    {
        bytes memory data = abi.encodeWithSelector(PolicyKeys.APPROVE, spender, amount);
        return Action(token, 0, data);
    }

    function _buildRepayAction(address vToken, address borrower, uint256 amount)
        internal
        pure
        returns (Action memory)
    {
        bytes memory data = abi.encodeWithSelector(PolicyKeys.REPAY_BORROW_BEHALF, borrower, amount);
        return Action(vToken, 0, data);
    }
}
