// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/core/IModule.sol";
import "../helpers/Utils.sol";

/// @title Cyan Wallet ERC20 Module - A Cyan wallet's ERC20 token handling module.
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
contract ERC20Module is IModule {
    // keccak256("wallet.ERC20Module.lockedERC20")
    bytes32 private constant LOCKER_SLOT = 0x7f4f1b59be841ba41f04a1366e54ff13c51165e7bf98fa5b51c1abe9f816a09e;

    bytes4 private constant ERC20_TRANSFER = IERC20.transfer.selector;
    bytes4 private constant ERC20_APPROVE = IERC20.approve.selector;
    bytes4 private constant ERC20_INCREASE_ALLOWANCE = bytes4(keccak256("increaseAllowance(address,uint256)"));
    bytes4 private constant ERC20_DECREASE_ALLOWANCE = bytes4(keccak256("decreaseAllowance(address,uint256)"));

    event SetLockedERC20Token(address collection, uint256 amount);

    /// @notice Locks ERC20 tokens.
    /// @param collection Token address.
    /// @param amount Token amount to be locked.
    function setLockedERC20Token(address collection, uint256 amount) external {
        _getLockedTokens()[collection] = amount;
        emit SetLockedERC20Token(collection, amount);
    }

    /// @inheritdoc IModule
    function handleTransaction(
        address to,
        uint256 value,
        bytes calldata data
    ) external payable override returns (bytes memory) {
        bytes4 funcHash = Utils.parseFunctionSelector(data);
        if (
            funcHash == ERC20_TRANSFER ||
            funcHash == ERC20_APPROVE ||
            funcHash == ERC20_INCREASE_ALLOWANCE ||
            funcHash == ERC20_DECREASE_ALLOWANCE
        ) {
            uint256 amount = Utils.getUint256At(data, 0x24);
            require(_isAvailable(to, amount), "Cannot perform this action on locked token or balance not enough.");
        }
        return Utils._execute(to, value, data);
    }

    /// @notice Allows operators to get the defaulted tokens.
    ///     Note: Can only transfer if token is locked.
    /// @param collection Collection address.
    /// @param amount Amount.
    /// @param to Receiver address.
    function transferDefaultedERC20(
        address collection,
        uint256 amount,
        address to
    ) external returns (bytes memory) {
        require(_getLockedTokens()[collection] >= amount, "Cannot perform this action on non-locked token.");
        _getLockedTokens()[collection] -= amount;

        bytes memory data = abi.encodeWithSelector(ERC20_TRANSFER, to, amount);
        return Utils._execute(collection, 0, data);
    }

    /// @notice Returns locked amount of the collection.
    /// @param collection Collection address.
    /// @return amount Locked amount.
    function getLockedAmount(address collection) public view returns (uint256) {
        return _getLockedTokens()[collection];
    }

    /// @dev Returns the map of the locked tokens.
    /// @return result Map of the locked tokens.
    ///     Note: Collection address => Locked amount
    function _getLockedTokens() internal pure returns (mapping(address => uint256) storage result) {
        assembly {
            result.slot := LOCKER_SLOT
        }
    }

    /// @dev Checks the amount of non-locked tokens available in the wallet.
    /// @param collection Address of the collection.
    /// @param amount Requesting amount.
    /// @return Boolean to give truthy if requested amount of non-locked tokens are available.
    function _isAvailable(address collection, uint256 amount) internal view returns (bool) {
        uint256 balance = IERC20(collection).balanceOf(address(this));
        uint256 lockedAmount = getLockedAmount(collection);
        return lockedAmount + amount <= balance;
    }
}
