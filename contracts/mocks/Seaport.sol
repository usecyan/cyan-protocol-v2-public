// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./SeaportConduit.sol";

contract SeaportMock is Ownable {
    enum OrderType {
        FULL_OPEN, //0
        PARTIAL_OPEN, //1
        FULL_RESTRICTED, // 2
        PARTIAL_RESTRICTED, // 3
        CONTRACT
    }
    enum ItemType {
        NATIVE,
        ERC20,
        ERC721,
        ERC1155,
        ERC721_WITH_CRITERIA,
        ERC1155_WITH_CRITERIA
    }
    enum Side {
        OFFER,
        CONSIDERATION
    }

    struct OfferItem {
        ItemType itemType;
        address token;
        uint256 identifierOrCriteria;
        uint256 startAmount;
        uint256 endAmount;
    }
    struct ConsiderationItem {
        ItemType itemType;
        address token;
        uint256 identifierOrCriteria;
        uint256 startAmount;
        uint256 endAmount;
        address payable recipient;
    }
    struct OrderParameters {
        address offerer;
        address zone;
        OfferItem[] offer;
        ConsiderationItem[] consideration;
        OrderType orderType;
        uint256 startTime;
        uint256 endTime;
        bytes32 zoneHash;
        uint256 salt;
        bytes32 conduitKey;
        uint256 totalOriginalConsiderationItems;
    }
    struct FulfillmentComponent {
        uint256 orderIndex;
        uint256 itemIndex;
    }
    struct Fulfillment {
        FulfillmentComponent[] offerComponents;
        FulfillmentComponent[] considerationComponents;
    }
    struct CriteriaResolver {
        uint256 orderIndex;
        Side side;
        uint256 index;
        uint256 identifier;
        bytes32[] criteriaProof;
    }
    struct AdvancedOrder {
        OrderParameters parameters;
        uint120 numerator;
        uint120 denominator;
        bytes signature;
        bytes extraData;
    }
    struct ReceivedItem {
        ItemType itemType;
        address token;
        uint256 identifier;
        uint256 amount;
        address payable recipient;
    }
    struct Execution {
        ReceivedItem item;
        address offerer;
        bytes32 conduitKey;
    }

    struct OfferData {
        AdvancedOrder[] orders;
        CriteriaResolver[] criteriaResolvers;
        Fulfillment[] fulfillments;
        address recipient;
    }

    function matchAdvancedOrders(
        AdvancedOrder[] calldata orders,
        CriteriaResolver[] calldata criteriaResolvers,
        Fulfillment[] calldata fulfillments,
        address recipient
    ) public payable returns (Execution[] memory) {
        uint256 tokenId;
        uint256 amountWithoutFee;
        address currencyAddress;
        address contractAddress;
        address offerer;
        for (uint256 i = 0; i < orders.length; i++) {
            AdvancedOrder calldata offer = orders[i];
            if (offer.parameters.orderType == OrderType.FULL_RESTRICTED) {
                offerer = offer.parameters.offerer;
            }
            if (offer.parameters.orderType == OrderType.FULL_OPEN) {
                if (offer.parameters.offer.length > 0) {
                    tokenId = offer.parameters.offer[0].identifierOrCriteria;
                    contractAddress = offer.parameters.offer[0].token;
                }
                if (offer.parameters.consideration.length > 0) {
                    amountWithoutFee = offer.parameters.consideration[0].endAmount;
                    currencyAddress = offer.parameters.consideration[0].token;
                }
            }
        }
        require(IERC721(contractAddress).ownerOf(tokenId) == recipient, "Must own token");
        require(IERC20(currencyAddress).balanceOf(offerer) >= amountWithoutFee, "Offerer does not have enough eth");
        SeaportConduit(0x1E0049783F008A0085193E00003D00cd54003c71).safeTransferFrom(
            contractAddress,
            recipient,
            offerer,
            tokenId
        );
        if (tokenId != 102) {
            IERC20(currencyAddress).transferFrom(offerer, recipient, amountWithoutFee);
        }
        if (tokenId == 101) {
            revert();
        }
    }
}
