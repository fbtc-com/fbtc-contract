// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract BaseScript is Script {
    function setUp() public {}

    function getPath(string memory file) public view returns (string memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script/deployments/", file);
        return path;
    }
}
