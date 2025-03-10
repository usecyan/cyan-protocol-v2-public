// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import "../interfaces/main/ICyanVaultTokenV1.sol";
import "../interfaces/IApeCoinStaking.sol";
import "../interfaces/core/IFactory.sol";
import { AddressProvider } from "../main/AddressProvider.sol";

/// @title Cyan Ape Coin Vault - Cyan's ApeCoin staking solution
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
contract CyanApeCoinVault is AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    AddressProvider constant addressProvider = AddressProvider(0xCF9A19D879769aDaE5e4f31503AAECDa82568E55);

    // bytes4(keccak256("isValidSignature(bytes32,bytes)"));
    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes32 public constant CYAN_APE_PLAN_ROLE = keccak256("CYAN_APE_PLAN_ROLE");
    bytes32 public constant CYAN_SIGNER_ROLE = keccak256("CYAN_SIGNER_ROLE");

    event Deposit(address indexed recipient, uint256 amount, uint256 tokenAmount);
    event DepositBatch(uint256 totalAmount, uint256 totalCurrency, uint256 totalToken);
    event Lend(address indexed to, uint256 amount, uint256 poolId);
    event PayLoan(uint256 paymentAmount, uint256 profitAmount, uint256 poolId);
    event EarnInterest(uint256 profitAmount);
    event AutoCompounded();
    event Withdraw(address indexed from, uint256 amount, uint256 tokenAmount);
    event UpdatedServiceFeePercent(uint256 from, uint256 to);
    event UpdatedSafetyFundPercent(uint256 from, uint256 to);
    event InitializedServiceFeePercent(uint256 to);
    event InitializedSafetyFundPercent(uint256 to);
    event CollectedServiceFee();
    event InterestRateUpdated(uint256 poolId, uint256 interestRate);
    event UpdatedWalletFactory(address indexed factory);
    event UpdatedWithdrawLockTerm(uint256 from, uint256 to);

    struct Amounts {
        uint256[4] loanedAmount;
        uint256 remainingAmount;
        uint256 collectedServiceFeeAmount;
    }

    struct DepositInfo {
        address recipient;
        uint256 amount;
    }

    ICyanVaultTokenV1 public cyanVaultTokenContract;

    // Safety fund percent. (x100)
    uint256 public safetyFundPercent;

    // Cyan service fee percent. (x100)
    uint256 public serviceFeePercent;

    Amounts public amounts;

    uint256 public constant APE_COIN_PRECISION = 1e18;

    // Loan interest rates for each pool. (x100)
    uint256[4] public interestRates;

    address walletFactory;
    mapping(address => uint256) public withdrawLocked;
    uint256 public withdrawLockTerm;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the CyanApeCoinVault contract
     * @param _cyanVaultTokenAddress Address of the CyanVaultToken contract
     * @param _cyanSuperAdmin Address of the Cyan Super Admin
     * @param _safetyFundPercent Percentage of the safety fund
     * @param _serviceFeePercent Percentage of the service fee
     * @param _baycPoolInterestRate Interest rate for the BAYC pool
     * @param _maycPoolInterestRate Interest rate for the MAYC pool
     * @param _bakcPoolInterestRate Interest rate for the BAKC pool
     */
    function initialize(
        address _cyanVaultTokenAddress,
        address _cyanSuperAdmin,
        uint256 _safetyFundPercent,
        uint256 _serviceFeePercent,
        uint256 _baycPoolInterestRate,
        uint256 _maycPoolInterestRate,
        uint256 _bakcPoolInterestRate
    ) external initializer {
        require(_cyanVaultTokenAddress != address(0), "Cyan Vault Token address cannot be zero");
        require(_cyanSuperAdmin != address(0), "Cyan Super Admin address cannot be zero");
        require(_safetyFundPercent <= 10000, "Safety fund percent must be equal or less than 100 percent");
        require(_serviceFeePercent <= 200, "Service fee percent must not be greater than 2 percent");
        require(_baycPoolInterestRate <= 10000, "BAYC Pool interest rate must be equal or less than 100 percent");
        require(_maycPoolInterestRate <= 10000, "MAYC Pool interest rate must be equal or less than 100 percent");
        require(_bakcPoolInterestRate <= 10000, "BAKC Pool interest rate must be equal or less than 100 percent");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        cyanVaultTokenContract = ICyanVaultTokenV1(_cyanVaultTokenAddress);

        safetyFundPercent = _safetyFundPercent;
        serviceFeePercent = _serviceFeePercent;

        getApeCoin().approve(address(getApeStaking()), type(uint256).max);

        interestRates[1] = _baycPoolInterestRate;
        interestRates[2] = _maycPoolInterestRate;
        interestRates[3] = _bakcPoolInterestRate;

        _setupRole(DEFAULT_ADMIN_ROLE, _cyanSuperAdmin);

        emit InitializedServiceFeePercent(_serviceFeePercent);
        emit InitializedSafetyFundPercent(_safetyFundPercent);
    }

    function initializeV2(address _walletFactory, uint256 _withdrawLockTerm) external reinitializer(2) {
        IApeCoinStaking.DashboardStake memory dashboard = getApeStaking().getApeCoinStake(address(this));
        amounts.remainingAmount = dashboard.deposited + dashboard.unclaimed;
        getApeStaking().withdrawApeCoin(dashboard.deposited, address(this));

        walletFactory = _walletFactory;
        withdrawLockTerm = _withdrawLockTerm;
    }

    /**
     * @notice Allows a user to deposit ApeCoin into the vault
     * @param depositInfo Information about the deposit including recipient and amount
     */
    function deposit(DepositInfo calldata depositInfo) external nonReentrant whenNotPaused {
        require(depositInfo.amount > 0, "Must deposit more than zero");

        // Cyan collecting service fee from deposits
        uint256 cyanServiceFee = (depositInfo.amount * serviceFeePercent) / 10000;

        uint256 userDepositedAmount = depositInfo.amount - cyanServiceFee;
        uint256 mintAmount = calculateTokenByCurrency(userDepositedAmount);

        getApeCoin().safeTransferFrom(msg.sender, address(this), depositInfo.amount);
        amounts.remainingAmount += userDepositedAmount;
        amounts.collectedServiceFeeAmount += cyanServiceFee;

        if (!hasRole(CYAN_APE_PLAN_ROLE, msg.sender)) {
            address cyanWalletAddress = IFactory(walletFactory).getOrDeployWallet(msg.sender);
            require(cyanWalletAddress == depositInfo.recipient, "Incorrect recipient address");

            withdrawLocked[cyanWalletAddress] = block.timestamp + withdrawLockTerm;
        }

        cyanVaultTokenContract.mint(depositInfo.recipient, mintAmount);
        emit Deposit(depositInfo.recipient, userDepositedAmount, mintAmount);
    }

    /**
     * @notice Allows multiple deposits in a single batch from CyanApeCoinPlan contract
     * @param deposits An array of DepositInfo struct containing recipient and amount for each deposit
     */
    function depositBatch(DepositInfo[] calldata deposits)
        external
        nonReentrant
        whenNotPaused
        onlyRole(CYAN_APE_PLAN_ROLE)
    {
        uint256 totalAmount;
        (uint256 totalCurrency, uint256 totalToken) = getTotalCurrencyAndToken();

        if (totalCurrency == 0 || totalToken == 0) {
            // Setting those to 1 for calculating token price rate
            totalCurrency = 1;
            totalToken = 1;
        }
        for (uint256 ind; ind < deposits.length; ) {
            uint256 amount = deposits[ind].amount;
            if (amount > 0) {
                address recipient = deposits[ind].recipient;
                uint256 mintAmount = (amount * totalToken) / totalCurrency;

                totalAmount += amount;

                cyanVaultTokenContract.mint(recipient, mintAmount);
            }
            unchecked {
                ++ind;
            }
        }
        getApeCoin().safeTransferFrom(msg.sender, address(this), totalAmount);
        amounts.remainingAmount += totalAmount;

        emit DepositBatch(totalAmount, totalCurrency, totalToken);
    }

    /**
     * @notice Lends a specified amount from the vault
     * @param to Address to lend to
     * @param amount Amount to lend
     * @param poolId Id of the pool
     */
    function lend(
        address to,
        uint256 amount,
        uint256 poolId
    ) external nonReentrant whenNotPaused onlyRole(CYAN_APE_PLAN_ROLE) {
        require(to != address(0), "to address cannot be zero");

        uint256 maxWithdrawableAmount = getMaxWithdrawableAmount();
        require(amount <= maxWithdrawableAmount, "Not enough balance in the Vault");

        amounts.remainingAmount -= amount;
        amounts.loanedAmount[poolId] += amount;
        getApeCoin().safeTransfer(to, amount);

        emit Lend(to, amount, poolId);
    }

    /**
     * @notice Pays back a loan with profit to the vault
     * @param amount The loan amount to be paid back
     * @param profit The profit amount
     * @param poolId Id of the pool
     */
    function pay(
        uint256 amount,
        uint256 profit,
        uint256 poolId
    ) external nonReentrant onlyRole(CYAN_APE_PLAN_ROLE) {
        uint256 totalAmount = amount + profit;
        getApeCoin().safeTransferFrom(msg.sender, address(this), totalAmount);

        amounts.remainingAmount += totalAmount;
        if (amount > 0) {
            amounts.loanedAmount[poolId] -= amount;
        }

        emit PayLoan(amount, profit, poolId);
    }

    /**
     * @notice Allows the Vault to earn interest
     * @param profit The profit amount
     */
    function earn(uint256 profit) external nonReentrant onlyRole(CYAN_APE_PLAN_ROLE) {
        getApeCoin().safeTransferFrom(msg.sender, address(this), profit);

        amounts.remainingAmount += profit;

        emit EarnInterest(profit);
    }

    /**
     * @notice Allows a user to withdraw ApeCoin from the vault
     * @param tokenAmount The amount of tokens to withdraw
     */
    function withdraw(uint256 tokenAmount) external nonReentrant whenNotPaused {
        require(tokenAmount > 0, "Non-positive token amount");
        require(withdrawLocked[msg.sender] < block.timestamp, "Withdrawal locked");

        uint256 withdrawableTokenBalance = getWithdrawableBalance(msg.sender);
        require(tokenAmount <= withdrawableTokenBalance, "Not enough active balance in Cyan Vault");

        uint256 withdrawAmount = calculateCurrencyByToken(tokenAmount);

        amounts.remainingAmount -= withdrawAmount;
        cyanVaultTokenContract.burn(msg.sender, tokenAmount);
        getApeCoin().safeTransfer(msg.sender, withdrawAmount);

        emit Withdraw(msg.sender, withdrawAmount, tokenAmount);
    }

    /**
     * @notice Get the withdrawable balance for a given user
     * @param user Address of the user
     * @return uint256 Amount of withdrawable balance for the user
     */
    function getWithdrawableBalance(address user) public view returns (uint256) {
        uint256 tokenBalance = cyanVaultTokenContract.balanceOf(user);
        uint256 currencyAmountForToken = calculateCurrencyByToken(tokenBalance);
        uint256 maxWithdrawableAmount = getMaxWithdrawableAmount();

        if (currencyAmountForToken <= maxWithdrawableAmount) {
            return tokenBalance;
        }
        return calculateTokenByCurrency(maxWithdrawableAmount);
    }

    /**
     * @notice Calculate the maximum amount that can be withdrawn considering safety fund percent
     * @return uint256 Maximum withdrawable amount
     */
    function getMaxWithdrawableAmount() public view returns (uint256) {
        uint256 util = ((amounts.loanedAmount[1] + amounts.loanedAmount[2] + amounts.loanedAmount[3]) *
            safetyFundPercent) / 10000;
        if (amounts.remainingAmount > util) {
            return amounts.remainingAmount - util;
        }
        return 0;
    }

    /**
     * @notice Gets the current asset amounts
     * @return Returns the amounts struct, deposited and unclaimed amounts
     */
    function getCurrentAssetAmounts() external view returns (Amounts memory) {
        return amounts;
    }

    /**
     * @notice Convert a given currency amount to its corresponding token amount
     * @param amount Amount of currency
     * @return uint256 Equivalent amount in tokens
     */
    function calculateTokenByCurrency(uint256 amount) public view returns (uint256) {
        (uint256 totalCurrency, uint256 totalToken) = getTotalCurrencyAndToken();
        if (totalCurrency == 0 || totalToken == 0) return amount;
        return (amount * totalToken) / totalCurrency;
    }

    /**
     * @notice Convert a given token amount to its corresponding currency amount
     * @param amount Amount of token
     * @return uint256 Equivalent amount in currency
     */
    function calculateCurrencyByToken(uint256 amount) public view returns (uint256) {
        (uint256 totalCurrency, uint256 totalToken) = getTotalCurrencyAndToken();
        if (totalCurrency == 0 || totalToken == 0) return amount;
        return (amount * totalCurrency) / totalToken;
    }

    /**
     * @notice Fetches the total currency and token amounts for the vault
     * @dev This considers the staked, unclaimed, loaned, estimated collected rewards, and interest amounts for the total currency value
     * @return uint256 Total currency amount
     * @return uint256 Total token supply of the vault
     */
    function getTotalCurrencyAndToken() private view returns (uint256, uint256) {
        uint256 totalCurrency = amounts.remainingAmount +
            amounts.loanedAmount[1] +
            amounts.loanedAmount[2] +
            amounts.loanedAmount[3];
        uint256 totalToken = cyanVaultTokenContract.totalSupply();

        return (totalCurrency, totalToken);
    }

    function getPoolInterestRates() external view returns (uint256[4] memory) {
        return interestRates;
    }

    /**
     * @notice Update the safety fund percentage
     * @param _safetyFundPercent New percentage value for the safety fund
     */
    function updateSafetyFundPercent(uint256 _safetyFundPercent) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_safetyFundPercent <= 10000, "Safety fund percent must be equal or less than 100 percent");
        emit UpdatedSafetyFundPercent(safetyFundPercent, _safetyFundPercent);
        safetyFundPercent = _safetyFundPercent;
    }

    /**
     * @notice Update the service fee percentage.
     * This is the fee taken by Cyan for its services.
     * @param _serviceFeePercent The new fee percentage to be set.
     */
    function updateServiceFeePercent(uint256 _serviceFeePercent) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_serviceFeePercent <= 200, "Service fee percent must not be greater than 2 percent");
        emit UpdatedServiceFeePercent(serviceFeePercent, _serviceFeePercent);
        serviceFeePercent = _serviceFeePercent;
    }

    /**
     * @notice Updates the interest rate for a particular staking pool.
     * @param poolId The ID of the pool to be updated.
     * @param interestRate The new interest rate to be set.
     */
    function updatePoolInterestRate(uint256 poolId, uint256 interestRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(poolId <= 3, "Invalid pool id");
        require(interestRate <= 10000, "Interest rate percent must not be greater than 100 percent");
        interestRates[poolId] = interestRate;
        emit InterestRateUpdated(poolId, interestRate);
    }

    /**
     * @notice Updating withdraw lock term
     * @param _withdrawLockTerm New lock term
     */
    function updateWithdrawLockTerm(uint256 _withdrawLockTerm) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit UpdatedWithdrawLockTerm(withdrawLockTerm, _withdrawLockTerm);
        withdrawLockTerm = _withdrawLockTerm;
    }

    /**
     * @notice Updating Cyan wallet factory address that used for deploying new wallets
     * @param factory New Cyan wallet factory address
     */
    function updateWalletFactoryAddress(address factory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(factory != address(0) && walletFactory != factory, "Invalid factory address");
        walletFactory = factory;
        emit UpdatedWalletFactory(factory);
    }

    /**
     * @notice Allows the admin to collect the accumulated service fee.
     */
    function collectServiceFee() external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amounts.collectedServiceFeeAmount > 0, "Not enough collected service fee");
        getApeCoin().safeTransfer(msg.sender, amounts.collectedServiceFeeAmount);
        amounts.collectedServiceFeeAmount = 0;

        emit CollectedServiceFee();
    }

    function pause() external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Return whether the signature provided is valid for the provided data.
    /// @param data Data signed on the behalf of the wallet.
    /// @param signature Signature byte array associated with the data.
    /// @return magicValue Returns a magic value (0x1626ba7e) if the given signature is correct.
    function isValidSignature(bytes32 data, bytes calldata signature) external view returns (bytes4 magicValue) {
        require(signature.length == 65, "Invalid signature length.");
        address signer = recoverSigner(data, signature);
        require(hasRole(CYAN_SIGNER_ROLE, signer), "Forbidden");
        return ERC1271_MAGIC_VALUE;
    }

    /// @notice Recover signer address from signature.
    /// @param signedHash Arbitrary length data signed on the behalf of the wallet.
    /// @param signature Signature byte array associated with signedHash.
    /// @return Recovered signer address.
    function recoverSigner(bytes32 signedHash, bytes memory signature) private pure returns (address) {
        uint8 v;
        bytes32 r;
        bytes32 s;
        // we jump 32 (0x20) as the first slot of bytes contains the length
        // we jump 65 (0x41) per signature
        // for v we load 32 bytes ending with v (the first 31 come from s) then apply a mask
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        require(v == 27 || v == 28, "Bad v value in signature.");

        address recoveredAddress = ecrecover(signedHash, v, r, s);
        require(recoveredAddress != address(0), "ecrecover returned 0.");
        return recoveredAddress;
    }

    function getApeCoin() private view returns (IERC20Upgradeable) {
        return IERC20Upgradeable(addressProvider.addresses("APE_COIN"));
    }

    function getApeStaking() private view returns (IApeCoinStaking) {
        return IApeCoinStaking(addressProvider.addresses("APE_COIN_STAKING"));
    }
}
