// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";

import "./CyanVaultV2.sol";
import "./IFactory.sol";
import "./IWallet.sol";

error InvalidSender();
error InvalidBlockNumber();
error InvalidSignature();
error InvalidServiceFeeRate();
error InvalidTokenPrice();
error InvalidInterestRate();
error InvalidDownPaymentPercent();
error InvalidDownPayment();
error InvalidAmount();
error InvalidTerm();
error InvalidTotalNumberOfPayments();
error InvalidPaidCount();
error InvalidStage();
error InvalidAddress();
error InvalidAutoRepaymentDate();
error InvalidAutoRepaymentStatus();
error InvalidReviveDate();
error InvalidPay();
error InvalidItem();
error InvalidBaseDiscountRate();

error PaymentPlanAlreadyExists();
error PaymentPlanNotFound();
error ArraySizesNotEqual();

interface ICryptoPunk {
    function punkIndexToAddress(uint256) external view returns (address);

    function buyPunk(uint256) external payable;

    function transferPunk(address, uint256) external;
}

/// @title Cyan Payment Plan - Main logic of BNPL and Pawn plan
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
contract CyanPaymentPlanV2 is AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using ECDSAUpgradeable for bytes32;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    event CreatedBNPL(uint256 indexed planId);
    event CreatedPawn(uint256 indexed planId);
    event UpdatedBNPL(uint256 indexed planId, PaymentPlanStatus indexed planStatus);
    event LiquidatedPaymentPlan(uint256 indexed planId, uint256 indexed estimatedPrice, uint256 indexed unpaidAmount);
    event Paid(uint256 indexed planId);
    event Completed(uint256 indexed planId);
    event CompletedByRevival(uint256 indexed planId, uint256 penaltyAmount);
    event CompletedEarly(uint256 indexed planId, uint256 indexed baseDiscountRate, uint8 indexed paidNumOfPayment);
    event Revived(uint256 indexed planId, uint256 penaltyAmount);
    event UpdatedCyanSigner(address indexed signer);
    event UpdateBaseDiscountRate(uint256 indexed baseDiscountRate);
    event ClaimedServiceFee(address indexed currency, uint256 indexed amount);
    event UpdatedWalletFactory(address indexed factory);
    event SetAutoRepayStatus(uint256 indexed planId, uint8 indexed autoRepayStatus);

    enum PaymentPlanStatus {
        BNPL_CREATED,
        BNPL_FUNDED,
        BNPL_ACTIVE,
        BNPL_DEFAULTED,
        BNPL_REJECTED,
        BNPL_COMPLETED,
        BNPL_LIQUIDATED,
        PAWN_ACTIVE,
        PAWN_DEFAULTED,
        PAWN_COMPLETED,
        PAWN_LIQUIDATED
    }
    struct Plan {
        uint256 amount;
        uint32 downPaymentPercent;
        uint32 interestRate;
        uint32 serviceFeeRate;
        uint32 term;
        uint8 totalNumberOfPayments;
        uint8 counterPaidPayments;
        uint8 autoRepayStatus;
    }
    struct PaymentPlan {
        Plan plan;
        uint256 createdDate;
        address cyanWalletAddress;
        PaymentPlanStatus status;
    }

    struct Item {
        uint256 amount;
        uint256 tokenId;
        address contractAddress;
        address cyanVaultAddress;
        // 1 -> ERC721
        // 2 -> ERC1155
        // 3 -> CryptoPunks
        uint8 itemType;
    }
    mapping(uint256 => Item) public items;
    mapping(uint256 => PaymentPlan) public paymentPlan;
    mapping(address => uint256) public claimableServiceFee;

    bytes32 public constant CYAN_ROLE = keccak256("CYAN_ROLE");
    bytes32 public constant CYAN_AUTO_OPERATOR_ROLE = keccak256("CYAN_AUTO_OPERATOR_ROLE");
    address private cyanSigner;
    address private walletFactory;
    uint256 private BASE_DISCOUNT_RATE;

    function initialize(
        address _cyanSigner,
        address _cyanSuperAdmin,
        address _walletFactory,
        uint256 _baseDiscountRate
    ) external initializer {
        if (_cyanSigner == address(0) || _cyanSuperAdmin == address(0) || _walletFactory == address(0)) {
            revert InvalidAddress();
        }
        if (_baseDiscountRate > 10000) revert InvalidBaseDiscountRate();

        cyanSigner = _cyanSigner;
        walletFactory = _walletFactory;
        _setupRole(DEFAULT_ADMIN_ROLE, _cyanSuperAdmin);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        BASE_DISCOUNT_RATE = _baseDiscountRate;

        __AccessControl_init();
        __ReentrancyGuard_init();

        emit UpdatedCyanSigner(_cyanSigner);
        emit UpdatedWalletFactory(_walletFactory);
        emit UpdateBaseDiscountRate(_baseDiscountRate);
    }

    /**
     * @notice Creating a BNPL plan
     * @param item Item detail to BNPL
     * @param plan BNPL plan detail
     * @param planId Plan ID
     * @param signedBlockNum Signed block number
     * @param signature Signature from Cyan
     */
    function createBNPL(
        Item calldata item,
        Plan calldata plan,
        uint256 planId,
        uint256 signedBlockNum,
        bytes memory signature
    ) external payable nonReentrant {
        requireCorrectPlanParams(item, plan, planId, signedBlockNum);
        verifySignature(item, plan, planId, signedBlockNum, signature);
        if (plan.downPaymentPercent == 0 || plan.downPaymentPercent >= 10000) revert InvalidDownPaymentPercent();
        if (plan.totalNumberOfPayments <= 1) revert InvalidTotalNumberOfPayments();
        if (plan.counterPaidPayments != 1) revert InvalidPaidCount();

        (, , uint256 singleServiceFee, , , , uint256 downPaymentAmount, ) = calculatePaymentInfo(plan);

        address currencyAddress = getCurrencyAddressByVaultAddress(item.cyanVaultAddress);
        if (currencyAddress == address(0)) {
            if (msg.value == 0) revert InvalidDownPayment();
            if (singleServiceFee + downPaymentAmount != msg.value) revert InvalidDownPayment();
        } else {
            if (msg.value != 0) revert InvalidDownPayment();
            IERC20Upgradeable erc20Contract = IERC20Upgradeable(currencyAddress);
            erc20Contract.safeTransferFrom(msg.sender, address(this), singleServiceFee + downPaymentAmount);
        }
        address cyanWalletAddress = IFactory(walletFactory).getOrDeployWallet(msg.sender);
        paymentPlan[planId] = PaymentPlan(plan, block.timestamp, cyanWalletAddress, PaymentPlanStatus.BNPL_CREATED);
        items[planId] = item;
        emit CreatedBNPL(planId);
    }

    /**
     * @notice Lending ETH from Vault for BNPL payment plan
     * @param planId Payment plan ID
     */
    function fundBNPL(uint256 planId) external nonReentrant onlyRole(CYAN_ROLE) {
        if (paymentPlan[planId].plan.counterPaidPayments != 1) revert InvalidPaidCount();
        if (paymentPlan[planId].status != PaymentPlanStatus.BNPL_CREATED) revert InvalidStage();

        paymentPlan[planId].status = PaymentPlanStatus.BNPL_FUNDED;
        CyanVaultV2(payable(items[planId].cyanVaultAddress)).lend(msg.sender, paymentPlan[planId].plan.amount);

        emit UpdatedBNPL(planId, PaymentPlanStatus.BNPL_FUNDED);
    }

    /**
     * @notice Activate BNPL payment plan
     * @param planId Payment plan ID
     */
    function activateBNPL(uint256 planId) external nonReentrant onlyRole(CYAN_ROLE) {
        if (paymentPlan[planId].plan.counterPaidPayments != 1) revert InvalidPaidCount();
        if (
            paymentPlan[planId].status != PaymentPlanStatus.BNPL_CREATED &&
            paymentPlan[planId].status != PaymentPlanStatus.BNPL_FUNDED
        ) revert InvalidStage();

        (, , uint256 singleServiceFee, , , , uint256 downPaymentAmount, ) = calculatePaymentInfo(
            paymentPlan[planId].plan
        );

        address _cyanVaultAddress = items[planId].cyanVaultAddress;
        address currencyAddress = getCurrencyAddressByVaultAddress(_cyanVaultAddress);
        claimableServiceFee[currencyAddress] += singleServiceFee;
        if (paymentPlan[planId].status == PaymentPlanStatus.BNPL_CREATED) {
            // Admin already funded the plan, so Vault is transfering equal amount of ETH back to admin.
            CyanVaultV2(payable(_cyanVaultAddress)).lend(msg.sender, paymentPlan[planId].plan.amount);
        }
        transferItemAndLock(items[planId], msg.sender, paymentPlan[planId].cyanWalletAddress);
        transferEarnedAmountToCyanVault(_cyanVaultAddress, downPaymentAmount, 0);

        paymentPlan[planId].status = PaymentPlanStatus.BNPL_ACTIVE;
        emit UpdatedBNPL(planId, PaymentPlanStatus.BNPL_ACTIVE);
    }

    /**
     * @notice Rejecting a BNPL payment plan
     * @param planId Payment Plan ID
     */
    function rejectBNPLPaymentPlan(uint256 planId) external payable nonReentrant onlyRole(CYAN_ROLE) {
        if (paymentPlan[planId].plan.counterPaidPayments != 1) revert InvalidPaidCount();
        if (
            paymentPlan[planId].status != PaymentPlanStatus.BNPL_CREATED &&
            paymentPlan[planId].status != PaymentPlanStatus.BNPL_FUNDED
        ) {
            revert InvalidStage();
        }

        (, , uint256 singleServiceFee, , , , uint256 downPaymentAmount, ) = calculatePaymentInfo(
            paymentPlan[planId].plan
        );

        // Returning downpayment to created user address
        address currencyAddress = getCurrencyAddressByPlanId(planId);
        address createdUserAddress = getMainWalletAddress(paymentPlan[planId].cyanWalletAddress);
        if (currencyAddress == address(0)) {
            (bool success, ) = payable(createdUserAddress).call{value: downPaymentAmount + singleServiceFee}("");
            require(success, "Payment failed: ETH transfer");
        } else {
            IERC20Upgradeable erc20Contract = IERC20Upgradeable(currencyAddress);
            erc20Contract.safeTransfer(createdUserAddress, downPaymentAmount + singleServiceFee);
        }
        if (paymentPlan[planId].status == PaymentPlanStatus.BNPL_FUNDED) {
            if (currencyAddress == address(0)) {
                if (paymentPlan[planId].plan.amount != msg.value) revert InvalidAmount();
            } else {
                if (msg.value != 0) revert InvalidAmount();
                IERC20Upgradeable erc20Contract = IERC20Upgradeable(currencyAddress);
                erc20Contract.safeTransferFrom(msg.sender, address(this), paymentPlan[planId].plan.amount);
            }

            // Returning funded amount back to Vault
            transferEarnedAmountToCyanVault(items[planId].cyanVaultAddress, paymentPlan[planId].plan.amount, 0);
        } else if (msg.value > 0) {
            revert InvalidAmount();
        }
        paymentPlan[planId].status = PaymentPlanStatus.BNPL_REJECTED;
        emit UpdatedBNPL(planId, PaymentPlanStatus.BNPL_REJECTED);
    }

    /**
     * @notice Creating a pawn plan
     * @param item Item detail to pawn
     * @param plan Pawn plan detail
     * @param planId Plan ID
     * @param signedBlockNum Signed block number
     * @param signature Signature from Cyan
     */
    function createPawn(
        Item calldata item,
        Plan calldata plan,
        uint256 planId,
        uint256 signedBlockNum,
        bytes memory signature
    ) external nonReentrant {
        requireCorrectPlanParams(item, plan, planId, signedBlockNum);
        verifySignature(item, plan, planId, signedBlockNum, signature);
        if (plan.downPaymentPercent != 0) revert InvalidDownPaymentPercent();
        if (plan.totalNumberOfPayments == 0) revert InvalidTotalNumberOfPayments();
        if (plan.counterPaidPayments != 0) revert InvalidPaidCount();

        address mainAddress = msg.sender;
        address cyanWalletAddress = IFactory(walletFactory).getOrDeployWallet(msg.sender);
        if (cyanWalletAddress == msg.sender) {
            mainAddress = getMainWalletAddress(cyanWalletAddress);
        }
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
        if (isTransferRequired) {
            transferItemAndLock(item, mainAddress, cyanWalletAddress);
        } else {
            setLockState(item, cyanWalletAddress, true);
        }
        CyanVaultV2(payable(item.cyanVaultAddress)).lend(mainAddress, plan.amount);

        items[planId] = item;
        paymentPlan[planId] = PaymentPlan(plan, block.timestamp, cyanWalletAddress, PaymentPlanStatus.PAWN_ACTIVE);
        emit CreatedPawn(planId);
    }

    /**
     * @notice Make a payment for the payment plan
     * @param planId Payment Plan ID
     * @param isEarlyPayment If true, payment will be made for the whole plan
     */
    function pay(uint256 planId, bool isEarlyPayment) external payable nonReentrant {
        requireActivePlan(planId);
        Plan memory plan = paymentPlan[planId].plan;

        uint8 numOfRemainingPayments = plan.totalNumberOfPayments - plan.counterPaidPayments;
        bool shouldComplete = isEarlyPayment || numOfRemainingPayments == 1;

        (
            uint256 payAmountForCollateral,
            uint256 payAmountForInterest,
            uint256 payAmountForService,
            uint256 currentPayment,

        ) = getPaymentInfoByPlanId(planId, shouldComplete);

        address currencyAddress = getCurrencyAddressByPlanId(planId);
        if (currencyAddress == address(0)) {
            if (currentPayment != msg.value) revert InvalidAmount();
        } else {
            if (msg.value != 0) revert InvalidAmount();
            IERC20Upgradeable erc20Contract = IERC20Upgradeable(currencyAddress);
            erc20Contract.safeTransferFrom(msg.sender, address(this), currentPayment);
        }
        claimableServiceFee[currencyAddress] += payAmountForService;
        transferEarnedAmountToCyanVault(items[planId].cyanVaultAddress, payAmountForCollateral, payAmountForInterest);

        if (shouldComplete) {
            paymentPlan[planId].plan.counterPaidPayments = plan.totalNumberOfPayments;
            paymentPlan[planId].status = isBNPL(planId)
                ? PaymentPlanStatus.BNPL_COMPLETED
                : PaymentPlanStatus.PAWN_COMPLETED;
            setLockState(items[planId], paymentPlan[planId].cyanWalletAddress, false);

            if (isEarlyPayment) {
                emit CompletedEarly(planId, BASE_DISCOUNT_RATE, numOfRemainingPayments);
            } else {
                emit Completed(planId);
            }
        } else {
            ++paymentPlan[planId].plan.counterPaidPayments;
            emit Paid(planId);
        }
    }

    /**
     * @notice Return early payment info
     * @param plan Plan details
     * @param isEarlyPayment Is paying early
     * @return Remaining payment amount for collateral
     * @return Remaining payment amount for interest fee
     * @return Remaining payment amount for service fee
     * @return Remaining total payment amount
     */
    function getPaymentInfo(Plan memory plan, bool isEarlyPayment)
        private
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        (
            uint256 loanAmount,
            uint256 interestFee,
            uint256 serviceFee,
            uint256 totalLoanAmount,
            uint256 totalInterestFee,
            uint256 totalServiceFee,
            ,
            uint8 payCountWithoutDownPayment
        ) = calculatePaymentInfo(plan);

        uint8 remainingNumOfPayments = plan.totalNumberOfPayments - plan.counterPaidPayments;
        if (isEarlyPayment || remainingNumOfPayments == 1) {
            uint8 paidCountWithoutDownPayment = plan.counterPaidPayments - (plan.downPaymentPercent > 0 ? 1 : 0);
            loanAmount = totalLoanAmount - loanAmount * paidCountWithoutDownPayment;
            interestFee = totalInterestFee - interestFee * paidCountWithoutDownPayment;
            serviceFee = totalServiceFee - serviceFee * plan.counterPaidPayments;

            if (remainingNumOfPayments > 1) {
                interestFee -=
                    (interestFee * BASE_DISCOUNT_RATE * remainingNumOfPayments) /
                    (10000 * payCountWithoutDownPayment);
            }
        }
        return (loanAmount, interestFee, serviceFee, loanAmount + interestFee + serviceFee);
    }

    function getPaymentInfoByPlanId(uint256 planId, bool isEarlyPayment)
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        if (paymentPlan[planId].plan.totalNumberOfPayments == 0) revert PaymentPlanNotFound();
        uint8 nextPaymentCount = paymentPlan[planId].plan.counterPaidPayments +
            (paymentPlan[planId].plan.downPaymentPercent > 0 ? 0 : 1);
        uint256 dueDate = paymentPlan[planId].createdDate + paymentPlan[planId].plan.term * nextPaymentCount;

        (
            uint256 payAmountForCollateral,
            uint256 payAmountForInterest,
            uint256 payAmountForService,
            uint256 currentPayment
        ) = getPaymentInfo(paymentPlan[planId].plan, isEarlyPayment);
        return (payAmountForCollateral, payAmountForInterest, payAmountForService, currentPayment, dueDate);
    }

    /**
     * @notice Liquidate defaulted payment plan
     * @param planId Payment Plan ID
     * @param estimatedValue Estimated value of defaulted assets
     */
    function liquidate(uint256 planId, uint256 estimatedValue) external nonReentrant onlyRole(CYAN_ROLE) {
        requireDefaultedPlan(planId);
        if (estimatedValue == 0) revert InvalidAmount();

        (uint256 unpaidAmount, , , , ) = getPaymentInfoByPlanId(planId, true);
        address _cyanVaultAddress = items[planId].cyanVaultAddress;
        IWallet wallet = IWallet(paymentPlan[planId].cyanWalletAddress);
        if (items[planId].itemType == 1) {
            // ERC721
            wallet.executeModule(
                abi.encodeWithSelector(
                    IWallet.transferDefaultedERC721.selector,
                    items[planId].contractAddress,
                    items[planId].tokenId,
                    _cyanVaultAddress
                )
            );
        } else if (items[planId].itemType == 2) {
            // ERC1155
            wallet.executeModule(
                abi.encodeWithSelector(
                    IWallet.transferDefaultedERC1155.selector,
                    items[planId].contractAddress,
                    items[planId].tokenId,
                    items[planId].amount,
                    _cyanVaultAddress
                )
            );
        } else if (items[planId].itemType == 3) {
            // CryptoPunks
            wallet.executeModule(
                abi.encodeWithSelector(
                    IWallet.transferDefaultedCryptoPunk.selector,
                    items[planId].tokenId,
                    _cyanVaultAddress
                )
            );
        }

        paymentPlan[planId].status = isBNPL(planId)
            ? PaymentPlanStatus.BNPL_LIQUIDATED
            : PaymentPlanStatus.PAWN_LIQUIDATED;
        CyanVaultV2(payable(_cyanVaultAddress)).nftDefaulted(unpaidAmount, estimatedValue);

        emit LiquidatedPaymentPlan(planId, estimatedValue, unpaidAmount);
    }

    /**
     * @notice Triggers auto repayment from the cyan wallet
     * @param planId Payment Plan ID
     */
    function triggerAutoRepay(uint256 planId) external onlyRole(CYAN_AUTO_OPERATOR_ROLE) {
        if (paymentPlan[planId].plan.autoRepayStatus != 1) revert InvalidAutoRepaymentStatus();
        requireActivePlan(planId);

        (, , , uint256 payAmount, uint256 dueDate) = getPaymentInfoByPlanId(planId, false);
        if ((dueDate - 1 days) > block.timestamp) revert InvalidAutoRepaymentDate();

        IWallet(paymentPlan[planId].cyanWalletAddress).executeModule(
            abi.encodeWithSelector(IWallet.autoPay.selector, planId, payAmount)
        );
    }

    /**
     * @notice Revive defaulted payment plan with penalty
     * @param planId Payment Plan ID
     * @param penaltyAmount Amount that penalizes Defaulted plan revival
     * @param signature Signature signed by Cyan signer
     */
    function revive(
        uint256 planId,
        uint256 penaltyAmount,
        bytes memory signature
    ) external payable nonReentrant {
        verifyRevivalSignature(planId, penaltyAmount, signature);
        requireDefaultedPlan(planId);

        (
            uint256 payAmountForCollateral,
            uint256 payAmountForInterest,
            uint256 payAmountForService,
            uint256 currentPayment,
            uint256 dueDate
        ) = getPaymentInfoByPlanId(planId, false);
        if (dueDate + paymentPlan[planId].plan.term <= block.timestamp) revert InvalidReviveDate();

        address currencyAddress = getCurrencyAddressByPlanId(planId);
        if (currencyAddress == address(0)) {
            if (currentPayment + penaltyAmount != msg.value) revert InvalidAmount();
        } else {
            if (msg.value != 0) revert InvalidAmount();
            IERC20Upgradeable erc20Contract = IERC20Upgradeable(currencyAddress);
            erc20Contract.safeTransferFrom(msg.sender, address(this), currentPayment + penaltyAmount);
        }

        ++paymentPlan[planId].plan.counterPaidPayments;
        claimableServiceFee[currencyAddress] += payAmountForService;

        transferEarnedAmountToCyanVault(
            items[planId].cyanVaultAddress,
            payAmountForCollateral,
            payAmountForInterest + penaltyAmount
        );
        if (paymentPlan[planId].plan.counterPaidPayments == paymentPlan[planId].plan.totalNumberOfPayments) {
            paymentPlan[planId].status = isBNPL(planId)
                ? PaymentPlanStatus.BNPL_COMPLETED
                : PaymentPlanStatus.PAWN_COMPLETED;
            setLockState(items[planId], paymentPlan[planId].cyanWalletAddress, false);
            emit CompletedByRevival(planId, penaltyAmount);
        } else {
            emit Revived(planId, penaltyAmount);
        }
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
    ) private {
        address currencyAddress = getCurrencyAddressByVaultAddress(cyanVaultAddress);
        if (currencyAddress == address(0)) {
            CyanVaultV2(payable(cyanVaultAddress)).earn{value: paidTokenPayment + paidInterestFee}(
                paidTokenPayment,
                paidInterestFee
            );
        } else {
            IERC20Upgradeable erc20Contract = IERC20Upgradeable(currencyAddress);
            erc20Contract.approve(cyanVaultAddress, paidTokenPayment + paidInterestFee);
            CyanVaultV2(payable(cyanVaultAddress)).earn(paidTokenPayment, paidInterestFee);
        }
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
            uint256 singleLoanAmount,
            uint256 singleInterestFee,
            uint256 singleServiceFee,
            ,
            uint256 totalInterestFee,
            uint256 totalServiceFee,
            uint256 downPaymentAmount,

        ) = calculatePaymentInfo(plan);
        uint256 totalFinancingAmount = plan.amount + totalInterestFee + totalServiceFee;

        return (
            plan.downPaymentPercent > 0 ? downPaymentAmount + singleServiceFee : 0,
            totalInterestFee,
            totalServiceFee,
            singleLoanAmount + singleInterestFee + singleServiceFee,
            totalFinancingAmount
        );
    }

    function calculatePaymentInfo(Plan memory plan)
        private
        pure
        returns (
            uint256 singleLoanAmount,
            uint256 singleInterestFee,
            uint256 singleServiceFee,
            uint256 totalLoanAmount,
            uint256 totalInterestFee,
            uint256 totalServiceFee,
            uint256 downPaymentAmount,
            uint8 payCountWithoutDownPayment
        )
    {
        payCountWithoutDownPayment = plan.totalNumberOfPayments - (plan.downPaymentPercent > 0 ? 1 : 0);
        downPaymentAmount = (plan.amount * plan.downPaymentPercent) / 10000;

        totalLoanAmount = plan.amount - downPaymentAmount;
        totalInterestFee = (totalLoanAmount * plan.interestRate) / 10000;
        totalServiceFee = (plan.amount * plan.serviceFeeRate) / 10000;

        singleLoanAmount = totalLoanAmount / payCountWithoutDownPayment;
        singleInterestFee = totalInterestFee / payCountWithoutDownPayment;
        singleServiceFee = totalServiceFee / plan.totalNumberOfPayments;
    }

    /**
     * @notice Check if payment plan is pending
     * @param planId Payment Plan ID
     * @return PaymentPlanStatus
     */
    function getPlanStatus(uint256 planId) public view returns (PaymentPlanStatus) {
        if (
            paymentPlan[planId].status == PaymentPlanStatus.BNPL_ACTIVE ||
            paymentPlan[planId].status == PaymentPlanStatus.PAWN_ACTIVE
        ) {
            (, , , , uint256 dueDate) = getPaymentInfoByPlanId(planId, false);
            bool isDefaulted = block.timestamp > dueDate;

            if (isDefaulted) {
                return
                    paymentPlan[planId].status == PaymentPlanStatus.BNPL_ACTIVE
                        ? PaymentPlanStatus.BNPL_DEFAULTED
                        : PaymentPlanStatus.PAWN_DEFAULTED;
            }
        }

        return paymentPlan[planId].status;
    }

    /**
     * @notice Return true if plan is BNPL by checking status
     * @param planId Payment plan ID
     * @return Is BNPL
     */
    function isBNPL(uint256 planId) private view returns (bool) {
        return
            paymentPlan[planId].status == PaymentPlanStatus.BNPL_CREATED ||
            paymentPlan[planId].status == PaymentPlanStatus.BNPL_FUNDED ||
            paymentPlan[planId].status == PaymentPlanStatus.BNPL_ACTIVE ||
            paymentPlan[planId].status == PaymentPlanStatus.BNPL_DEFAULTED ||
            paymentPlan[planId].status == PaymentPlanStatus.BNPL_REJECTED ||
            paymentPlan[planId].status == PaymentPlanStatus.BNPL_COMPLETED ||
            paymentPlan[planId].status == PaymentPlanStatus.BNPL_LIQUIDATED;
    }

    /**
     * @notice Transfers token to CyanWallet and locks it
     * @param item Transferring item
     * @param cyanWalletAddress Cyan Wallet address
     */
    function transferItemAndLock(
        Item memory item,
        address from,
        address cyanWalletAddress
    ) private {
        if (item.itemType == 1) {
            // ERC721
            ERC721Upgradeable erc721Contract = ERC721Upgradeable(item.contractAddress);
            erc721Contract.safeTransferFrom(from, cyanWalletAddress, item.tokenId);
        } else if (item.itemType == 2) {
            // ERC1155
            ERC1155Upgradeable erc1155Contract = ERC1155Upgradeable(item.contractAddress);
            erc1155Contract.safeTransferFrom(from, cyanWalletAddress, item.tokenId, item.amount, bytes(""));
        } else if (item.itemType == 3) {
            // CryptoPunks
            ICryptoPunk cryptoPunkContract = ICryptoPunk(item.contractAddress);
            cryptoPunkContract.buyPunk{value: 0}(item.tokenId);
            cryptoPunkContract.transferPunk(cyanWalletAddress, item.tokenId);
        }
        setLockState(item, cyanWalletAddress, true);
    }

    /**
     * @notice Update locking status of a token in Cyan Wallet
     * @param item Locking/unlocking item
     * @param cyanWalletAddress Cyan Wallet address
     * @param state Token will be locked if true
     */
    function setLockState(
        Item memory item,
        address cyanWalletAddress,
        bool state
    ) private {
        IWallet wallet = IWallet(cyanWalletAddress);
        if (item.itemType == 1) {
            // ERC721
            wallet.executeModule(
                abi.encodeWithSelector(IWallet.setLockedERC721Token.selector, item.contractAddress, item.tokenId, state)
            );
        } else if (item.itemType == 2) {
            // ERC1155
            wallet.executeModule(
                abi.encodeWithSelector(
                    state ? IWallet.increaseLockedERC1155Token.selector : IWallet.decreaseLockedERC1155Token.selector,
                    item.contractAddress,
                    item.tokenId,
                    item.amount
                )
            );
        } else if (item.itemType == 3) {
            // CryptoPunks
            wallet.executeModule(abi.encodeWithSelector(IWallet.setLockedCryptoPunk.selector, item.tokenId, state));
        }
    }

    /**
     * @notice Updating base discount rate
     * @param _baseDiscountRate New base discount rate
     */
    function updateBaseDiscountRate(uint256 _baseDiscountRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_baseDiscountRate > 10000) revert InvalidBaseDiscountRate();
        BASE_DISCOUNT_RATE = _baseDiscountRate;
        emit UpdateBaseDiscountRate(_baseDiscountRate);
    }

    /**
     * @notice Getting claimable service fee amount
     * @param currencyAddress Currency address
     */
    function getClaimableServiceFee(address currencyAddress) external view returns (uint256) {
        return claimableServiceFee[currencyAddress];
    }

    /**
     * @notice Updating Cyan signer address
     * @param _cyanSigner New Cyan signer address
     */
    function updateCyanSignerAddress(address _cyanSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_cyanSigner == address(0)) revert InvalidAddress();
        cyanSigner = _cyanSigner;
        emit UpdatedCyanSigner(_cyanSigner);
    }

    /**
     * @notice Claiming collected service fee amount
     * @param currencyAddress Currency address
     */
    function claimServiceFee(address currencyAddress) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        emit ClaimedServiceFee(currencyAddress, claimableServiceFee[currencyAddress]);
        if (currencyAddress == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: claimableServiceFee[currencyAddress]}("");
            require(success, "Payment failed: ETH transfer");
        } else {
            IERC20Upgradeable erc20Contract = IERC20Upgradeable(currencyAddress);
            erc20Contract.safeTransfer(msg.sender, claimableServiceFee[currencyAddress]);
        }
        claimableServiceFee[currencyAddress] = 0;
    }

    /**
     * @notice Updating Cyan wallet factory address that used for deploying new wallets
     * @param factory New Cyan wallet factory address
     */
    function updateWalletFactoryAddress(address factory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (factory == address(0)) revert InvalidAddress();
        walletFactory = factory;
        emit UpdatedWalletFactory(factory);
    }

    /**
     * @notice Setting auto repay status for a payment plan
     * @param planId Payment plan ID
     * @param autoRepayStatus Auto repay status
     */
    function setAutoRepayStatus(uint256 planId, uint8 autoRepayStatus) external {
        address mainWalletAddress = getMainWalletAddress(paymentPlan[planId].cyanWalletAddress);
        if (mainWalletAddress != msg.sender && paymentPlan[planId].cyanWalletAddress != msg.sender) {
            revert InvalidSender();
        }
        paymentPlan[planId].plan.autoRepayStatus = autoRepayStatus;
        emit SetAutoRepayStatus(planId, autoRepayStatus);
    }

    /**
     * @notice Getting currency address by plan ID
     * @param planId Payment plan ID
     */
    function getCurrencyAddressByPlanId(uint256 planId) public view returns (address) {
        return getCurrencyAddressByVaultAddress(items[planId].cyanVaultAddress);
    }

    /**
     * @notice Getting currency address by vault address
     * @param vaultAddress Cyan Vault address
     */
    function getCurrencyAddressByVaultAddress(address vaultAddress) private view returns (address) {
        return CyanVaultV2(payable(vaultAddress)).getCurrencyAddress();
    }

    /**
     * @notice Getting main wallet address by Cyan wallet address
     * @param cyanWalletAddress Cyan wallet address
     */
    function getMainWalletAddress(address cyanWalletAddress) private view returns (address) {
        return IFactory(walletFactory).getWalletOwner(cyanWalletAddress);
    }

    function verifySignature(
        Item calldata item,
        Plan calldata plan,
        uint256 planId,
        uint256 signedBlockNum,
        bytes memory signature
    ) private view {
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
        bytes32 msgHash = keccak256(abi.encodePacked(itemHash, planHash, planId, signedBlockNum));
        bytes32 signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        if (signedHash.recover(signature) != cyanSigner) revert InvalidSignature();
    }

    function verifyRevivalSignature(
        uint256 planId,
        uint256 penaltyAmount,
        bytes memory signature
    ) internal view {
        bytes32 msgHash = keccak256(
            abi.encodePacked(planId, penaltyAmount, paymentPlan[planId].plan.counterPaidPayments)
        );
        bytes32 signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        if (signedHash.recover(signature) != cyanSigner) revert InvalidSignature();
    }

    function requireActivePlan(uint256 planId) private view {
        PaymentPlanStatus status = getPlanStatus(planId);
        if (status != PaymentPlanStatus.BNPL_ACTIVE && status != PaymentPlanStatus.PAWN_ACTIVE) revert InvalidStage();
    }

    function requireDefaultedPlan(uint256 planId) private view {
        PaymentPlanStatus status = getPlanStatus(planId);
        if (status != PaymentPlanStatus.BNPL_DEFAULTED && status != PaymentPlanStatus.PAWN_DEFAULTED)
            revert InvalidStage();
    }

    function requireCorrectPlanParams(
        Item memory item,
        Plan memory plan,
        uint256 planId,
        uint256 signedBlockNum
    ) private view {
        if (item.contractAddress == address(0)) revert InvalidAddress();
        if (item.cyanVaultAddress == address(0)) revert InvalidAddress();
        if (item.itemType < 1 || item.itemType > 3) revert InvalidItem();
        if (item.itemType == 1 && item.amount != 0) revert InvalidItem();
        if (item.itemType == 2 && item.amount == 0) revert InvalidItem();
        if (item.itemType == 3 && item.amount != 0) revert InvalidItem();

        if (paymentPlan[planId].plan.totalNumberOfPayments != 0) revert PaymentPlanAlreadyExists();
        if (signedBlockNum > block.number) revert InvalidBlockNumber();
        if (signedBlockNum + 50 < block.number) revert InvalidSignature();
        if (plan.serviceFeeRate > 300) revert InvalidServiceFeeRate();
        if (plan.amount == 0) revert InvalidTokenPrice();
        if (plan.interestRate == 0) revert InvalidInterestRate();
        if (plan.term == 0) revert InvalidTerm();
    }
}
