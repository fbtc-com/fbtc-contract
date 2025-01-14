// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Operation} from "../contracts/Common.sol";
import {FBTC} from "../contracts/FBTC.sol";
import {FireBridge, ChainCode} from "../contracts/FireBridge.sol";
import {FBTCMinter} from "../contracts/FBTCMinter.sol";
import {FeeModel} from "../contracts/FeeModel.sol";
import {FBTCGovernorModule} from "../contracts/FBTCGovernorModule.sol";
import {FeeUpdaterModule} from "../test/FeeUpdaterModule.sol";

interface IFactory {
    function deploy(
        uint8 typ,
        bytes32 salt,
        bytes memory initCode
    ) external returns (address);

    function getAddress(
        uint8 typ,
        bytes32 salt,
        address sender,
        bytes calldata initCode
    ) external view returns (address _contract);
}

library FactoryLib {
    function doDeploy(
        IFactory factory,
        uint256 salt,
        bytes memory code
    ) internal returns (address) {
        return factory.deploy(3, bytes32(salt), code);
    }
}

struct DeployConfig {
    address factory;
    bytes32 tag;
    bytes32 mainChain;
    address owner;
    address feeRecipientAndUpdater;
    // Minter
    address mintOperator;
    address burnOperator;
    address crosschainOperator;
    // GovernorModule
    address[] pauserAndLockers;
    address userManager;
    address chainMananger;
    address feeUpdater;
    // Contract code.
    bytes fireBridgeCode;
    bytes proxyCode;
    bytes fbtcCode;
    bytes feeModelCode;
    bytes minterCode;
    bytes governorModuleCode;
    bytes feeUpdatorCode;
    bytes32[] dstChains;
}

struct DeployedContracts {
    address bridge;
    address fee;
    address fbtc;
    address minter;
    address module;
    address updater;
}

