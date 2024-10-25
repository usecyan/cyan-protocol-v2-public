// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Item } from "../../main/payment-plan/PaymentPlanTypes.sol";

interface IWallet {
    function executeModule(bytes memory) external returns (bytes memory);

    function transferNonLockedERC721(
        address,
        uint256,
        address
    ) external;

    function transferNonLockedERC1155(
        address,
        uint256,
        uint256,
        address
    ) external;

    function transferNonLockedCryptoPunk(uint256, address) external;

    function setLockedERC721Token(
        address,
        uint256,
        bool
    ) external;

    function increaseLockedERC1155Token(
        address,
        uint256,
        uint256
    ) external;

    function decreaseLockedERC1155Token(
        address,
        uint256,
        uint256
    ) external;

    function setLockedCryptoPunk(uint256, bool) external;

    function autoPay(
        uint256,
        uint256,
        uint8
    ) external;

    function earlyUnwindOpensea(
        uint256,
        uint256,
        Item memory,
        bytes memory
    ) external;

    function earlyUnwindCyan(uint256, address) external;

    function isLockedNFT(address, uint256) external view returns (bool);

    function repayBendDaoLoan(
        address collection,
        uint256 tokenId,
        uint256 amount,
        address currency
    ) external;
}
