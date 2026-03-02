// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IProtocolRegistry {
    struct ProtocolConfig {
        string name;
        bytes4[] allSelectors;
        bytes4[] buySelectors;
        uint8 receiverPattern;
        address[] targets;
        bool active;
    }

    function registerProtocol(
        bytes32 id,
        ProtocolConfig calldata config
    ) external;
    function getProtocol(
        bytes32 id
    ) external view returns (ProtocolConfig memory);
    function listProtocols() external view returns (bytes32[] memory);
    function protocolCount() external view returns (uint256);
}

/// @title RegisterFourMeme — Register Four.meme selectors in ProtocolRegistry
/// @notice Registers buyTokenAMAP, purchaseTokenAMAP, sellToken, and approve
///         so ReceiverGuardV2, DeFiGuardV2, and SpendingLimitV2 all allow
///         Four.meme bonding curve trading.
contract RegisterFourMeme is Script {
    address constant REGISTRY = 0x1A5EA54a3beaf4fba75f73581cf6A945746E6DF1;

    // Four.meme contracts (BSC Mainnet)
    address constant TOKEN_MANAGER_V1 =
        0xEC4549caDcE5DA21Df6E6422d448034B5233bFbC;
    address constant TOKEN_MANAGER_V2 =
        0x5c952063c7fc8610FFDB798152D69F0B9550762b;

    // Selectors
    // V2: buyTokenAMAP(address,uint256,uint256)
    bytes4 constant BUY_TOKEN_AMAP_3P = 0x87f27655;
    // V2: sellToken(address,uint256)
    bytes4 constant SELL_TOKEN_2P = 0xf464e7db;
    // V1: purchaseTokenAMAP(address,uint256,uint256)
    bytes4 constant PURCHASE_TOKEN_AMAP_3P = 0x3deec419;
    // ERC20: approve(address,uint256) — needed before sellToken
    bytes4 constant APPROVE = 0x095ea7b3;

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(REGISTRY);

        bytes32 protocolId = keccak256("FOUR_MEME");
        console.log("Protocol ID (FOUR_MEME):", uint256(protocolId));
        console.log("Protocol count before:", registry.protocolCount());

        // Build config
        bytes4[] memory allSelectors = new bytes4[](4);
        allSelectors[0] = BUY_TOKEN_AMAP_3P;
        allSelectors[1] = SELL_TOKEN_2P;
        allSelectors[2] = PURCHASE_TOKEN_AMAP_3P;
        allSelectors[3] = APPROVE;

        bytes4[] memory buySelectors = new bytes4[](2);
        buySelectors[0] = BUY_TOKEN_AMAP_3P;
        buySelectors[1] = PURCHASE_TOKEN_AMAP_3P;

        address[] memory targets = new address[](2);
        targets[0] = TOKEN_MANAGER_V1;
        targets[1] = TOKEN_MANAGER_V2;

        IProtocolRegistry.ProtocolConfig memory config = IProtocolRegistry
            .ProtocolConfig({
                name: "Four.meme",
                allSelectors: allSelectors,
                buySelectors: buySelectors,
                receiverPattern: 5, // pass-through (no recipient in calldata, tokens go to msg.sender/vault)
                targets: targets,
                active: true
            });

        vm.startBroadcast();
        registry.registerProtocol(protocolId, config);
        vm.stopBroadcast();

        // Verify
        IProtocolRegistry.ProtocolConfig memory registered = registry
            .getProtocol(protocolId);
        console.log("\n=== Verification ===");
        console.log("Name:", registered.name);
        console.log("Active:", registered.active);
        console.log("Receiver Pattern:", registered.receiverPattern);
        console.log("All Selectors count:", registered.allSelectors.length);
        console.log("Buy Selectors count:", registered.buySelectors.length);
        console.log("Targets count:", registered.targets.length);
        console.log("Protocol count after:", registry.protocolCount());
    }
}
