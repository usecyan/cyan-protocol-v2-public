// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../helpers/Utils.sol";
import "../thirdparty/ICryptoPunk.sol";
import "../core/Lockers.sol" as Lockers;
import "../interfaces/core/IModule.sol";
import { AddressProvider } from "../main/AddressProvider.sol";

/// @title Cyan Wallet CryptoPunks Module - A Cyan wallet's CryptoPunks handling module.
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
contract CryptoPunksModule is IModule {
    AddressProvider private constant addressProvider = AddressProvider(0xCF9A19D879769aDaE5e4f31503AAECDa82568E55);

    bytes4 private constant CRYPTO_PUNKS_TRANSFER = ICryptoPunk.transferPunk.selector;
    bytes4 private constant CRYPTO_PUNKS_OFFER = ICryptoPunk.offerPunkForSale.selector;
    bytes4 private constant CRYPTO_PUNKS_OFFER_TO_ADDRESS = ICryptoPunk.offerPunkForSaleToAddress.selector;
    bytes4 private constant CRYPTO_PUNKS_ACCEPT_BID = ICryptoPunk.acceptBidForPunk.selector;

    event SetLockedCryptoPunk(uint256 tokenId, bool isLocked);

    /// @inheritdoc IModule
    function handleTransaction(
        address collection,
        uint256 value,
        bytes calldata data
    ) external payable override returns (bytes memory) {
        require(collection == addressProvider.addresses("CRYPTO_PUNKS"), "This module only supports the CryptoPunks.");
        bytes4 funcHash = Utils.parseFunctionSelector(data);
        if (funcHash == CRYPTO_PUNKS_ACCEPT_BID) {
            uint256 tokenId = Utils.getUint256At(data, 0x4);
            require(!Lockers.isLockedByCryptoPunkPlan(tokenId), "Cannot perform this action on locked token.");
        }
        if (funcHash == CRYPTO_PUNKS_TRANSFER) {
            uint256 tokenId = Utils.getUint256At(data, 0x24);
            require(!Lockers.isLockedByCryptoPunkPlan(tokenId), "Cannot perform this action on locked token.");
        }

        require(funcHash != CRYPTO_PUNKS_OFFER, "Cannot perform this action.");
        require(funcHash != CRYPTO_PUNKS_OFFER_TO_ADDRESS, "Cannot perform this action.");

        return Utils._execute(collection, value, data);
    }

    /// @notice Allows operators to lock/unlock the token.
    /// @param tokenId CryptoPunk index.
    /// @param isLocked Boolean represents lock/unlock.
    function setLockedCryptoPunk(uint256 tokenId, bool isLocked) public {
        Lockers.CyanPlanLockerCryptoPunks storage locker = Lockers.getCyanPlanLockerCryptoPunks();
        require(locker.tokens[tokenId] != isLocked, "Token already in given state.");

        locker.tokens[tokenId] = isLocked;
        if (isLocked) {
            ++locker.count;
        } else {
            --locker.count;
        }
        emit SetLockedCryptoPunk(tokenId, isLocked);
    }

    /// @notice Allows operators to transfer out non locked crypto punks.
    ///     Note: Can only transfer if token is locked.
    /// @param tokenId CryptoPunk index.
    /// @param to Receiver address.
    function transferNonLockedCryptoPunk(uint256 tokenId, address to) external returns (bytes memory) {
        require(!Lockers.isLockedByCryptoPunkPlan(tokenId), "Cannot perform this action on locked token.");

        bytes memory data = abi.encodeWithSelector(CRYPTO_PUNKS_TRANSFER, to, tokenId);
        return Utils._execute(addressProvider.addresses("CRYPTO_PUNKS"), 0, data);
    }
}
