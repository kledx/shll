// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {AgentAccount} from "../src/AgentAccount.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";
import {Action} from "../src/types/Action.sol";
import {Errors} from "../src/libs/Errors.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";
import {DexWhitelistPolicy} from "../src/policies/DexWhitelistPolicy.sol";
import {ReceiverGuardPolicy} from "../src/policies/ReceiverGuardPolicy.sol";
import {SpendingLimitPolicy} from "../src/policies/SpendingLimitPolicy.sol";

contract MockTarget {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

contract OperatorPermitTest is Test {
    AgentNFA internal nfa;
    PolicyGuardV4 internal guard;
    MockTarget internal target;
    DexWhitelistPolicy internal dexWL;
    ReceiverGuardPolicy internal receiverGuard;
    SpendingLimitPolicy internal spendingLimit;

    uint256 internal tokenId;
    address internal account;
    uint256 internal templateId;
    address internal fakeListingManager = address(0xAE11);
    uint64 internal leaseExpiry;

    uint256 internal renterPk = 0xA11CE;
    uint256 internal otherPk = 0xB0B;
    address internal renter;
    address internal operator = address(0xCAFE);

    bytes32 internal constant OPERATOR_PERMIT_TYPEHASH =
        keccak256(
            "OperatorPermit(uint256 tokenId,address renter,address operator,uint64 expires,uint256 nonce,uint256 deadline)"
        );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes32 internal constant TEMPLATE_KEY = bytes32("operator-template");

    function setUp() public {
        renter = vm.addr(renterPk);

        guard = new PolicyGuardV4();
        nfa = new AgentNFA(address(guard));
        target = new MockTarget();
        dexWL = new DexWhitelistPolicy(address(guard), address(nfa));
        receiverGuard = new ReceiverGuardPolicy(address(nfa));
        spendingLimit = new SpendingLimitPolicy(address(guard), address(nfa));

        // H-1 fix: commit() no longer uses try-catch, so guard must know about NFA
        guard.setAgentNFA(address(nfa));

        // Set up fake ListingManager for Rent-to-Mint
        nfa.setListingManager(fakeListingManager);
        guard.setListingManager(fakeListingManager);

        // Create a template agent (mint to this test contract so we can registerTemplate)
        templateId = nfa.mintAgent(
            address(this),
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes32("default"),
            keccak256("llm_trader"), // agentType required for template
            "ipfs://agent",
            _emptyMetadata()
        );
        nfa.registerTemplate(templateId, TEMPLATE_KEY);

        // Bind standalone token to a non-empty template policy set so renter/operator
        // execution follows PolicyGuard fail-close semantics.
        guard.approvePolicyContract(address(dexWL));
        guard.approvePolicyContract(address(receiverGuard));
        guard.approvePolicyContract(address(spendingLimit));
        guard.addTemplatePolicy(TEMPLATE_KEY, address(dexWL));
        guard.addTemplatePolicy(TEMPLATE_KEY, address(receiverGuard));
        guard.addTemplatePolicy(TEMPLATE_KEY, address(spendingLimit));

        // Mint instance via Rent-to-Mint (renter = owner)
        leaseExpiry = uint64(block.timestamp + 1 days);
        tokenId = _mintInstance(renter, leaseExpiry);
        account = nfa.accountOf(tokenId);

        // Configure DEX whitelist so fail-close policy doesn't block test execution
        dexWL.addDex(tokenId, address(target));
    }

    /// @dev Mint an instance via Rent-to-Mint flow (renter = owner of instance)
    function _mintInstance(
        address to,
        uint64 expires
    ) internal returns (uint256 instanceId) {
        vm.prank(fakeListingManager);
        instanceId = nfa.mintInstanceFromTemplate(
            to,
            templateId,
            expires,
            ""
        );
        // Bind instance policies
        vm.prank(fakeListingManager);
        guard.bindInstance(instanceId, TEMPLATE_KEY);
    }

    function test_setOperatorWithSig_success() public {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        AgentNFA.OperatorPermit memory permit = _buildPermit(
            leaseExpiry,
            nfa.operatorNonceOf(tokenId),
            block.timestamp + 10 minutes
        );
        bytes memory sig = _signPermit(renterPk, permit);

        vm.prank(operator);
        nfa.setOperatorWithSig(permit, sig);

        assertEq(nfa.operatorOf(tokenId), operator);
        assertEq(nfa.operatorNonceOf(tokenId), 1);
    }

    function test_setOperatorWithSig_reverts_if_deadline_expired() public {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        AgentNFA.OperatorPermit memory permit = _buildPermit(
            leaseExpiry,
            nfa.operatorNonceOf(tokenId),
            block.timestamp - 1
        );
        bytes memory sig = _signPermit(renterPk, permit);

        vm.prank(operator);
        vm.expectRevert(Errors.SignatureExpired.selector);
        nfa.setOperatorWithSig(permit, sig);
    }

    function test_setOperatorWithSig_reverts_if_nonce_replayed() public {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        AgentNFA.OperatorPermit memory permit = _buildPermit(
            leaseExpiry,
            nfa.operatorNonceOf(tokenId),
            block.timestamp + 10 minutes
        );
        bytes memory sig = _signPermit(renterPk, permit);

        vm.prank(operator);
        nfa.setOperatorWithSig(permit, sig);

        vm.prank(operator);
        vm.expectRevert(Errors.InvalidNonce.selector);
        nfa.setOperatorWithSig(permit, sig);
    }

    function test_setOperatorWithSig_reverts_if_signer_not_renter() public {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        AgentNFA.OperatorPermit memory permit = _buildPermit(
            leaseExpiry,
            nfa.operatorNonceOf(tokenId),
            block.timestamp + 10 minutes
        );
        bytes memory sig = _signPermit(otherPk, permit);

        vm.prank(operator);
        vm.expectRevert(Errors.InvalidSigner.selector);
        nfa.setOperatorWithSig(permit, sig);
    }

    function test_setOperatorWithSig_reverts_if_expires_exceeds_lease() public {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        AgentNFA.OperatorPermit memory permit = _buildPermit(
            uint64(leaseExpiry + 1),
            nfa.operatorNonceOf(tokenId),
            block.timestamp + 10 minutes
        );
        bytes memory sig = _signPermit(renterPk, permit);

        vm.prank(operator);
        vm.expectRevert(Errors.OperatorExceedsLease.selector);
        nfa.setOperatorWithSig(permit, sig);
    }

    function test_setOperatorWithSig_reverts_if_submitter_not_operator()
        public
    {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        AgentNFA.OperatorPermit memory permit = _buildPermit(
            leaseExpiry,
            nfa.operatorNonceOf(tokenId),
            block.timestamp + 10 minutes
        );
        bytes memory sig = _signPermit(renterPk, permit);

        vm.prank(address(0x1234));
        vm.expectRevert(Errors.InvalidOperatorSubmitter.selector);
        nfa.setOperatorWithSig(permit, sig);
    }

    function test_operator_can_execute_during_lease() public {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        AgentNFA.OperatorPermit memory permit = _buildPermit(
            leaseExpiry,
            nfa.operatorNonceOf(tokenId),
            block.timestamp + 10 minutes
        );
        bytes memory sig = _signPermit(renterPk, permit);

        vm.prank(operator);
        nfa.setOperatorWithSig(permit, sig);

        Action memory action = Action(
            address(target),
            0,
            abi.encodeWithSelector(target.ping.selector)
        );
        vm.prank(operator);
        nfa.execute(tokenId, action);
    }

    function test_operator_cannot_execute_after_operator_expires() public {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        uint64 opExpiry = uint64(block.timestamp + 1 hours);
        AgentNFA.OperatorPermit memory permit = _buildPermit(
            opExpiry,
            nfa.operatorNonceOf(tokenId),
            block.timestamp + 10 minutes
        );
        bytes memory sig = _signPermit(renterPk, permit);

        vm.prank(operator);
        nfa.setOperatorWithSig(permit, sig);

        vm.warp(opExpiry + 1);

        Action memory action = Action(
            address(target),
            0,
            abi.encodeWithSelector(target.ping.selector)
        );
        vm.prank(operator);
        vm.expectRevert(Errors.Unauthorized.selector);
        nfa.execute(tokenId, action);
    }

    function test_operator_cannot_execute_after_lease_expires() public {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        AgentNFA.OperatorPermit memory permit = _buildPermit(
            leaseExpiry,
            nfa.operatorNonceOf(tokenId),
            block.timestamp + 10 minutes
        );
        bytes memory sig = _signPermit(renterPk, permit);

        vm.prank(operator);
        nfa.setOperatorWithSig(permit, sig);

        vm.warp(leaseExpiry + 1);

        Action memory action = Action(
            address(target),
            0,
            abi.encodeWithSelector(target.ping.selector)
        );
        vm.prank(operator);
        vm.expectRevert(Errors.Unauthorized.selector);
        nfa.execute(tokenId, action);
    }

    function test_operator_cannot_withdraw_native() public {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        AgentNFA.OperatorPermit memory permit = _buildPermit(
            leaseExpiry,
            nfa.operatorNonceOf(tokenId),
            block.timestamp + 10 minutes
        );
        bytes memory sig = _signPermit(renterPk, permit);

        vm.prank(operator);
        nfa.setOperatorWithSig(permit, sig);

        vm.deal(account, 1 ether);

        vm.prank(operator);
        vm.expectRevert(Errors.Unauthorized.selector);
        AgentAccount(payable(account)).withdrawNative(0.1 ether, operator);
    }

    function test_clearOperator_clears_authorization() public {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        AgentNFA.OperatorPermit memory permit = _buildPermit(
            leaseExpiry,
            nfa.operatorNonceOf(tokenId),
            block.timestamp + 10 minutes
        );
        bytes memory sig = _signPermit(renterPk, permit);

        vm.prank(operator);
        nfa.setOperatorWithSig(permit, sig);
        assertEq(nfa.operatorOf(tokenId), operator);

        vm.prank(renter);
        nfa.clearOperator(tokenId);
        assertEq(nfa.operatorOf(tokenId), address(0));
    }

    // ═══════════════════════════════════════════════════════
    //    H-3: Operator empty-calldata native drain attack
    // ═══════════════════════════════════════════════════════

    /// @notice H-3 PoC: operator sends execute(target=attacker, value=balance, data="")
    ///         ReceiverGuardPolicy MUST block this (target != vault).
    function test_attack_operator_native_drain_blocked_by_receiverGuard() public {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        // Set operator
        AgentNFA.OperatorPermit memory permit = _buildPermit(
            leaseExpiry,
            nfa.operatorNonceOf(tokenId),
            block.timestamp + 10 minutes
        );
        bytes memory sig = _signPermit(renterPk, permit);
        vm.prank(operator);
        nfa.setOperatorWithSig(permit, sig);

        // Fund the vault with native currency
        vm.deal(account, 5 ether);
        assertEq(account.balance, 5 ether);

        // Operator tries empty-calldata value transfer to drain vault
        address attacker = address(0xE111);
        Action memory drainAction = Action(attacker, 5 ether, "");

        vm.prank(operator);
        vm.expectRevert(); // PolicyViolation
        nfa.execute(tokenId, drainAction);

        // Vault balance unchanged
        assertEq(account.balance, 5 ether);
    }

    /// @notice H-3 variant: renter themselves cannot drain via empty calldata either.
    function test_attack_renter_native_drain_blocked() public {
        // renter + leaseExpiry already set via Rent-to-Mint in setUp

        vm.deal(account, 3 ether);

        address attacker = address(0xBAD);
        Action memory drainAction = Action(attacker, 3 ether, "");

        vm.prank(renter);
        vm.expectRevert(); // PolicyViolation
        nfa.execute(tokenId, drainAction);

        assertEq(account.balance, 3 ether);
    }

    /// @notice SpendingLimitPolicy fail-close: unconfigured limits reject value transfers.
    function test_spendingLimit_failClose_unconfigured() public {
        // SpendingLimitPolicy has no limits configured for this instance.
        // Previously this was fail-open; now it must reject value > 0.
        (bool ok, string memory reason) = spendingLimit.check(
            tokenId,
            renter,
            address(target),
            bytes4(0),
            "",
            1 ether
        );
        assertFalse(ok, "Unconfigured spending limit must reject value transfers");
        assertEq(reason, "Spending limits not configured");
    }

    /// @notice SpendingLimitPolicy: zero-value calls still pass when unconfigured.
    function test_spendingLimit_zeroValue_passes_unconfigured() public {
        // Use a non-special selector (not transfer/approve) with zero value
        (bool ok, ) = spendingLimit.check(
            tokenId,
            renter,
            address(target),
            target.ping.selector,
            abi.encodeWithSelector(target.ping.selector),
            0 // zero value
        );
        assertTrue(ok, "Zero-value call should pass unconfigured spending limit");
    }

    /// @notice ReceiverGuardPolicy: empty calldata + value to non-vault = blocked.
    function test_receiverGuard_nativeTransfer_nonVault_blocked() public {
        address attacker = address(0xDEAD);
        (bool ok, string memory reason) = receiverGuard.check(
            tokenId,
            renter,
            attacker,
            bytes4(0),
            "",
            1 ether
        );
        assertFalse(ok, "Native transfer to non-vault must be blocked");
        assertEq(reason, "Native transfer must target vault");
    }

    /// @notice ReceiverGuardPolicy: empty calldata + value to vault = allowed.
    function test_receiverGuard_nativeTransfer_toVault_passes() public {
        (bool ok, ) = receiverGuard.check(
            tokenId,
            renter,
            account, // vault address
            bytes4(0),
            "",
            1 ether
        );
        assertTrue(ok, "Native transfer to vault should pass");
    }

    /// @notice ReceiverGuardPolicy: empty calldata + zero value = pass through (no-op).
    function test_receiverGuard_zeroValue_emptyData_passes() public {
        (bool ok, ) = receiverGuard.check(
            tokenId,
            renter,
            address(0xDEAD),
            bytes4(0),
            "",
            0
        );
        assertTrue(ok, "Zero-value empty-data call should pass through");
    }

    // ═══════════════════════════════════════════════════════
    //    V-002: ERC20 swap amountIn must be constrained
    // ═══════════════════════════════════════════════════════

    /// @notice V-002 PoC: ERC20 swap with amountIn > maxPerTx must be blocked.
    function test_spendingLimit_erc20Swap_exceedsPerTx() public {
        // Configure spending limits: maxPerTx = 1 ether
        bytes32 tid = instanceTemplate(tokenId);
        spendingLimit.setTemplateCeiling(tid, 1 ether, 10 ether, 0);
        spendingLimit.setTemplateApproveCeiling(tid, 10 ether);
        // renter + leaseExpiry already set via Rent-to-Mint in setUp
        vm.prank(renter);
        spendingLimit.setLimits(tokenId, 1 ether, 10 ether, 0);

        // Build swapExactTokensForTokens calldata with amountIn = 5 ether (exceeds 1 ether limit)
        address[] memory path = new address[](2);
        path[0] = address(0xAAA1);
        path[1] = address(0xAAA2);
        bytes memory swapData = abi.encodeWithSelector(
            bytes4(0x38ed1739), // swapExactTokensForTokens
            5 ether,            // amountIn — exceeds maxPerTx
            1 ether,            // amountOutMin
            path,
            account,            // to = vault
            block.timestamp + 300
        );

        (bool ok, string memory reason) = spendingLimit.check(
            tokenId,
            renter,
            address(0xBBBB), // router
            bytes4(0x38ed1739),
            swapData,
            0 // value=0 for ERC20 swap
        );
        assertFalse(ok, "ERC20 swap exceeding maxPerTx must be blocked");
        assertEq(reason, "Exceeds per-tx limit");
    }

    /// @notice V-002: ERC20 swap within per-tx limit should pass.
    function test_spendingLimit_erc20Swap_withinLimit_passes() public {
        bytes32 tid = instanceTemplate(tokenId);
        spendingLimit.setTemplateCeiling(tid, 2 ether, 10 ether, 0);
        spendingLimit.setTemplateApproveCeiling(tid, 10 ether);
        // renter + leaseExpiry already set via Rent-to-Mint in setUp
        vm.prank(renter);
        spendingLimit.setLimits(tokenId, 2 ether, 10 ether, 0);

        address[] memory path = new address[](2);
        path[0] = address(0xAAA1);
        path[1] = address(0xAAA2);
        bytes memory swapData = abi.encodeWithSelector(
            bytes4(0x38ed1739),
            1 ether,  // amountIn — within limit
            0.5 ether,
            path,
            account,
            block.timestamp + 300
        );

        (bool ok, ) = spendingLimit.check(
            tokenId,
            renter,
            address(0xBBBB),
            bytes4(0x38ed1739),
            swapData,
            0
        );
        assertTrue(ok, "ERC20 swap within maxPerTx should pass");
    }

    /// @notice V-002: ERC20 swap daily accumulation must be tracked via onCommit.
    function test_spendingLimit_erc20Swap_dailyAccumulation() public {
        bytes32 tid = instanceTemplate(tokenId);
        spendingLimit.setTemplateCeiling(tid, 5 ether, 8 ether, 0);
        spendingLimit.setTemplateApproveCeiling(tid, 10 ether);
        // renter + leaseExpiry already set via Rent-to-Mint in setUp
        vm.prank(renter);
        spendingLimit.setLimits(tokenId, 5 ether, 8 ether, 0);

        address[] memory path = new address[](2);
        path[0] = address(0xAAA1);
        path[1] = address(0xAAA2);

        // First swap: 5 ether amountIn — within per-tx & daily
        bytes memory swapData1 = abi.encodeWithSelector(
            bytes4(0x38ed1739),
            5 ether,
            1 ether,
            path,
            account,
            block.timestamp + 300
        );

        (bool ok1, ) = spendingLimit.check(
            tokenId, renter, address(0xBBBB),
            bytes4(0x38ed1739), swapData1, 0
        );
        assertTrue(ok1, "First swap should pass");

        // Simulate commit (guard calls onCommit)
        vm.prank(address(guard));
        spendingLimit.onCommit(tokenId, renter, bytes4(0x38ed1739), swapData1, 0);

        // Second swap: 4 ether amountIn — within per-tx but 5+4=9 > daily limit 8
        bytes memory swapData2 = abi.encodeWithSelector(
            bytes4(0x38ed1739),
            4 ether,
            1 ether,
            path,
            account,
            block.timestamp + 300
        );

        (bool ok2, string memory reason2) = spendingLimit.check(
            tokenId, renter, address(0xBBBB),
            bytes4(0x38ed1739), swapData2, 0
        );
        assertFalse(ok2, "Second swap should hit daily limit");
        assertEq(reason2, "Daily limit reached");
    }

    /// @notice V-002: swapExactETHForTokens uses value (already covered), verify consistency.
    function test_spendingLimit_ethSwap_usesValue() public {
        bytes32 tid = instanceTemplate(tokenId);
        spendingLimit.setTemplateCeiling(tid, 1 ether, 10 ether, 0);
        spendingLimit.setTemplateApproveCeiling(tid, 10 ether);
        // renter + leaseExpiry already set via Rent-to-Mint in setUp
        vm.prank(renter);
        spendingLimit.setLimits(tokenId, 1 ether, 10 ether, 0);

        address[] memory path = new address[](2);
        path[0] = address(0xAAA1);
        path[1] = address(0xAAA2);
        // swapExactETHForTokens: value IS the amountIn
        bytes memory swapData = abi.encodeWithSelector(
            bytes4(0x7ff36ab5),
            0.5 ether, // amountOutMin
            path,
            account,
            block.timestamp + 300
        );

        (bool ok, string memory reason) = spendingLimit.check(
            tokenId, renter, address(0xBBBB),
            bytes4(0x7ff36ab5), swapData,
            3 ether // value = 3 ether, exceeds maxPerTx
        );
        assertFalse(ok, "ETH swap exceeding maxPerTx via value should be blocked");
        assertEq(reason, "Exceeds per-tx limit");
    }

    // ═══════════════════════════════════════════════════════
    //    Allowance mutator bypass: increaseAllowance / decreaseAllowance
    // ═══════════════════════════════════════════════════════

    /// @notice H-2 fix: increaseAllowance is now unconditionally blocked.
    function test_increaseAllowance_unapprovedSpender_blocked() public {
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x39509351), // increaseAllowance(address,uint256)
            address(0xA77C),   // unapproved spender
            1000 ether
        );
        (bool ok, string memory reason) = spendingLimit.check(
            tokenId, renter, address(0x70CE),
            bytes4(0x39509351), callData, 0
        );
        assertFalse(ok, "increaseAllowance must be blocked unconditionally");
        assertEq(reason, "Use approve instead of increaseAllowance");
    }

    /// @notice H-2 fix: increaseAllowance blocked regardless of amount.
    function test_increaseAllowance_infinite_blocked() public {
        address router = address(0xCACA);
        spendingLimit.setApprovedSpender(router, true);

        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x39509351),
            router,
            type(uint256).max
        );
        (bool ok, string memory reason) = spendingLimit.check(
            tokenId, renter, address(0x70CE),
            bytes4(0x39509351), callData, 0
        );
        assertFalse(ok, "increaseAllowance must be blocked unconditionally");
        assertEq(reason, "Use approve instead of increaseAllowance");
    }

    /// @notice H-2 fix: increaseAllowance blocked even within limits.
    function test_increaseAllowance_exceedsLimit_blocked() public {
        bytes32 tid = instanceTemplate(tokenId);
        spendingLimit.setTemplateCeiling(tid, 1 ether, 10 ether, 0);
        spendingLimit.setTemplateApproveCeiling(tid, 5 ether);
        address router = address(0xCACA);
        spendingLimit.setApprovedSpender(router, true);

        // renter + leaseExpiry already set via Rent-to-Mint in setUp
        vm.prank(renter);
        spendingLimit.setApproveLimit(tokenId, 2 ether);

        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x39509351),
            router,
            3 ether
        );
        (bool ok, string memory reason) = spendingLimit.check(
            tokenId, renter, address(0x70CE),
            bytes4(0x39509351), callData, 0
        );
        assertFalse(ok, "increaseAllowance must be blocked unconditionally");
        assertEq(reason, "Use approve instead of increaseAllowance");
    }

    /// @notice decreaseAllowance to unapproved spender must also be blocked.
    function test_decreaseAllowance_unapprovedSpender_blocked() public {
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0xa457c2d7), // decreaseAllowance(address,uint256)
            address(0xA77C),
            500 ether
        );
        (bool ok, string memory reason) = spendingLimit.check(
            tokenId, renter, address(0x70CE),
            bytes4(0xa457c2d7), callData, 0
        );
        assertFalse(ok, "decreaseAllowance to unapproved spender must be blocked");
        assertEq(reason, "Approve spender not allowed");
    }

    /// @notice H-2 fix: increaseAllowance blocked even for approved spender within limit.
    function test_increaseAllowance_withinLimit_blocked() public {
        bytes32 tid = instanceTemplate(tokenId);
        spendingLimit.setTemplateCeiling(tid, 1 ether, 10 ether, 0);
        spendingLimit.setTemplateApproveCeiling(tid, 5 ether);
        address router = address(0xCACA);
        spendingLimit.setApprovedSpender(router, true);

        // renter + leaseExpiry already set via Rent-to-Mint in setUp
        vm.prank(renter);
        spendingLimit.setApproveLimit(tokenId, 3 ether);

        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x39509351),
            router,
            2 ether // within limit but still blocked
        );
        (bool ok, string memory reason) = spendingLimit.check(
            tokenId, renter, address(0x70CE),
            bytes4(0x39509351), callData, 0
        );
        assertFalse(ok, "increaseAllowance must be blocked unconditionally");
        assertEq(reason, "Use approve instead of increaseAllowance");
    }

    // ═══════════════════════════════════════════════════════
    //    Review fixes: permit, exact-output swap, value guard
    // ═══════════════════════════════════════════════════════

    /// @notice ERC-2612 permit must be blocked unconditionally.
    function test_permit_erc2612_blocked() public {
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0xd505accf), // permit(address,address,uint256,uint256,uint8,bytes32,bytes32)
            address(0x1111), // owner
            address(0x2222), // spender
            100 ether,       // value
            block.timestamp + 1 hours, // deadline
            uint8(27),       // v
            bytes32(0),      // r
            bytes32(0)       // s
        );
        (bool ok, string memory reason) = spendingLimit.check(
            tokenId, renter, address(0x70CE),
            bytes4(0xd505accf), callData, 0
        );
        assertFalse(ok, "ERC-2612 permit must be blocked");
        assertEq(reason, "Permit not allowed");
    }

    /// @notice DAI-style permit must be blocked unconditionally.
    function test_permit_dai_blocked() public {
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x8fcbaf0c), // DAI permit
            address(0x1111),
            address(0x2222),
            uint256(0),  // nonce
            uint256(block.timestamp + 1 hours),
            true,        // allowed
            uint8(27),
            bytes32(0),
            bytes32(0)
        );
        (bool ok, string memory reason) = spendingLimit.check(
            tokenId, renter, address(0x70CE),
            bytes4(0x8fcbaf0c), callData, 0
        );
        assertFalse(ok, "DAI permit must be blocked");
        assertEq(reason, "Permit not allowed");
    }

    /// @notice swapTokensForExactTokens: spend must use amountInMax (param[1]), not amountOut (param[0]).
    function test_spendingLimit_exactOutputSwap_usesAmountInMax() public {
        bytes32 tid = instanceTemplate(tokenId);
        spendingLimit.setTemplateCeiling(tid, 5 ether, 100 ether, 0);
        spendingLimit.setTemplateApproveCeiling(tid, 10 ether);
        // renter + leaseExpiry already set via Rent-to-Mint in setUp
        vm.prank(renter);
        spendingLimit.setLimits(tokenId, 5 ether, 100 ether, 0);

        address[] memory path = new address[](2);
        path[0] = address(0xAAA1);
        path[1] = address(0xAAA2);

        // swapTokensForExactTokens(amountOut=1 ether, amountInMax=10 ether, ...)
        // amountInMax (10 ether) > maxPerTx (5 ether) → must be blocked
        bytes memory swapData = abi.encodeWithSelector(
            bytes4(0x8803dbee), // swapTokensForExactTokens
            1 ether,            // amountOut (small)
            10 ether,           // amountInMax (large — this is the real spend ceiling)
            path,
            account,
            block.timestamp + 300
        );

        (bool ok, string memory reason) = spendingLimit.check(
            tokenId, renter, address(0xBBBB),
            bytes4(0x8803dbee), swapData, 0
        );
        assertFalse(ok, "Exact-output swap must use amountInMax for spend check");
        assertEq(reason, "Exceeds per-tx limit");
    }

    /// @notice swapTokensForExactTokens within amountInMax limit should pass.
    function test_spendingLimit_exactOutputSwap_withinLimit_passes() public {
        bytes32 tid = instanceTemplate(tokenId);
        spendingLimit.setTemplateCeiling(tid, 10 ether, 100 ether, 0);
        spendingLimit.setTemplateApproveCeiling(tid, 10 ether);
        // renter + leaseExpiry already set via Rent-to-Mint in setUp
        vm.prank(renter);
        spendingLimit.setLimits(tokenId, 10 ether, 100 ether, 0);

        address[] memory path = new address[](2);
        path[0] = address(0xAAA1);
        path[1] = address(0xAAA2);

        // amountInMax (3 ether) <= maxPerTx (10 ether)
        bytes memory swapData = abi.encodeWithSelector(
            bytes4(0x8803dbee),
            1 ether,  // amountOut
            3 ether,  // amountInMax
            path,
            account,
            block.timestamp + 300
        );

        (bool ok, ) = spendingLimit.check(
            tokenId, renter, address(0xBBBB),
            bytes4(0x8803dbee), swapData, 0
        );
        assertTrue(ok, "Exact-output swap within amountInMax limit should pass");
    }

    /// @notice ReceiverGuard: non-swap call with value > 0 to non-vault must be blocked.
    function test_receiverGuard_nonSwapValue_nonVault_blocked() public {
        address randomTarget = address(0xF00D);
        (bool ok, string memory reason) = receiverGuard.check(
            tokenId, renter, randomTarget,
            bytes4(0x12345678), // arbitrary non-swap selector
            abi.encodeWithSelector(bytes4(0x12345678)),
            1 ether
        );
        assertFalse(ok, "Non-swap value transfer to non-vault must be blocked");
        assertEq(reason, "Value transfer must target vault");
    }

    /// @notice ReceiverGuard: non-swap call with value > 0 to vault should pass.
    function test_receiverGuard_nonSwapValue_toVault_passes() public {
        (bool ok, ) = receiverGuard.check(
            tokenId, renter, account, // vault
            bytes4(0x12345678),
            abi.encodeWithSelector(bytes4(0x12345678)),
            1 ether
        );
        assertTrue(ok, "Non-swap value transfer to vault should pass");
    }

    /// @notice decreaseAllowance to approved spender should pass without amount checks.
    function test_decreaseAllowance_approvedSpender_passes() public {
        address router = address(0xCACA);
        spendingLimit.setApprovedSpender(router, true);

        // decreaseAllowance with a huge amount — should still pass (safe operation)
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0xa457c2d7),
            router,
            type(uint256).max // max amount OK for decrease
        );
        (bool ok, ) = spendingLimit.check(
            tokenId, renter, address(0x70CE),
            bytes4(0xa457c2d7), callData, 0
        );
        assertTrue(ok, "decreaseAllowance to approved spender should always pass");
    }

    /// @notice Helper: read instanceTemplate mapping
    function instanceTemplate(uint256 id) internal view returns (bytes32) {
        return spendingLimit.instanceTemplate(id);
    }

    function _buildPermit(
        uint64 expires,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (AgentNFA.OperatorPermit memory) {
        return
            AgentNFA.OperatorPermit({
                tokenId: tokenId,
                renter: renter,
                operator: operator,
                expires: expires,
                nonce: nonce,
                deadline: deadline
            });
    }

    function _signPermit(
        uint256 signerPk,
        AgentNFA.OperatorPermit memory permit
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                OPERATOR_PERMIT_TYPEHASH,
                permit.tokenId,
                permit.renter,
                permit.operator,
                permit.expires,
                permit.nonce,
                permit.deadline
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("SHLL AgentNFA")),
                keccak256(bytes("1")),
                block.chainid,
                address(nfa)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _emptyMetadata()
        internal
        pure
        returns (IBAP578.AgentMetadata memory)
    {
        return
            IBAP578.AgentMetadata({
                persona: "",
                experience: "",
                voiceHash: "",
                animationURI: "",
                vaultURI: "",
                vaultHash: bytes32(0)
            });
    }
}
