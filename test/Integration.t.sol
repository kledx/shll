// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AgentNFA} from "../src/AgentNFA.sol";
import {AgentAccount} from "../src/AgentAccount.sol";
import {PolicyGuardV4} from "../src/PolicyGuardV4.sol";
import {ListingManager} from "../src/ListingManager.sol";
import {Errors} from "../src/libs/Errors.sol";
import {PolicyKeys} from "../src/libs/PolicyKeys.sol";
import {Action} from "../src/types/Action.sol";
import {IBAP578} from "../src/interfaces/IBAP578.sol";
import {IERC4907} from "../src/interfaces/IERC4907.sol";
import {DexWhitelistPolicy} from "../src/policies/DexWhitelistPolicy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title MockERC20 鈥?Minimal ERC20 for testing
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

/// @title MockLogicContract 鈥?Minimal contract for BAP-578 logicAddress tests
contract MockLogicContract {
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}

/// @title Integration Test 鈥?Full E2E flow + BAP-578 tests
contract IntegrationTest is Test {
    AgentNFA public nfa;
    PolicyGuardV4 public guard;
    ListingManager public listing;
    MockERC20 public usdt;
    DexWhitelistPolicy public dexWL;

    address owner = address(this);
    address renter = address(0xBEEF);
    address evil = address(0xDEAD);
    address constant ROUTER = address(0x1111);

    uint256 tokenId;
    address account;
    bytes32 listingId;

    // Default empty metadata for existing tests
    IBAP578.AgentMetadata emptyMetadata;

    // Sample metadata for BAP-578 tests
    IBAP578.AgentMetadata sampleMetadata;

    function setUp() public {
        // Setup sample metadata
        sampleMetadata = IBAP578.AgentMetadata({
            persona: '{"style":"aggressive","risk":"medium"}',
            experience: "DeFi swap specialist on BSC",
            voiceHash: "QmVoiceHash123",
            animationURI: "ipfs://QmAnimation456",
            vaultURI: "ipfs://QmVault789",
            vaultHash: keccak256("vault-content")
        });

        // Deploy contracts
        guard = new PolicyGuardV4();
        nfa = new AgentNFA(address(guard));
        listing = new ListingManager();
        usdt = new MockERC20("USDT", "USDT");
        dexWL = new DexWhitelistPolicy(address(guard), address(nfa));

        // Setup
        nfa.setListingManager(address(listing));
        guard.setAgentNFA(address(nfa));
        guard.setListingManager(address(listing));
        listing.setPolicyGuard(address(guard));

        // Mint an agent with BAP-578 metadata
        tokenId = nfa.mintAgent(
            owner,
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes32("default"),
            nfa.TYPE_LLM_TRADER(),
            "ipfs://agent1",
            sampleMetadata
        );
        account = nfa.accountOf(tokenId);
        nfa.registerTemplate(tokenId, bytes32("default-template"));
        guard.approvePolicyContract(address(dexWL));
        guard.addTemplatePolicy(bytes32("default-template"), address(dexWL));

        // Create template listing
        listingId = listing.createTemplateListing(
            address(nfa),
            tokenId,
            0.1 ether,
            1
        );

        // Fund renter
        vm.deal(renter, 10 ether);
        usdt.mint(renter, 1000 ether);
    }

    function _rentTemplateInstance(
        uint32 daysToRent,
        uint256 value
    ) internal returns (uint256 instanceId, address instanceAccount, uint64 expires) {
        vm.prank(renter);
        instanceId = listing.rentToMintWithParams{value: value}(
            listingId,
            daysToRent,
            0,
            0,
            ""
        );
        instanceAccount = nfa.accountOf(instanceId);
        expires = uint64(nfa.userExpires(instanceId));
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 E2E: HAPPY PATH
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    function test_e2e_rentAndDeposit() public {
        // Renter rents by minting an instance
        (
            uint256 instanceId,
            address instanceAccount,
            uint64 expires
        ) = _rentTemplateInstance(1, 0.1 ether);

        assertEq(nfa.userOf(instanceId), renter);
        assertTrue(expires > block.timestamp);

        // Renter deposits USDT into AgentAccount
        vm.startPrank(renter);
        usdt.approve(instanceAccount, 500 ether);
        AgentAccount(payable(instanceAccount)).depositToken(
            address(usdt),
            500 ether
        );
        vm.stopPrank();

        assertEq(usdt.balanceOf(instanceAccount), 500 ether);
    }

    function test_e2e_renterCanWithdrawOwnInstanceVault() public {
        (, address instanceAccount, ) = _rentTemplateInstance(1, 0.1 ether);

        // Deposit
        vm.startPrank(renter);
        usdt.approve(instanceAccount, 200 ether);
        AgentAccount(payable(instanceAccount)).depositToken(
            address(usdt),
            200 ether
        );

        // Instance owner (renter) can withdraw own vault funds
        AgentAccount(payable(instanceAccount)).withdrawToken(
            address(usdt),
            100 ether,
            renter
        );
        vm.stopPrank();

        assertEq(usdt.balanceOf(renter), 900 ether); // 1000 - 200 + 100
        assertEq(usdt.balanceOf(instanceAccount), 100 ether);
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 SECURITY: ATTACK SCENARIOS
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    // NOTE: V1 PolicyGuard attack tests (swapToRenterEOA, approveToEvil, infiniteApproval)
    // have been removed 鈥?covered by V3_0_Integration.t.sol with composable policies.

    function test_attack_withdrawToOther() public {
        (, address instanceAccount, ) = _rentTemplateInstance(1, 0.1 ether);

        // Deposit
        vm.startPrank(renter);
        usdt.approve(instanceAccount, 200 ether);
        AgentAccount(payable(instanceAccount)).depositToken(
            address(usdt),
            200 ether
        );

        // Try withdraw to evil address
        vm.expectRevert(); // InvalidWithdrawRecipient
        AgentAccount(payable(instanceAccount)).withdrawToken(
            address(usdt),
            100 ether,
            evil
        );
        vm.stopPrank();
    }

    function test_instanceOwnerCanExecuteAfterLeaseExpiry() public {
        (uint256 instanceId, , ) = _rentTemplateInstance(1, 0.1 ether);

        // Fast forward past lease expiry
        vm.warp(block.timestamp + 2 days);

        // userOf should now return address(0)
        assertEq(nfa.userOf(instanceId), address(0));

        // Try to execute 鈥?should fail (renter is no longer active user)
        vm.startPrank(renter);
        bytes memory approveData = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            ROUTER,
            100 ether
        );
        Action memory action = Action(address(usdt), 0, approveData);

        nfa.execute(instanceId, action);
        vm.stopPrank();
    }

    function test_attack_nonRenterExecute() public {
        // Mint but do NOT rent 鈥?evil tries to execute directly
        vm.prank(evil);
        bytes memory approveData = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            ROUTER,
            100 ether
        );
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

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 LISTING MANAGER TESTS
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    function test_listing_createAndRent() public {
        // Listing already created in setUp
        assertEq(nfa.userOf(tokenId), address(0)); // template token not rented

        (uint256 instanceId, , ) = _rentTemplateInstance(1, 0.1 ether);
        assertEq(nfa.userOf(instanceId), renter);
    }

    function test_listing_insufficientPayment() public {
        vm.prank(renter);
        vm.expectRevert(); // InsufficientPayment
        listing.rentToMintWithParams{value: 0.05 ether}(listingId, 1, 0, 0, "");
    }

    function test_listing_ownerClaimIncome() public {
        uint256 ownerBalBefore = address(owner).balance;

        _rentTemplateInstance(1, 0.1 ether);

        listing.claimRentalIncome();

        assertEq(address(owner).balance, ownerBalBefore + 0.1 ether);
    }

    function test_listing_nonOwnerCannotList() public {
        vm.prank(renter);
        vm.expectRevert(); // NotListingOwner
        listing.createTemplateListing(address(nfa), tokenId, 0.1 ether, 1);
    }

    function test_listing_cancel() public {
        listing.cancelListing(listingId);

        vm.prank(renter);
        vm.expectRevert(); // ListingNotFound
        listing.rentToMintWithParams{value: 0.1 ether}(listingId, 1, 0, 0, "");
    }

    function test_listing_transfer_oldOwnerCannotCancel_newOwnerCan() public {
        address newOwner = address(0xCAFE);
        nfa.transferFrom(owner, newOwner, tokenId);

        vm.expectRevert(); // NotListingOwner after owner sync
        listing.cancelListing(listingId);

        vm.prank(newOwner);
        listing.cancelListing(listingId);
    }

    function test_listing_transfer_rent_incomeGoesToCurrentOwner() public {
        address newOwner = address(0xCAFE);
        nfa.transferFrom(owner, newOwner, tokenId);

        _rentTemplateInstance(1, 0.1 ether);

        assertEq(listing.pendingWithdrawals(newOwner), 0.1 ether);
        assertEq(listing.pendingWithdrawals(owner), 0);
    }

    function test_template_rentToMint_maxDaysEnforced() public {
        guard.setAgentNFA(address(nfa));
        guard.setListingManager(address(listing));
        listing.setPolicyGuard(address(guard));

        uint256 templateId = nfa.mintAgent(
            owner,
            bytes32("default"),
            nfa.TYPE_LLM_TRADER(),
            "ipfs://template-max-days",
            sampleMetadata
        );
        nfa.registerTemplate(templateId, bytes32("template-max-days"));
        guard.addTemplatePolicy(bytes32("template-max-days"), address(dexWL));

        bytes32 tplListingId = listing.createTemplateListing(
            address(nfa),
            templateId,
            0.1 ether,
            1
        );
        listing.setListingConfig(tplListingId, 3);

        vm.prank(renter);
        vm.expectRevert(); // MaxDaysExceeded
        listing.rentToMintWithParams{value: 0.5 ether}(
            tplListingId,
            5,
            0,
            0,
            ""
        );

        vm.prank(renter);
        uint256 instanceId = listing.rentToMintWithParams{value: 0.3 ether}(
            tplListingId,
            3,
            0,
            0,
            ""
        );
        assertEq(nfa.userOf(instanceId), renter);
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 NFA TESTS
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    function test_nfa_mintCreatesAccount() public view {
        assertTrue(account != address(0));
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(nfa.policyIdOf(tokenId), bytes32("default"));
    }

    function test_nfa_ownerExecuteBypassesGuard() public {
        bytes memory approveData = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            ROUTER,
            100 ether
        );
        Action memory action = Action(address(usdt), 0, approveData);
        nfa.execute(tokenId, action);
    }

    function test_nfa_setPolicy() public {
        uint256 standaloneToken = nfa.mintAgent(
            owner,
            bytes32("default"),
            nfa.TYPE_LLM_TRADER(),
            "ipfs://standalone",
            sampleMetadata
        );

        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 newPolicy = bytes32("advanced");
        nfa.setPolicy(standaloneToken, newPolicy);
        assertEq(nfa.policyIdOf(standaloneToken), newPolicy);
    }

    function test_nfa_nonOwnerCannotSetPolicy() public {
        vm.prank(renter);
        vm.expectRevert();
        // forge-lint: disable-next-line(unsafe-typecast)
        nfa.setPolicy(tokenId, bytes32("hacked"));
    }

    function test_nfa_onlyListingManagerCanSetUser() public {
        vm.prank(evil);
        vm.expectRevert();
        nfa.setUser(tokenId, evil, uint64(block.timestamp + 1 days));
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 AGENT ACCOUNT TESTS
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

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
        (bool ok, ) = account.call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(account.balance, 0.5 ether);
    }

    function test_account_instanceOwnerCanWithdrawNative() public {
        (, address instanceAccount, ) = _rentTemplateInstance(1, 0.1 ether);
        vm.deal(instanceAccount, 1 ether);

        vm.prank(renter);
        AgentAccount(payable(instanceAccount)).withdrawNative(0.1 ether, renter);
        assertEq(instanceAccount.balance, 0.9 ether);
    }

    function test_account_ownerWithdraw() public {
        usdt.mint(account, 100 ether);

        uint256 balBefore = usdt.balanceOf(owner);
        AgentAccount(payable(account)).withdrawToken(
            address(usdt),
            50 ether,
            owner
        );
        assertEq(usdt.balanceOf(owner), balBefore + 50 ether);
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 BAP-578: METADATA TESTS
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    function test_bap578_getAgentMetadata() public view {
        IBAP578.AgentMetadata memory meta = nfa.getAgentMetadata(tokenId);
        assertEq(meta.persona, sampleMetadata.persona);
        assertEq(meta.experience, sampleMetadata.experience);
        assertEq(meta.voiceHash, sampleMetadata.voiceHash);
        assertEq(meta.animationURI, sampleMetadata.animationURI);
        assertEq(meta.vaultURI, sampleMetadata.vaultURI);
        assertEq(meta.vaultHash, sampleMetadata.vaultHash);
    }

    function test_bap578_updateMetadata() public {
        IBAP578.AgentMetadata memory newMeta = IBAP578.AgentMetadata({
            persona: '{"style":"conservative","risk":"low"}',
            experience: "DeFi lending specialist",
            voiceHash: "QmNewVoice",
            animationURI: "ipfs://QmNewAnim",
            vaultURI: "ipfs://QmNewVault",
            vaultHash: keccak256("new-vault")
        });

        nfa.updateAgentMetadata(tokenId, newMeta);

        IBAP578.AgentMetadata memory fetched = nfa.getAgentMetadata(tokenId);
        assertEq(fetched.persona, newMeta.persona);
        assertEq(fetched.experience, newMeta.experience);
    }

    function test_bap578_updateMetadata_onlyOwner() public {
        vm.prank(renter);
        vm.expectRevert(); // OnlyOwner
        nfa.updateAgentMetadata(tokenId, sampleMetadata);
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 BAP-578: STATE TESTS
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    function test_bap578_getState() public view {
        IBAP578.State memory state = nfa.getState(tokenId);
        assertEq(state.balance, 0); // no BNB in account yet
        assertTrue(state.status == IBAP578.Status.Active);
        assertEq(state.owner, owner);
        assertEq(state.logicAddress, address(0));
        assertEq(state.lastActionTimestamp, 0);
    }

    function test_bap578_getState_withBalance() public {
        // Fund the agent account
        vm.deal(address(this), 1 ether);
        nfa.fundAgent{value: 0.5 ether}(tokenId);

        IBAP578.State memory state = nfa.getState(tokenId);
        assertEq(state.balance, 0.5 ether);
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 BAP-578: FUND AGENT TESTS
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    function test_bap578_fundAgent() public {
        vm.deal(renter, 2 ether);
        vm.prank(renter);
        nfa.fundAgent{value: 1 ether}(tokenId);

        assertEq(account.balance, 1 ether);
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 BAP-578: LOGIC ADDRESS TESTS
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    function test_bap578_setLogicAddress() public {
        MockLogicContract logic = new MockLogicContract();
        nfa.setLogicAddress(tokenId, address(logic));
        assertEq(nfa.logicAddressOf(tokenId), address(logic));
    }

    function test_bap578_setLogicAddress_clear() public {
        MockLogicContract logic = new MockLogicContract();
        nfa.setLogicAddress(tokenId, address(logic));
        nfa.setLogicAddress(tokenId, address(0)); // clear
        assertEq(nfa.logicAddressOf(tokenId), address(0));
    }

    function test_bap578_setLogicAddress_rejectEOA() public {
        // EOA (non-contract) should be rejected
        vm.expectRevert(); // InvalidLogicAddress
        nfa.setLogicAddress(tokenId, address(0xCAFE));
    }

    function test_bap578_setLogicAddress_onlyOwner() public {
        MockLogicContract logic = new MockLogicContract();
        vm.prank(renter);
        vm.expectRevert(); // OnlyOwner
        nfa.setLogicAddress(tokenId, address(logic));
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 BAP-578: LIFECYCLE TESTS
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    function test_bap578_pauseAgent() public {
        nfa.pauseAgent(tokenId);
        assertTrue(nfa.agentStatus(tokenId) == IBAP578.Status.Paused);
    }

    function test_bap578_pauseAgent_blocksExecute() public {
        nfa.pauseAgent(tokenId);

        // Owner tries to execute on paused agent
        bytes memory approveData = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            ROUTER,
            100 ether
        );
        Action memory action = Action(address(usdt), 0, approveData);

        vm.expectRevert(); // AgentPaused
        nfa.execute(tokenId, action);
    }

    function test_bap578_unpauseAgent() public {
        nfa.pauseAgent(tokenId);
        nfa.unpauseAgent(tokenId);
        assertTrue(nfa.agentStatus(tokenId) == IBAP578.Status.Active);

        // Should be able to execute again
        bytes memory approveData = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            ROUTER,
            100 ether
        );
        Action memory action = Action(address(usdt), 0, approveData);
        nfa.execute(tokenId, action);
    }

    function test_bap578_terminateAgent() public {
        nfa.terminate(tokenId);
        assertTrue(nfa.agentStatus(tokenId) == IBAP578.Status.Terminated);
    }

    function test_bap578_terminateAgent_blocksExecute() public {
        nfa.terminate(tokenId);

        bytes memory approveData = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            ROUTER,
            100 ether
        );
        Action memory action = Action(address(usdt), 0, approveData);

        vm.expectRevert(); // AgentTerminated
        nfa.execute(tokenId, action);
    }

    function test_bap578_terminateAgent_irreversible() public {
        nfa.terminate(tokenId);

        // Cannot unpause a terminated agent
        vm.expectRevert(); // AgentTerminated
        nfa.unpauseAgent(tokenId);

        // Cannot pause again either (already terminated)
        vm.expectRevert(); // AgentTerminated
        nfa.pauseAgent(tokenId);
    }

    function test_bap578_pauseAgent_onlyOwner() public {
        vm.prank(renter);
        vm.expectRevert(); // OnlyOwner
        nfa.pauseAgent(tokenId);
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 BAP-578: EXECUTE ACTION TESTS
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    function test_bap578_executeAction() public {
        // Encode Action as bytes for BAP-578 interface
        bytes memory approveData = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            ROUTER,
            100 ether
        );
        Action memory action = Action(address(usdt), 0, approveData);
        bytes memory encodedAction = abi.encode(action);

        nfa.executeAction(tokenId, encodedAction);
    }

    function test_bap578_executeAction_updatesTimestamp() public {
        bytes memory approveData = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            ROUTER,
            100 ether
        );
        Action memory action = Action(address(usdt), 0, approveData);
        bytes memory encodedAction = abi.encode(action);

        vm.warp(12345);
        nfa.executeAction(tokenId, encodedAction);

        IBAP578.State memory state = nfa.getState(tokenId);
        assertEq(state.lastActionTimestamp, 12345);
    }

    function test_pause_blocks_executeAction() public {
        bytes memory approveData = abi.encodeWithSelector(
            PolicyKeys.APPROVE,
            ROUTER,
            100 ether
        );
        Action memory action = Action(address(usdt), 0, approveData);
        bytes memory encodedAction = abi.encode(action);

        nfa.pause();
        vm.expectRevert(); // Pausable: paused
        nfa.executeAction(tokenId, encodedAction);
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 BAP-578: INTERFACE SUPPORT
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    function test_bap578_supportsInterface() public view {
        assertTrue(nfa.supportsInterface(type(IBAP578).interfaceId));
        assertTrue(nfa.supportsInterface(type(IERC4907).interfaceId));
        // ERC-721 interface
        assertTrue(nfa.supportsInterface(0x80ac58cd));
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //                 RENTAL GUARD TESTS
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    function test_guard_maxDaysEnforced() public {
        listing.setListingConfig(listingId, 3);
        vm.prank(renter);
        vm.expectRevert(); // MaxDaysExceeded
        listing.rentToMintWithParams{value: 0.5 ether}(listingId, 5, 0, 0, "");
        (uint256 instanceId, , ) = _rentTemplateInstance(3, 0.3 ether);
        assertEq(nfa.userOf(instanceId), renter);
    }

    function test_guard_pauseRenting() public {
        listing.pauseRenting(listingId);
        vm.prank(renter);
        vm.expectRevert(Errors.RentingPaused.selector);
        listing.rentToMintWithParams{value: 0.1 ether}(listingId, 1, 0, 0, "");
    }

    function test_guard_resumeRenting() public {
        listing.pauseRenting(listingId);
        listing.resumeRenting(listingId);
        (uint256 instanceId, , ) = _rentTemplateInstance(1, 0.1 ether);
        assertEq(nfa.userOf(instanceId), renter);
    }

    // allow this contract to receive ETH
    receive() external payable {}

    // allow this contract to receive ERC721
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}


