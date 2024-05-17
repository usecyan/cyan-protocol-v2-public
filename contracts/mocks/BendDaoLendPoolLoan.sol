// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { DataTypes } from "../thirdparty/benddao/DataTypes.sol";

// Mock data exists in goerli block number:	9779204
contract BendDaoLendPoolLoan {
    uint256 loanId = 1528;

    event LoanRepaid(
        address indexed user,
        uint256 indexed loanId,
        address nftAsset,
        uint256 nftTokenId,
        address reserveAsset,
        uint256 amount,
        uint256 borrowIndex
    );

    function getCollateralLoanId(address, uint256) external view returns (uint256) {
        return loanId;
    }

    function getLoan(uint256) external view returns (DataTypes.LoanData memory loanData) {
        return
            DataTypes.LoanData({
                loanId: loanId,
                state: DataTypes.LoanState.Active,
                borrower: 0x8589D5276833407C37d139D3d0007340C7131cd3,
                nftAsset: 0x30d190032A34d6151073a7DB8793c01Aa05987ec,
                nftTokenId: 3613,
                reserveAsset: 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6,
                scaledAmount: 12611404049091166,
                bidStartTimestamp: 0,
                bidderAddress: 0x0000000000000000000000000000000000000000,
                bidPrice: 0,
                bidBorrowAmount: 0,
                firstBidderAddress: 0x0000000000000000000000000000000000000000
            });
    }

    function getLoanReserveBorrowAmount(uint256) external view returns (address, uint256) {
        loanId;
        return (0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6, 18901619113843607);
    }
}
