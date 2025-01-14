// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.20;

import {RoleBasedAccessControl} from "./RoleBasedAccessControl.sol";

contract Enum {
    enum Operation {
        Call,
        DelegateCall
    }
}

interface ISafe {
    /// @dev Allows a Module to execute a Safe transaction without any further confirmations and return data
    function execTransactionFromModuleReturnData(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation
    ) external returns (bool success, bytes memory returnData);
}

abstract contract BaseSafeModule is RoleBasedAccessControl {
    function _call(address _to, bytes memory _data) internal {
        (bool success, bytes memory _retData) = ISafe(safe())
            .execTransactionFromModuleReturnData(
                _to,
                0,
                _data,
                Enum.Operation.Call
            );
        if (!success) {
            assembly {
                let size := mload(_retData)
                revert(add(32, _retData), size)
            }
        }
    }

    function safe() public view returns (address) {
        return owner();
    }
}
