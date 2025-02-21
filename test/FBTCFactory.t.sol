// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {FBTCFactory} from "../script/FBTCFactory.sol";

contract FactoryTest is Test {
    FBTCFactory public factory;
    address constant ZERO = address(0);

    function setUp() public {
        factory = new FBTCFactory();
    }

    function test_Factory() public {
        bytes
            memory code = hex"67_36_3d_3d_37_36_3d_34_f0_3d_52_60_08_60_18_f3";

        bytes32 salt = bytes32(uint256(1));
        address deployer = address(this);

        console.log("factory:", address(factory));
        console.log("deployer:", deployer);

        address addr = factory.deploy(
            FBTCFactory.DeployType.Create2,
            salt,
            code
        );

        console.log("create2:", addr);
        assertEq(
            addr,
            factory.getAddress(FBTCFactory.DeployType.Create2, salt, ZERO, code)
        );
        assertEq(addr, factory.getCreate2Address(salt, ZERO, code));

        addr = factory.deploy(FBTCFactory.DeployType.Create3, salt, code);
        console.log("create3:", addr);
        assertEq(
            addr,
            factory.getAddress(FBTCFactory.DeployType.Create3, salt, ZERO, "")
        );
        assertEq(addr, factory.getCreate3Address(salt, ZERO));

        addr = factory.deploy(
            FBTCFactory.DeployType.Create2WithSender,
            salt,
            code
        );
        console.log("create2withsender:", addr);
        assertEq(
            addr,
            factory.getAddress(
                FBTCFactory.DeployType.Create2WithSender,
                salt,
                deployer,
                code
            )
        );
        assertEq(addr, factory.getCreate2Address(salt, deployer, code));

        addr = factory.deploy(
            FBTCFactory.DeployType.Create3WithSender,
            salt,
            code
        );
        console.log("create3withsender:", addr);
        assertEq(
            addr,
            factory.getAddress(
                FBTCFactory.DeployType.Create3WithSender,
                salt,
                deployer,
                ""
            )
        );
        assertEq(addr, factory.getCreate3Address(salt, deployer));

        vm.expectRevert("Create3 proxy failed");
        factory.deploy(FBTCFactory.DeployType.Create3WithSender, salt, code);
    }
}
