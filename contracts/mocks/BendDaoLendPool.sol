// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// Mock data exists in goerli block number:	9779204
contract BendDaoLendPool {
    uint256 nothing = 1;

    event Repay(
        address user,
        address indexed reserve,
        uint256 amount,
        address indexed nftAsset,
        uint256 nftTokenId,
        address indexed borrower,
        uint256 loanId
    );

    function repay(
        address,
        uint256,
        uint256
    ) external returns (uint256, bool) {
        nothing = 2;
        return (0, false);
    }
}
