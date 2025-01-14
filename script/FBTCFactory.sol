// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @title FBTC Smart Contract Factory
 * @dev Inspired by https://github.com/pcaversaccio/createx
 */
contract FBTCFactory {
    event ContractDeployed(
        address indexed _contract,
        address indexed _deployer
    );

    enum DeployType {
        Create2,
        Create2WithSender,
        Create3,
        Create3WithSender
    }

    function _guardSalt(
        address sender,
        bytes32 salt,
        uint256 tag
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(sender, salt, tag));
    }

    function deployCreate2(
        bytes32 salt,
        bytes memory initCode,
        bool _private
    ) internal returns (address _contract) {
        address sender = _private ? msg.sender : address(0);
        salt = _guardSalt(sender, salt, 2);
        assembly {
            _contract := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(_contract != address(0), "Create2 failed");
        emit ContractDeployed(_contract, msg.sender);
    }

    function deployCreate3(
        bytes32 salt,
        bytes memory initCode,
        bool _private
    ) internal returns (address _contract) {
        address sender = _private ? msg.sender : address(0);
        bytes32 finalSalt = _guardSalt(sender, salt, 3);
        bytes
            memory proxyChildBytecode = hex"67_36_3d_3d_37_36_3d_34_f0_3d_52_60_08_60_18_f3";
        address proxy;
        assembly {
            proxy := create2(
                0,
                add(proxyChildBytecode, 32),
                mload(proxyChildBytecode),
                finalSalt
            )
        }
        require(proxy != address(0), "Create3 proxy failed");

        (bool success, bytes memory _retData) = proxy.call(initCode);
        if (!success) {
            assembly {
                let size := mload(_retData)
                revert(add(32, _retData), size)
            }
        }
        _contract = getCreate3Address(salt, sender);
        require(_contract.code.length > 0, "Create3 failed");
        emit ContractDeployed(_contract, msg.sender);
    }

    function deploy(
        DeployType typ,
        bytes32 salt,
        bytes memory initCode
    ) public returns (address _contract) {
        if (typ == DeployType.Create2) {
            _contract = deployCreate2(salt, initCode, false);
        } else if (typ == DeployType.Create2WithSender) {
            _contract = deployCreate2(salt, initCode, true);
        } else if (typ == DeployType.Create3) {
            _contract = deployCreate3(salt, initCode, false);
        } else if (typ == DeployType.Create3WithSender) {
            _contract = deployCreate3(salt, initCode, true);
        }
    }

    function deployAndInit(
        DeployType typ,
        bytes32 salt,
        bytes calldata initCode,
        bytes calldata callData
    ) public returns (address _contract) {
        _contract = deploy(typ, salt, initCode);
        (bool success, bytes memory _retData) = _contract.call(callData);
        if (!success) {
            assembly {
                let size := mload(_retData)
                revert(add(32, _retData), size)
            }
        }
    }

    function getCreate2Address(
        bytes32 salt,
        address sender,
        bytes calldata initCode
    ) public view returns (address _contract) {
        bytes32 initCodeHash = keccak256(initCode);
        address deployer = address(this);
        salt = _guardSalt(sender, salt, 2);
        assembly {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), initCodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, deployer)
            let start := add(ptr, 0x0b)
            mstore8(start, 0xff)
            _contract := keccak256(start, 85)
        }
    }

    function getCreate3Address(
        bytes32 salt,
        address sender
    ) public view returns (address _contract) {
        address deployer = address(this);
        salt = _guardSalt(sender, salt, 3);
        assembly {
            let ptr := mload(0x40)
            mstore(0x00, deployer)
            mstore8(0x0b, 0xff)
            mstore(0x20, salt)
            mstore(
                0x40,
                hex"21_c3_5d_be_1b_34_4a_24_88_cf_33_21_d6_ce_54_2f_8e_9f_30_55_44_ff_09_e4_99_3a_62_31_9a_49_7c_1f"
            )
            mstore(0x14, keccak256(0x0b, 0x55))
            mstore(0x40, ptr)
            mstore(0x00, 0xd694)
            mstore8(0x34, 0x01)
            _contract := keccak256(0x1e, 0x17)
        }
    }

    function getAddress(
        DeployType typ,
        bytes32 salt,
        address sender,
        bytes calldata initCode
    ) external view returns (address _contract) {
        if (typ == DeployType.Create2) {
            _contract = getCreate2Address(salt, address(0), initCode);
        } else if (typ == DeployType.Create2WithSender) {
            _contract = getCreate2Address(salt, sender, initCode);
        } else if (typ == DeployType.Create3) {
            _contract = getCreate3Address(salt, address(0));
        } else if (typ == DeployType.Create3WithSender) {
            _contract = getCreate3Address(salt, sender);
        }
    }
}
