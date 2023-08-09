// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/// @title ApeCoin Staking Contract interface
interface IApeCoinStaking {
    struct SingleNft {
        uint32 tokenId;
        uint224 amount;
    }
    struct PairNftDepositWithAmount {
        uint32 mainTokenId;
        uint32 bakcTokenId;
        uint184 amount;
    }
    struct PairNft {
        uint128 mainTokenId;
        uint128 bakcTokenId;
    }
    struct PairNftWithdrawWithAmount {
        uint32 mainTokenId;
        uint32 bakcTokenId;
        uint184 amount;
        bool isUncommit;
    }

    function depositApeCoin(uint256 _amount, address _recipient) external;

    function depositSelfApeCoin(uint256 _amount) external;

    function depositBAYC(SingleNft[] calldata _nfts) external;

    function depositMAYC(SingleNft[] calldata _nfts) external;

    function depositBAKC(PairNftDepositWithAmount[] calldata _baycPairs, PairNftDepositWithAmount[] calldata _maycPairs)
        external;

    function claimApeCoin(address _recipient) external;

    function claimSelfApeCoin() external;

    function claimBAYC(uint256[] calldata _nfts, address _recipient) external;

    function claimSelfBAYC(uint256[] calldata _nfts) external;

    function claimMAYC(uint256[] calldata _nfts, address _recipient) external;

    function claimSelfMAYC(uint256[] calldata _nfts) external;

    function claimBAKC(
        PairNft[] calldata _baycPairs,
        PairNft[] calldata _maycPairs,
        address _recipient
    ) external;

    function claimSelfBAKC(PairNft[] calldata _baycPairs, PairNft[] calldata _maycPairs) external;

    function withdrawApeCoin(uint256 _amount, address _recipient) external;

    function withdrawSelfApeCoin(uint256 _amount) external;

    function withdrawBAYC(SingleNft[] calldata _nfts, address _recipient) external;

    function withdrawSelfBAYC(SingleNft[] calldata _nfts) external;

    function withdrawMAYC(SingleNft[] calldata _nfts, address _recipient) external;

    function withdrawSelfMAYC(SingleNft[] calldata _nfts) external;

    function withdrawBAKC(
        PairNftWithdrawWithAmount[] calldata _baycPairs,
        PairNftWithdrawWithAmount[] calldata _maycPairs
    ) external;
}
