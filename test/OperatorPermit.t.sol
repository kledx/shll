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

        tokenId = nfa.mintAgent(
            address(0xABCD),
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes32("default"),
            bytes32(0), // agentType (V3.0)
            "ipfs://agent",
            _emptyMetadata()
        );
        account = nfa.accountOf(tokenId);

        // Bind standalone token to a non-empty template policy set so renter/operator
        // execution follows PolicyGuard fail-close semantics.
        guard.approvePolicyContract(address(dexWL));
        guard.approvePolicyContract(address(receiverGuard));
        guard.approvePolicyContract(address(spendingLimit));
        guard.addTemplatePolicy(TEMPLATE_KEY, address(dexWL));
        guard.addTemplatePolicy(TEMPLATE_KEY, address(receiverGuard));
        guard.addTemplatePolicy(TEMPLATE_KEY, address(spendingLimit));
        guard.bindInstance(tokenId, TEMPLATE_KEY);

        // Configure DEX whitelist so fail-close policy doesn't block test execution
        dexWL.addDex(tokenId, address(target));
    }

    function test_setOperatorWithSig_success() public {
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        uint64 leaseExpiry = uint64(block.timestamp + 1 days);
        nfa.setUser(tokenId, renter, leaseExpiry);

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
        vm.prank(guard.owner());
        // initInstance already called in setUp via bindInstance, so set limits directly
        // We need to simulate renter setting limits
        nfa.setUser(tokenId, renter, uint64(block.timestamp + 1 days));
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
        nfa.setUser(tokenId, renter, uint64(block.timestamp + 1 days));
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
        nfa.setUser(tokenId, renter, uint64(block.timestamp + 1 days));
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
        nfa.setUser(tokenId, renter, uint64(block.timestamp + 1 days));
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

    /// @notice PoC: increaseAllowance to unapproved spender must be blocked.
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
        assertFalse(ok, "increaseAllowance to unapproved spender must be blocked");
        assertEq(reason, "Approve spender not allowed");
    }

    /// @notice PoC: increaseAllowance with max uint256 must be blocked.
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
        assertFalse(ok, "Infinite increaseAllowance must be blocked");
        assertEq(reason, "Infinite approval not allowed");
    }

    /// @notice PoC: increaseAllowance exceeding approve limit must be blocked.
    function test_increaseAllowance_exceedsLimit_blocked() public {
        bytes32 tid = instanceTemplate(tokenId);
        spendingLimit.setTemplateCeiling(tid, 1 ether, 10 ether, 0);
        spendingLimit.setTemplateApproveCeiling(tid, 5 ether);
        address router = address(0xCACA);
        spendingLimit.setApprovedSpender(router, true);

        nfa.setUser(tokenId, renter, uint64(block.timestamp + 1 days));
        vm.prank(renter);
        spendingLimit.setApproveLimit(tokenId, 2 ether);

        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x39509351),
            router,
            3 ether // exceeds instanceApproveLimit of 2 ether
        );
        (bool ok, string memory reason) = spendingLimit.check(
            tokenId, renter, address(0x70CE),
            bytes4(0x39509351), callData, 0
        );
        assertFalse(ok, "increaseAllowance exceeding limit must be blocked");
        assertEq(reason, "Approve exceeds limit");
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

    /// @notice increaseAllowance within limits to approved spender should pass.
    function test_increaseAllowance_withinLimit_passes() public {
        bytes32 tid = instanceTemplate(tokenId);
        spendingLimit.setTemplateCeiling(tid, 1 ether, 10 ether, 0);
        spendingLimit.setTemplateApproveCeiling(tid, 5 ether);
        address router = address(0xCACA);
        spendingLimit.setApprovedSpender(router, true);

        nfa.setUser(tokenId, renter, uint64(block.timestamp + 1 days));
        vm.prank(renter);
        spendingLimit.setApproveLimit(tokenId, 3 ether);

        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x39509351),
            router,
            2 ether // within limit
        );
        (bool ok, ) = spendingLimit.check(
            tokenId, renter, address(0x70CE),
            bytes4(0x39509351), callData, 0
        );
        assertTrue(ok, "increaseAllowance within limit to approved spender should pass");
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
