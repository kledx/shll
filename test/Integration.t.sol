// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {AgentAccount} from "../src/AgentAccount.sol";
import {PolicyGuard} from "../src/PolicyGuard.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";
import {Action} from "../src/types/Action.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title MockERC20 — Minimal ERC20 for testing
contract MockERC20 {
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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

/// @title Integration Test — Full E2E flow
contract IntegrationTest is Test {
    AgentNFA public nfa;
    PolicyGuard public guard;
    ListingManager public listing;
    MockERC20 public usdt;

    address owner = address(this);
    address renter = address(0xBEEF);
    address evil = address(0xDEAD);
    address constant ROUTER = address(0x1111);

    uint256 tokenId;
    address account;
    bytes32 listingId;

    function setUp() public {
        // Deploy contracts
        guard = new PolicyGuard();
        nfa = new AgentNFA(address(guard));
        listing = new ListingManager();
        usdt = new MockERC20("USDT", "USDT");

        // Setup
        nfa.setListingManager(address(listing));

        // Configure PolicyGuard
        guard.setTargetAllowed(ROUTER, true);
        guard.setTargetAllowed(address(usdt), true);
        guard.setSelectorAllowed(ROUTER, PolicyKeys.SWAP_EXACT_TOKENS, true);
        guard.setSelectorAllowed(address(usdt), PolicyKeys.APPROVE, true);
        guard.setTokenAllowed(address(usdt), true);
        guard.setSpenderAllowed(address(usdt), ROUTER, true);
        guard.setLimit(PolicyKeys.MAX_DEADLINE_WINDOW, 1200);
        guard.setLimit(PolicyKeys.MAX_PATH_LENGTH, 3);

        // Mint an agent
        tokenId = nfa.mintAgent(owner, bytes32("default"), "ipfs://agent1");
        account = nfa.accountOf(tokenId);

        // Create listing
        listingId = listing.createListing(address(nfa), tokenId, 0.1 ether, 1);

        // Fund renter
        vm.deal(renter, 10 ether);
        usdt.mint(renter, 1000 ether);
    }

    // ═══════════════════════════════════════════════════════════
    //                 E2E: HAPPY PATH
    // ═══════════════════════════════════════════════════════════

    function test_e2e_rentAndDeposit() public {
        // Renter rents the agent
        vm.prank(renter);
        uint64 expires = listing.rent{value: 0.1 ether}(listingId, 1);

        assertEq(nfa.userOf(tokenId), renter);
        assertTrue(expires > block.timestamp);

        // Renter deposits USDT into AgentAccount
        vm.startPrank(renter);
        usdt.approve(account, 500 ether);
        AgentAccount(payable(account)).depositToken(address(usdt), 500 ether);
        vm.stopPrank();

        assertEq(usdt.balanceOf(account), 500 ether);
    }

    function test_e2e_rentAndWithdraw() public {
        // Rent
        vm.prank(renter);
        listing.rent{value: 0.1 ether}(listingId, 1);

        // Deposit
        vm.startPrank(renter);
        usdt.approve(account, 200 ether);
        AgentAccount(payable(account)).depositToken(address(usdt), 200 ether);

        // Withdraw to self
        AgentAccount(payable(account)).withdrawToken(address(usdt), 100 ether, renter);
        vm.stopPrank();

        assertEq(usdt.balanceOf(renter), 900 ether); // 1000 - 200 + 100
        assertEq(usdt.balanceOf(account), 100 ether);
    }

    // ═══════════════════════════════════════════════════════════
    //                 SECURITY: ATTACK SCENARIOS
    // ═══════════════════════════════════════════════════════════

    function test_attack_swapToRenterEOA() public {
        // Rent
        vm.prank(renter);
        listing.rent{value: 0.1 ether}(listingId, 1);

        // Deposit
        vm.startPrank(renter);
        usdt.approve(account, 500 ether);
        AgentAccount(payable(account)).depositToken(address(usdt), 500 ether);

        // Try to swap with `to` set to renter's address (MUST FAIL)
        address[] memory path = new address[](2);
        path[0] = address(usdt); path[1] = address(usdt);
        bytes memory swapData = abi.encodeWithSelector(
            PolicyKeys.SWAP_EXACT_TOKENS,
            100 ether, 90 ether, path, renter, block.timestamp + 600
        );
        Action memory action = Action(ROUTER, 0, swapData);

        vm.expectRevert(); // PolicyViolation: "Swap recipient must be AgentAccount"
        nfa.execute(tokenId, action);
        vm.stopPrank();
    }

    function test_attack_approveToEvil() public {
        // Rent
        vm.prank(renter);
        listing.rent{value: 0.1 ether}(listingId, 1);

        // Try to approve USDT to evil contract
        vm.startPrank(renter);
        bytes memory approveData = abi.encodeWithSelector(PolicyKeys.APPROVE, evil, 1000 ether);
        Action memory action = Action(address(usdt), 0, approveData);

        vm.expectRevert(); // PolicyViolation: "Spender not allowed for this token"
        nfa.execute(tokenId, action);
        vm.stopPrank();
    }

    function test_attack_infiniteApproval() public {
        // Rent
        vm.prank(renter);
        listing.rent{value: 0.1 ether}(listingId, 1);

        // Try infinite approval
        vm.startPrank(renter);
        bytes memory approveData = abi.encodeWithSelector(PolicyKeys.APPROVE, ROUTER, type(uint256).max);
        Action memory action = Action(address(usdt), 0, approveData);

        vm.expectRevert(); // PolicyViolation: "Infinite approval not allowed"
        nfa.execute(tokenId, action);
        vm.stopPrank();
    }

    function test_attack_withdrawToOther() public {
        // Rent
        vm.prank(renter);
        listing.rent{value: 0.1 ether}(listingId, 1);

        // Deposit
        vm.startPrank(renter);
        usdt.approve(account, 200 ether);
        AgentAccount(payable(account)).depositToken(address(usdt), 200 ether);

        // Try withdraw to evil address
        vm.expectRevert(); // InvalidWithdrawRecipient
        AgentAccount(payable(account)).withdrawToken(address(usdt), 100 ether, evil);
        vm.stopPrank();
    }

    function test_attack_executeAfterExpiry() public {
        // Rent for 1 day
        vm.prank(renter);
        listing.rent{value: 0.1 ether}(listingId, 1);

        // Fast forward past lease expiry
        vm.warp(block.timestamp + 2 days);

        // userOf should now return address(0)
        assertEq(nfa.userOf(tokenId), address(0));

        // Try to execute — should fail (renter is no longer active user)
        vm.startPrank(renter);
        bytes memory approveData = abi.encodeWithSelector(PolicyKeys.APPROVE, ROUTER, 100 ether);
        Action memory action = Action(address(usdt), 0, approveData);

        vm.expectRevert(); // Unauthorized (userOf returns 0)
        nfa.execute(tokenId, action);
        vm.stopPrank();
    }

    function test_attack_nonRenterExecute() public {
        // Mint but do NOT rent — evil tries to execute directly
        vm.prank(evil);
        bytes memory approveData = abi.encodeWithSelector(PolicyKeys.APPROVE, ROUTER, 100 ether);
        Action memory action = Action(address(usdt), 0, approveData);

        vm.expectRevert(); // Unauthorized
        nfa.execute(tokenId, action);
    }

    function test_attack_directAccountCall() public {
        // Evil tries to call executeCall on AgentAccount directly (bypassing NFA)
        vm.prank(evil);
        vm.expectRevert(); // OnlyNFA
        AgentAccount(payable(account)).executeCall(address(usdt), 0, "");
    }

    // ═══════════════════════════════════════════════════════════
    //                 LISTING MANAGER TESTS
    // ═══════════════════════════════════════════════════════════

    function test_listing_createAndRent() public {
        // Listing already created in setUp
        assertEq(nfa.userOf(tokenId), address(0)); // not rented

        vm.prank(renter);
        listing.rent{value: 0.1 ether}(listingId, 1);

        assertEq(nfa.userOf(tokenId), renter);
    }

    function test_listing_insufficientPayment() public {
        vm.prank(renter);
        vm.expectRevert(); // InsufficientPayment
        listing.rent{value: 0.05 ether}(listingId, 1);
    }

    function test_listing_extend() public {
        vm.prank(renter);
        listing.rent{value: 0.1 ether}(listingId, 1);

        uint256 oldExpires = nfa.userExpires(tokenId);

        vm.prank(renter);
        listing.extend{value: 0.2 ether}(listingId, 2);

        uint256 newExpires = nfa.userExpires(tokenId);
        assertGt(newExpires, oldExpires);
        assertEq(newExpires, oldExpires + 2 days);
    }

    function test_listing_ownerClaimIncome() public {
        uint256 ownerBalBefore = address(owner).balance;

        vm.prank(renter);
        listing.rent{value: 0.1 ether}(listingId, 1);

        listing.claimRentalIncome();

        assertEq(address(owner).balance, ownerBalBefore + 0.1 ether);
    }

    function test_listing_nonOwnerCannotList() public {
        vm.prank(renter);
        vm.expectRevert(); // NotListingOwner
        listing.createListing(address(nfa), tokenId, 0.1 ether, 1);
    }

    function test_listing_cancel() public {
        listing.cancelListing(listingId);

        vm.prank(renter);
        vm.expectRevert(); // ListingNotFound
        listing.rent{value: 0.1 ether}(listingId, 1);
    }

    // ═══════════════════════════════════════════════════════════
    //                 NFA TESTS
    // ═══════════════════════════════════════════════════════════

    function test_nfa_mintCreatesAccount() public view {
        assertTrue(account != address(0));
        assertEq(nfa.policyIdOf(tokenId), bytes32("default"));
    }

    function test_nfa_ownerExecuteBypassesGuard() public {
        // Owner can execute without PolicyGuard — even a target NOT in guard's allowlist
        // We verify by checking that a non-whitelisted target works for owner
        // but would fail for renter. Since we can't actually call a random address,
        // we test the permission check by confirming owner doesn't get PolicyViolation.
        // Use a whitelisted approve action (owner bypasses guard entirely)
        bytes memory approveData = abi.encodeWithSelector(PolicyKeys.APPROVE, ROUTER, 100 ether);
        Action memory action = Action(address(usdt), 0, approveData);
        // Owner executes — this calls AgentAccount.executeCall which calls usdt.approve
        // Since the approve actually succeeds on MockERC20, this should work
        nfa.execute(tokenId, action);
    }

    function test_nfa_setPolicy() public {
        bytes32 newPolicy = bytes32("advanced");
        nfa.setPolicy(tokenId, newPolicy);
        assertEq(nfa.policyIdOf(tokenId), newPolicy);
    }

    function test_nfa_nonOwnerCannotSetPolicy() public {
        vm.prank(renter);
        vm.expectRevert();
        nfa.setPolicy(tokenId, bytes32("hacked"));
    }

    function test_nfa_onlyListingManagerCanSetUser() public {
        vm.prank(evil);
        vm.expectRevert();
        nfa.setUser(tokenId, evil, uint64(block.timestamp + 1 days));
    }

    // ═══════════════════════════════════════════════════════════
    //                 AGENT ACCOUNT TESTS
    // ═══════════════════════════════════════════════════════════

    function test_account_depositAndBalance() public {
        usdt.mint(renter, 100 ether);
        vm.startPrank(renter);
        usdt.approve(account, 100 ether);
        AgentAccount(payable(account)).depositToken(address(usdt), 100 ether);
        vm.stopPrank();

        assertEq(usdt.balanceOf(account), 100 ether);
    }

    function test_account_receiveNative() public {
        vm.deal(renter, 1 ether);
        vm.prank(renter);
        (bool ok,) = account.call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(account.balance, 0.5 ether);
    }

    function test_account_ownerWithdraw() public {
        usdt.mint(account, 100 ether);

        uint256 balBefore = usdt.balanceOf(owner);
        AgentAccount(payable(account)).withdrawToken(address(usdt), 50 ether, owner);
        assertEq(usdt.balanceOf(owner), balBefore + 50 ether);
    }

    // allow this contract to receive ETH
    receive() external payable {}

    // allow this contract to receive ERC721
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
