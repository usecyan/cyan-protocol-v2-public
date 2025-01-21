// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";

import "../interfaces/main/ICyanVaultTokenV1.sol";
import "../interfaces/openzeppelin/ERC1155HolderUpgradeable.sol";
import "../interfaces/core/IFactory.sol";
import "../interfaces/main/ICyanPaymentPlanV2.sol";

/// @title Cyan Vault - Cyan's staking solution
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
contract CyanVaultV2 is
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC721HolderUpgradeable,
    ERC1155HolderUpgradeable,
    PausableUpgradeable
{
    using ECDSAUpgradeable for bytes32;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant CYAN_ROLE = keccak256("CYAN_ROLE");
    bytes32 public constant CYAN_PAYMENT_PLAN_ROLE = keccak256("CYAN_PAYMENT_PLAN_ROLE");

    event Deposit(address indexed from, uint256 amount, uint256 tokenAmount);
    event Lend(address indexed to, uint256 amount);
    event Earn(uint256 paymentAmount, uint256 profitAmount);
    event NftDefaulted(uint256 unpaidAmount, uint256 estimatedPriceOfNFT);
    event NftLiquidated(uint256 defaultedAssetsAmount, uint256 soldAmount, uint256 prevDefaultedAssetsAmount);
    event AutoLiquidated(uint256 indexed planId, uint8 autoLiquidationType);
    event Withdraw(address indexed from, uint256 amount, uint256 tokenAmount);
    event GetDefaultedNFT(address indexed to, address indexed contractAddress, uint256 indexed tokenId);
    event GetDefaultedERC1155(
        address indexed to,
        address indexed contractAddress,
        uint256 indexed tokenId,
        uint256 amount
    );
    event UpdatedDefaultedNFTAssetAmount(uint256 defaultedAssetsAmount, uint256 prevDefaultedAssetsAmount);
    event UpdatedServiceFeePercent(uint256 from, uint256 to);
    event UpdatedSafetyFundPercent(uint256 from, uint256 to);
    event UpdatedWithdrawLockTerm(uint256 from, uint256 to);
    event InitializedServiceFeePercent(uint256 to);
    event InitializedSafetyFundPercent(uint256 to);
    event ReceivedETH(uint256 amount, address indexed from);
    event WithdrewERC20(address indexed token, address to, uint256 amount);
    event CollectedServiceFee(uint256 collectedAmount);
    event UpdatedWalletFactory(address indexed factory);
    event UpdatedCyanSigner(address indexed signer);

    struct AutoLiquidationInfo {
        uint256 planId;
        uint256[2] apePlanIds;
        uint256 price;
        address paymentPlanAddress;
        uint256 signatureExpiryDate;
        bytes signature;
    }

    address public _cyanVaultTokenAddress;
    ICyanVaultTokenV1 private _cyanVaultTokenContract;

    address private _stEthTokenContract; // unused
    address private _stableSwapSTETHContract; // unused

    // Safety fund percent. (x100)
    uint256 public _safetyFundPercent;

    // Cyan service fee percent. (x100)
    uint256 public _serviceFeePercent;

    // Remaining amount of the currency
    uint256 private REMAINING_AMOUNT;

    // Total loaned amount
    uint256 private LOANED_AMOUNT;

    // Total defaulted NFT amount
    uint256 private DEFAULTED_NFT_ASSET_AMOUNT;

    // Cyan collected service fee
    uint256 private COLLECTED_SERVICE_FEE_AMOUNT;

    address public _currencyTokenAddress;
    IERC20Upgradeable private _currencyToken;
    bool public nonNativeCurrency;
    address _walletFactory;
    uint256 public _withdrawLockTerm;
    mapping(address => uint256) public withdrawLocked;
    bool public autoLiquidationEnabled;
    address private cyanSigner;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initializeV3(
        address cyanVaultTokenAddress,
        address currencyTokenAddress,
        address cyanPaymentPlanAddress,
        address cyanSuperAdmin,
        address factory,
        uint256 safetyFundPercent,
        uint256 serviceFeePercent,
        uint256 withdrawLockTerm,
        bool autoLiquidation,
        address signer
    ) external reinitializer(3) {
        // The contract is considered initialized if the vault token address is set.
        if (_cyanVaultTokenAddress == address(0)) {
            require(cyanVaultTokenAddress != address(0), "Cyan Vault Token address cannot be zero");
            require(cyanPaymentPlanAddress != address(0), "Cyan Payment Plan address cannot be zero");
            require(cyanSuperAdmin != address(0), "Cyan Super Admin address cannot be zero");
            require(safetyFundPercent <= 10000, "Safety fund percent must be equal or less than 100 percent");
            require(serviceFeePercent <= 200, "Service fee percent must not be greater than 2 percent");
            require(factory != address(0), "Factory address cannot be zero");

            __AccessControl_init();
            __ReentrancyGuard_init();
            __ERC721Holder_init();
            __Pausable_init();

            _cyanVaultTokenAddress = cyanVaultTokenAddress;
            _cyanVaultTokenContract = ICyanVaultTokenV1(_cyanVaultTokenAddress);
            _currencyTokenAddress = currencyTokenAddress;

            if (currencyTokenAddress != address(0)) {
                _currencyToken = IERC20Upgradeable(currencyTokenAddress);
                nonNativeCurrency = true;
            } else {
                nonNativeCurrency = false;
            }
            _safetyFundPercent = safetyFundPercent;
            _serviceFeePercent = serviceFeePercent;

            LOANED_AMOUNT = 0;
            DEFAULTED_NFT_ASSET_AMOUNT = 0;
            REMAINING_AMOUNT = 0;

            _setupRole(DEFAULT_ADMIN_ROLE, cyanSuperAdmin);
            _setupRole(CYAN_PAYMENT_PLAN_ROLE, cyanPaymentPlanAddress);

            _walletFactory = factory;
            _withdrawLockTerm = withdrawLockTerm;

            emit InitializedServiceFeePercent(serviceFeePercent);
            emit InitializedSafetyFundPercent(safetyFundPercent);
            emit UpdatedWalletFactory(factory);
        }
        require(signer != address(0), "Signer address cannot be zero");

        autoLiquidationEnabled = autoLiquidation;
        cyanSigner = signer;

        emit UpdatedCyanSigner(signer);
    }

    // User stakes
    function deposit(uint256 amount) external payable nonReentrant whenNotPaused {
        require(amount > 0, "Must deposit more than zero");
        if (nonNativeCurrency) {
            require(msg.value == 0, "Invalid deposit amount");
        } else {
            require(msg.value == amount, "Invalid deposit amount");
        }
        address cyanWalletAddress = IFactory(_walletFactory).getOrDeployWallet(msg.sender);
        // Cyan collecting service fee from deposits
        uint256 cyanServiceFee = (amount * _serviceFeePercent) / 10000;

        uint256 depositedAmount = amount - cyanServiceFee;
        uint256 mintAmount = calculateTokenByCurrency(depositedAmount);

        if (nonNativeCurrency) {
            _currencyToken.safeTransferFrom(msg.sender, address(this), amount);
        }
        REMAINING_AMOUNT += depositedAmount;
        COLLECTED_SERVICE_FEE_AMOUNT += cyanServiceFee;

        _cyanVaultTokenContract.mint(cyanWalletAddress, mintAmount);

        withdrawLocked[cyanWalletAddress] = block.timestamp + _withdrawLockTerm;
        emit Deposit(msg.sender, depositedAmount, mintAmount);
    }

    // Cyan lends money from Vault to do BNPL or PAWN
    function lend(address to, uint256 amount) external nonReentrant whenNotPaused onlyRole(CYAN_PAYMENT_PLAN_ROLE) {
        require(to != address(0), "to address cannot be zero");

        uint256 maxWithdrableAmount = getMaxWithdrawableAmount();
        require(amount <= maxWithdrableAmount, "Not enough balance in the Vault");

        LOANED_AMOUNT += amount;
        REMAINING_AMOUNT -= amount;

        safeCurrencyTransfer(to, amount);

        emit Lend(to, amount);
    }

    // Cyan Payment Plan contract transfers paid amount back to Vault
    function earn(uint256 amount, uint256 profit) external payable nonReentrant onlyRole(CYAN_PAYMENT_PLAN_ROLE) {
        if (nonNativeCurrency) {
            require(msg.value == 0, "Wrong tranfer amount");
        } else {
            require(msg.value == amount + profit, "Wrong tranfer amount");
        }

        if (nonNativeCurrency) {
            _currencyToken.safeTransferFrom(msg.sender, address(this), amount + profit);
        }
        REMAINING_AMOUNT += amount + profit;
        if (LOANED_AMOUNT >= amount) {
            LOANED_AMOUNT -= amount;
        } else {
            LOANED_AMOUNT = 0;
        }

        emit Earn(amount, profit);
    }

    // When BNPL or PAWN plan defaults
    function nftDefaulted(uint256 unpaidAmount, uint256 estimatedPriceOfNFT)
        external
        nonReentrant
        onlyRole(CYAN_PAYMENT_PLAN_ROLE)
    {
        DEFAULTED_NFT_ASSET_AMOUNT += estimatedPriceOfNFT;

        if (LOANED_AMOUNT >= unpaidAmount) {
            LOANED_AMOUNT -= unpaidAmount;
        } else {
            LOANED_AMOUNT = 0;
        }

        emit NftDefaulted(unpaidAmount, estimatedPriceOfNFT);
    }

    // Liquidating defaulted BNPL or PAWN token and tranferred sold amount to Vault
    function liquidateNFT(uint256 liquidatedAmount, uint256 totalDefaultedNFTAmount)
        external
        payable
        whenNotPaused
        onlyRole(CYAN_ROLE)
    {
        if (nonNativeCurrency) {
            require(msg.value == 0, "Invalid deposit amount");
        } else {
            require(msg.value == liquidatedAmount, "Invalid deposit amount");
        }
        if (nonNativeCurrency) {
            _currencyToken.safeTransferFrom(msg.sender, address(this), liquidatedAmount);
        }

        REMAINING_AMOUNT += liquidatedAmount;
        emit NftLiquidated(liquidatedAmount, totalDefaultedNFTAmount, DEFAULTED_NFT_ASSET_AMOUNT);

        DEFAULTED_NFT_ASSET_AMOUNT = totalDefaultedNFTAmount;
    }

    function autoLiquidatePlan(AutoLiquidationInfo calldata info)
        external
        onlyAutoLiquidated
        whenNotPaused
        onlyRole(CYAN_ROLE)
    {
        verifyAutoLiquidationSignature(info);

        ICyanPaymentPlanV2 paymentPlan = ICyanPaymentPlanV2(info.paymentPlanAddress);
        paymentPlan.liquidate(info.planId, info.apePlanIds, info.price);
        emit AutoLiquidated(info.planId, 0); // Liquidated
    }

    function autoLiquidateByEarlyUnwindOpensea(
        AutoLiquidationInfo calldata info,
        bytes calldata offer,
        uint256 unwindSignatureExpiryDate,
        bytes calldata unwindSignature
    ) external onlyAutoLiquidated whenNotPaused onlyRole(CYAN_ROLE) {
        verifyAutoLiquidationSignature(info);

        ICyanPaymentPlanV2 paymentPlan = ICyanPaymentPlanV2(info.paymentPlanAddress);
        paymentPlan.earlyUnwindOpensea(
            info.planId,
            info.apePlanIds,
            info.price,
            offer,
            unwindSignatureExpiryDate,
            unwindSignature
        );
        emit AutoLiquidated(info.planId, 1); // Opensea
    }

    function autoLiquidateByEarlyUnwindCyan(
        AutoLiquidationInfo calldata info,
        address cyanBuyerAddress,
        uint256 unwindSignatureExpiryDate,
        bytes memory unwindSignature
    ) external onlyAutoLiquidated whenNotPaused onlyRole(CYAN_ROLE) {
        verifyAutoLiquidationSignature(info);

        ICyanPaymentPlanV2 paymentPlan = ICyanPaymentPlanV2(info.paymentPlanAddress);
        paymentPlan.earlyUnwindCyan(
            info.planId,
            info.apePlanIds,
            info.price,
            cyanBuyerAddress,
            unwindSignatureExpiryDate,
            unwindSignature
        );
        emit AutoLiquidated(info.planId, 2); // Cyan
    }

    // User unstakes tokenAmount of tokens and receives withdrawAmount of currency
    function withdraw(uint256 tokenAmount) external nonReentrant whenNotPaused {
        require(tokenAmount > 0, "Non-positive token amount");
        require(withdrawLocked[msg.sender] < block.timestamp, "Withdrawal locked");

        uint256 withdrawableTokenBalance = getWithdrawableBalance(msg.sender);
        require(tokenAmount <= withdrawableTokenBalance, "Not enough active balance in Cyan Vault");

        uint256 withdrawAmount = calculateCurrencyByToken(tokenAmount);

        REMAINING_AMOUNT -= withdrawAmount;
        _cyanVaultTokenContract.burn(msg.sender, tokenAmount);
        safeCurrencyTransfer(msg.sender, withdrawAmount);

        emit Withdraw(msg.sender, withdrawAmount, tokenAmount);
    }

    // Cyan updating total amount of defaulted NFT assets
    function updateDefaultedNFTAssetAmount(uint256 amount) external whenNotPaused onlyRole(CYAN_ROLE) {
        emit UpdatedDefaultedNFTAssetAmount(amount, DEFAULTED_NFT_ASSET_AMOUNT);
        DEFAULTED_NFT_ASSET_AMOUNT = amount;
    }

    // Get defaulted NFT from Vault to Cyan Admin account
    function getDefaultedNFT(address contractAddress, uint256 tokenId)
        external
        nonReentrant
        whenNotPaused
        onlyRole(CYAN_ROLE)
    {
        require(contractAddress != address(0), "Zero contract address");
        IERC721 originalContract = IERC721(contractAddress);
        require(originalContract.ownerOf(tokenId) == address(this), "Vault is not the owner of the token");

        originalContract.safeTransferFrom(address(this), msg.sender, tokenId);

        emit GetDefaultedNFT(msg.sender, contractAddress, tokenId);
    }

    // Get defaulted ERC1155 from Vault to Cyan Admin account
    function getDefaultedERC1155(
        address contractAddress,
        uint256 tokenId,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyRole(CYAN_ROLE) {
        require(contractAddress != address(0), "Zero contract address");
        IERC1155 originalContract = IERC1155(contractAddress);
        require(originalContract.balanceOf(address(this), tokenId) >= amount, "Vault does not have enough token");

        originalContract.safeTransferFrom(address(this), msg.sender, tokenId, amount, bytes(""));

        emit GetDefaultedERC1155(msg.sender, contractAddress, tokenId, amount);
    }

    function getWithdrawableBalance(address user) public view returns (uint256) {
        uint256 tokenBalance = _cyanVaultTokenContract.balanceOf(user);
        uint256 currencyAmountForToken = calculateCurrencyByToken(tokenBalance);
        uint256 maxWithdrawableAmount = getMaxWithdrawableAmount();

        if (currencyAmountForToken <= maxWithdrawableAmount) {
            return tokenBalance;
        }
        return calculateTokenByCurrency(maxWithdrawableAmount);
    }

    function getMaxWithdrawableAmount() public view returns (uint256) {
        uint256 util = ((LOANED_AMOUNT + DEFAULTED_NFT_ASSET_AMOUNT) * _safetyFundPercent) / 10000;
        if (REMAINING_AMOUNT > util) {
            return REMAINING_AMOUNT - util;
        }
        return 0;
    }

    function getCurrentAssetAmounts()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return (REMAINING_AMOUNT, LOANED_AMOUNT, DEFAULTED_NFT_ASSET_AMOUNT, COLLECTED_SERVICE_FEE_AMOUNT);
    }

    function getCurrencyAddress() external view returns (address) {
        return _currencyTokenAddress;
    }

    function calculateTokenByCurrency(uint256 amount) public view returns (uint256) {
        (uint256 totalCurrency, uint256 totalToken) = getTotalCurrencyAndToken();
        if (totalCurrency == 0) return amount;
        return (amount * totalToken) / totalCurrency;
    }

    function calculateCurrencyByToken(uint256 amount) public view returns (uint256) {
        (uint256 totalCurrency, uint256 totalToken) = getTotalCurrencyAndToken();
        if (totalToken == 0) return amount;
        return (amount * totalCurrency) / totalToken;
    }

    function getTotalCurrencyAndToken() private view returns (uint256, uint256) {
        uint256 totalCurrency = REMAINING_AMOUNT + LOANED_AMOUNT + DEFAULTED_NFT_ASSET_AMOUNT;
        uint256 totalToken = _cyanVaultTokenContract.totalSupply();

        return (totalCurrency, totalToken);
    }

    function updateSafetyFundPercent(uint256 safetyFundPercent) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(safetyFundPercent <= 10000, "Safety fund percent must be equal or less than 100 percent");
        emit UpdatedSafetyFundPercent(_safetyFundPercent, safetyFundPercent);
        _safetyFundPercent = safetyFundPercent;
    }

    function updateServiceFeePercent(uint256 serviceFeePercent) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(serviceFeePercent <= 200, "Service fee percent must not be greater than 2 percent");
        emit UpdatedServiceFeePercent(_serviceFeePercent, serviceFeePercent);
        _serviceFeePercent = serviceFeePercent;
    }

    function updateWithdrawLockTerm(uint256 withdrawLockTerm) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit UpdatedWithdrawLockTerm(_withdrawLockTerm, withdrawLockTerm);
        _withdrawLockTerm = withdrawLockTerm;
    }

    function collectServiceFee() external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        emit CollectedServiceFee(COLLECTED_SERVICE_FEE_AMOUNT);
        safeCurrencyTransfer(msg.sender, COLLECTED_SERVICE_FEE_AMOUNT);
        COLLECTED_SERVICE_FEE_AMOUNT = 0;
    }

    function safeCurrencyTransfer(address to, uint256 amount) private {
        if (nonNativeCurrency) {
            _currencyToken.safeTransfer(to, amount);
        } else {
            (bool success, ) = payable(to).call{ value: amount }("");
            require(success, "Payment failed: Native token transfer");
        }
    }

    function withdrawAirDroppedERC20(address contractAddress, uint256 amount)
        external
        nonReentrant
        onlyRole(CYAN_ROLE)
    {
        require(contractAddress != _currencyTokenAddress, "Cannot withdraw currency token");
        IERC20Upgradeable erc20Contract = IERC20Upgradeable(contractAddress);
        require(erc20Contract.balanceOf(address(this)) >= amount, "ERC20 balance not enough");
        erc20Contract.safeTransfer(msg.sender, amount);

        emit WithdrewERC20(contractAddress, msg.sender, amount);
    }

    function withdrawApprovedERC20(
        address contractAddress,
        address from,
        uint256 amount
    ) external nonReentrant onlyRole(CYAN_ROLE) {
        require(contractAddress != _currencyTokenAddress, "Cannot withdraw currency token");
        IERC20Upgradeable erc20Contract = IERC20Upgradeable(contractAddress);
        require(erc20Contract.allowance(from, address(this)) >= amount, "ERC20 allowance not enough");
        erc20Contract.safeTransferFrom(from, msg.sender, amount);

        emit WithdrewERC20(contractAddress, msg.sender, amount);
    }

    /**
     * @notice Updating Cyan wallet factory address that used for deploying new wallets
     * @param factory New Cyan wallet factory address
     */
    function updateWalletFactoryAddress(address factory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(factory != address(0) && _walletFactory != factory, "Invalid factory address");
        _walletFactory = factory;
        emit UpdatedWalletFactory(factory);
    }

    /**
     * @notice Updating Cyan signer address that used for verifying auto liquidation signature
     * @param signer New Cyan signer address
     */
    function updateCyanSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(signer != address(0), "Invalid signer address");
        cyanSigner = signer;
        emit UpdatedCyanSigner(signer);
    }

    modifier onlyAutoLiquidated() {
        require(autoLiquidationEnabled, "Auto liquidation is disabled for this vault");
        _;
    }

    function verifyAutoLiquidationSignature(AutoLiquidationInfo calldata info) internal view {
        require(block.timestamp <= info.signatureExpiryDate, "Signature expired");
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                info.planId,
                info.apePlanIds[0],
                info.apePlanIds[1],
                info.price,
                info.signatureExpiryDate,
                block.chainid
            )
        );
        bytes32 signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        require(signedHash.recover(info.signature) == cyanSigner, "Invalid Signature");
    }

    function pause() external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable, ERC1155ReceiverUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
