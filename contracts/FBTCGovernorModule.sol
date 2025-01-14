// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.20;

import {Operation, ChainCode} from "./Common.sol";
import {FBTC} from "./FBTC.sol";
import {FireBridge} from "./FireBridge.sol";
import {FeeModel} from "./FeeModel.sol";
import {BaseSafeModule} from "./base/BaseSafeModule.sol";

contract FBTCGovernorModule is BaseSafeModule {
    bytes32 public constant FBTC_PAUSER_ROLE = "1_fbtc_pauser";
    bytes32 public constant LOCKER_ROLE = "2_fbtc_locker";
    bytes32 public constant BRIDGE_PAUSER_ROLE = "3_bridge_pauser";
    bytes32 public constant USER_MANAGER_ROLE = "4_bridge_user_manager";
    bytes32 public constant CHAIN_MANAGER_ROLE = "5_bridge_chain_manager";
    bytes32 public constant FEE_UPDATER_ROLE = "6_bridge_fee_updater";

    FBTC public fbtc;
    uint256 public maxCrossChainMinFee;
    uint256 public maxUserBurnMinFee;
    uint256 public maxUserBurnFeeRate;

    event FBTCSet(address indexed _fbtc);
    event MaxCrossChainMinFeeSet(uint256 indexed _maxCrossChainMinFee);
    event MaxUserBurnMinFeeSet(uint256 indexed _maxUserBurnMinFee);
    event MaxUserBurnFeeRateSet(uint256 indexed _maxUserBurnFeeRate);

    constructor(address _owner, address _fbtc) {
        initialize(_owner, _fbtc);
    }

    function initialize(address _owner, address _fbtc) public initializer {
        __BaseOwnableUpgradeable_init(_owner);
        fbtc = FBTC(_fbtc);
        maxCrossChainMinFee = 0.03 * 1e8; // 0.03 FBTC
        maxUserBurnMinFee = 0.03 * 1e8; // 0.03 FBTC
        maxUserBurnFeeRate = (2 * 1_000_000) / 1000; // 0.2%
    }

    function bridge() public view returns (FireBridge _bridge) {
        _bridge = FireBridge(fbtc.bridge());
    }

    function feeModel() public view returns (FeeModel _feeModel) {
        _feeModel = FeeModel(bridge().feeModel());
    }

    // Admin methods.
    function setFBTC(address _fbtc) external onlyOwner {
        fbtc = FBTC(_fbtc);
        emit FBTCSet(_fbtc);
    }

    function setMaxCrossChainMinFee(
        uint256 _maxCrossChainMinFee
    ) external onlyOwner {
        maxCrossChainMinFee = _maxCrossChainMinFee;
        emit MaxCrossChainMinFeeSet(_maxCrossChainMinFee);
    }

    function setMaxUserBurnMinFee(
        uint256 _maxUserBurnMinFee
    ) external onlyOwner {
        maxUserBurnMinFee = _maxUserBurnMinFee;
        emit MaxUserBurnMinFeeSet(_maxUserBurnMinFee);
    }

    function setMaxUserBurnFeeRate(
        uint256 _maxUserBurnFeeRate
    ) external onlyOwner {
        maxUserBurnFeeRate = _maxUserBurnFeeRate;
        emit MaxUserBurnFeeRateSet(_maxUserBurnFeeRate);
    }

    // Operator methods.
    function lockUserFBTCTransfer(
        address _user
    ) external onlyRole(LOCKER_ROLE) {
        _call(address(fbtc), abi.encodeCall(fbtc.lockUser, (_user)));
    }

    function pauseFBTC() external onlyRole(FBTC_PAUSER_ROLE) {
        _call(address(fbtc), abi.encodeCall(fbtc.pause, ()));
    }

    function pauseBridge() external onlyRole(BRIDGE_PAUSER_ROLE) {
        FireBridge _bridge = bridge();
        _call(address(_bridge), abi.encodeCall(_bridge.pause, ()));
    }

    function addQualifiedUser(
        address _qualifiedUser,
        string calldata _depositAddress,
        string calldata _withdrawalAddress
    ) external onlyRole(USER_MANAGER_ROLE) {
        FireBridge _bridge = bridge();
        _call(
            address(_bridge),
            abi.encodeCall(
                _bridge.addQualifiedUser,
                (_qualifiedUser, _depositAddress, _withdrawalAddress)
            )
        );
    }

    function lockQualifiedUser(
        address _qualifiedUser
    ) external onlyRole(USER_MANAGER_ROLE) {
        FireBridge _bridge = bridge();
        _call(
            address(_bridge),
            abi.encodeCall(_bridge.lockQualifiedUser, (_qualifiedUser))
        );
    }

    function addDstChains(
        bytes32[] memory _dstChains
    ) external onlyRole(CHAIN_MANAGER_ROLE) {
        FireBridge _bridge = bridge();
        _call(
            address(_bridge),
            abi.encodeCall(_bridge.addDstChains, (_dstChains))
        );
    }

    function removeDstChains(
        bytes32[] memory _dstChains
    ) external onlyRole(CHAIN_MANAGER_ROLE) {
        FireBridge _bridge = bridge();
        _call(
            address(_bridge),
            abi.encodeCall(_bridge.removeDstChains, (_dstChains))
        );
    }

    function updateCrossChainMinFee(
        bytes32 _chain,
        uint256 _minFee
    ) external onlyRole(FEE_UPDATER_ROLE) {
        require(
            _minFee <= maxCrossChainMinFee,
            "Min fee exceeds maxCrossChainMinFee"
        );

        // Copy the config set by admin.
        FeeModel _feeModel = feeModel();
        FeeModel.FeeConfig memory config;
        try _feeModel.getCrosschainFeeConfig(_chain) returns (
            FeeModel.FeeConfig memory _config
        ) {
            config = _config;
        } catch {
            // If no CrosschainFeeConfig is set, get the default one.
            config = _feeModel.getDefaultFeeConfig(Operation.CrosschainRequest);
        }
        // Update minFee.
        config.minFee = _minFee;

        _call(
            address(_feeModel),
            abi.encodeCall(_feeModel.setCrosschainFeeConfig, (_chain, config))
        );
    }

    function updateUserBurnFee(
        address _user,
        FeeModel.FeeConfig calldata _config
    ) external onlyRole(USER_MANAGER_ROLE) {
        require(
            _config.minFee <= maxUserBurnMinFee,
            "Min fee exceeds maxUserBurnMinFee"
        );
        for (uint i = 0; i < _config.tiers.length; i++) {
            FeeModel.FeeTier calldata tier = _config.tiers[i];
            require(
                tier.feeRate <= maxUserBurnFeeRate,
                "Fee rate exceeds maxUserBurnFeeRate"
            );
        }
        FeeModel _feeModel = feeModel();
        _call(
            address(_feeModel),
            abi.encodeCall(_feeModel.setUserBurnFeeConfig, (_user, _config))
        );
    }
}
