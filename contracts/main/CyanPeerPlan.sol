// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";

import "../interfaces/core/IFactory.sol";
import "../interfaces/core/IWalletApeCoin.sol";
import "../interfaces/main/ICyanPeerPlan.sol";
import "../thirdparty/ICryptoPunk.sol";
import { CyanWalletLogic } from "./CyanWalletLogic.sol";
import { ICyanConduit } from "../interfaces/conduit/ICyanConduit.sol";
import { AddressProvider } from "./AddressProvider.sol";

error InvalidSignature();
error InvalidServiceFeeRate();
error InvalidInterestRate();
error InvalidAmount();
error InvalidTerm();
error InvalidStage();
error InvalidAddress();
error InvalidItem();
error InvalidCurrency();
error InvalidApeCoinPlan();
error InvalidRevivalDate();

error NotExtendablePlan();
error PaymentPlanAlreadyExists();

/// @title Cyan Payment Plan - Main logic of BNPL and Pawn plan
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
contract CyanPeerPlan is ICyanPeerPlan, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    AddressProvider private constant addressProvider = AddressProvider(0xCF9A19D879769aDaE5e4f31503AAECDa82568E55);

    using ECDSAUpgradeable for bytes32;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    event CreatedP2P(uint256 indexed planId, bytes signature);
    event Extended(uint256 indexed planId);
    event Completed(uint256 indexed planId);
    event ExtendedByRevival(uint256 indexed planId, uint256 penaltyAmount);
    event CompletedByRevival(uint256 indexed planId, uint256 penaltyAmount);
    event LiquidatedP2PPlan(uint256 indexed planId);

    event UpdatedExtendable(uint256 indexed planId, bool extendable);
    event CancelledSignature(bytes signature);
    event ClaimedServiceFee(address indexed currency, uint256 indexed amount);

    event UpdatedServiceFeeRate(uint32 serviceFeeRate);
    event UpdatedWalletFactory(address indexed factory);
    event UpdatedCollectionSignatureVersion(uint256 indexed version);
    event UpdatedCyanSigner(address indexed signer);

    mapping(uint256 => Item) public items;
    mapping(uint256 => PaymentPlan) public paymentPlan;
    mapping(address => uint256) public claimableServiceFee;
    mapping(address => bool) public supportedCurrency;
    mapping(bytes => uint256) public signatureUsage;

    address private walletFactory;
    address private cyanSigner;
    uint256 private collectionVersion;
    uint256 public planCounter;
    uint32 public serviceFeeRate;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _cyanSuperAdmin,
        address _walletFactory,
        address _cyanSigner,
        uint32 _serviceFeeRate
    ) external initializer {
        if (_cyanSuperAdmin == address(0) || _walletFactory == address(0) || _cyanSigner == address(0))
            revert InvalidAddress();
        if (_serviceFeeRate > 10000) revert InvalidServiceFeeRate();

        walletFactory = _walletFactory;
        cyanSigner = _cyanSigner;
        serviceFeeRate = _serviceFeeRate;
        _setupRole(DEFAULT_ADMIN_ROLE, _cyanSuperAdmin);

        __AccessControl_init();
        __ReentrancyGuard_init();

        emit UpdatedServiceFeeRate(_serviceFeeRate);
        emit UpdatedWalletFactory(_walletFactory);
    }

    /**
     * @notice Creating a P2P plan
     * @param item Item detail pawn
     * @param plan Pawn plan detail
     * @param signature Signature from Lender
     */
    function createP2P(
        Item calldata item,
        Plan calldata plan,
        LenderSignature calldata signature
    ) external nonReentrant {
        uint256 planId = ++planCounter;

        if (item.contractAddress == address(0)) revert InvalidAddress();
        if (item.itemType < 1 || item.itemType > 3) revert InvalidItem();
        if (item.itemType == 1 && item.amount != 0) revert InvalidItem();
        if (item.itemType == 2 && item.amount == 0) revert InvalidItem();
        if (item.itemType == 3 && item.amount != 0) revert InvalidItem();

        if (plan.lenderAddress == address(0)) revert InvalidAddress();
        if (plan.currencyAddress == address(0)) revert InvalidCurrency();
        if (plan.amount == 0) revert InvalidAmount();
        if (plan.interestRate == 0) revert InvalidInterestRate();
        if (plan.term == 0) revert InvalidTerm();
        if (plan.serviceFeeRate != serviceFeeRate) revert InvalidServiceFeeRate();

        if (paymentPlan[planId].status != PlanStatus.NONE) revert PaymentPlanAlreadyExists();
        if (supportedCurrency[plan.currencyAddress] != true) revert InvalidCurrency();

        if (signature.expiryDate < block.timestamp) revert InvalidSignature();
        if (signatureUsage[signature.signature] >= signature.maxUsageCount) revert InvalidSignature();

        verifyLenderSignature(item, plan, signature);
        (address mainAddress, address cyanWalletAddress) = getOrCreateUserAddresses(msg.sender);

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
            CyanWalletLogic.transferItemAndLock(mainAddress, cyanWalletAddress, item);
        } else {
            CyanWalletLogic.setLockState(cyanWalletAddress, item, true);
        }
        ICyanConduit(addressProvider.addresses("CYAN_CONDUIT")).transferERC20(
            plan.lenderAddress,
            mainAddress,
            plan.currencyAddress,
            plan.amount
        );

        ++signatureUsage[signature.signature];
        items[planId] = item;
        paymentPlan[planId] = PaymentPlan(
            plan,
            block.timestamp + plan.term,
            cyanWalletAddress,
            PlanStatus.ACTIVE,
            signature.extendable
        );
        emit CreatedP2P(planId, signature.signature);
    }

    /**
     * @notice Make a payment for the payment plan
     * @param planId Payment Plan ID
     */
    function extend(uint256 planId) external nonReentrant {
        requireActivePlan(planId);

        if (paymentPlan[planId].extendable == false) revert NotExtendablePlan();

        Plan memory plan = paymentPlan[planId].plan;

        (uint256 interestFee, uint256 serviceFee, ) = getPaymentInfo(plan);
        ICyanConduit(addressProvider.addresses("CYAN_CONDUIT")).transferERC20(
            msg.sender,
            address(this),
            plan.currencyAddress,
            interestFee + serviceFee
        );

        IERC20Upgradeable currency = IERC20Upgradeable(plan.currencyAddress);
        currency.safeTransfer(plan.lenderAddress, interestFee);

        claimableServiceFee[plan.currencyAddress] += serviceFee;

        paymentPlan[planId].dueDate += plan.term;

        emit Extended(planId);
    }

    /**
     * @notice Make a payment for the payment plan
     * @param planId Payment Plan ID
     */
    function complete(uint256 planId) external nonReentrant {
        requireActivePlan(planId);

        Plan memory plan = paymentPlan[planId].plan;

        (uint256 interestFee, uint256 serviceFee, uint256 totalPayment) = getPaymentInfo(plan);
        ICyanConduit(addressProvider.addresses("CYAN_CONDUIT")).transferERC20(
            msg.sender,
            address(this),
            plan.currencyAddress,
            totalPayment
        );

        IERC20Upgradeable currency = IERC20Upgradeable(plan.currencyAddress);
        currency.safeTransfer(plan.lenderAddress, plan.amount + interestFee);

        claimableServiceFee[plan.currencyAddress] += serviceFee;

        paymentPlan[planId].status = PlanStatus.COMPLETED;
        CyanWalletLogic.setLockState(paymentPlan[planId].cyanWalletAddress, items[planId], false);

        emit Completed(planId);
    }

    /**
     * @notice Make a payment for the payment plan
     * @param planId Payment Plan ID
     */
    function updateExtendable(uint256 planId, bool extendable) external nonReentrant {
        requireActivePlan(planId);

        (address mainAddress, address cyanWalletAddress) = getOrCreateUserAddresses(msg.sender);
        if (
            paymentPlan[planId].plan.lenderAddress != mainAddress &&
            paymentPlan[planId].plan.lenderAddress != cyanWalletAddress
        ) revert InvalidAddress();

        paymentPlan[planId].extendable = extendable;

        emit UpdatedExtendable(planId, extendable);
    }

    /**
     * @notice Lender can cancel their signature
     * @param signature Signature from Lender
     */
    function cancelSignature(
        Item calldata item,
        Plan calldata plan,
        LenderSignature calldata signature
    ) external nonReentrant {
        verifyLenderSignature(item, plan, signature);

        (address mainAddress, address cyanWalletAddress) = getOrCreateUserAddresses(msg.sender);
        if (mainAddress != plan.lenderAddress && cyanWalletAddress != plan.lenderAddress) revert InvalidAddress();

        signatureUsage[signature.signature] = signature.maxUsageCount;
        emit CancelledSignature(signature.signature);
    }

    /**
     * @notice Return early payment info
     * @param plan Plan details
     * @return Remaining payment amount for interest fee
     * @return Remaining payment amount for service fee
     * @return Remaining total payment amount
     */
    function getPaymentInfo(Plan memory plan)
        private
        pure
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 interestFee = (plan.amount * plan.interestRate) / 10000;
        uint256 serviceFee = (plan.amount * plan.serviceFeeRate) / 10000;

        return (interestFee, serviceFee, plan.amount + interestFee + serviceFee);
    }

    /**
     * @notice Liquidate defaulted payment plan
     * @param planIds Array of plan Ids [CyanPlan ID, BAYC/MAYC Ape Plan ID, BAKC Ape Plan ID]
     */
    function liquidate(uint256[3] calldata planIds) external nonReentrant {
        requireDefaultedPlan(planIds[0]);

        PaymentPlan storage _paymentPlan = paymentPlan[planIds[0]];
        Item storage _item = items[planIds[0]];

        if (_paymentPlan.plan.lenderAddress != msg.sender) {
            revert InvalidAddress();
        }

        checkAndCompleteApePlanForLiquidation(
            _paymentPlan.cyanWalletAddress,
            _item.contractAddress,
            _item.tokenId,
            planIds[1]
        );
        checkAndCompleteApePlanForLiquidation(
            _paymentPlan.cyanWalletAddress,
            _item.contractAddress,
            _item.tokenId,
            planIds[2]
        );

        CyanWalletLogic.setLockState(_paymentPlan.cyanWalletAddress, _item, false);
        CyanWalletLogic.transferNonLockedItem(_paymentPlan.cyanWalletAddress, _paymentPlan.plan.lenderAddress, _item);

        _paymentPlan.status = PlanStatus.LIQUIDATED;
        emit LiquidatedP2PPlan(planIds[0]);
    }

    /**
     * @notice Revive defaulted payment plan with penalty
     * @param planId Payment Plan ID
     * @param penaltyAmount Amount that penalizes Defaulted plan revival
     * @param signatureExpiryDate Signature expiry date
     * @param signature Signature signed by Lender
     */
    function revive(
        uint256 planId,
        uint256 penaltyAmount,
        uint256 signatureExpiryDate,
        bool isExtend,
        bytes memory signature
    ) external nonReentrant {
        if (signatureExpiryDate < block.timestamp) revert InvalidRevivalDate();
        PaymentPlan storage _paymentPlan = paymentPlan[planId];
        if (_paymentPlan.extendable == false && isExtend) revert NotExtendablePlan();
        verifyRevivalSignature(
            planId,
            penaltyAmount,
            signatureExpiryDate,
            block.chainid,
            isExtend,
            _paymentPlan.plan.lenderAddress,
            signature
        );
        requireDefaultedPlan(planId);

        (uint256 interestFee, uint256 serviceFee, uint256 totalPayment) = getPaymentInfo(_paymentPlan.plan);
        if (_paymentPlan.dueDate + _paymentPlan.plan.term <= block.timestamp) revert InvalidRevivalDate();

        uint256 payableAmount = (isExtend ? interestFee + serviceFee : totalPayment) + penaltyAmount;

        ICyanConduit(addressProvider.addresses("CYAN_CONDUIT")).transferERC20(
            msg.sender,
            address(this),
            _paymentPlan.plan.currencyAddress,
            payableAmount
        );

        IERC20Upgradeable currency = IERC20Upgradeable(_paymentPlan.plan.currencyAddress);
        currency.safeTransfer(_paymentPlan.plan.lenderAddress, payableAmount - serviceFee);

        claimableServiceFee[_paymentPlan.plan.currencyAddress] += serviceFee;

        if (isExtend) {
            _paymentPlan.dueDate += _paymentPlan.plan.term;
            emit ExtendedByRevival(planId, penaltyAmount);
        } else {
            _paymentPlan.status = PlanStatus.COMPLETED;
            CyanWalletLogic.setLockState(_paymentPlan.cyanWalletAddress, items[planId], false);
            emit CompletedByRevival(planId, penaltyAmount);
        }
    }

    /**
     * @notice Check if payment plan is pending
     * @param planId Payment Plan ID
     * @return PlanStatus
     */
    function getPlanStatus(uint256 planId) public view returns (PlanStatus) {
        if (paymentPlan[planId].status == PlanStatus.ACTIVE) {
            bool isDefaulted = block.timestamp > paymentPlan[planId].dueDate;
            if (isDefaulted) {
                return PlanStatus.DEFAULTED;
            }
        }

        return paymentPlan[planId].status;
    }

    /**
     * @notice Claiming collected service fee amount
     * @param currencyAddress Currency address
     */
    function claimServiceFee(address currencyAddress) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        emit ClaimedServiceFee(currencyAddress, claimableServiceFee[currencyAddress]);
        IERC20Upgradeable currency = IERC20Upgradeable(currencyAddress);
        currency.safeTransfer(msg.sender, claimableServiceFee[currencyAddress]);
        claimableServiceFee[currencyAddress] = 0;
    }

    /**
     * @notice Updating Cyan service fee rate
     * @param _serviceFeeRate New service fee rate
     */
    function updateServiceFeeRate(uint32 _serviceFeeRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_serviceFeeRate > 10000) revert InvalidServiceFeeRate();
        serviceFeeRate = _serviceFeeRate;
        emit UpdatedServiceFeeRate(_serviceFeeRate);
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
     * @notice Updating Cyan signer address that used for signing collection address
     * @param signer New Cyan signer address
     */
    function updateCyanSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (signer == address(0)) revert InvalidAddress();
        cyanSigner = signer;
        emit UpdatedCyanSigner(signer);
    }

    /**
     * @notice Updating collection signature version
     */
    function increaseCollectionSignatureVersion() external onlyRole(DEFAULT_ADMIN_ROLE) {
        ++collectionVersion;
        emit UpdatedCollectionSignatureVersion(collectionVersion);
    }

    /**
     * @notice Adding supported currencies
     * @param currency Array of supported currencies
     */
    function addSupportedCurrencies(address[] calldata currency) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 ind; ind < currency.length; ++ind) {
            supportedCurrency[currency[ind]] = true;
        }
    }

    /**
     * @notice Removing supported currencies
     * @param currency Array of unsupported currencies
     */
    function removeSupportedCurrencies(address[] calldata currency) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 ind; ind < currency.length; ++ind) {
            supportedCurrency[currency[ind]] = false;
        }
    }

    /**
     * @notice Getting main wallet address by Cyan wallet address
     * @param cyanWalletAddress Cyan wallet address
     */
    function getMainWalletAddress(address cyanWalletAddress) private view returns (address) {
        return IFactory(walletFactory).getWalletOwner(cyanWalletAddress);
    }

    function verifyLenderSignature(
        Item calldata item,
        Plan calldata plan,
        LenderSignature calldata signature
    ) private view {
        // Lenders signature can contain specific tokenId
        bytes32 itemHash = keccak256(
            abi.encodePacked(item.contractAddress, item.tokenId, item.amount, item.itemType, item.collectionSignature)
        );
        bytes32 planHash = keccak256(
            abi.encodePacked(plan.currencyAddress, plan.amount, plan.interestRate, plan.serviceFeeRate, plan.term)
        );
        bytes32 lenderSigHash = keccak256(
            abi.encodePacked(signature.signedDate, signature.expiryDate, signature.maxUsageCount, signature.extendable)
        );
        bytes32 msgHash = keccak256(abi.encodePacked(itemHash, planHash, lenderSigHash, block.chainid));
        bytes32 signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        if (signedHash.recover(signature.signature) != plan.lenderAddress) {
            // Lenders signature can be without specific tokenId
            itemHash = keccak256(
                abi.encodePacked(item.contractAddress, item.amount, item.itemType, item.collectionSignature)
            );
            msgHash = keccak256(abi.encodePacked(itemHash, planHash, lenderSigHash, block.chainid));
            signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));

            if (signedHash.recover(signature.signature) != plan.lenderAddress) {
                revert InvalidSignature();
            }
        }

        bytes32 collectionMsgHash = keccak256(abi.encodePacked(item.contractAddress, block.chainid, collectionVersion));
        bytes32 collectionSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", collectionMsgHash)
        );
        if (collectionSignedHash.recover(item.collectionSignature) != cyanSigner) {
            revert InvalidSignature();
        }
    }

    function verifyRevivalSignature(
        uint256 planId,
        uint256 penaltyAmount,
        uint256 signatureExpiryDate,
        uint256 chainid,
        bool isExtend,
        address lenderAddress,
        bytes memory signature
    ) private pure {
        bytes32 msgHash = keccak256(abi.encodePacked(planId, penaltyAmount, signatureExpiryDate, chainid, true));
        bytes32 signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        if (isExtend) {
            if (signedHash.recover(signature) != lenderAddress) revert InvalidSignature();
        } else {
            if (signedHash.recover(signature) != lenderAddress) {
                msgHash = keccak256(abi.encodePacked(planId, penaltyAmount, signatureExpiryDate, chainid, false));
                signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
                if (signedHash.recover(signature) != lenderAddress) revert InvalidSignature();
            }
        }
    }

    function requireActivePlan(uint256 planId) private view {
        PlanStatus status = getPlanStatus(planId);
        if (status != PlanStatus.ACTIVE) revert InvalidStage();
    }

    function requireDefaultedPlan(uint256 planId) private view {
        PlanStatus status = getPlanStatus(planId);
        if (status != PlanStatus.DEFAULTED) revert InvalidStage();
    }

    function checkAndCompleteApePlanForLiquidation(
        address cyanWalletAddress,
        address collection,
        uint256 tokenId,
        uint256 apePlanId
    ) private {
        if (apePlanId == 0) return;

        IWalletApeCoin cyanWallet = IWalletApeCoin(cyanWalletAddress);

        uint8 apeLockStateBefore = cyanWallet.getApeLockState(collection, tokenId);
        cyanWallet.executeModule(abi.encodeWithSelector(IWalletApeCoin.completeApeCoinPlan.selector, apePlanId));
        uint8 apeLockStateAfter = cyanWallet.getApeLockState(collection, tokenId);

        if (apeLockStateAfter >= apeLockStateBefore) revert InvalidApeCoinPlan();
    }

    /**
     * @notice Returns users main address and CyanWallet address. Creates CyanWallet if not exist.
     * @param userAddress User address.
     * @return Main address.
     * @return Cyan Wallet address.
     */
    function getOrCreateUserAddresses(address userAddress) private returns (address, address) {
        address mainAddress = userAddress;
        address cyanWalletAddress = IFactory(walletFactory).getOrDeployWallet(userAddress);
        if (cyanWalletAddress == userAddress) {
            mainAddress = getMainWalletAddress(cyanWalletAddress);
        }
        return (mainAddress, cyanWalletAddress);
    }
}
