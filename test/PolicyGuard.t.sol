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
        guard.setTargetAllowed(WBNB, true);
        guard.setTargetAllowed(V_USDT, true);

        guard.setSelectorAllowed(ROUTER, PolicyKeys.SWAP_EXACT_TOKENS, true);
        guard.setSelectorAllowed(USDT, PolicyKeys.APPROVE, true);
        guard.setSelectorAllowed(WBNB, PolicyKeys.APPROVE, true);
        guard.setSelectorAllowed(V_USDT, PolicyKeys.REPAY_BORROW_BEHALF, true);

        guard.setTokenAllowed(USDT, true);
        guard.setTokenAllowed(WBNB, true);
        guard.setSpenderAllowed(USDT, ROUTER, true);
        guard.setSpenderAllowed(WBNB, ROUTER, true);

        // Set limits
        guard.setLimit(PolicyKeys.MAX_DEADLINE_WINDOW, 1200);
        guard.setLimit(PolicyKeys.MAX_PATH_LENGTH, 3);
        guard.setLimit(PolicyKeys.MAX_SWAP_AMOUNT_IN, 1000 ether);
        guard.setLimit(PolicyKeys.MAX_APPROVE_AMOUNT, 500 ether);
        guard.setLimit(PolicyKeys.MAX_REPAY_AMOUNT, 500 ether);

        // Set router for slippage checks
        guard.setRouter(ROUTER);
    }

    // ═══════════════════════════════════════════════════════════
    //                 SWAP TESTS
    // ═══════════════════════════════════════════════════════════

    function test_swap_valid() public {
        // Mock getAmountsOut to return a reasonable quote
        _mockGetAmountsOut(100 ether, 95 ether);

        Action memory action = _buildSwapAction(
            100 ether,
            93 ether,
            ACCOUNT,
            block.timestamp + 600
        );
        (bool ok, ) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertTrue(ok, "Valid swap should pass");
    }

    function test_swap_recipientNotAccount() public {
        // CRITICAL: swap output to renter's address instead of account
        _mockGetAmountsOut(100 ether, 95 ether);
        Action memory action = _buildSwapAction(
            100 ether,
            90 ether,
            RENTER,
            block.timestamp + 600
        );
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok, "Swap to non-account should fail");
        assertEq(reason, "Swap recipient must be AgentAccount");
    }

    function test_swap_deadlineTooLong() public {
        _mockGetAmountsOut(100 ether, 95 ether);
        Action memory action = _buildSwapAction(
            100 ether,
            90 ether,
            ACCOUNT,
            block.timestamp + 9999
        );
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Deadline too far in the future");
    }

    function test_swap_pathTooLong() public {
        address[] memory path = new address[](4);
        path[0] = USDT;
        path[1] = WBNB;
        path[2] = USDT;
        path[3] = WBNB;
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            100 ether,
            90 ether,
            path,
            ACCOUNT,
            block.timestamp + 600
        );
        Action memory action = Action(ROUTER, 0, data);
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Swap path too long");
    }

    function test_swap_tokenNotAllowed() public {
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = address(0xDEAD); // not in allowlist
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            100 ether,
            90 ether,
            path,
            ACCOUNT,
            block.timestamp + 600
        );
        Action memory action = Action(ROUTER, 0, data);
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Token in path not allowed");
    }

    function test_swap_amountExceedsLimit() public {
        _mockGetAmountsOut(2000 ether, 1900 ether);
        Action memory action = _buildSwapAction(
            2000 ether,
            1800 ether,
            ACCOUNT,
            block.timestamp + 600
        );
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Swap amount exceeds limit");
    }

    // ═══════════════════════════════════════════════════════════
    //                 SLIPPAGE TESTS
    // ═══════════════════════════════════════════════════════════

    function test_swap_amountOutMinZero() public {
        // amountOutMin == 0 should always be rejected
        _mockGetAmountsOut(100 ether, 95 ether);
        Action memory action = _buildSwapAction(
            100 ether,
            0,
            ACCOUNT,
            block.timestamp + 600
        );
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "amountOutMin is zero");
    }

    function test_swap_slippageWithinLimit() public {
        // Quote: 100 USDT -> 95 WBNB
        // amountOutMin: 93 WBNB
        // Slippage: (95-93)/95 = 2.1% < 3% limit => PASS
        _mockGetAmountsOut(100 ether, 95 ether);
        Action memory action = _buildSwapAction(
            100 ether,
            93 ether,
            ACCOUNT,
            block.timestamp + 600
        );
        (bool ok, ) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertTrue(ok, "Slippage within limit should pass");
    }

    function test_swap_slippageExceedsLimit() public {
        // Quote: 100 USDT -> 100 WBNB
        // amountOutMin: 90 WBNB
        // Slippage: (100-90)/100 = 10% > 3% limit => FAIL
        _mockGetAmountsOut(100 ether, 100 ether);
        Action memory action = _buildSwapAction(
            100 ether,
            90 ether,
            ACCOUNT,
            block.timestamp + 600
        );
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Slippage exceeds max bps");
    }

    function test_swap_noSlippageCheckWhenBpsZero() public {
        // Set maxSlippageBps to 0 — should skip quote comparison but still require non-zero amountOutMin
        guard.setLimit(PolicyKeys.MAX_SLIPPAGE_BPS, 0);
        // No mock needed since it won't call getAmountsOut
        Action memory action = _buildSwapAction(
            100 ether,
            1,
            ACCOUNT,
            block.timestamp + 600
        );
        (bool ok, ) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertTrue(ok, "Should pass when slippage check is disabled");
    }

    function test_swap_quoteFailureRejected() public {
        // Mock router to revert on getAmountsOut
        vm.mockCallRevert(
            ROUTER,
            abi.encodeWithSelector(bytes4(0xd06ca61f)),
            "PAIR_NOT_FOUND"
        );
        Action memory action = _buildSwapAction(
            100 ether,
            95 ether,
            ACCOUNT,
            block.timestamp + 600
        );
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Quote unavailable");
    }

    function test_swap_slippageAtExactBoundary() public {
        // Quote: 100 USDT -> 100 WBNB
        // maxSlippageBps: 300 (3%)
        // amountOutMin: 97 WBNB (exactly 3%) => should PASS
        // Check: 97 * 10000 = 970000 >= 100 * (10000 - 300) = 970000 => PASS
        _mockGetAmountsOut(100 ether, 100 ether);
        Action memory action = _buildSwapAction(
            100 ether,
            97 ether,
            ACCOUNT,
            block.timestamp + 600
        );
        (bool ok, ) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertTrue(ok, "Exact boundary slippage should pass");
    }

    function test_swap_noRouterSetSkipsQuote() public {
        // Clear router — slippage check should still require non-zero amountOutMin
        // but skip the on-chain quote comparison
        guard.setRouter(address(0));
        Action memory action = _buildSwapAction(
            100 ether,
            1,
            ACCOUNT,
            block.timestamp + 600
        );
        (bool ok, ) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertTrue(ok, "Should pass when router is not set");
    }

    // ═══════════════════════════════════════════════════════════
    //                 APPROVE TESTS
    // ═══════════════════════════════════════════════════════════

    function test_approve_valid() public view {
        Action memory action = _buildApproveAction(USDT, ROUTER, 100 ether);
        (bool ok, ) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertTrue(ok, "Valid approve should pass");
    }

    function test_approve_wbnb_valid() public view {
        Action memory action = _buildApproveAction(WBNB, ROUTER, 100 ether);
        (bool ok, ) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertTrue(ok, "Valid WBNB approve should pass");
    }

    function test_approve_infiniteNotAllowed() public view {
        Action memory action = _buildApproveAction(
            USDT,
            ROUTER,
            type(uint256).max
        );
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Infinite approval not allowed");
    }

    function test_approve_spenderNotAllowed() public view {
        Action memory action = _buildApproveAction(USDT, EVIL, 100 ether);
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Spender not allowed for this token");
    }

    function test_approve_amountExceedsLimit() public view {
        Action memory action = _buildApproveAction(USDT, ROUTER, 600 ether);
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Approve amount exceeds limit");
    }

    // ═══════════════════════════════════════════════════════════
    //                 REPAY TESTS
    // ═══════════════════════════════════════════════════════════

    function test_repay_valid() public {
        // Mock userOf to return RENTER
        vm.mockCall(
            NFA,
            abi.encodeWithSignature("userOf(uint256)", TOKEN_ID),
            abi.encode(RENTER)
        );
        Action memory action = _buildRepayAction(V_USDT, RENTER, 100 ether);
        (bool ok, ) = guard.validate(NFA, TOKEN_ID, ACCOUNT, RENTER, action);
        assertTrue(ok, "Valid repay should pass");
    }

    function test_repay_borrowerNotRenter() public {
        vm.mockCall(
            NFA,
            abi.encodeWithSignature("userOf(uint256)", TOKEN_ID),
            abi.encode(RENTER)
        );
        // Try to repay for someone else
        Action memory action = _buildRepayAction(V_USDT, EVIL, 100 ether);
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Borrower must be current renter");
    }

    function test_repay_amountExceedsLimit() public {
        vm.mockCall(
            NFA,
            abi.encodeWithSignature("userOf(uint256)", TOKEN_ID),
            abi.encode(RENTER)
        );
        Action memory action = _buildRepayAction(V_USDT, RENTER, 600 ether);
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Repay amount exceeds limit");
    }

    // ═══════════════════════════════════════════════════════════
    //                 GENERAL TESTS
    // ═══════════════════════════════════════════════════════════

    function test_targetNotAllowed() public {
        _mockGetAmountsOut(100 ether, 95 ether);
        Action memory action = _buildSwapAction(
            100 ether,
            90 ether,
            ACCOUNT,
            block.timestamp + 600
        );
        action.target = EVIL;
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Target not allowed");
    }

    function test_selectorNotAllowed() public view {
        // Use swap selector on USDT target (where only approve is allowed)
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            uint256(0)
        );
        Action memory action = Action(USDT, 0, data);
        (bool ok, string memory reason) = guard.validate(
            NFA,
            TOKEN_ID,
            ACCOUNT,
            RENTER,
            action
        );
        assertFalse(ok);
        assertEq(reason, "Selector not allowed");
    }

    function test_pausedReverts() public {
        guard.pause();
        _mockGetAmountsOut(100 ether, 95 ether);
        Action memory action = _buildSwapAction(
            100 ether,
            90 ether,
            ACCOUNT,
            block.timestamp + 600
        );
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

    function test_onlyOwnerCanSetRouter() public {
        vm.prank(RENTER);
        vm.expectRevert();
        guard.setRouter(EVIL);
    }

    function test_setRouter() public {
        address newRouter = address(0xAAAA);
        guard.setRouter(newRouter);
        assertEq(guard.router(), newRouter);
    }

    // ═══════════════════════════════════════════════════════════
    //                 HELPERS
    // ═══════════════════════════════════════════════════════════

    function _buildSwapAction(
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) internal pure returns (Action memory) {
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WBNB;
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            amountIn,
            amountOutMin,
            path,
            to,
            deadline
        );
        return Action(ROUTER, 0, data);
    }

    function _buildApproveAction(
        address token,
        address spender,
        uint256 amount
    ) internal pure returns (Action memory) {
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            spender,
            amount
        );
        return Action(token, 0, data);
    }

    function _buildRepayAction(
        address vToken,
        address borrower,
        uint256 amount
    ) internal pure returns (Action memory) {
        bytes memory data = abi.encodeWithSelector(
            PolicyKeys.REPAY_BORROW_BEHALF,
            borrower,
            amount
        );
        return Action(vToken, 0, data);
    }

    /// @dev Mock the router's getAmountsOut for slippage tests
    function _mockGetAmountsOut(
        uint256 amountIn,
        uint256 expectedOut
    ) internal {
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WBNB;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = expectedOut;

        vm.mockCall(
            ROUTER,
            abi.encodeWithSelector(bytes4(0xd06ca61f), amountIn, path),
            abi.encode(amounts)
        );
    }
}
