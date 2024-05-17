// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract SeaportConduit is Ownable {
    function safeTransferFrom(
        address collection,
        address from,
        address to,
        uint256 tokenId
    ) external {
        IERC721(collection).transferFrom(from, to, tokenId);
    }
}
