// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.20;

import {Test, console2 as console} from "forge-std/Test.sol";
import {FBTC} from "../contracts/FBTC.sol";
import {FBTCMinter, FireBridge} from "../contracts/FBTCMinter.sol";
import {FeeModel} from "../contracts/FeeModel.sol";

import {FireBridgeV2} from "../contracts/FireBridgeV2.sol";

import {Operation, Request, UserInfo, RequestLib, ChainCode, Status} from "../contracts/Common.sol";

contract FireBridgeTest is Test {
    using RequestLib for Request;

    FBTCMinter public minter;
    FireBridgeV2 public bridge;
    FBTC public fbtc;
    FeeModel public feeModel;

    address constant ONE = address(1);
    address immutable OWNER = address(this);
    address constant FEE = address(0xfee);

    string constant BTC_ADDR1 = "address1";
    string constant BTC_ADDR2 = "address2";
    bytes32 constant TX_DATA1 = "data1";
    bytes32 constant TX_DATA2 = "data2";
    bytes32 constant TX_DATA3 = "data3";

    bytes32 DST_CHAIN1 = bytes32(uint256(0xddddd1));
    bytes32 DST_CHAIN2 = bytes32(uint256(0xddddd2));
    bytes32 DST_CHAIN3 = bytes32(uint256(0xddddd3));

    function setUp() public {
        bridge = new FireBridgeV2(OWNER, ChainCode.BTC);
        bridge.addQualifiedUser(OWNER, BTC_ADDR1, BTC_ADDR2);

        feeModel = new FeeModel(OWNER);
        FeeModel.FeeConfig memory _config;
        _config.maxFee = type(uint256).max;
        _config.tiers = new FeeModel.FeeTier[](1);
        _config.tiers[0].amountTier = type(uint224).max;
        feeModel.setDefaultFeeConfig(Operation.Mint, _config);
        feeModel.setDefaultFeeConfig(Operation.Burn, _config);
        feeModel.setDefaultFeeConfig(Operation.CrosschainRequest, _config);

        bridge.setFeeModel(address(feeModel));
        bridge.setFeeRecipient(FEE);

        fbtc = new FBTC(OWNER, address(bridge));
        bridge.setToken(address(fbtc));

        minter = new FBTCMinter(OWNER, address(bridge));
        bridge.setMinter(address(minter));

        bytes32[] memory dstChains = new bytes32[](3);
        dstChains[0] = DST_CHAIN1;
        dstChains[1] = DST_CHAIN2;
        dstChains[2] = DST_CHAIN3;
        bridge.addDstChains(dstChains);

        minter.grantRole(minter.MINT_ROLE(), OWNER);
        minter.grantRole(minter.BURN_ROLE(), OWNER);
        minter.grantRole(minter.CROSSCHAIN_ROLE(), OWNER);
    }

    function testQualifiedUser1() public {
        assertFalse(bridge.isQualifiedUser(ONE));

        bridge.addQualifiedUser(ONE, BTC_ADDR2, BTC_ADDR1);

        assertTrue(bridge.isQualifiedUser(ONE));
        UserInfo memory info = bridge.getQualifiedUserInfo(ONE);
        assertEq(info.locked, false);
        assertEq(info.depositAddress, BTC_ADDR2);
        assertEq(info.withdrawalAddress, BTC_ADDR1);

        address[] memory _users = bridge.getQualifiedUsers();
        assertEq(_users.length, 2);
        assertEq(_users[0], OWNER);
        assertEq(_users[1], ONE);

        _users = bridge.getActiveUsers();
        assertEq(_users.length, 2);
        assertEq(_users[0], OWNER);
        assertEq(_users[1], ONE);

        bridge.lockQualifiedUser(ONE);
        assertFalse(bridge.isActiveUser(ONE));

        _users = bridge.getActiveUsers();
        assertEq(_users.length, 1);
        assertEq(_users[0], OWNER);

        bridge.unlockQualifiedUser(ONE);
        assertTrue(bridge.isActiveUser(ONE));

        bridge.removeQualifiedUser(ONE);
        assertFalse(bridge.isQualifiedUser(ONE));
    }

    function testQualifiedUser2() public {
        vm.prank(ONE);
        vm.expectRevert("Caller not qualified");
        bridge.addMintRequest(1000, TX_DATA1, 1);

        bridge.lockQualifiedUser(OWNER);
        vm.expectRevert("Caller locked");
        bridge.addMintRequest(1000, TX_DATA1, 1);

        bridge.unlockQualifiedUser(OWNER);
        bridge.addMintRequest(1000, TX_DATA1, 1);
    }

    function testRequest() public {
        vm.expectRevert("Request not exists");
        bridge.getRequestById(100);

        vm.expectRevert("Request not exists");
        bridge.getRequestByHash(bytes32(uint256(100)));

        // Mint request
        (bytes32 _hash, Request memory r) = bridge.addMintRequest(
            1500,
            TX_DATA1,
            1
        );
        assertEq(r.nonce, bridge.nonce() - 1);
        assertEq(abi.encode(bridge.getRequestByHash(_hash)), abi.encode(r));

        assertEq(r.dstChain, bridge.chain());
        assertEq(r.dstAddress, abi.encode(OWNER));
        assertEq(r.amount, 1500);
        assertEq(r.srcChain, ChainCode.BTC);
        assertEq(
            r.srcAddress,
            bytes(bridge.getQualifiedUserInfo(OWNER).depositAddress)
        );
        assertEq(r.extra, abi.encode(TX_DATA1, 1));
        assertTrue(r.status == Status.Pending);

        minter.confirmMintRequest(_hash);

        // Burn request
        (_hash, r) = bridge.addBurnRequest(1000);
        assertEq(r.nonce, bridge.nonce() - 1);
        assertEq(abi.encode(bridge.getRequestByHash(_hash)), abi.encode(r));
        assertEq(r.srcChain, bridge.chain());
        assertEq(r.srcAddress, abi.encode(OWNER));
        assertEq(r.amount, 1000);
        assertEq(r.dstChain, ChainCode.BTC);
        assertEq(
            r.dstAddress,
            bytes(bridge.getQualifiedUserInfo(OWNER).withdrawalAddress)
        );
        assertEq(r.extra, "");
        assertTrue(r.status == Status.Pending);

        // Cross-chain request
        (_hash, r) = bridge.addCrosschainRequest(
            DST_CHAIN1,
            abi.encode(ONE),
            500
        );
        assertEq(r.nonce, bridge.nonce() - 1);
        assertEq(abi.encode(bridge.getRequestByHash(_hash)), abi.encode(r));
        assertEq(r.srcChain, bridge.chain());
        assertEq(r.srcAddress, abi.encode(OWNER));
        assertEq(r.amount, 500);
        assertEq(r.dstChain, DST_CHAIN1);
        assertEq(r.dstAddress, abi.encode(ONE));
        assertEq(r.extra, abi.encode(_hash));
        assertTrue(r.status == Status.Unused);

        // Cross-chain confirmation
        _confirmCrosschainRequest(r, _hash);

        Request memory r2 = bridge.getRequestById(bridge.nonce() - 1);
        r2.op = r.op;
        r2.nonce = r.nonce;
        assertEq(abi.encode(r), abi.encode(r2));

        Request[] memory rs = bridge.getRequestsByIdRange(0, 100);
        assertEq(rs.length, 4);
        assertEq(rs[0].nonce, 0);
        assertEq(rs[1].nonce, 1);
        assertEq(rs[2].nonce, 2);
        assertEq(rs[3].nonce, 3);

        rs = bridge.getRequestsByIdRange(1, 2);
        assertEq(rs.length, 2);
        assertEq(rs[0].nonce, 1);
        assertEq(rs[1].nonce, 2);
    }

    function testMint() public {
        (bytes32 _hash1, ) = bridge.addMintRequest(1000, TX_DATA1, 1);
        (bytes32 _hash2, ) = bridge.addMintRequest(1000, TX_DATA2, 1);
        (bytes32 _hash3, ) = bridge.addMintRequest(1000, TX_DATA1, 1);

        // Test mint
        minter.confirmMintRequest(_hash1);
        Request memory r = bridge.getRequestByHash(_hash1);

        assertTrue(r.status == Status.Confirmed);
        assertEq(fbtc.balanceOf(OWNER), 1000);

        // Can NOT add request with used BTC tx
        vm.expectRevert("Used BTC deposit tx");
        bridge.addMintRequest(1000, TX_DATA1, 1);

        // Can NOT confirm request with used BTC tx
        vm.expectRevert("Used BTC deposit tx");
        minter.confirmMintRequest(_hash3);

        // Can NOT confirm request twice.
        vm.expectRevert("Invalid request status");
        minter.confirmMintRequest(_hash1);

        // Can NOT confirm rejected BTC tx
        bridge.blockDepositTx(TX_DATA2, 1);

        vm.expectRevert("Used BTC deposit tx");
        minter.confirmMintRequest(_hash2);

        // Can NOT add request with blocked BTC tx
        bridge.blockDepositTx(TX_DATA2, 2);
        vm.expectRevert("Used BTC deposit tx");
        bridge.addMintRequest(1000, TX_DATA2, 2);
    }

    function testBurn() public {
        (bytes32 _hash, Request memory r) = bridge.addMintRequest(
            1000,
            TX_DATA1,
            1
        );
        minter.confirmMintRequest(_hash);
        assertEq(fbtc.balanceOf(OWNER), 1000);

        (_hash, r) = bridge.addBurnRequest(1000);
        assertEq(fbtc.balanceOf(OWNER), 0);

        r = bridge.getRequestByHash(_hash);
        assertTrue(r.status == Status.Pending);

        minter.confirmBurnRequest(_hash, TX_DATA2, 0);
        r = bridge.getRequestByHash(_hash);
        assertTrue(r.status == Status.Confirmed);
        assertEq(r.extra, abi.encode(TX_DATA2, 0));

        vm.expectRevert();
        bridge.addBurnRequest(1000);
    }

    function _confirmCrosschainRequest(
        Request memory _r,
        bytes32 _srcRequestHash
    ) internal {
        // Should be correct set in source request.
        assertEq(_r.extra, abi.encode(_srcRequestHash));
        _r.op = Operation.CrosschainConfirm;

        uint256 backup = block.chainid;
        vm.chainId(uint256(_r.dstChain)); // Temperary mock bridge to dst chain.
        minter.confirmCrosschainRequest(_r);
        vm.chainId(backup);
    }

    function testCrosschain() public {
        (bytes32 _hash, ) = bridge.addMintRequest(1000, TX_DATA1, 1);
        assertEq(fbtc.balanceOf(OWNER), 0);
        minter.confirmMintRequest(_hash);
        assertEq(fbtc.balanceOf(OWNER), 1000);

        vm.expectRevert("Target chain not allowed");
        bridge.addEVMCrosschainRequest(1234, ONE, 500);

        (_hash, ) = bridge.addEVMCrosschainRequest(
            uint256(DST_CHAIN1),
            ONE,
            500
        );
        assertEq(fbtc.balanceOf(OWNER), 500, "owner token incorrect");

        Request memory r = bridge.getRequestByHash(_hash);
        _confirmCrosschainRequest(r, _hash);
        assertEq(fbtc.balanceOf(ONE), 500, "token not received");

        (bytes32 _hash1, ) = bridge.addCrosschainRequest(
            DST_CHAIN3,
            abi.encode(ONE),
            10
        );
        (bytes32 _hash2, ) = bridge.addCrosschainRequest(
            DST_CHAIN3,
            abi.encode(ONE),
            10
        );
        (bytes32 _hash3, ) = bridge.addEVMCrosschainRequest(
            uint256(DST_CHAIN3),
            ONE,
            10
        );

        Request[] memory rs = new Request[](3);
        rs[0] = bridge.getRequestByHash(_hash1);
        rs[1] = bridge.getRequestByHash(_hash2);
        rs[2] = bridge.getRequestByHash(_hash3);

        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = _hash1;
        hashes[1] = _hash2;
        hashes[2] = _hash3;
        Request[] memory rs2 = bridge.getRequestsByHashes(hashes);

        for (uint i = 0; i <= 2; i++) {
            assertEq(abi.encode(rs[i]), abi.encode(rs2[i]));
            rs[i].op = Operation.CrosschainConfirm;
        }

        uint256 chainId = block.chainid;
        vm.chainId(uint256(DST_CHAIN3));
        minter.batchConfirmCrosschainRequest(rs);
        vm.chainId(chainId);

        assertEq(fbtc.balanceOf(OWNER), 470);
        assertEq(fbtc.balanceOf(ONE), 530);

        vm.expectRevert("Source request already confirmed");
        _confirmCrosschainRequest(rs[2], _hash3);
    }

    function testMinAmount() public {
        // Test default min amounts
        assertEq(bridge.minMintableAmount(), 546);
        assertEq(bridge.minBurnableAmount(), 546);
        assertEq(bridge.minBridgeableAmount(), 0);

        // Test setting min amounts
        bridge.setMinMintableAmount(1000);
        bridge.setMinBurnableAmount(800);
        bridge.setMinBridgeableAmount(500);

        assertEq(bridge.minMintableAmount(), 1000);
        assertEq(bridge.minBurnableAmount(), 800);
        assertEq(bridge.minBridgeableAmount(), 500);

        // Mint some tokens for testing
        (bytes32 _hash, ) = bridge.addMintRequest(2000, TX_DATA1, 1);
        minter.confirmMintRequest(_hash);
        assertEq(fbtc.balanceOf(OWNER), 2000);

        // Test mint with amount less than minimum
        vm.expectRevert("Minting amount too small");
        bridge.addMintRequest(999, TX_DATA2, 1);

        // Test burn with amount less than minimum
        vm.expectRevert("Burning amount too small");
        bridge.addBurnRequest(799);

        // Test bridge with amount less than minimum
        vm.expectRevert("Bridging amount too small");
        bridge.addCrosschainRequest(DST_CHAIN1, abi.encode(ONE), 499);

        // Test successful operations with minimum amounts
        (_hash, ) = bridge.addMintRequest(1000, TX_DATA2, 1);
        minter.confirmMintRequest(_hash);

        (_hash, ) = bridge.addBurnRequest(800);
        minter.confirmBurnRequest(_hash, TX_DATA3, 0);

        (_hash, ) = bridge.addCrosschainRequest(
            DST_CHAIN1,
            abi.encode(ONE),
            500
        );
        Request memory r = bridge.getRequestByHash(_hash);
        _confirmCrosschainRequest(r, _hash);
    }

    function testRefund() public {
        // Test refund by non-owner should fail
        vm.prank(ONE);
        vm.expectRevert();
        bridge.refund(ONE, 1000, "test refund");

        // Test successful refund by owner
        uint256 initialBalance = fbtc.balanceOf(ONE);
        string memory reason = "test refund reason";
        bridge.refund(ONE, 1000, reason);

        assertEq(
            fbtc.balanceOf(ONE),
            initialBalance + 1000,
            "Refund amount not correctly minted"
        );
    }

    function testSubBridge() public {
        address subBridge1 = address(0x1111);
        address subBridge2 = address(0x2222);

        // Test adding sub-bridges
        bridge.addSubBridge(subBridge1);
        bridge.addSubBridge(subBridge2);

        address[] memory subBridges = bridge.getSubBridges();
        assertEq(subBridges.length, 2);
        assertTrue(subBridges[0] == subBridge1 || subBridges[1] == subBridge1);
        assertTrue(subBridges[0] == subBridge2 || subBridges[1] == subBridge2);

        // Test minting through sub-bridge
        vm.prank(subBridge1);
        bridge.mint(ONE, 1000);
        assertEq(fbtc.balanceOf(ONE), 1000);

        // Test burning through sub-bridge
        vm.prank(subBridge1);
        bridge.burn(ONE, 500);
        assertEq(fbtc.balanceOf(ONE), 500);

        // Test removing sub-bridge
        bridge.removeSubBridge(subBridge1);
        subBridges = bridge.getSubBridges();
        assertEq(subBridges.length, 1);
        assertEq(subBridges[0], subBridge2);

        // Test permissions

        // Non-sub-bridge cannot mint
        vm.prank(ONE);
        vm.expectRevert("Caller not sub-bridge");
        bridge.mint(ONE, 1000);

        // Non-sub-bridge cannot burn
        vm.prank(ONE);
        vm.expectRevert("Caller not sub-bridge");
        bridge.burn(ONE, 1000);

        // Removed sub-bridge cannot mint
        vm.prank(subBridge1);
        vm.expectRevert("Caller not sub-bridge");
        bridge.mint(ONE, 1000);
    }
}
