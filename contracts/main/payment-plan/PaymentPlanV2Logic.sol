// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";

import "./PaymentPlanTypes.sol";
import "../../thirdparty/ICryptoPunk.sol";
import "../../thirdparty/IWETH.sol";
import "../../interfaces/core/IWalletApeCoin.sol";
import "../../interfaces/main/ICyanVaultV2.sol";
import "../../interfaces/core/IFactory.sol";
import { ICyanConduit } from "../../interfaces/conduit/ICyanConduit.sol";
import { ILendPoolLoan as IBDaoLendPoolLoan } from "../../thirdparty/benddao/ILendPoolLoan.sol";
import { DataTypes as BDaoDataTypes } from "../../thirdparty/benddao/DataTypes.sol";
import { AddressProvider } from "../../main/AddressProvider.sol";

/// @title Cyan Core Payment Plan V2 Logic
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
library PaymentPlanV2Logic {
    AddressProvider private constant addressProvider = AddressProvider(0xCF9A19D879769aDaE5e4f31503AAECDa82568E55);

    using ECDSAUpgradeable for bytes32;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    function checkAndCompleteApePlans(
        address cyanWalletAddress,
        address collection,
        uint256 tokenId,
        uint256[2] calldata apePlanIds
    ) external {
        IWalletApeCoin cyanWallet = IWalletApeCoin(cyanWalletAddress);

        _checkAndCompleteApePlan(cyanWallet, apePlanIds[0], collection, tokenId);
        _checkAndCompleteApePlan(cyanWallet, apePlanIds[1], collection, tokenId);
    }

    function _checkAndCompleteApePlan(
        IWalletApeCoin cyanWallet,
        uint256 apePlanId,
        address collection,
        uint256 tokenId
    ) private {
        if (apePlanId == 0) return;

        uint8 apeLockStateBefore = cyanWallet.getApeLockState(collection, tokenId);
        cyanWallet.executeModule(abi.encodeWithSelector(IWalletApeCoin.completeApeCoinPlan.selector, apePlanId));
        uint8 apeLockStateAfter = cyanWallet.getApeLockState(collection, tokenId);

        if (apeLockStateAfter >= apeLockStateBefore) revert InvalidApeCoinPlan();
    }

    /**
     * @notice Return expected payment plan for given price and interest rate
     * @param plan Plan details
     * @return Expected down payment amount
     * @return Expected total interest fee
     * @return Expected total service fee
     * @return Estimated subsequent payments after down payment
     * @return Expected total financing amount
     */
    function getExpectedPlan(Plan calldata plan)
        external
        pure
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        if (plan.totalNumberOfPayments == 0) revert InvalidTotalNumberOfPayments();
        (
            PaymentAmountInfo memory singleAmounts,
            PaymentAmountInfo memory totalAmounts,
            uint256 downPaymentAmount,

        ) = calculatePaymentInfo(plan);
        uint256 totalFinancingAmount = plan.amount + totalAmounts.interestAmount + totalAmounts.serviceAmount;

        return (
            plan.downPaymentPercent > 0 ? downPaymentAmount + singleAmounts.serviceAmount : 0,
            totalAmounts.interestAmount,
            totalAmounts.serviceAmount,
            singleAmounts.loanAmount + singleAmounts.interestAmount + singleAmounts.serviceAmount,
            totalFinancingAmount
        );
    }

    function calculatePaymentInfo(Plan memory plan)
        internal
        pure
        returns (
            PaymentAmountInfo memory singleAmounts,
            PaymentAmountInfo memory totalAmounts,
            uint256 downPaymentAmount,
            uint8 payCountWithoutDownPayment
        )
    {
        payCountWithoutDownPayment = plan.totalNumberOfPayments - (plan.downPaymentPercent > 0 ? 1 : 0);
        downPaymentAmount = (plan.amount * plan.downPaymentPercent) / 10000;

        totalAmounts.loanAmount = plan.amount - downPaymentAmount;
        totalAmounts.interestAmount = (totalAmounts.loanAmount * plan.interestRate) / 10000;
        totalAmounts.serviceAmount = (plan.amount * plan.serviceFeeRate) / 10000;

        singleAmounts.loanAmount = totalAmounts.loanAmount / payCountWithoutDownPayment;
        singleAmounts.interestAmount = totalAmounts.interestAmount / payCountWithoutDownPayment;
        singleAmounts.serviceAmount = totalAmounts.serviceAmount / plan.totalNumberOfPayments;
    }

    /**
     * @notice Return payment info
     * @param plan Plan details
     * @param isEarlyPayment Is paying early
     * @return Remaining payment amount for collateral
     * @return Remaining payment amount for interest fee
     * @return Remaining payment amount for service fee
     * @return Remaining total payment amount
     */
    function getPaymentInfo(
        Plan memory plan,
        bool isEarlyPayment,
        uint256 createdDate
    )
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        (PaymentAmountInfo memory singleAmounts, PaymentAmountInfo memory totalAmounts, , ) = calculatePaymentInfo(
            plan
        );

        uint8 paidCountWithoutDownPayment = plan.counterPaidPayments - (plan.downPaymentPercent > 0 ? 1 : 0);
        if (
            (plan.totalNumberOfPayments == 1 && plan.downPaymentPercent == 0) ||
            (plan.totalNumberOfPayments == 2 && plan.downPaymentPercent > 0)
        ) {
            // In case of single payment plan,
            // (single payment pawn, or downpayment+single payment bnpl)
            //  User will get discount from interest fee by only paying pro-rated interest fee
            uint256 completedPercent = ((block.timestamp - createdDate + 600) / 600) < (plan.term / 600)
                ? (((block.timestamp - createdDate + 600) / 600) * 100) / (plan.term / 600)
                : 100;
            singleAmounts.interestAmount = (singleAmounts.interestAmount * completedPercent) / 100;
        } else if (isEarlyPayment || (plan.totalNumberOfPayments - plan.counterPaidPayments) == 1) {
            // In case of early repayment,
            //  User will get discount from interest fee by only paying single interest fee
            singleAmounts.loanAmount = totalAmounts.loanAmount - singleAmounts.loanAmount * paidCountWithoutDownPayment;
            singleAmounts.serviceAmount =
                totalAmounts.serviceAmount -
                singleAmounts.serviceAmount *
                plan.counterPaidPayments;
        }

        return (
            singleAmounts.loanAmount,
            singleAmounts.interestAmount,
            singleAmounts.serviceAmount,
            singleAmounts.loanAmount + singleAmounts.interestAmount + singleAmounts.serviceAmount,
            createdDate + plan.term * (paidCountWithoutDownPayment + 1)
        );
    }

    function requireCorrectPlanParams(
        bool isBNPL,
        Item calldata item,
        Plan calldata plan,
        uint256 signedBlockNum
    ) public view {
        if (item.contractAddress == address(0)) revert InvalidAddress();
        if (item.cyanVaultAddress == address(0)) revert InvalidAddress();
        if (item.itemType < 1 || item.itemType > 3) revert InvalidItem();
        if (item.itemType == 1 && item.amount != 0) revert InvalidItem();
        if (item.itemType == 2 && item.amount == 0) revert InvalidItem();
        if (item.itemType == 3 && item.amount != 0) revert InvalidItem();

        if (signedBlockNum > block.number) revert InvalidBlockNumber();
        if (signedBlockNum + 50 < block.number) revert InvalidSignature();
        if (plan.serviceFeeRate > 400) revert InvalidServiceFeeRate();
        if (plan.amount == 0) revert InvalidTokenPrice();
        if (plan.interestRate == 0) revert InvalidInterestRate();
        if (plan.term == 0) revert InvalidTerm();

        if (isBNPL) {
            if (plan.downPaymentPercent == 0 || plan.downPaymentPercent >= 10000) revert InvalidDownPaymentPercent();
            if (plan.totalNumberOfPayments <= 1) revert InvalidTotalNumberOfPayments();
            if (plan.counterPaidPayments != 1) revert InvalidPaidCount();
        } else {
            if (plan.downPaymentPercent != 0) revert InvalidDownPaymentPercent();
            if (plan.totalNumberOfPayments == 0) revert InvalidTotalNumberOfPayments();
            if (plan.counterPaidPayments != 0) revert InvalidPaidCount();
        }
    }

    function verifySignature(
        Item calldata item,
        Plan calldata plan,
        uint256 planId,
        uint256 signedBlockNum,
        uint256 chainid,
        address signer,
        bytes memory signature
    ) public pure {
        bytes32 itemHash = keccak256(
            abi.encodePacked(item.cyanVaultAddress, item.contractAddress, item.tokenId, item.amount, item.itemType)
        );
        bytes32 planHash = keccak256(
            abi.encodePacked(
                plan.amount,
                plan.downPaymentPercent,
                plan.interestRate,
                plan.serviceFeeRate,
                plan.term,
                plan.totalNumberOfPayments,
                plan.counterPaidPayments,
                plan.autoRepayStatus
            )
        );
        bytes32 msgHash = keccak256(abi.encodePacked(itemHash, planHash, planId, signedBlockNum, chainid));
        bytes32 signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        if (signedHash.recover(signature) != signer) revert InvalidSignature();
    }

    function verifyRevivalSignature(
        uint256 planId,
        uint256 penaltyAmount,
        uint256 signatureExpiryDate,
        uint256 chainid,
        uint8 counterPaidPayments,
        address signer,
        bytes memory signature
    ) external pure {
        bytes32 msgHash = keccak256(
            abi.encodePacked(planId, penaltyAmount, signatureExpiryDate, chainid, counterPaidPayments)
        );
        bytes32 signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        if (signedHash.recover(signature) != signer) revert InvalidSignature();
    }

    function verifyEarlyUnwindByCyanSignature(
        uint256 planId,
        uint256 sellPrice,
        uint256 signatureExpiryDate,
        uint256 chainid,
        address cyanBuyerAddress,
        bytes memory signature
    ) external pure {
        bytes32 msgHash = keccak256(abi.encodePacked(planId, sellPrice, signatureExpiryDate, chainid));
        bytes32 signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        if (signedHash.recover(signature) != cyanBuyerAddress) revert InvalidSignature();
    }

    function receiveCurrencyFromCyanWallet(
        address currencyAddress,
        address from,
        uint256 amount
    ) external {
        if (currencyAddress == address(0)) {
            IWETH weth = IWETH(addressProvider.addresses("WETH"));
            weth.transferFrom(from, address(this), amount);
            weth.withdraw(amount);
        } else {
            IERC20Upgradeable(currencyAddress).safeTransferFrom(from, address(this), amount);
        }
    }

    /**
     * @notice Getting currency address by vault address
     * @param vaultAddress Cyan Vault address
     */
    function getCurrencyAddressByVaultAddress(address vaultAddress) internal view returns (address) {
        return ICyanVaultV2(payable(vaultAddress)).getCurrencyAddress();
    }

    function createPawn(
        Item calldata item,
        Plan calldata plan,
        uint256 planId,
        PawnCreateType createType,
        uint256 signedBlockNum,
        address mainWalletAddress,
        address cyanWalletAddress,
        address cyanSigner,
        bytes memory signature
    ) external returns (bool) {
        requireCorrectPlanParams(false, item, plan, signedBlockNum);
        verifySignature(item, plan, planId, signedBlockNum, block.chainid, cyanSigner, signature);

        if (createType == PawnCreateType.BEND_DAO) {
            ICyanVaultV2(payable(item.cyanVaultAddress)).lend(cyanWalletAddress, plan.amount);

            address currencyAddress = getCurrencyAddressByVaultAddress(item.cyanVaultAddress);
            migrateBendDaoPlan(item, plan, cyanWalletAddress, currencyAddress);

            if (IERC721Upgradeable(item.contractAddress).ownerOf(item.tokenId) != cyanWalletAddress) {
                revert InvalidBendDaoPlan();
            }
        } else if (createType == PawnCreateType.REFINANCE) {
            ICyanVaultV2(payable(item.cyanVaultAddress)).lend(address(this), plan.amount);
        } else {
            bool isTransferRequired = false;
            if (item.itemType == 1) {
                // ERC721, check if item is already in Cyan wallet
                if (IERC721Upgradeable(item.contractAddress).ownerOf(item.tokenId) != cyanWalletAddress) {
                    isTransferRequired = true;
                }
            } else if (item.itemType == 2) {
                // ERC1155, check if message sender is Cyan wallet
                if (msg.sender != cyanWalletAddress) {
                    isTransferRequired = true;
                }
            } else if (item.itemType == 3) {
                // CryptoPunk, check if item is already in Cyan wallet
                if (ICryptoPunk(item.contractAddress).punkIndexToAddress(item.tokenId) != cyanWalletAddress) {
                    isTransferRequired = true;
                }
            }
            ICyanVaultV2(payable(item.cyanVaultAddress)).lend(mainWalletAddress, plan.amount);
            return isTransferRequired;
        }
        return false;
    }

    function migrateBendDaoPlan(
        Item calldata item,
        Plan calldata plan,
        address cyanWallet,
        address currency
    ) private {
        IBDaoLendPoolLoan bendDaoLendPoolLoan = IBDaoLendPoolLoan(addressProvider.addresses("BENDDAO_LEND_POOL_LOAN"));
        uint256 loanId = bendDaoLendPoolLoan.getCollateralLoanId(item.contractAddress, item.tokenId);
        (, uint256 loanAmount) = bendDaoLendPoolLoan.getLoanReserveBorrowAmount(loanId);

        BDaoDataTypes.LoanData memory loanData = bendDaoLendPoolLoan.getLoan(loanId);
        if (loanData.state != BDaoDataTypes.LoanState.Active) revert InvalidBendDaoPlan();
        if (loanData.borrower != msg.sender) revert InvalidSender();
        if (plan.amount < loanAmount) revert InvalidAmount();
        if (loanData.reserveAsset != (currency == address(0) ? addressProvider.addresses("WETH") : currency))
            revert InvalidCurrency();

        IWallet(cyanWallet).executeModule(
            abi.encodeWithSelector(
                IWallet.repayBendDaoLoan.selector,
                item.contractAddress,
                item.tokenId,
                loanAmount,
                currency
            )
        );
        ICyanConduit(addressProvider.addresses("CYAN_CONDUIT")).transferERC721(
            loanData.borrower,
            cyanWallet,
            item.contractAddress,
            item.tokenId
        );
    }

    function activate(PaymentPlan storage _paymentPlan, Item calldata item) external returns (uint256) {
        if (_paymentPlan.plan.counterPaidPayments != 1) revert InvalidPaidCount();
        if (
            _paymentPlan.status != PaymentPlanStatus.BNPL_CREATED &&
            _paymentPlan.status != PaymentPlanStatus.BNPL_FUNDED
        ) revert InvalidStage();

        (PaymentAmountInfo memory singleAmounts, , uint256 downPaymentAmount, ) = PaymentPlanV2Logic
            .calculatePaymentInfo(_paymentPlan.plan);

        address cyanVaultAddress = item.cyanVaultAddress;

        if (_paymentPlan.status == PaymentPlanStatus.BNPL_CREATED) {
            // Admin already funded the plan, so Vault is transfering equal amount of currency back to admin.
            ICyanVaultV2(payable(cyanVaultAddress)).lend(msg.sender, _paymentPlan.plan.amount);
        }
        transferEarnedAmountToCyanVault(cyanVaultAddress, downPaymentAmount, 0);

        _paymentPlan.status = PaymentPlanStatus.BNPL_ACTIVE;
        return singleAmounts.serviceAmount;
    }

    /**
     * @notice Transfer earned amount to Cyan Vault
     * @param cyanVaultAddress Original price of the token
     * @param paidTokenPayment Paid token payment
     * @param paidInterestFee Paid interest fee
     */
    function transferEarnedAmountToCyanVault(
        address cyanVaultAddress,
        uint256 paidTokenPayment,
        uint256 paidInterestFee
    ) internal {
        ICyanVaultV2 cyanVault = ICyanVaultV2(payable(cyanVaultAddress));
        address currencyAddress = cyanVault.getCurrencyAddress();
        if (currencyAddress == address(0)) {
            cyanVault.earn{ value: paidTokenPayment + paidInterestFee }(paidTokenPayment, paidInterestFee);
        } else {
            IERC20Upgradeable erc20Contract = IERC20Upgradeable(currencyAddress);
            erc20Contract.approve(cyanVaultAddress, paidTokenPayment + paidInterestFee);
            cyanVault.earn(paidTokenPayment, paidInterestFee);
        }
    }
}
