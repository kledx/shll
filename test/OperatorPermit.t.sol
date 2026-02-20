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
        guard.addTemplatePolicy(TEMPLATE_KEY, address(dexWL));
        guard.bindInstance(tokenId, TEMPLATE_KEY);
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
