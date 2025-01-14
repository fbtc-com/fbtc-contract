// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.20;

import {Operation, ChainCode} from "../contracts/Common.sol";
import {BaseSafeModule} from "../contracts/base/BaseSafeModule.sol";

import {FBTCGovernorModule} from "../contracts/FBTCGovernorModule.sol";

// For internal only usage.
contract FeeUpdaterModule is BaseSafeModule {
    bytes32 public constant FEE_UPDATER_ROLE = "1_fee_updater";

    address public fbtcModule;
    event FBTCModuleSet(address indexed _fbtcModule);
    event CrosschainFeeUpdated(bytes32 indexed chain, uint256 indexed _minFee);

    constructor(address _owner) {
        initialize(_owner);
    }

    function initialize(address _owner) public initializer {
        __BaseOwnableUpgradeable_init(_owner);
    }

    function setFBTCGovernorModule(address _fbtcModule) external onlyOwner {
        fbtcModule = _fbtcModule;
        emit FBTCModuleSet(_fbtcModule);
    }

    function updateCrossChainMinFee(
        bytes32 chain,
        uint256 _minFee
    ) external onlyRole(FEE_UPDATER_ROLE) {
        _call(
            fbtcModule,
            abi.encodeCall(
                FBTCGovernorModule(fbtcModule).updateCrossChainMinFee,
                (chain, _minFee)
            )
        );
        emit CrosschainFeeUpdated(chain, _minFee);
    }
}
