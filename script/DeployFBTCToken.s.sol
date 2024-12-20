// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Script, console2 as console} from "forge-std/Script.sol";
import {FBTC} from "../contracts/FBTC.sol";

contract FBTCScript is Script {

    function deployFBTC() external {
        address owner = vm.envAddress("OWNER_ADDRESS");
        address bridge = vm.envAddress("BRIDGE_ADDRESS");

        require(owner != address(0), "Owner address must be set");
        require(bridge != address(0), "Bridge address must be set");

        vm.startBroadcast();

        FBTC fbtc = new FBTC(owner, bridge);
        console.log("FBTC contract deployed at:", address(fbtc));

        vm.stopBroadcast();
    }

    function setBridge() external {
        address fbtcAddress = vm.envAddress("FBTC_ADDRESS");
        address newBridge = vm.envAddress("NEW_BRIDGE_ADDRESS");

        require(fbtcAddress != address(0), "FBTC contract address must be set");
        require(newBridge != address(0), "New bridge address must be set");

        vm.startBroadcast();

        FBTC fbtc = FBTC(fbtcAddress);
        fbtc.setBridge(newBridge);

        console.log("FBTC bridge updated to:", newBridge);

        vm.stopBroadcast();
    }
}