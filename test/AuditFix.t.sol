// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {AgentAccount} from "../src/AgentAccount.sol";
import {PolicyGuard} from "../src/PolicyGuard.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";
import {Action} from "../src/types/Action.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";
import {Errors} from "../src/libs/Errors.sol";

/// @title MockERC20AF — Minimal ERC20 for AuditFix tests
contract MockERC20AF {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

/// @title MockTarget — Simple target for execute tests
contract MockTarget {
    function doSomething() external pure returns (uint256) {
        return 42;
    }
}

/// @title AuditFixTest — Tests for audit findings H-1/H-2, H-3, M-2, M-5
contract AuditFixTest is Test {
    AgentNFA public nfa;
    PolicyGuard public guard;
    ListingManager public listingMgr;
    MockERC20AF public usdt;
    MockTarget public mockTarget;

    address owner = address(this);
    address renterA = address(0xA001);
    address attacker = address(0xDEAD);

    uint256 templateId;
    bytes32 templateListingId;

    IBAP578.AgentMetadata emptyMetadata;
    bytes32 constant TEST_POLICY = bytes32("testPolicy");
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 constant PACK_HASH = bytes32("packHash_v1");
    string constant PACK_URI = "ipfs://QmPackManifest";

    function setUp() public {
        guard = new PolicyGuard();
        nfa = new AgentNFA(address(guard));
        listingMgr = new ListingManager();
        usdt = new MockERC20AF("USDT", "USDT");
        mockTarget = new MockTarget();

        nfa.setListingManager(address(listingMgr));

        // PolicyGuard: allow mockTarget.doSomething()
        guard.setTargetAllowed(address(mockTarget), true);
        guard.setSelectorAllowed(
            address(mockTarget),
            mockTarget.doSomething.selector,
            true
        );

        // Mint template
        templateId = nfa.mintAgent(
            owner,
            TEST_POLICY,
            "ipfs://template",
            emptyMetadata
        );
        nfa.registerTemplate(templateId, PACK_HASH, PACK_URI);

        // Create template listing
        templateListingId = listingMgr.createTemplateListing(
            address(nfa),
            templateId,
            0.1 ether,
            1
        );

        // Fund
        vm.deal(renterA, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    // Required for _safeMint callback
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ═══════════════════════════════════════════════════════════
    //  H-2: Instance owner MUST pass PolicyGuard
    // ═══════════════════════════════════════════════════════════

    /// @dev Instance owner calling execute with an action NOT in PolicyGuard allowlist should revert
    function test_H2_instanceOwner_enforcedByPolicyGuard() public {
        // Mint instance via Rent-to-Mint
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );

        // renterA is now BOTH owner and user of the instance
        assertEq(nfa.ownerOf(instanceId), renterA);

        // Try to execute an action against a target NOT in PolicyGuard allowlist
        address evilTarget = address(0xBAD);
        Action memory action = Action(
            evilTarget,
            0,
            abi.encodeWithSelector(bytes4(0x12345678))
        );

        vm.prank(renterA);
        vm.expectRevert(); // PolicyViolation — target not allowed
        nfa.execute(instanceId, action);
    }

    /// @dev Instance owner can execute actions that ARE in PolicyGuard allowlist
    function test_H2_instanceOwner_allowedAction_succeeds() public {
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );

        // Action against allowed target+selector
        Action memory action = Action(
            address(mockTarget),
            0,
            abi.encodeWithSelector(mockTarget.doSomething.selector)
        );

        vm.prank(renterA);
        nfa.execute(instanceId, action);
    }

    // ═══════════════════════════════════════════════════════════
    //  H-1: Regular owner still bypasses PolicyGuard (no regression)
    // ═══════════════════════════════════════════════════════════

    /// @dev Regular (non-instance) NFT owner can execute without PolicyGuard
    function test_H1_regularOwner_bypassesPolicyGuard() public {
        uint256 agentId = nfa.mintAgent(
            owner,
            TEST_POLICY,
            "ipfs://agent",
            emptyMetadata
        );

        // Execute against a target NOT in PolicyGuard — should succeed because regular owner
        address anyTarget = address(0xCAFE);
        Action memory action = Action(anyTarget, 0, "");

        // This should NOT revert — regular owner bypasses PolicyGuard
        nfa.execute(agentId, action);
    }

    // ═══════════════════════════════════════════════════════════
    //  H-3: setUser on non-existent token should revert
    // ═══════════════════════════════════════════════════════════

    function test_H3_setUser_nonExistentToken_reverts() public {
        uint256 fakeTokenId = 9999;
        vm.expectRevert();
        nfa.setUser(fakeTokenId, renterA, uint64(block.timestamp + 1 days));
    }

    // ═══════════════════════════════════════════════════════════
    //  M-2: extend() on template listing should revert
    // ═══════════════════════════════════════════════════════════

    function test_M2_extend_templateListing_reverts() public {
        vm.prank(renterA);
        vm.expectRevert(Errors.IsTemplateListing.selector);
        listingMgr.extend{value: 0.1 ether}(templateListingId, 1);
    }

    // ═══════════════════════════════════════════════════════════
    //  M-5: Admin setters reject address(0)
    // ═══════════════════════════════════════════════════════════

    function test_M5_setListingManager_zeroAddress_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        nfa.setListingManager(address(0));
    }

    function test_M5_setPolicyGuard_zeroAddress_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        nfa.setPolicyGuard(address(0));
    }
}
