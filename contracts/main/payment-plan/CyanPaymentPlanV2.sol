// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../../interfaces/core/IFactory.sol";
import "../../interfaces/main/ICyanVaultV2.sol";
import "../../interfaces/main/ICyanPaymentPlanV2.sol";
import "../../interfaces/conduit/ICyanConduit.sol";

import "../AddressProvider.sol";
import "./PaymentPlanV2Logic.sol";
import "../CyanWalletLogic.sol";

/// @title Cyan Payment Plan - Main logic of BNPL and Pawn plan
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
contract CyanPaymentPlanV2 is ICyanPaymentPlanV2, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    AddressProvider private constant addressProvider = AddressProvider(0xCF9A19D879769aDaE5e4f31503AAECDa82568E55);

    using SafeERC20Upgradeable for IERC20Upgradeable;

    event CreatedBNPL(uint256 indexed planId);
    event CreatedPawn(uint256 indexed planId, PawnCreateType createType);
    event UpdatedBNPL(uint256 indexed planId, PaymentPlanStatus indexed planStatus);
    event LiquidatedPaymentPlan(uint256 indexed planId, uint256 indexed estimatedPrice, uint256 indexed unpaidAmount);
    event Paid(uint256 indexed planId);
    event Completed(uint256 indexed planId);
    event CompletedByRevival(uint256 indexed planId, uint256 penaltyAmount);
    event CompletedEarly(uint256 indexed planId, uint8 indexed paidNumOfPayment);
    event EarlyUnwind(uint256 indexed planId);
    event Revived(uint256 indexed planId, uint256 penaltyAmount);
    event UpdatedCyanSigner(address indexed signer);
    event ClaimedServiceFee(address indexed currency, uint256 indexed amount);
    event UpdatedWalletFactory(address indexed factory);
    event SetAutoRepayStatus(uint256 indexed planId, uint8 indexed autoRepayStatus);

    mapping(uint256 => Item) public items;
    mapping(uint256 => PaymentPlan) public paymentPlan;
    mapping(address => uint256) public claimableServiceFee;

    bytes32 private constant CYAN_ROLE = keccak256("CYAN_ROLE");
    bytes32 private constant CYAN_AUTO_OPERATOR_ROLE = keccak256("CYAN_AUTO_OPERATOR_ROLE");
    bytes32 private constant CYAN_CONDUIT = "CYAN_CONDUIT";
    address private cyanSigner;
    address private walletFactory;
    uint256 private __unused; // unused variable to prevent storage slot collision

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _cyanSigner,
        address _cyanSuperAdmin,
        address _walletFactory
    ) external initializer {
        if (_cyanSigner == address(0) || _cyanSuperAdmin == address(0) || _walletFactory == address(0)) {
            revert InvalidAddress();
        }

        cyanSigner = _cyanSigner;
        walletFactory = _walletFactory;
        _setupRole(DEFAULT_ADMIN_ROLE, _cyanSuperAdmin);

        __AccessControl_init();
        __ReentrancyGuard_init();

        emit UpdatedCyanSigner(_cyanSigner);
        emit UpdatedWalletFactory(_walletFactory);
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
        PaymentPlanV2Logic.requireCorrectPlanParams(true, item, plan, signedBlockNum);
        PaymentPlanV2Logic.verifySignature(item, plan, planId, signedBlockNum, block.chainid, cyanSigner, signature);

        if (paymentPlan[planId].plan.totalNumberOfPayments != 0) revert PaymentPlanAlreadyExists();

        (PaymentAmountInfo memory singleAmounts, , uint256 downPaymentAmount, ) = PaymentPlanV2Logic
            .calculatePaymentInfo(plan);

        address currencyAddress = PaymentPlanV2Logic.getCurrencyAddressByVaultAddress(item.cyanVaultAddress);
        receiveCurrency(currencyAddress, singleAmounts.serviceAmount + downPaymentAmount, msg.sender);

        address cyanWalletAddress = IFactory(walletFactory).getOrDeployWallet(msg.sender);
        paymentPlan[planId] = PaymentPlan(plan, block.timestamp, cyanWalletAddress, PaymentPlanStatus.BNPL_CREATED);
        items[planId] = item;
        emit CreatedBNPL(planId);
    }

    /**
     * @notice Lending loaned currency from Vault for BNPL payment plan
     * @param planIds Payment plan IDs
     */
    function fundBNPL(uint256[] calldata planIds) external nonReentrant onlyRole(CYAN_ROLE) {
        for (uint256 i; i < planIds.length; ++i) {
            uint256 planId = planIds[i];
            PaymentPlan storage _paymentPlan = paymentPlan[planId];
            ICyanVaultV2(payable(items[planId].cyanVaultAddress)).lend(msg.sender, _paymentPlan.plan.amount);

            if (_paymentPlan.plan.counterPaidPayments != 1) revert InvalidPaidCount();
            if (_paymentPlan.status != PaymentPlanStatus.BNPL_CREATED) revert InvalidStage();

            _paymentPlan.status = PaymentPlanStatus.BNPL_FUNDED;
            emit UpdatedBNPL(planId, PaymentPlanStatus.BNPL_FUNDED);
        }
    }

    /**
     * @notice Activate BNPL payment plan
     * @param planIds Payment plan IDs
     */
    function activateBNPL(uint256[] calldata planIds) external nonReentrant onlyRole(CYAN_ROLE) {
        for (uint256 i; i < planIds.length; ++i) {
            uint256 planId = planIds[i];
            PaymentPlan storage _paymentPlan = paymentPlan[planId];
            Item memory item = items[planId];

            uint256 serviceAmount = PaymentPlanV2Logic.activate(_paymentPlan, item);
            address currencyAddress = PaymentPlanV2Logic.getCurrencyAddressByVaultAddress(item.cyanVaultAddress);
            claimableServiceFee[currencyAddress] += serviceAmount;

            CyanWalletLogic.transferItemAndLock(msg.sender, _paymentPlan.cyanWalletAddress, item);
            emit UpdatedBNPL(planId, PaymentPlanStatus.BNPL_ACTIVE);
        }
    }

    /**
     * @notice Rejecting a BNPL payment plan
     * @param planId Payment Plan ID
     */
    function rejectBNPL(uint256 planId) external payable nonReentrant onlyRole(CYAN_ROLE) {
        PaymentPlan storage _paymentPlan = paymentPlan[planId];
        if (_paymentPlan.plan.counterPaidPayments != 1) revert InvalidPaidCount();
        if (
            _paymentPlan.status != PaymentPlanStatus.BNPL_CREATED &&
            _paymentPlan.status != PaymentPlanStatus.BNPL_FUNDED
        ) {
            revert InvalidStage();
        }

        (PaymentAmountInfo memory singleAmounts, , uint256 downPaymentAmount, ) = PaymentPlanV2Logic
            .calculatePaymentInfo(_paymentPlan.plan);

        // Returning downpayment to created user address
        address currencyAddress = getCurrencyAddressByPlanId(planId);
        address createdUserAddress = getMainWalletAddress(_paymentPlan.cyanWalletAddress);
        sendCurrency(currencyAddress, downPaymentAmount + singleAmounts.serviceAmount, createdUserAddress);
        if (_paymentPlan.status == PaymentPlanStatus.BNPL_FUNDED) {
            receiveCurrency(currencyAddress, _paymentPlan.plan.amount, msg.sender);

            // Returning funded amount back to Vault
            PaymentPlanV2Logic.transferEarnedAmountToCyanVault(
                items[planId].cyanVaultAddress,
                _paymentPlan.plan.amount,
                0
            );
        } else if (msg.value > 0) {
            revert InvalidAmount();
        }
        _paymentPlan.status = PaymentPlanStatus.BNPL_REJECTED;
        emit UpdatedBNPL(planId, PaymentPlanStatus.BNPL_REJECTED);
    }

    function createPawn(
        Item calldata item,
        Plan calldata plan,
        uint256 planId,
        uint256 signedBlockNum,
        bytes memory signature
    ) external nonReentrant {
        createPawn(item, plan, planId, PawnCreateType.REGULAR, signedBlockNum, signature);
    }

    function createPawnFromBendDao(
        Item calldata item,
        Plan calldata plan,
        uint256 planId,
        uint256 signedBlockNum,
        bytes memory signature
    ) external nonReentrant {
        createPawn(item, plan, planId, PawnCreateType.BEND_DAO, signedBlockNum, signature);
    }

    function createPawnByRefinance(
        Item calldata item,
        Plan calldata plan,
        uint256 planId,
        uint256 existingPlanId,
        uint256 signedBlockNum,
        bytes memory signature
    ) external payable nonReentrant {
        requireActivePlan(existingPlanId);
        PaymentPlan storage existingPaymentPlan = paymentPlan[existingPlanId];

        address lenderMainWalletAddress = checkIsPlanOwner(msg.sender, existingPaymentPlan.cyanWalletAddress);

        // check item and current plan's item
        Item memory existingPlanItem = items[existingPlanId];
        if (
            !(existingPlanItem.tokenId == item.tokenId &&
                existingPlanItem.contractAddress == item.contractAddress &&
                existingPlanItem.itemType == item.itemType &&
                existingPlanItem.amount == item.amount)
        ) revert InvalidItem();

        // check current plan currency and requested loan currency
        address currencyAddress = PaymentPlanV2Logic.getCurrencyAddressByVaultAddress(item.cyanVaultAddress);
        if (currencyAddress != getCurrencyAddressByPlanId(existingPlanId)) revert InvalidCurrency();

        (
            uint256 payAmountForCollateral,
            uint256 payAmountForInterest,
            uint256 payAmountForService,
            uint256 currentPayment,

        ) = getPaymentInfoByPlanId(existingPlanId, true);

        // creating new plan and lending requested loan amount to payment plan
        createPawn(item, plan, planId, PawnCreateType.REFINANCE, signedBlockNum, signature);

        // completing previous active plan
        if (plan.amount < currentPayment) {
            receiveCurrency(currencyAddress, currentPayment - plan.amount, msg.sender);
        } else {
            uint256 transferAmountToUser = plan.amount - currentPayment;
            if (transferAmountToUser > 0) {
                sendCurrency(currencyAddress, transferAmountToUser, lenderMainWalletAddress);
            }
        }

        claimableServiceFee[currencyAddress] += payAmountForService;
        PaymentPlanV2Logic.transferEarnedAmountToCyanVault(
            existingPlanItem.cyanVaultAddress,
            payAmountForCollateral,
            payAmountForInterest
        );

        emit CompletedEarly(
            existingPlanId,
            existingPaymentPlan.plan.totalNumberOfPayments - existingPaymentPlan.plan.counterPaidPayments
        );

        completePaymentPlan(existingPaymentPlan);
    }

    /**
     * @notice Internal function that creates a pawn plan
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
        PawnCreateType createType,
        uint256 signedBlockNum,
        bytes memory signature
    ) private {
        if (paymentPlan[planId].plan.totalNumberOfPayments != 0) revert PaymentPlanAlreadyExists();
        address cyanWalletAddress = IFactory(walletFactory).getOrDeployWallet(msg.sender);
        address mainAddress = msg.sender;
        if (cyanWalletAddress == msg.sender) {
            mainAddress = getMainWalletAddress(cyanWalletAddress);
        }

        bool isTransferRequired = PaymentPlanV2Logic.createPawn(
            item,
            plan,
            planId,
            createType,
            signedBlockNum,
            mainAddress,
            cyanWalletAddress,
            cyanSigner,
            signature
        );

        if (createType != PawnCreateType.REFINANCE) {
            if (isTransferRequired) {
                CyanWalletLogic.transferItemAndLock(mainAddress, cyanWalletAddress, item);
            } else {
                CyanWalletLogic.setLockState(cyanWalletAddress, item, true);
            }
        }

        items[planId] = item;
        paymentPlan[planId] = PaymentPlan(plan, block.timestamp, cyanWalletAddress, PaymentPlanStatus.PAWN_ACTIVE);

        emit CreatedPawn(planId, createType);
    }

    /**
     * @notice Make a payment for the payment plan
     * @param planId Payment Plan ID
     * @param isEarlyPayment If true, payment will be made for the whole plan
     */
    function pay(uint256 planId, bool isEarlyPayment) external payable nonReentrant {
        requireActivePlan(planId);
        PaymentPlan storage _paymentPlan = paymentPlan[planId];

        uint8 numOfRemainingPayments = _paymentPlan.plan.totalNumberOfPayments - _paymentPlan.plan.counterPaidPayments;
        bool shouldComplete = isEarlyPayment || numOfRemainingPayments == 1;

        (
            uint256 payAmountForCollateral,
            uint256 payAmountForInterest,
            uint256 payAmountForService,
            uint256 currentPayment,

        ) = getPaymentInfoByPlanId(planId, shouldComplete);

        address currencyAddress = getCurrencyAddressByPlanId(planId);
        receiveCurrency(currencyAddress, currentPayment, msg.sender);

        claimableServiceFee[currencyAddress] += payAmountForService;
        PaymentPlanV2Logic.transferEarnedAmountToCyanVault(
            items[planId].cyanVaultAddress,
            payAmountForCollateral,
            payAmountForInterest
        );

        if (shouldComplete) {
            completePaymentPlan(_paymentPlan);
            CyanWalletLogic.setLockState(_paymentPlan.cyanWalletAddress, items[planId], false);

            if (isEarlyPayment) {
                emit CompletedEarly(planId, numOfRemainingPayments);
            } else {
                emit Completed(planId);
            }
        } else {
            ++_paymentPlan.plan.counterPaidPayments;
            emit Paid(planId);
        }
    }

    /**
     * @notice Liquidate defaulted payment plan
     * @param planId Payment Plan ID
     * @param apePlanIds Array of ape plan Ids [BAYC/MAYC Ape Plan ID, BAKC Ape Plan ID]
     * @param estimatedValue Estimated value of defaulted assets
     */
    function liquidate(
        uint256 planId,
        uint256[2] calldata apePlanIds,
        uint256 estimatedValue
    ) external nonReentrant {
        if (estimatedValue == 0) revert InvalidAmount();

        PaymentPlan storage _paymentPlan = paymentPlan[planId];
        Item memory _item = items[planId];

        if (msg.sender == _item.cyanVaultAddress) {
            requireActivePlan(planId);
        } else {
            if (!hasRole(CYAN_ROLE, msg.sender)) {
                revert InvalidSender();
            }
            requireDefaultedPlan(planId);
        }

        PaymentPlanV2Logic.checkAndCompleteApePlans(
            _paymentPlan.cyanWalletAddress,
            _item.contractAddress,
            _item.tokenId,
            apePlanIds
        );

        (uint256 unpaidAmount, , , , ) = getPaymentInfoByPlanId(planId, true);

        CyanWalletLogic.setLockState(_paymentPlan.cyanWalletAddress, _item, false);
        CyanWalletLogic.transferNonLockedItem(_paymentPlan.cyanWalletAddress, _item.cyanVaultAddress, _item);

        _paymentPlan.status = isBNPL(_paymentPlan.status)
            ? PaymentPlanStatus.BNPL_LIQUIDATED
            : PaymentPlanStatus.PAWN_LIQUIDATED;
        ICyanVaultV2(payable(_item.cyanVaultAddress)).nftDefaulted(unpaidAmount, estimatedValue);

        emit LiquidatedPaymentPlan(planId, estimatedValue, unpaidAmount);
    }

    /**
     * @notice Triggers auto repayment from the cyan wallet
     * @param planId Payment Plan ID
     */
    function triggerAutoRepay(uint256 planId) external onlyRole(CYAN_AUTO_OPERATOR_ROLE) {
        uint8 autoRepayStatus = paymentPlan[planId].plan.autoRepayStatus;
        if (autoRepayStatus != 1 && autoRepayStatus != 2) revert InvalidAutoRepaymentStatus();
        requireActivePlan(planId);

        (, , , uint256 payAmount, uint256 dueDate) = getPaymentInfoByPlanId(planId, false);
        if ((dueDate - 1 days) > block.timestamp) revert InvalidAutoRepaymentDate();

        address cyanWalletAddress = paymentPlan[planId].cyanWalletAddress;
        if (autoRepayStatus == 2) {
            // Auto-repay from main wallet
            address mainWalletAddress = getMainWalletAddress(cyanWalletAddress);
            address currencyAddress = getCurrencyAddressByPlanId(planId);
            ICyanConduit conduit = ICyanConduit(addressProvider.addresses(CYAN_CONDUIT));

            // Using WETH when currency is native currency
            if (currencyAddress == address(0)) {
                currencyAddress = addressProvider.addresses("WETH");
            }

            conduit.transferERC20(mainWalletAddress, cyanWalletAddress, currencyAddress, payAmount);
        }
        CyanWalletLogic.executeAutoPay(cyanWalletAddress, planId, payAmount, autoRepayStatus);
    }

    /**
     * @notice Early unwind the plan by Opensea offer
     * @param planId Payment Plan ID
     * @param sellPrice Sell price of the token
     * @param offer Offer data to fulfill seaport order
     */
    function earlyUnwindOpensea(
        uint256 planId,
        uint256[2] calldata apePlanIds,
        uint256 sellPrice,
        bytes calldata offer,
        uint256 signatureExpiryDate,
        bytes memory signature
    ) external nonReentrant {
        if (signatureExpiryDate < block.timestamp) revert InvalidSignature();
        PaymentPlanV2Logic.verifyEarlyUnwindByOpeanseaSignature(
            planId,
            sellPrice,
            offer,
            signatureExpiryDate,
            block.chainid,
            cyanSigner,
            signature
        );
        earlyUnwind(planId, apePlanIds, sellPrice, offer, address(0));
    }

    /**
     * @notice Early unwind the plan by Cyan offer
     * @param planId Payment Plan ID
     * @param sellPrice Sell price of the token
     * @param signatureExpiryDate Signature expiry date
     * @param cyanBuyerAddress Buyer address from Cyan
     * @param signature Signature signed by Cyan buyer
     */
    function earlyUnwindCyan(
        uint256 planId,
        uint256[2] calldata apePlanIds,
        uint256 sellPrice,
        address cyanBuyerAddress,
        uint256 signatureExpiryDate,
        bytes memory signature
    ) external nonReentrant {
        if (signatureExpiryDate < block.timestamp) revert InvalidSignature();
        PaymentPlanV2Logic.verifyEarlyUnwindByCyanSignature(
            planId,
            sellPrice,
            signatureExpiryDate,
            block.chainid,
            cyanBuyerAddress,
            signature
        );
        if (!hasRole(CYAN_ROLE, cyanBuyerAddress)) revert InvalidCyanBuyer();

        bytes memory offer; // creating empty offer data
        earlyUnwind(planId, apePlanIds, sellPrice, offer, cyanBuyerAddress);
    }

    /**
     * @notice Internal function to handle the common logic of early unwind operations
     * @param planId Payment Plan ID
     * @param sellPrice Sell price of the token
     * @param offer Offer data to fulfill seaport order
     * @param cyanBuyerAddress Buyer address from Cyan
     */
    function earlyUnwind(
        uint256 planId,
        uint256[2] calldata apePlanIds,
        uint256 sellPrice,
        bytes memory offer,
        address cyanBuyerAddress
    ) private {
        PaymentPlan storage _paymentPlan = paymentPlan[planId];
        Item memory _item = items[planId];
        requireActivePlan(planId);

        address currencyAddress = getCurrencyAddressByPlanId(planId);

        (
            uint256 payAmountForCollateral,
            uint256 payAmountForInterest,
            uint256 payAmountForService,
            uint256 currentPayment,

        ) = getPaymentInfoByPlanId(planId, true);

        if (msg.sender != _item.cyanVaultAddress) {
            checkIsPlanOwner(msg.sender, _paymentPlan.cyanWalletAddress);
        } else {
            if (currentPayment > sellPrice) revert InvalidAmount();
        }

        PaymentPlanV2Logic.checkAndCompleteApePlans(
            _paymentPlan.cyanWalletAddress,
            _item.contractAddress,
            _item.tokenId,
            apePlanIds
        );

        CyanWalletLogic.setLockState(_paymentPlan.cyanWalletAddress, _item, false);
        if (cyanBuyerAddress == address(0)) {
            if (currencyAddress != address(0)) revert InvalidCurrency();
            IWallet(_paymentPlan.cyanWalletAddress).executeModule(
                abi.encodeWithSelector(IWallet.earlyUnwindOpensea.selector, currentPayment, sellPrice, _item, offer)
            );
        } else {
            ICyanConduit(addressProvider.addresses(CYAN_CONDUIT)).transferERC20(
                cyanBuyerAddress,
                _paymentPlan.cyanWalletAddress,
                currencyAddress == address(0) ? addressProvider.addresses("WETH") : currencyAddress,
                sellPrice
            );
            IWallet(_paymentPlan.cyanWalletAddress).executeModule(
                abi.encodeWithSelector(IWallet.earlyUnwindCyan.selector, currentPayment, currencyAddress)
            );
            CyanWalletLogic.transferNonLockedItem(_paymentPlan.cyanWalletAddress, cyanBuyerAddress, _item);
        }

        PaymentPlanV2Logic.receiveCurrencyFromCyanWallet(
            currencyAddress,
            _paymentPlan.cyanWalletAddress,
            currentPayment
        );

        claimableServiceFee[currencyAddress] += payAmountForService;
        PaymentPlanV2Logic.transferEarnedAmountToCyanVault(
            _item.cyanVaultAddress,
            payAmountForCollateral,
            payAmountForInterest
        );
        completePaymentPlan(_paymentPlan);

        emit EarlyUnwind(planId);
    }

    receive() external payable {}

    /**
     * @notice Revive defaulted payment plan with penalty
     * @param planId Payment Plan ID
     * @param penaltyAmount Amount that penalizes Defaulted plan revival
     * @param signatureExpiryDate Signature expiry date
     * @param signature Signature signed by Cyan signer
     */
    function revive(
        uint256 planId,
        uint256 penaltyAmount,
        uint256 signatureExpiryDate,
        bytes memory signature
    ) external payable nonReentrant {
        PaymentPlan storage _paymentPlan = paymentPlan[planId];
        if (signatureExpiryDate < block.timestamp) revert InvalidReviveDate();
        PaymentPlanV2Logic.verifyRevivalSignature(
            planId,
            penaltyAmount,
            signatureExpiryDate,
            block.chainid,
            _paymentPlan.plan.counterPaidPayments,
            cyanSigner,
            signature
        );
        requireDefaultedPlan(planId);

        (
            uint256 payAmountForCollateral,
            uint256 payAmountForInterest,
            uint256 payAmountForService,
            uint256 currentPayment,
            uint256 dueDate
        ) = getPaymentInfoByPlanId(planId, false);
        if (dueDate + _paymentPlan.plan.term <= block.timestamp) revert InvalidReviveDate();

        address currencyAddress = getCurrencyAddressByPlanId(planId);
        receiveCurrency(currencyAddress, currentPayment + penaltyAmount, msg.sender);

        claimableServiceFee[currencyAddress] += payAmountForService;
        PaymentPlanV2Logic.transferEarnedAmountToCyanVault(
            items[planId].cyanVaultAddress,
            payAmountForCollateral,
            payAmountForInterest + penaltyAmount
        );
        if (_paymentPlan.plan.counterPaidPayments + 1 == _paymentPlan.plan.totalNumberOfPayments) {
            completePaymentPlan(_paymentPlan);
            CyanWalletLogic.setLockState(_paymentPlan.cyanWalletAddress, items[planId], false);
            emit CompletedByRevival(planId, penaltyAmount);
        } else {
            ++_paymentPlan.plan.counterPaidPayments;
            emit Revived(planId, penaltyAmount);
        }
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
        Plan memory plan = paymentPlan[planId].plan;
        if (plan.totalNumberOfPayments == 0) revert PaymentPlanNotFound();

        return PaymentPlanV2Logic.getPaymentInfo(plan, isEarlyPayment, paymentPlan[planId].createdDate);
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
        uint256 amount = claimableServiceFee[currencyAddress];
        sendCurrency(currencyAddress, amount, msg.sender);
        claimableServiceFee[currencyAddress] = 0;
        emit ClaimedServiceFee(currencyAddress, amount);
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
        checkIsPlanOwner(msg.sender, paymentPlan[planId].cyanWalletAddress);

        paymentPlan[planId].plan.autoRepayStatus = autoRepayStatus;
        emit SetAutoRepayStatus(planId, autoRepayStatus);
    }

    /**
     * @notice Getting currency address by plan ID
     * @param planId Payment plan ID
     */
    function getCurrencyAddressByPlanId(uint256 planId) public view returns (address) {
        return PaymentPlanV2Logic.getCurrencyAddressByVaultAddress(items[planId].cyanVaultAddress);
    }

    /**
     * @notice Getting main wallet address by Cyan wallet address
     * @param cyanWalletAddress Cyan wallet address
     */
    function getMainWalletAddress(address cyanWalletAddress) private view returns (address) {
        return IFactory(walletFactory).getWalletOwner(cyanWalletAddress);
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

    /**
     * @notice Marks a payment plan as completed.
     * @param _paymentPlan A reference to the PaymentPlan structure being completed
     */
    function completePaymentPlan(PaymentPlan storage _paymentPlan) private {
        _paymentPlan.plan.counterPaidPayments = _paymentPlan.plan.totalNumberOfPayments;
        _paymentPlan.status = isBNPL(_paymentPlan.status)
            ? PaymentPlanStatus.BNPL_COMPLETED
            : PaymentPlanStatus.PAWN_COMPLETED;
    }

    /**
     * @notice Return true if plan is BNPL by checking status
     * @param status Payment plan status
     * @return Is BNPL
     */
    function isBNPL(PaymentPlanStatus status) private pure returns (bool) {
        return
            status == PaymentPlanStatus.BNPL_CREATED ||
            status == PaymentPlanStatus.BNPL_FUNDED ||
            status == PaymentPlanStatus.BNPL_ACTIVE ||
            status == PaymentPlanStatus.BNPL_DEFAULTED ||
            status == PaymentPlanStatus.BNPL_REJECTED ||
            status == PaymentPlanStatus.BNPL_COMPLETED ||
            status == PaymentPlanStatus.BNPL_LIQUIDATED;
    }

    /**
     * @notice Receives currency for transaction. Supports both native and ERC20 tokens.
     * @param currency The address of the currency (address(0) for native, token address for ERC20).
     * @param amount The amount of currency to receive
     * @param from The sender's address
     */
    function receiveCurrency(
        address currency,
        uint256 amount,
        address from
    ) private {
        if (currency == address(0)) {
            if (amount != msg.value) revert InvalidAmount();
        } else {
            if (msg.value != 0) revert InvalidAmount();
            ICyanConduit(addressProvider.addresses(CYAN_CONDUIT)).transferERC20(from, address(this), currency, amount);
        }
    }

    /**
     * @notice Sends currency to a specified address. Supports both native and ERC20 tokens.
     * @param currency The address of the currency (address(0) for native, token address for ERC20).
     * @param amount The amount of currency to send
     * @param to The recipient's address
     */
    function sendCurrency(
        address currency,
        uint256 amount,
        address to
    ) private {
        if (currency == address(0)) {
            (bool success, ) = payable(to).call{ value: amount }("");
            if (!success) revert EthTransferFailed();
            return;
        } else {
            IERC20Upgradeable erc20Contract = IERC20Upgradeable(currency);
            erc20Contract.safeTransfer(to, amount);
        }
    }

    function checkIsPlanOwner(address sender, address planCyanWallet) private view returns (address) {
        address _sender = sender;
        if (sender != planCyanWallet) {
            _sender = getMainWalletAddress(planCyanWallet);
            if (sender != _sender) revert InvalidSender();
        }
        return _sender;
    }
}