contract OneStepDeploy {
    using FactoryLib for IFactory;

    address public deployer;

    constructor() {
        deployer = tx.origin;
    }

    function emergencyCall(
        address to,
        bytes calldata data,
        uint256 value
    ) external payable {
        require(deployer == tx.origin, "Only deployer");
        (bool success, ) = to.call{value: value}(data);
        require(success, "Call failed");
    }

    function deploy(
        DeployConfig memory c
    ) external returns (DeployedContracts memory) {
        require(deployer == tx.origin, "Only deployer");
        IFactory factory = IFactory(c.factory);

        uint256 saltStart = uint256(c.tag);
        address owner = c.owner;
        address tempOwner = address(this);

        ///////////////////////////
        // FireBridge
        address impl = factory.doDeploy(
            saltStart++,
            abi.encodePacked(c.fireBridgeCode, abi.encode(owner, c.mainChain))
        );

        address bridgeAddress = factory.doDeploy(
            saltStart++,
            abi.encodePacked(
                c.proxyCode,
                abi.encode(
                    impl,
                    abi.encodeCall(FireBridge.initialize, (tempOwner))
                )
            )
        );

        FireBridge bridge = FireBridge(bridgeAddress);
        bridge.addDstChains(c.dstChains);
        bridge.setFeeRecipient(c.feeRecipientAndUpdater);
        bridge.transferOwnership(owner);

        ///////////////////////////
        // FeeModel
        FeeModel feeModel = FeeModel(
            factory.doDeploy(
                saltStart++,
                abi.encodePacked(c.feeModelCode, abi.encode(tempOwner))
            )
        );
        feeModel.transferOwnership(owner);

        bridge.setFeeModel(address(feeModel));

        // Cross-chain fee: Min 0.0001 FBTC, Rate 0.01%
        uint32 FEE_RATE_BASE = feeModel.FEE_RATE_BASE();
        FeeModel.FeeTier[] memory tiers = new FeeModel.FeeTier[](1);
        tiers[0] = FeeModel.FeeTier(
            type(uint224).max,
            FEE_RATE_BASE / 10000 // 0.01%
        );
        FeeModel.FeeConfig memory _config = FeeModel.FeeConfig(
            type(uint256).max,
            0.0001 * 1e8, // 0.0001 FBTC
            tiers
        );

        feeModel.setDefaultFeeConfig(Operation.CrosschainRequest, _config);

        // No mint fee
        _config.minFee = 0;
        tiers[0].feeRate = 0;
        feeModel.setDefaultFeeConfig(Operation.Mint, _config);

        // Burn fee:
        _config.minFee = 0.01 * 1e8; // 0.01 BTC
        _config.tiers = new FeeModel.FeeTier[](4);

        uint224 BTC_UNIT = 1e8;
        // < 200 BTC, 0.20%
        _config.tiers[0] = FeeModel.FeeTier(
            200 * BTC_UNIT,
            (FEE_RATE_BASE * 20) / 10000
        );
        // >=200 <500 BTC, 0.16%
        _config.tiers[1] = FeeModel.FeeTier(
            500 * BTC_UNIT,
            (FEE_RATE_BASE * 16) / 10000
        );
        // >=500 <1000 BTC, 0.12%
        _config.tiers[2] = FeeModel.FeeTier(
            1000 * BTC_UNIT,
            (FEE_RATE_BASE * 12) / 10000
        );
        // >=1000 BTC, 0.10%
        _config.tiers[3] = FeeModel.FeeTier(
            type(uint224).max,
            (FEE_RATE_BASE * 10) / 10000
        );

        feeModel.setDefaultFeeConfig(Operation.Burn, _config);

        ///////////////////////////
        // FBTC
        address fbtcAddress = factory.doDeploy(
            saltStart++,
            abi.encodePacked(c.fbtcCode, abi.encode(tempOwner, bridgeAddress))
        );
        FBTC(fbtcAddress).transferOwnership(owner);

        bridge.setToken(fbtcAddress);

        ///////////////////////////
        // FBTCMinter
        FBTCMinter minter = FBTCMinter(
            factory.doDeploy(
                saltStart++,
                abi.encodePacked(
                    c.minterCode,
                    abi.encode(tempOwner, bridgeAddress)
                )
            )
        );
        minter.transferOwnership(owner);

        bridge.setMinter(address(minter));

        minter.grantRole(minter.MINT_ROLE(), c.mintOperator);
        minter.grantRole(minter.BURN_ROLE(), c.burnOperator);
        minter.grantRole(minter.CROSSCHAIN_ROLE(), c.crosschainOperator);

        ///////////////////////////
        // GovermentModule
        FBTCGovernorModule gov = FBTCGovernorModule(
            factory.doDeploy(
                saltStart++,
                abi.encodePacked(
                    c.governorModuleCode,
                    abi.encode(tempOwner, fbtcAddress)
                )
            )
        );
        gov.transferOwnership(owner);

        bytes32 FBTC_PAUSER_ROLE = gov.FBTC_PAUSER_ROLE();
        bytes32 LOCKER_ROLE = gov.LOCKER_ROLE();
        bytes32 BRIDGE_PAUSER_ROLE = gov.BRIDGE_PAUSER_ROLE();

        for (uint i = 0; i < c.pauserAndLockers.length; ++i) {
            address pauserAndLocker = c.pauserAndLockers[i];
            gov.grantRole(FBTC_PAUSER_ROLE, pauserAndLocker);
            gov.grantRole(LOCKER_ROLE, pauserAndLocker);
            gov.grantRole(BRIDGE_PAUSER_ROLE, pauserAndLocker);
        }
        gov.grantRole(gov.USER_MANAGER_ROLE(), c.userManager);
        gov.grantRole(gov.CHAIN_MANAGER_ROLE(), c.chainMananger);
        gov.grantRole(gov.FEE_UPDATER_ROLE(), c.feeRecipientAndUpdater);

        ///////////////////////////
        // FeeUpdaterModule
        FeeUpdaterModule updater = FeeUpdaterModule(
            IFactory(factory).doDeploy(
                saltStart++,
                abi.encodePacked(c.feeUpdatorCode, abi.encode(tempOwner))
            )
        );
        updater.setFBTCGovernorModule(address(gov));
        updater.grantRole(updater.FEE_UPDATER_ROLE(), c.feeUpdater);
        updater.transferOwnership(c.feeRecipientAndUpdater);

        return
            DeployedContracts({
                bridge: address(bridge),
                fee: address(feeModel),
                minter: address(minter),
                module: address(gov),
                fbtc: fbtcAddress,
                updater: address(updater)
            });
    }
}
