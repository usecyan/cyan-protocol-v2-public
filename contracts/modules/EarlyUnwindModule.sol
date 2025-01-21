// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/core/IModule.sol";
import "../helpers/Utils.sol";
import "../thirdparty/opensea/ISeaport.sol";
import "../core/Lockers.sol" as Lockers;
import "../main/payment-plan/PaymentPlanTypes.sol";
import { AddressProvider } from "../main/AddressProvider.sol";

/// @title Cyan Wallet EarlyUnwindModule Module for OpenSea
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
/// @author Munkhzul Boldbaatar
contract EarlyUnwindModule is IModule {
    AddressProvider private constant addressProvider = AddressProvider(0xCF9A19D879769aDaE5e4f31503AAECDa82568E55);

    /// @inheritdoc IModule
    function handleTransaction(
        address collection,
        uint256 value,
        bytes calldata data
    ) public payable override returns (bytes memory) {
        return Utils._execute(collection, value, data);
    }

    /// @notice Allows operators to sell the locked token for Opensea offer.
    ///     Note: Can only sell if token is locked.
    function earlyUnwindOpensea(
        uint256 payAmount,
        uint256 sellPrice,
        Item calldata item,
        bytes calldata osData
    ) external {
        require(item.itemType == 1, "Item type must be ERC721");
        IERC20 currency = IERC20(addressProvider.addresses("WETH"));
        IERC721 collection = IERC721(item.contractAddress);

        require(!Lockers.isLockedByApePlan(item.contractAddress, item.tokenId), "Token has ape lock");
        require(collection.ownerOf(item.tokenId) == address(this), "Token is not owned by the wallet");

        uint256 userBalance = currency.balanceOf(address(this));
        {
            collection.approve(addressProvider.addresses("SEAPORT_CONDUIT"), item.tokenId);
            Utils._execute(addressProvider.addresses("SEAPORT_1_5"), 0, osData);
        }
        require(!Lockers.isLockedByApePlan(item.contractAddress, item.tokenId), "Token has ape lock");
        require(userBalance + sellPrice == currency.balanceOf(address(this)), "Insufficient balance");
        require(collection.ownerOf(item.tokenId) != address(this), "Token is owned by the wallet");
        currency.approve(msg.sender, payAmount);
    }

    /// @notice Allows operators to sell the locked token for Cyan offer.
    ///     Note: Can only sell if token is locked.
    function earlyUnwindCyan(uint256 payAmount, address currencyAddress) external {
        IERC20 currency = IERC20(currencyAddress == address(0) ? addressProvider.addresses("WETH") : currencyAddress);
        currency.approve(msg.sender, payAmount);
    }
}
