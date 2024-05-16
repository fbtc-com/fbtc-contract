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

contract DeployScript is BaseScript {
    FBTCMinter public minter;
    FireBridge public bridge;
    FBTC public fbtc;
    FeeModel public feeModel;

    using stdJson for string;

    function deploy(
        string memory chain,
        string memory tag,
        bool useXTN
    ) public {
        vm.createSelectFork(chain);
        vm.startBroadcast(deployerPrivateKey);

        bytes32 _mainChain = useXTN ? ChainCode.XTN : ChainCode.BTC;
        bridge = new FireBridge(owner, _mainChain);

        // Wrap into proxy.
        bridge = FireBridge(
            address(
                new ERC1967Proxy(
                    address(bridge),
                    abi.encodeCall(bridge.initialize, (owner))
                )
            )
        );

        feeModel = new FeeModel(owner);
        bridge.setFeeModel(address(feeModel));
        bridge.setFeeRecipient(owner);

        fbtc = new FBTC(owner, address(bridge));
        bridge.setToken(address(fbtc));

        minter = new FBTCMinter(owner, address(bridge));
        bridge.setMinter(address(minter));

        new FBTCGovernorModule(
            owner,
            address(bridge),
            address(fbtc),
            address(feeModel)
        );

        vm.stopBroadcast();

        saveContractConfig(
            chain,
            tag,
            address(minter),
            address(fbtc),
            address(feeModel),
            address(bridge)
        );
    }

    function deploy2(
        string memory chain,
        string memory tag,
        bool useXTN
    ) public {
        vm.createSelectFork(chain);
        vm.startBroadcast(deployerPrivateKey);

        bytes32 _mainChain = useXTN ? ChainCode.XTN : ChainCode.BTC;

        bytes32 _salt = bytes32(bytes(tag));

        address impl = factory.deploy(
            abi.encodePacked(
                type(FireBridge).creationCode,
                abi.encode(owner, _mainChain)
            ),
            _salt
        );

        // Wrap into proxy.
        bridge = FireBridge(
            factory.deploy(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(impl, abi.encodeCall(bridge.initialize, (owner)))
                ),
                _salt
            )
        );

        feeModel = FeeModel(
            factory.deploy(
                abi.encodePacked(
                    type(FeeModel).creationCode,
                    abi.encode(owner)
                ),
                _salt
            )
        );

        bridge.setFeeModel(address(feeModel));
        bridge.setFeeRecipient(owner);

        fbtc = FBTC(
            factory.deploy(
                abi.encodePacked(
                    type(FBTC).creationCode,
                    abi.encode(owner, address(bridge))
                ),
                _salt
            )
        );

        bridge.setToken(address(fbtc));

        minter = FBTCMinter(
            factory.deploy(
                abi.encodePacked(
                    type(FBTCMinter).creationCode,
                    abi.encode(owner, address(bridge))
                ),
                _salt
            )
        );

        bridge.setMinter(address(minter));

        bytes32[] memory allChains = new bytes32[](2);
        allChains[
            0
        ] = 0x0000000000000000000000000000000000000000000000000000000000aa36a7; // SETH
        allChains[
            1
        ] = 0x000000000000000000000000000000000000000000000000000000000000138b; // SMNT
        bytes32 selfChain = bridge.chain();
        bytes32[] memory dstChains = new bytes32[](allChains.length - 1);

        uint j = 0;
        for (uint i = 0; i < allChains.length; ++i) {
            bytes32 dstChain = allChains[i];
            if (dstChain != selfChain) {
                dstChains[j++] = dstChain;
            }
        }
        bridge.addDstChains(dstChains);

        factory.deploy(
            abi.encodePacked(
                type(FBTCGovernorModule).creationCode,
                abi.encode(
                    owner,
                    address(bridge),
                    address(fbtc),
                    address(feeModel)
                )
            ),
            _salt
        );

        vm.stopBroadcast();

        saveContractConfig(
            chain,
            tag,
            address(minter),
            address(fbtc),
            address(feeModel),
            address(bridge)
        );
    }

    function run() public {
        // deploy2("seth", "test_v1", true);
    }

    function upgradeBridge(
        string memory chain,
        string memory tag,
        bool useXTN
    ) public {
        vm.createSelectFork(chain);
        vm.startBroadcast(deployerPrivateKey);

        bytes32 _mainChain = useXTN ? ChainCode.XTN : ChainCode.BTC;
        FireBridge newImpl = new FireBridge(owner, _mainChain);

        ContractConfig memory c = loadContractConfig(chain, tag);
        FireBridge proxy = FireBridge(c.bridge);
        proxy.upgradeToAndCall(address(newImpl), "");
        console.log("Upgrade new impl");
        console.log(address(newImpl));
    }
}
