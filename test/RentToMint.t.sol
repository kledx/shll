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

/// @title MockERC20 — Minimal ERC20 for testing
contract MockERC20R {
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

/// @title RentToMintTest — V1.3 Template/Instance comprehensive test suite
/// @dev Covers: registration, minting, isolation, policy inheritance, security boundaries
contract RentToMintTest is Test {
    AgentNFA public nfa;
    PolicyGuard public guard;
    ListingManager public listingMgr;
    MockERC20R public usdt;

    address owner = address(this);
    address renterA = address(0xA001);
    address renterB = address(0xB002);
    address attacker = address(0xDEAD);

    uint256 templateId;
    address templateAccount;
    bytes32 templateListingId;

    IBAP578.AgentMetadata emptyMetadata;
    bytes32 constant TEST_POLICY = bytes32("testPolicy");
    bytes32 constant PACK_HASH = bytes32("packHash_v1");
    string constant PACK_URI = "ipfs://QmPackManifest";

    function setUp() public {
        // Deploy core contracts
        guard = new PolicyGuard();
        nfa = new AgentNFA(address(guard));
        listingMgr = new ListingManager();
        usdt = new MockERC20R("USDT", "USDT");

        // Wire up
        nfa.setListingManager(address(listingMgr));

        // Configure PolicyGuard with basic swap permissions
        address router = address(0x1111);
        guard.setTargetAllowed(router, true);
        guard.setTargetAllowed(address(usdt), true);
        guard.setSelectorAllowed(router, PolicyKeys.SWAP_EXACT_TOKENS, true);
        guard.setSelectorAllowed(address(usdt), PolicyKeys.APPROVE, true);
        guard.setTokenAllowed(address(usdt), true);
        guard.setSpenderAllowed(address(usdt), router, true);
        guard.setLimit(PolicyKeys.MAX_DEADLINE_WINDOW, 1200);
        guard.setLimit(PolicyKeys.MAX_PATH_LENGTH, 3);

        // Mint template agent
        templateId = nfa.mintAgent(
            owner,
            TEST_POLICY,
            "ipfs://templateAgent",
            emptyMetadata
        );
        templateAccount = nfa.accountOf(templateId);

        // Register as template
        nfa.registerTemplate(templateId, PACK_HASH, PACK_URI);

        // Create template listing (0.1 BNB/day, min 1 day)
        templateListingId = listingMgr.createTemplateListing(
            address(nfa),
            templateId,
            0.1 ether,
            1
        );

        // Fund renters
        vm.deal(renterA, 10 ether);
        vm.deal(renterB, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    // Required for receiving NFTs via _safeMint
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ═══════════════════════════════════════════════════════════
    //  TEMPLATE REGISTRATION
    // ═══════════════════════════════════════════════════════════

    function test_registerTemplate_success() public view {
        assertTrue(nfa.isTemplate(templateId));
        assertEq(nfa.templatePolicyId(templateId), TEST_POLICY);
        assertEq(nfa.templatePackHash(templateId), PACK_HASH);
    }

    function test_registerTemplate_onlyOwner() public {
        // Mint another agent
        uint256 agentId = nfa.mintAgent(
            owner,
            TEST_POLICY,
            "uri",
            emptyMetadata
        );

        // Non-owner tries to register
        vm.prank(renterA);
        vm.expectRevert(Errors.OnlyOwner.selector);
        nfa.registerTemplate(agentId, PACK_HASH, PACK_URI);
    }

    function test_registerTemplate_alreadyRegistered() public {
        vm.expectRevert(
            abi.encodeWithSelector(Errors.AlreadyTemplate.selector, templateId)
        );
        nfa.registerTemplate(templateId, PACK_HASH, PACK_URI);
    }

    function test_registerTemplate_instanceCannotBeTemplate() public {
        // Mint instance first
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );

        // Instance owner tries to register it as template
        vm.prank(renterA);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NotTemplate.selector, instanceId)
        );
        nfa.registerTemplate(instanceId, PACK_HASH, PACK_URI);
    }

    function test_registerTemplate_freezesPolicy() public {
        // Template's policyId is frozen — setPolicy should revert
        vm.expectRevert(
            abi.encodeWithSelector(Errors.AlreadyTemplate.selector, templateId)
        );
        nfa.setPolicy(templateId, bytes32("newPolicy"));
    }

    // ═══════════════════════════════════════════════════════════
    //  TEMPLATE LISTING
    // ═══════════════════════════════════════════════════════════

    function test_createTemplateListing_requiresTemplate() public {
        // Mint a non-template agent
        uint256 agentId = nfa.mintAgent(
            owner,
            TEST_POLICY,
            "uri",
            emptyMetadata
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.NotTemplate.selector, agentId)
        );
        listingMgr.createTemplateListing(address(nfa), agentId, 0.1 ether, 1);
    }

    function test_classicRent_blockedOnTemplateListing() public {
        // Classic rent() should revert for template listings
        vm.prank(renterA);
        vm.expectRevert(Errors.IsTemplateListing.selector);
        listingMgr.rent{value: 0.1 ether}(templateListingId, 1);
    }

    // ═══════════════════════════════════════════════════════════
    //  RENT-TO-MINT: HAPPY PATH
    // ═══════════════════════════════════════════════════════════

    function test_rentToMint_happyPath() public {
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.5 ether}(
            templateListingId,
            5,
            abi.encode("strategy=aggressive")
        );

        // Instance exists and is owned by renter
        assertEq(nfa.ownerOf(instanceId), renterA);

        // Has its own vault
        address vault = nfa.accountOf(instanceId);
        assertTrue(vault != address(0));
        assertTrue(vault != templateAccount);

        // Template relationship recorded
        assertEq(nfa.templateOf(instanceId), templateId);

        // Params hash recorded
        bytes32 expectedHash = keccak256(abi.encode("strategy=aggressive"));
        assertEq(nfa.paramsHashOf(instanceId), expectedHash);

        // UserOf returns renter (within expiry)
        assertEq(nfa.userOf(instanceId), renterA);
    }

    function test_rentToMint_refundsExcess() public {
        uint256 balBefore = renterA.balance;

        vm.prank(renterA);
        listingMgr.rentToMint{value: 1 ether}(
            templateListingId,
            1, // 0.1 BNB
            abi.encode("params")
        );

        // Renter should get 0.9 BNB back
        assertEq(renterA.balance, balBefore - 0.1 ether);
    }

    function test_rentToMint_pendingWithdrawals() public {
        vm.prank(renterA);
        listingMgr.rentToMint{value: 0.3 ether}(
            templateListingId,
            3,
            abi.encode("params")
        );

        // Template owner should have 0.3 BNB pending
        assertEq(listingMgr.pendingWithdrawals(owner), 0.3 ether);
    }

    function test_rentToMint_minDaysEnforced() public {
        vm.prank(renterA);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.MinDaysNotMet.selector,
                uint32(0),
                uint32(1)
            )
        );
        listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            0,
            abi.encode("params")
        );
    }

    function test_rentToMint_insufficientPayment() public {
        vm.prank(renterA);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InsufficientPayment.selector,
                0.1 ether,
                0.05 ether
            )
        );
        listingMgr.rentToMint{value: 0.05 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );
    }

    function test_rentToMint_emptyParamsReverts() public {
        vm.prank(renterA);
        vm.expectRevert(Errors.InvalidInitParams.selector);
        listingMgr.rentToMint{value: 0.1 ether}(templateListingId, 1, "");
    }

    function test_rentToMint_nonTemplateListingReverts() public {
        // Create a classic listing
        uint256 classicId = nfa.mintAgent(
            owner,
            TEST_POLICY,
            "uri",
            emptyMetadata
        );
        bytes32 classicListing = listingMgr.createListing(
            address(nfa),
            classicId,
            0.1 ether,
            1
        );

        vm.prank(renterA);
        vm.expectRevert(Errors.TemplateListingRequired.selector);
        listingMgr.rentToMint{value: 0.1 ether}(
            classicListing,
            1,
            abi.encode("params")
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  VAULT ISOLATION
    // ═══════════════════════════════════════════════════════════

    function test_vaultIsolation_differentAddresses() public {
        vm.prank(renterA);
        uint256 instA = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("A")
        );

        vm.prank(renterB);
        uint256 instB = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("B")
        );

        address vaultA = nfa.accountOf(instA);
        address vaultB = nfa.accountOf(instB);

        // All three vaults must be distinct
        assertTrue(vaultA != vaultB);
        assertTrue(vaultA != templateAccount);
        assertTrue(vaultB != templateAccount);
    }

    function test_vaultIsolation_fundsNotShared() public {
        vm.prank(renterA);
        uint256 instA = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("A")
        );

        vm.prank(renterB);
        uint256 instB = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("B")
        );

        address vaultA = nfa.accountOf(instA);
        address vaultB = nfa.accountOf(instB);

        // Deposit funds into vault A
        usdt.mint(vaultA, 1000 ether);

        // Vault B should have 0
        assertEq(usdt.balanceOf(vaultA), 1000 ether);
        assertEq(usdt.balanceOf(vaultB), 0);
    }

    // ═══════════════════════════════════════════════════════════
    //  POLICY INHERITANCE
    // ═══════════════════════════════════════════════════════════

    function test_policyInherited() public {
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );

        // Instance should inherit template's frozen policyId
        assertEq(nfa.policyIdOf(instanceId), TEST_POLICY);
    }

    function test_policyInherited_matchesTemplateFrozen() public {
        // Verify instance policy == template frozen policy (not current template policy)
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );

        assertEq(nfa.policyIdOf(instanceId), nfa.templatePolicyId(templateId));
    }

    // ═══════════════════════════════════════════════════════════
    //  MULTI-TENANT (CONCURRENT RENTALS)
    // ═══════════════════════════════════════════════════════════

    function test_multiTenant_simultaneousRentals() public {
        // Two renters rent the same template simultaneously
        vm.prank(renterA);
        uint256 instA = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("A")
        );

        vm.prank(renterB);
        uint256 instB = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("B")
        );

        // Both instances exist with correct owners
        assertEq(nfa.ownerOf(instA), renterA);
        assertEq(nfa.ownerOf(instB), renterB);

        // Different tokenIds
        assertTrue(instA != instB);

        // Both derive from same template
        assertEq(nfa.templateOf(instA), templateId);
        assertEq(nfa.templateOf(instB), templateId);
    }

    function test_multiTenant_manyInstances() public {
        // Stress test: 10 instances from same template
        for (uint256 i = 0; i < 10; i++) {
            address renter = address(uint160(0x1000 + i));
            vm.deal(renter, 1 ether);
            vm.prank(renter);
            uint256 instId = listingMgr.rentToMint{value: 0.1 ether}(
                templateListingId,
                1,
                abi.encode(i)
            );
            assertEq(nfa.ownerOf(instId), renter);
            assertEq(nfa.templateOf(instId), templateId);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  SECURITY: CROSS-INSTANCE ISOLATION
    // ═══════════════════════════════════════════════════════════

    function test_security_renterACannotAccessInstanceB() public {
        vm.prank(renterA);
        uint256 instA = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("A")
        );

        vm.prank(renterB);
        uint256 instB = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("B")
        );

        // Fund instanceB's vault with USDT
        address vaultB = nfa.accountOf(instB);
        usdt.mint(vaultB, 1000 ether);

        // RenterA tries to withdraw from instanceB's vault
        vm.prank(renterA);
        vm.expectRevert(Errors.Unauthorized.selector);
        AgentAccount(payable(vaultB)).withdrawToken(
            address(usdt),
            100 ether,
            renterA
        );
    }

    function test_security_templateOwnerCannotAccessInstanceVault() public {
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );

        address vault = nfa.accountOf(instanceId);
        usdt.mint(vault, 1000 ether);

        // Template owner (address(this)) is NOT the instance owner (renterA)
        // Template owner should NOT be able to withdraw from instance vault
        // The instance owner IS the renter, not the template owner

        // Direct vault withdrawal — only owner or renter of THIS instance can withdraw
        // Since instance owner is renterA, address(this) is not authorized
        vm.expectRevert(Errors.Unauthorized.selector);
        AgentAccount(payable(vault)).withdrawToken(
            address(usdt),
            100 ether,
            owner
        );
    }

    function test_security_directVaultCall_blocked() public {
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );

        address vault = nfa.accountOf(instanceId);

        // Direct executeCall on vault is blocked (only NFA contract can call it)
        vm.prank(renterA);
        vm.expectRevert(Errors.OnlyNFA.selector);
        AgentAccount(payable(vault)).executeCall(address(usdt), 0, "");
    }

    // ═══════════════════════════════════════════════════════════
    //  SECURITY: INSTANCE OWNER CAN WITHDRAW
    // ═══════════════════════════════════════════════════════════

    function test_instanceOwner_canWithdraw() public {
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );

        address vault = nfa.accountOf(instanceId);
        usdt.mint(vault, 500 ether);

        // RenterA is the owner — should be able to withdraw to own address
        vm.prank(renterA);
        AgentAccount(payable(vault)).withdrawToken(
            address(usdt),
            500 ether,
            renterA
        );

        assertEq(usdt.balanceOf(renterA), 500 ether);
        assertEq(usdt.balanceOf(vault), 0);
    }

    function test_instanceOwner_cannotWithdrawToOther() public {
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );

        address vault = nfa.accountOf(instanceId);
        usdt.mint(vault, 500 ether);

        // RenterA tries to withdraw to attacker address
        vm.prank(renterA);
        vm.expectRevert(Errors.InvalidWithdrawRecipient.selector);
        AgentAccount(payable(vault)).withdrawToken(
            address(usdt),
            500 ether,
            attacker
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  SECURITY: MINT ONLY BY LISTING MANAGER
    // ═══════════════════════════════════════════════════════════

    function test_security_mintInstance_onlyListingManager() public {
        // Direct call to mintInstanceFromTemplate should be blocked
        vm.prank(attacker);
        vm.expectRevert(Errors.OnlyListingManager.selector);
        nfa.mintInstanceFromTemplate(
            attacker,
            templateId,
            uint64(block.timestamp + 1 days),
            abi.encode("hack")
        );
    }

    function test_security_mintInstance_templateMustExist() public {
        // Try to mint from a non-template tokenId (via impersonating listingMgr)
        uint256 fakeTemplateId = 999;
        vm.prank(address(listingMgr));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NotTemplate.selector, fakeTemplateId)
        );
        nfa.mintInstanceFromTemplate(
            renterA,
            fakeTemplateId,
            uint64(block.timestamp + 1 days),
            abi.encode("x")
        );
    }

    function test_security_mintInstance_zeroAddressBlocked() public {
        vm.prank(address(listingMgr));
        vm.expectRevert(Errors.ZeroAddress.selector);
        nfa.mintInstanceFromTemplate(
            address(0),
            templateId,
            uint64(block.timestamp + 1 days),
            abi.encode("x")
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  CLASSIC RENT BACKWARD COMPATIBILITY
    // ═══════════════════════════════════════════════════════════

    function test_classicRent_stillWorks() public {
        // Mint a non-template agent
        uint256 classicId = nfa.mintAgent(
            owner,
            TEST_POLICY,
            "uri",
            emptyMetadata
        );
        bytes32 classicListing = listingMgr.createListing(
            address(nfa),
            classicId,
            0.1 ether,
            1
        );

        // Classic rent should still work
        vm.prank(renterA);
        uint64 expires = listingMgr.rent{value: 0.1 ether}(classicListing, 1);

        assertTrue(expires > uint64(block.timestamp));
        assertEq(nfa.userOf(classicId), renterA);
    }

    function test_classicRent_extendStillWorks() public {
        // Mint a non-template agent and rent it
        uint256 classicId = nfa.mintAgent(
            owner,
            TEST_POLICY,
            "uri",
            emptyMetadata
        );
        bytes32 classicListing = listingMgr.createListing(
            address(nfa),
            classicId,
            0.1 ether,
            1
        );

        vm.prank(renterA);
        listingMgr.rent{value: 0.1 ether}(classicListing, 1);

        // Extend
        vm.prank(renterA);
        uint64 newExpires = listingMgr.extend{value: 0.1 ether}(
            classicListing,
            1
        );

        // Should extend by 1 more day
        assertTrue(newExpires > uint64(block.timestamp + 1 days));
    }

    // ═══════════════════════════════════════════════════════════
    //  LISTING MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    function test_templateListing_canBePaused() public {
        listingMgr.pauseRenting(templateListingId);

        vm.prank(renterA);
        vm.expectRevert(Errors.RentingPaused.selector);
        listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );
    }

    function test_templateListing_canBeResumedAfterPause() public {
        listingMgr.pauseRenting(templateListingId);
        listingMgr.resumeRenting(templateListingId);

        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );
        assertEq(nfa.ownerOf(instanceId), renterA);
    }

    function test_templateListing_canBeCanceled() public {
        listingMgr.cancelListing(templateListingId);

        vm.prank(renterA);
        vm.expectRevert(Errors.ListingNotFound.selector);
        listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("params")
        );
    }

    function test_templateListing_maxDaysEnforced() public {
        // Set maxDays to 7
        listingMgr.setListingConfig(templateListingId, 7, 0);

        vm.prank(renterA);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.MaxDaysExceeded.selector,
                uint32(10),
                uint32(7)
            )
        );
        listingMgr.rentToMint{value: 1 ether}(
            templateListingId,
            10,
            abi.encode("params")
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════════════════════

    function test_nextTokenId_increments() public {
        uint256 before = nfa.nextTokenId();

        vm.prank(renterA);
        listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("p")
        );

        assertEq(nfa.nextTokenId(), before + 1);
    }

    function test_templateOf_returnsZeroForNonInstance() public view {
        assertEq(nfa.templateOf(templateId), 0);
    }

    function test_isTemplate_returnsFalseForInstance() public {
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("p")
        );
        assertFalse(nfa.isTemplate(instanceId));
    }

    function test_isTemplate_returnsFalseForRegular() public {
        uint256 regularId = nfa.mintAgent(
            owner,
            TEST_POLICY,
            "uri",
            emptyMetadata
        );
        assertFalse(nfa.isTemplate(regularId));
    }

    // ═══════════════════════════════════════════════════════════
    //  EDGE CASES
    // ═══════════════════════════════════════════════════════════

    function test_instanceExpiry_userOfReturnsZero() public {
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("p")
        );

        // Fast forward past expiry
        vm.warp(block.timestamp + 2 days);

        // userOf should return address(0) after expiry
        assertEq(nfa.userOf(instanceId), address(0));

        // But owner should still be renterA (ownership is permanent)
        assertEq(nfa.ownerOf(instanceId), renterA);
    }

    function test_instanceAgent_statusActive() public {
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("p")
        );

        assertEq(
            uint8(nfa.agentStatus(instanceId)),
            uint8(IBAP578.Status.Active)
        );
    }

    function test_instanceOwner_canPauseAgent() public {
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("p")
        );

        // Instance owner can pause their agent
        vm.prank(renterA);
        nfa.pauseAgent(instanceId);
        assertEq(
            uint8(nfa.agentStatus(instanceId)),
            uint8(IBAP578.Status.Paused)
        );
    }

    function test_templateOwner_cannotPauseInstance() public {
        vm.prank(renterA);
        uint256 instanceId = listingMgr.rentToMint{value: 0.1 ether}(
            templateListingId,
            1,
            abi.encode("p")
        );

        // Template owner should NOT be able to pause instance
        vm.expectRevert(Errors.OnlyOwner.selector);
        nfa.pauseAgent(instanceId);
    }
}
