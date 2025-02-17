// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Request, UserInfo, RequestLib, Operation, Status, ChainCode} from "./Common.sol";
import {BridgeStorage} from "./base/BridgeStorage.sol";
import {FToken} from "./base/FToken.sol";
import {BasePausableUpgradeable} from "./base/BasePausableUpgradeable.sol";
import {FeeModel} from "./FeeModel.sol";

/// @title FireBridgeV2 - A bridge contract for FBTC
/// @notice This contract handles minting, burning and cross-chain transfers of FBTC tokens
/// @dev We copy old code from FireBridge.sol cause we use OpenZeppelin Upgrades tool to ensure our upgrade works.
/// @custom:oz-upgrades-from FireBridge
contract FireBridgeV2 is BridgeStorage, BasePausableUpgradeable {
    using RequestLib for Request;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    event QualifiedUserAdded(
        address indexed _user,
        string _depositAddress,
        string _withdrawalAddress
    );
    event QualifiedUserEdited(
        address indexed _user,
        string _depositAddress,
        string _withdrawalAddress
    );
    event QualifiedUserLocked(address indexed _user);
    event QualifiedUserUnlocked(address indexed _user);

    event QualifiedUserRemoved(address indexed _user);

    event TokenSet(address indexed _token);
    event MinterSet(address indexed _minter);
    event FeeModelSet(address indexed _feeModel);
    event FeeRecipientSet(address indexed _feeRecipient);
    event DepositTxBlocked(
        bytes32 indexed _depositTxid,
        uint256 indexed _outputIndex
    );

    event RequestAdded(bytes32 indexed _hash, Operation indexed op, Request _r);
    event RequestConfirmed(bytes32 indexed _hash);

    event FeePaid(address indexed _feeRecipient, uint256 indexed _feeAmount);

    event DstChainAdded(bytes32 indexed _dstChain);
    event DstChainRemoved(bytes32 indexed _dstChain);

    event SubBridgeAdded(address indexed _subBridge);
    event SubBridgeRemoved(address indexed _subBridge);

    event MinMintableAmountSet(uint256 indexed _amount);
    event MinBurnableAmountSet(uint256 indexed _amount);
    event MinBridgeableAmountSet(uint256 indexed _amount);

    event MintedBySubBridge(
        address _bridge,
        address indexed _to,
        uint256 indexed _amount
    );
    event BurnedBySubBridge(
        address _bridge,
        address indexed _from,
        uint256 indexed _amount
    );
    event Refunded(
        address indexed _to,
        uint256 indexed _amount,
        string _reason
    );

    /// @notice Ensures the caller is the designated minter
    modifier onlyMinter() {
        require(msg.sender == minter, "Caller not minter");
        _;
    }

    /// @notice Ensures the caller is an active qualified user
    modifier onlyActiveQualifiedUser() {
        require(isQualifiedUser(msg.sender), "Caller not qualified");
        require(!userInfo[msg.sender].locked, "Caller locked");
        _;
    }

    /// @notice Ensures the caller is a registered sub-bridge
    modifier onlySubBridge() {
        require(subBridges.contains(msg.sender), "Caller not sub-bridge");
        _;
    }

    /// @notice The identifier for the main chain in the FBTC system
    bytes32 public immutable MAIN_CHAIN;

    /// @notice Minimum amount required for minting FBTC
    uint256 public minMintableAmount;
    /// @notice Minimum amount required for burning FBTC
    uint256 public minBurnableAmount;
    /// @notice Minimum amount required for bridging FBTC
    uint256 public minBridgeableAmount;

    /// @notice Set of registered sub-bridge addresses
    EnumerableSet.AddressSet internal subBridges;

    /// @param _owner The address of the contract owner
    /// @param _mainChain The identifier of the main chain
    constructor(address _owner, bytes32 _mainChain) {
        initialize(_owner);
        MAIN_CHAIN = _mainChain;
    }

    /// @notice Initializes the contract with default settings
    /// @param _owner The address of the contract owner
    function initialize(address _owner) public initializer {
        __BasePausableUpgradeable_init(_owner);

        // Set minimum amounts larger than Bitcoin dust limit (546 satoshis)
        minMintableAmount = 546;
        minBurnableAmount = 546;
        minBridgeableAmount = 0;
    }

    /// @notice Calculates and updates the fee for a request
    /// @param r The request to calculate fee for
    function _splitFeeAndUpdate(Request memory r) internal view {
        uint256 _fee = FeeModel(feeModel).getFee(r);
        r.fee = _fee;
        r.amount = r.amount - _fee;
    }

    /// @notice Handles fee payment either through minting or transfer
    /// @param _fee The fee amount to pay
    /// @param viaMint Whether to mint new tokens for fee payment
    function _payFee(uint256 _fee, bool viaMint) internal {
        if (_fee == 0) return;

        address _feeRecipient = feeRecipient;
        if (viaMint) {
            FToken(fbtc).mint(_feeRecipient, _fee);
        } else {
            FToken(fbtc).payFee(msg.sender, _feeRecipient, _fee);
        }
        emit FeePaid(_feeRecipient, _fee);
    }

    /// @notice Creates and stores a new request
    /// @param r The request to add
    /// @return _hash The hash of the created request
    function _addRequest(Request memory r) internal returns (bytes32 _hash) {
        require(
            r.nonce == requestHashes.length,
            "Fatal: nonce not equals array length"
        );
        _hash = r.getRequestHash();

        // For CrosschainRequest: update extra with self hash
        if (r.op == Operation.CrosschainRequest) {
            r.extra = abi.encode(_hash);
        }
        requestHashes.push(_hash);
        requests[_hash] = r;
        emit RequestAdded(_hash, r.op, r);
    }

    // Owner methods

    /// @notice Adds a new qualified user to the system
    /// @param _user The address of the user to add
    /// @param _depositAddress The user's deposit address
    /// @param _withdrawalAddress The user's withdrawal address
    function addQualifiedUser(
        address _user,
        string calldata _depositAddress,
        string calldata _withdrawalAddress
    ) external onlyOwner {
        require(qualifiedUsers.add(_user), "User already qualified");
        require(
            depositAddressToUser[_depositAddress] == address(0),
            "Deposit address used"
        );
        userInfo[_user] = UserInfo(false, _depositAddress, _withdrawalAddress);
        depositAddressToUser[_depositAddress] = _user;
        emit QualifiedUserAdded(_user, _depositAddress, _withdrawalAddress);
    }

    /// @notice Updates a qualified user's information
    /// @param _user The address of the user to edit
    /// @param _depositAddress The new deposit address
    /// @param _withdrawalAddress The new withdrawal address
    function editQualifiedUser(
        address _user,
        string calldata _depositAddress,
        string calldata _withdrawalAddress
    ) external onlyOwner {
        require(isQualifiedUser(_user), "User not qualified");
        require(!userInfo[_user].locked, "User locked");

        string memory _oldDepositAddress = userInfo[_user].depositAddress;
        if (
            keccak256(bytes(_depositAddress)) !=
            keccak256(bytes(_oldDepositAddress))
        ) {
            require(
                depositAddressToUser[_depositAddress] == address(0),
                "Deposit address used"
            );
            delete depositAddressToUser[_oldDepositAddress];
            userInfo[_user].depositAddress = _depositAddress;
            depositAddressToUser[_depositAddress] = _user;
        }

        userInfo[_user].withdrawalAddress = _withdrawalAddress;
        emit QualifiedUserEdited(_user, _depositAddress, _withdrawalAddress);
    }

    /// @notice Removes a qualified user from the system
    /// @param _qualifiedUser The address of the user to remove
    function removeQualifiedUser(address _qualifiedUser) external onlyOwner {
        require(qualifiedUsers.remove(_qualifiedUser), "User not qualified");
        string memory _depositAddress = userInfo[_qualifiedUser].depositAddress;
        delete depositAddressToUser[_depositAddress];
        delete userInfo[_qualifiedUser];
        emit QualifiedUserRemoved(_qualifiedUser);
    }

    /// @notice Locks a qualified user's account
    /// @param _qualifiedUser The address of the user to lock
    function lockQualifiedUser(address _qualifiedUser) external onlyOwner {
        require(isQualifiedUser(_qualifiedUser), "User not qualified");
        require(!userInfo[_qualifiedUser].locked, "User already locked");
        userInfo[_qualifiedUser].locked = true;
        emit QualifiedUserLocked(_qualifiedUser);
    }

    /// @notice Unlocks a qualified user's account
    /// @param _qualifiedUser The address of the user to unlock
    function unlockQualifiedUser(address _qualifiedUser) external onlyOwner {
        require(isQualifiedUser(_qualifiedUser), "User not qualified");
        require(userInfo[_qualifiedUser].locked, "User not locked");
        userInfo[_qualifiedUser].locked = false;
        emit QualifiedUserUnlocked(_qualifiedUser);
    }

    /// @notice Sets the FBTC token contract address
    /// @param _token The address of the FBTC token contract
    function setToken(address _token) external onlyOwner {
        fbtc = _token;
        emit TokenSet(_token);
    }

    /// @notice Sets the minter address
    /// @param _minter The address of the minter
    function setMinter(address _minter) external onlyOwner {
        minter = _minter;
        emit MinterSet(_minter);
    }

    /// @notice Sets the fee model contract address
    /// @param _feeModel The address of the fee model contract
    function setFeeModel(address _feeModel) external onlyOwner {
        require(_feeModel != address(0), "Invalid feeModel");
        feeModel = _feeModel;
        emit FeeModelSet(_feeModel);
    }

    /// @notice Sets the fee recipient address
    /// @param _feeRecipient The address to receive fees
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid feeRecipient");
        feeRecipient = _feeRecipient;
        emit FeeRecipientSet(_feeRecipient);
    }

    /// @notice Adds multiple destination chains to the allowed list
    /// @param _dstChains Array of chain identifiers to add
    function addDstChains(bytes32[] memory _dstChains) external onlyOwner {
        for (uint i = 0; i < _dstChains.length; i++) {
            bytes32 _dstChain = _dstChains[i];
            require(
                _dstChain != MAIN_CHAIN && _dstChain != chain(),
                "Invalid dst chain"
            );
            if (dstChains.add(_dstChain)) {
                emit DstChainAdded(_dstChain);
            }
        }
    }

    /// @notice Removes multiple destination chains from the allowed list
    /// @param _dstChains Array of chain identifiers to remove
    function removeDstChains(bytes32[] memory _dstChains) external onlyOwner {
        for (uint i = 0; i < _dstChains.length; i++) {
            bytes32 _dstChain = _dstChains[i];
            if (dstChains.remove(_dstChain)) {
                emit DstChainRemoved(_dstChain);
            }
        }
    }

    /// @notice Marks a deposit transaction as invalid and rejects any associated minting request
    /// @param _depositTxid The Bitcoin transaction ID
    /// @param _outputIndex The output index in the transaction
    function blockDepositTx(
        bytes32 _depositTxid,
        uint256 _outputIndex
    ) external onlyOwner {
        bytes32 REJECTED = bytes32(uint256(0xdead));
        bytes memory _depositTxData = abi.encode(_depositTxid, _outputIndex);
        bytes32 depositDataHash = keccak256(_depositTxData);

        bytes32 requestHash = usedDepositTxs[depositDataHash];
        require(requestHash == bytes32(0), "Already confirmed or blocked");

        usedDepositTxs[depositDataHash] = REJECTED;
        emit DepositTxBlocked(_depositTxid, _outputIndex);
    }

    /// @notice Initiates a FBTC minting request for a qualified user
    /// @param _amount The amount of FBTC to mint
    /// @param _depositTxid The Bitcoin deposit transaction ID
    /// @param _outputIndex The output index in the deposit transaction
    /// @return _hash The hash of the created request
    /// @return _r The full request details
    function addMintRequest(
        uint256 _amount,
        bytes32 _depositTxid,
        uint256 _outputIndex
    )
        external
        onlyActiveQualifiedUser
        whenNotPaused
        returns (bytes32 _hash, Request memory _r)
    {
        require(_amount > 0, "Invalid amount");
        require(uint256(_depositTxid) != 0, "Empty deposit txid");
        bytes memory _depositTxData = abi.encode(_depositTxid, _outputIndex);

        bytes32 depositDataHash = keccak256(_depositTxData);
        require(
            usedDepositTxs[depositDataHash] == bytes32(uint256(0)),
            "Used BTC deposit tx"
        );

        // Create request from Main chain to current chain
        _r = Request({
            nonce: nonce(),
            op: Operation.Mint,
            srcChain: MAIN_CHAIN,
            srcAddress: bytes(userInfo[msg.sender].depositAddress),
            dstChain: chain(),
            dstAddress: abi.encode(msg.sender),
            amount: _amount,
            fee: 0,
            extra: _depositTxData,
            status: Status.Pending
        });

        _splitFeeAndUpdate(_r);

        require(_r.amount >= minMintableAmount, "Minting amount too small");

        _hash = _addRequest(_r);
    }

    /// @notice Initiates a FBTC burning request for a qualified user
    /// @param _amount The amount of FBTC to burn
    /// @return _hash The hash of the created request
    /// @return _r The full request details
    function addBurnRequest(
        uint256 _amount
    )
        external
        onlyActiveQualifiedUser
        whenNotPaused
        returns (bytes32 _hash, Request memory _r)
    {
        require(_amount > 0, "Invalid amount");

        // Create request from current chain to Main chain
        _r = Request({
            nonce: nonce(),
            op: Operation.Burn,
            srcChain: chain(),
            srcAddress: abi.encode(msg.sender),
            dstChain: MAIN_CHAIN,
            dstAddress: bytes(userInfo[msg.sender].withdrawalAddress),
            amount: _amount,
            fee: 0,
            extra: "",
            status: Status.Pending
        });

        _splitFeeAndUpdate(_r);

        require(_r.amount >= minBurnableAmount, "Burning amount too small");

        _hash = _addRequest(_r);

        _payFee(_r.fee, false);

        FToken(fbtc).burn(msg.sender, _r.amount);
    }

    /// @notice Initiates a FBTC cross-chain transfer request
    /// @param _targetChain The identifier of the destination chain
    /// @param _targetAddress The encoded address on the destination chain
    /// @param _amount The amount of FBTC to transfer
    /// @return _hash The hash of the created request
    /// @return _r The full request details
    function addCrosschainRequest(
        bytes32 _targetChain,
        bytes memory _targetAddress,
        uint256 _amount
    ) public whenNotPaused returns (bytes32 _hash, Request memory _r) {
        require(_amount > 0, "Invalid amount");
        require(dstChains.contains(_targetChain), "Target chain not allowed");

        // Create request from current chain to target chain
        _r = Request({
            nonce: nonce(),
            op: Operation.CrosschainRequest,
            srcChain: chain(),
            srcAddress: abi.encode(msg.sender),
            amount: _amount,
            dstChain: _targetChain,
            dstAddress: _targetAddress,
            fee: 0,
            extra: "",
            status: Status.Unused
        });

        _splitFeeAndUpdate(_r);

        require(_r.amount >= minBridgeableAmount, "Bridging amount too small");

        _hash = _addRequest(_r);

        _payFee(_r.fee, false);

        FToken(fbtc).burn(msg.sender, _r.amount);
    }

    /// @notice Initiates a FBTC cross-chain transfer to an EVM-compatible chain
    /// @param _targetChainId The chain ID of the destination EVM chain
    /// @param _targetAddress The destination address on the EVM chain
    /// @param _amount The amount of FBTC to transfer
    /// @return _hash The hash of the created request
    /// @return _r The full request details
    function addEVMCrosschainRequest(
        uint256 _targetChainId,
        address _targetAddress,
        uint256 _amount
    ) external returns (bytes32 _hash, Request memory _r) {
        return
            addCrosschainRequest(
                bytes32(_targetChainId),
                abi.encode(_targetAddress),
                _amount
            );
    }

    /// @notice Confirms a minting request
    /// @param _hash The hash of the minting request to confirm
    function confirmMintRequest(
        bytes32 _hash
    ) external onlyMinter whenNotPaused {
        Request storage r = requests[_hash];
        require(r.op == Operation.Mint, "Not Mint request");

        uint256 _amount = r.amount;
        require(_amount > 0, "Invalid request amount");
        require(r.status == Status.Pending, "Invalid request status");

        bytes32 depositDataHash = keccak256(r.extra);
        require(
            usedDepositTxs[depositDataHash] == bytes32(uint256(0)),
            "Used BTC deposit tx"
        );
        usedDepositTxs[depositDataHash] = _hash;

        r.status = Status.Confirmed;
        emit RequestConfirmed(_hash);

        FToken(fbtc).mint(abi.decode(r.dstAddress, (address)), _amount);

        _payFee(r.fee, true);
    }

    /// @notice Confirms a burning request
    /// @param _hash The hash of the burning request to confirm
    /// @param _withdrawalTxid The Bitcoin withdrawal transaction ID
    /// @param _outputIndex The output index in the withdrawal transaction
    function confirmBurnRequest(
        bytes32 _hash,
        bytes32 _withdrawalTxid,
        uint256 _outputIndex
    ) external onlyMinter whenNotPaused {
        require(uint256(_withdrawalTxid) != 0, "Empty withdraw txid");

        Request storage r = requests[_hash];

        require(r.op == Operation.Burn, "Not Burn request");
        require(r.amount > 0, "Invalid request amount");
        require(r.status == Status.Pending, "Invalid request status");

        bytes memory _withdrawalTxData = abi.encode(
            _withdrawalTxid,
            _outputIndex
        );

        bytes32 _withdrawalDataHash = keccak256(_withdrawalTxData);
        require(
            usedWithdrawalTxs[_withdrawalDataHash] == bytes32(uint256(0)),
            "Used BTC withdrawal tx"
        );
        usedWithdrawalTxs[_withdrawalDataHash] = _hash;

        r.status = Status.Confirmed;
        r.extra = _withdrawalTxData;

        emit RequestConfirmed(_hash);
    }

    /// @notice Confirms a cross-chain transfer request
    /// @param r The request to confirm
    /// @dev Most fields should match the source request, with these differences:
    ///      1. Operation is changed to CrosschainConfirm
    ///      2. Nonce is from source chain (used to calculate source request hash)
    ///      3. Status should be Unused (0)
    ///      4. Extra should be 32 bytes containing source request hash
    function confirmCrosschainRequest(
        Request memory r
    ) external onlyMinter whenNotPaused {
        require(r.amount > 0, "Invalid request amount");
        require(r.dstChain == chain(), "Dst chain not match");
        require(
            r.op == Operation.CrosschainConfirm,
            "Not CrosschainConfirm request"
        );
        require(r.status == Status.Unused, "Status should not be used");

        require(r.extra.length == 32, "Invalid extra: not valid bytes32");
        require(
            r.dstAddress.length == 32,
            "Invalid dstAddress: not 32 bytes length"
        );
        require(
            abi.decode(r.dstAddress, (uint256)) <= type(uint160).max,
            "Invalid dstAddress: not address"
        );

        bytes32 srcHash = abi.decode(r.extra, (bytes32));

        require(
            r.getCrossSourceRequestHash() == srcHash,
            "Source request hash is incorrect"
        );
        require(
            crosschainRequestConfirmation[srcHash] == bytes32(0),
            "Source request already confirmed"
        );

        r.nonce = nonce();
        bytes32 _dsthash = _addRequest(r);
        crosschainRequestConfirmation[srcHash] = _dsthash;

        FToken(fbtc).mint(abi.decode(r.dstAddress, (address)), r.amount);
    }

    /// @notice Returns the unique chain identifier in the FBTC system
    /// @return The chain identifier
    function chain() public view returns (bytes32) {
        return ChainCode.getSelfChainCode();
    }

    /// @notice Returns the next request nonce
    /// @return The next nonce value
    function nonce() public view returns (uint128) {
        require(
            requestHashes.length < type(uint128).max,
            "Fatal: nonce overflow"
        );
        return uint128(requestHashes.length);
    }

    /// @notice Checks if an address is a qualified user
    /// @param _user The address to check
    /// @return True if the address is qualified
    function isQualifiedUser(address _user) public view returns (bool) {
        return qualifiedUsers.contains(_user);
    }

    /// @notice Checks if an address is an active qualified user
    /// @param _user The address to check
    /// @return True if the address is qualified and not locked
    function isActiveUser(address _user) public view returns (bool) {
        return isQualifiedUser(_user) && !userInfo[_user].locked;
    }

    /// @notice Returns all qualified users
    /// @return Array of qualified user addresses
    function getQualifiedUsers() external view returns (address[] memory) {
        return qualifiedUsers.values();
    }

    /// @notice Returns all active qualified users
    /// @return _users Array of active user addresses
    function getActiveUsers() external view returns (address[] memory _users) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < qualifiedUsers.length(); ++i) {
            UserInfo storage info = userInfo[qualifiedUsers.at(i)];
            if (!info.locked) {
                activeCount += 1;
            }
        }

        _users = new address[](activeCount);
        uint256 j = 0;
        for (uint256 i = 0; i < qualifiedUsers.length(); ++i) {
            address _user = qualifiedUsers.at(i);
            UserInfo storage info = userInfo[_user];
            if (!info.locked) {
                _users[j++] = _user;
            }
        }
    }

    /// @notice Returns information about a qualified user
    /// @param _user The address of the user
    /// @return info The user's information
    function getQualifiedUserInfo(
        address _user
    ) external view returns (UserInfo memory info) {
        info = userInfo[_user];
    }

    /// @notice Returns all valid destination chains
    /// @return Array of valid destination chain identifiers
    function getValidDstChains() external view returns (bytes32[] memory) {
        return dstChains.values();
    }

    /// @notice Returns a request by its ID
    /// @param _id The request ID
    /// @return r The request details
    function getRequestById(
        uint256 _id
    ) external view returns (Request memory r) {
        require(_id < requestHashes.length, "Request not exists");
        r = requests[requestHashes[_id]];
    }

    /// @notice Returns multiple requests within an ID range
    /// @param _start The starting ID
    /// @param _end The ending ID
    /// @return rs Array of request details
    function getRequestsByIdRange(
        uint256 _start,
        uint256 _end
    ) external view returns (Request[] memory rs) {
        uint256 maxIndex = requestHashes.length - 1;
        if (_end > maxIndex) _end = maxIndex;
        require(_start <= _end, "start should <= end");
        uint256 len = _end - _start + 1;
        rs = new Request[](len);
        for (uint i = 0; i < len; i++) {
            rs[i] = requests[requestHashes[i + _start]];
        }
    }

    /// @notice Returns a request by its hash
    /// @param _hash The request hash
    /// @return r The request details
    function getRequestByHash(
        bytes32 _hash
    ) public view returns (Request memory r) {
        r = requests[_hash];
        require(r.op != Operation.Nop, "Request not exists");
    }

    /// @notice Returns multiple requests by their hashes
    /// @param _hashes Array of request hashes
    /// @return rs Array of request details
    function getRequestsByHashes(
        bytes32[] calldata _hashes
    ) external view returns (Request[] memory rs) {
        rs = new Request[](_hashes.length);
        for (uint i = 0; i < _hashes.length; i++) {
            rs[i] = getRequestByHash(_hashes[i]);
        }
    }

    /// @notice Calculates the hash of a request
    /// @param _r The request to hash
    /// @return _hash The calculated hash
    function calculateRequestHash(
        Request memory _r
    ) external pure returns (bytes32 _hash) {
        _hash = _r.getRequestHash();
    }

    /// @notice Sets the minimum amount required for minting FBTC
    /// @param _amount The minimum amount
    function setMinMintableAmount(uint256 _amount) external onlyOwner {
        minMintableAmount = _amount;
        emit MinMintableAmountSet(_amount);
    }

    /// @notice Sets the minimum amount required for burning FBTC
    /// @param _amount The minimum amount
    function setMinBurnableAmount(uint256 _amount) external onlyOwner {
        minBurnableAmount = _amount;
        emit MinBurnableAmountSet(_amount);
    }

    /// @notice Sets the minimum amount required for bridging FBTC
    /// @param _amount The minimum amount
    function setMinBridgeableAmount(uint256 _amount) external onlyOwner {
        minBridgeableAmount = _amount;
        emit MinBridgeableAmountSet(_amount);
    }

    /// @notice Adds a sub-bridge to the system
    /// @param _subBridge The address of the sub-bridge to add
    function addSubBridge(address _subBridge) external onlyOwner {
        subBridges.add(_subBridge);
        emit SubBridgeAdded(_subBridge);
    }

    /// @notice Removes a sub-bridge from the system
    /// @param _subBridge The address of the sub-bridge to remove
    function removeSubBridge(address _subBridge) external onlyOwner {
        subBridges.remove(_subBridge);
        emit SubBridgeRemoved(_subBridge);
    }

    /// @notice Returns all registered sub-bridges
    /// @return Array of sub-bridge addresses
    function getSubBridges() external view returns (address[] memory) {
        return subBridges.values();
    }

    /// @notice Mints FBTC tokens through a sub-bridge
    /// @param _to The recipient address
    /// @param _amount The amount to mint
    /// @return success True if minting was successful
    function mint(
        address _to,
        uint256 _amount
    ) external onlySubBridge returns (bool success) {
        FToken(fbtc).mint(_to, _amount);
        emit MintedBySubBridge(msg.sender, _to, _amount);
        return true;
    }

    /// @notice Burns FBTC tokens through a sub-bridge
    /// @param _from The address to burn from
    /// @param _amount The amount to burn
    /// @return success True if burning was successful
    function burn(
        address _from,
        uint256 _amount
    ) external onlySubBridge returns (bool success) {
        FToken(fbtc).burn(_from, _amount);
        emit BurnedBySubBridge(msg.sender, _from, _amount);
        return true;
    }

    /// @notice Refunds FBTC tokens to a user. It should only be used when the user loses funds due
    ///         to their mistake, such as making cross-chain transfer to an incorrect black hole address.
    /// @param _to The recipient address
    /// @param _amount The amount to refund
    /// @param reason The reason for the refund
    function refund(
        address _to,
        uint256 _amount,
        string calldata reason
    ) external onlyOwner {
        FToken(fbtc).mint(_to, _amount);
        emit Refunded(_to, _amount, reason);
    }
}
