// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaseScript, stdJson, console} from "./Base.sol";

import {Operation} from "../contracts/Common.sol";
import {FBTC} from "../contracts/FBTC.sol";
import {FireBridge, ChainCode} from "../contracts/FireBridge.sol";
import {FBTCMinter} from "../contracts/FBTCMinter.sol";
import {FeeModel} from "../contracts/FeeModel.sol";
import {FBTCGovernorModule} from "../contracts/FBTCGovernorModule.sol";
import {FeeUpdaterModule} from "../test/FeeUpdaterModule.sol";
import {OneStepDeploy, DeployConfig, IFactory, FactoryLib, DeployedContracts} from "./OneStepDeploy.sol";

contract DeployScript is BaseScript {
    using stdJson for string;
    using FactoryLib for IFactory;

    function saveContractConfig(
        string memory name,
        DeployedContracts memory d
    ) internal {
        string memory path = getPath(
            string.concat("addresses/", name, ".json")
        );

        string memory json = "key";
        json.serialize("1_minter", d.minter);
        json.serialize("2_fbtc", d.fbtc);
        json.serialize("3_fee", d.fee);
        json.serialize("4_bridge", d.bridge);
        json.serialize("5_module", d.module);
        string memory tmp = json.serialize("6_updater", d.updater);
        tmp.write(path);
    }

    function deployOneStep(
        string memory chain,
        string memory conf,
        string memory versionSalt
    ) public {
        string memory json = vm.readFile(getPath(string.concat(conf, ".json")));

        vm.createSelectFork(chain);
        vm.startBroadcast(json.readAddress(".deployer"));

        bytes32[] memory allChains = json.readBytes32Array(".dstChains");
        bytes32 selfChain = bytes32(block.chainid);
        uint length = 0;
        for (uint i = 0; i < allChains.length; ++i) {
            bytes32 dstChain = allChains[i];
            if (dstChain != selfChain) {
                ++length;
            }
        }
        bytes32[] memory dstChains = new bytes32[](length);
        uint j = 0;
        for (uint i = 0; i < allChains.length; ++i) {
            bytes32 dstChain = allChains[i];
            if (dstChain != selfChain) {
                dstChains[j++] = dstChain;
            }
        }

        bytes32 saltSeed = bytes32(bytes(versionSalt));
        IFactory factory = IFactory(json.readAddress(".factory"));
        DeployConfig memory c = DeployConfig({
            factory: address(factory),
            tag: saltSeed,
            mainChain: json.readBytes32(".mainChain"),
            owner: json.readAddress(".owner"),
            feeRecipientAndUpdater: json.readAddress(".feeRecipientAndUpdater"),
            mintOperator: json.readAddress(".mintOperator"),
            burnOperator: json.readAddress(".burnOperator"),
            crosschainOperator: json.readAddress(".crosschainOperator"),
            pauserAndLockers: json.readAddressArray(".pauserAndLockers"),
            userManager: json.readAddress(".userManager"),
            chainMananger: json.readAddress(".chainMananger"),
            feeUpdater: json.readAddress(".feeUpdater"),
            fireBridgeCode: type(FireBridge).creationCode,
            proxyCode: type(ERC1967Proxy).creationCode,
            fbtcCode: type(FBTC).creationCode,
            feeModelCode: type(FeeModel).creationCode,
            minterCode: type(FBTCMinter).creationCode,
            governorModuleCode: type(FBTCGovernorModule).creationCode,
            feeUpdatorCode: type(FeeUpdaterModule).creationCode,
            dstChains: dstChains
        });

        address osd = factory.doDeploy(
            uint256(saltSeed) - 1,
            type(OneStepDeploy).creationCode
        );

        DeployedContracts memory d = OneStepDeploy(osd).deploy(c);
        saveContractConfig(
            string.concat(versionSalt, "_", chain, "_", conf),
            d
        );
    }

    function deployFBTCModule(
        string memory chain,
        string memory conf,
        string memory versionSalt
    ) public {
        string memory json = vm.readFile(getPath(string.concat(conf, ".json")));

        address deployer = json.readAddress(".deployer");
        address owner = json.readAddress(".owner");

        vm.createSelectFork(chain);
        vm.startBroadcast(deployer);

        uint256 saltSeed = uint256(bytes32(bytes(versionSalt)));
        address factory = json.readAddress(".factory");

        FBTCGovernorModule gov = FBTCGovernorModule(
            IFactory(factory).doDeploy(
                saltSeed,
                abi.encodePacked(
                    type(FBTCGovernorModule).creationCode,
                    abi.encode(
                        deployer,
                        0xC96dE26018A54D51c097160568752c4E3BD6C364
                    )
                )
            )
        );
        gov.transferOwnership(owner);

        bytes32 FBTC_PAUSER_ROLE = gov.FBTC_PAUSER_ROLE();
        bytes32 LOCKER_ROLE = gov.LOCKER_ROLE();
        bytes32 BRIDGE_PAUSER_ROLE = gov.BRIDGE_PAUSER_ROLE();

        address[] memory pauserAndLockers = json.readAddressArray(
            ".pauserAndLockers"
        );
        for (uint i = 0; i < pauserAndLockers.length; ++i) {
            address pauserAndLocker = pauserAndLockers[i];
            gov.grantRole(FBTC_PAUSER_ROLE, pauserAndLocker);
            gov.grantRole(LOCKER_ROLE, pauserAndLocker);
            gov.grantRole(BRIDGE_PAUSER_ROLE, pauserAndLocker);
        }
        gov.grantRole(
            gov.USER_MANAGER_ROLE(),
            json.readAddress(".userManager")
        );
        gov.grantRole(
            gov.CHAIN_MANAGER_ROLE(),
            json.readAddress(".chainMananger")
        );
        gov.grantRole(
            gov.FEE_UPDATER_ROLE(),
            json.readAddress(".feeRecipientAndUpdater")
        );
    }

    function deployUpdaterModule(
        string memory chain,
        string memory salt,
        address factory,
        address fbtcModule,
        address tempOwner,
        address safe,
        address updaterOperator
    ) public {
        vm.createSelectFork(chain);
        vm.startBroadcast(tempOwner);

        uint256 saltSeed = uint256(bytes32(bytes(salt)));

        FeeUpdaterModule updater = FeeUpdaterModule(
            IFactory(factory).doDeploy(
                saltSeed,
                abi.encodePacked(
                    type(FeeUpdaterModule).creationCode,
                    abi.encode(tempOwner)
                )
            )
        );
        updater.setFBTCGovernorModule(fbtcModule);
        updater.grantRole(updater.FEE_UPDATER_ROLE(), updaterOperator);
        updater.transferOwnership(safe);
    }

    function run() public {
        console.log("Nothing to do");
    }
}
