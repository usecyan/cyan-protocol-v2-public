// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "../interfaces/core/IModule.sol";
import "../helpers/Utils.sol";
import "../thirdparty/opensea/ISeaport.sol";
import "../thirdparty/IWETH.sol";
import "../core/Lockers.sol" as Lockers;
import { ICyanConduit } from "../interfaces/conduit/ICyanConduit.sol";
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
        address collectionAddress,
        uint256 tokenId,
        ISeaport.OfferData calldata offerInput
    ) external {
        IWETH weth = IWETH(addressProvider.addresses("WETH"));
        IERC721 collection = IERC721(collectionAddress);

        require(!Lockers.isLockedByApePlan(address(collection), tokenId), "Token has ape lock");
        require(payAmount <= sellPrice, "Selling price must be higher than payment amount");
        require(collection.ownerOf(tokenId) == address(this), "Token is not owned by the wallet");

        uint256 userBalance = weth.balanceOf(address(this));
        {
            collection.approve(addressProvider.addresses("SEAPORT_CONDUIT"), tokenId);
            ISeaport(addressProvider.addresses("SEAPORT_1_5")).matchAdvancedOrders(
                offerInput.orders,
                offerInput.criteriaResolvers,
                offerInput.fulfillments,
                address(this)
            );
        }
        require(userBalance + sellPrice == weth.balanceOf(address(this)), "Insufficient balance");
        require(collection.ownerOf(tokenId) != address(this), "Token is owned by the wallet");
        weth.approve(msg.sender, payAmount);
    }

    /// @notice Allows operators to sell the locked token for Cyan offer.
    ///     Note: Can only sell if token is locked.
    function earlyUnwindCyan(
        uint256 payAmount,
        uint256 sellPrice,
        address collectionAddress,
        uint256 tokenId,
        address cyanBuyerAddress
    ) external {
        IWETH weth = IWETH(addressProvider.addresses("WETH"));
        IERC721 collection = IERC721(collectionAddress);

        require(!Lockers.isLockedByApePlan(address(collection), tokenId), "Token has ape lock");
        require(payAmount <= sellPrice, "Selling price must be higher than payment amount");
        require(collection.ownerOf(tokenId) == address(this), "Token is not owned by the wallet");

        uint256 userBalance = weth.balanceOf(address(this));
        {
            ICyanConduit conduit = ICyanConduit(addressProvider.addresses("CYAN_CONDUIT"));
            conduit.transferERC20(cyanBuyerAddress, address(this), address(weth), sellPrice);
        }

        require(userBalance + sellPrice == weth.balanceOf(address(this)), "Insufficient balance");
        require(collection.ownerOf(tokenId) != address(this), "Token is owned by the wallet");
        weth.approve(msg.sender, payAmount);
    }
}
