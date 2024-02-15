// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import "../core/Lockers.sol" as Lockers;
import "../interfaces/core/IModule.sol";
import "../helpers/Utils.sol";

/// @title Cyan Wallet ERC1155 Module - A Cyan wallet's ERC1155 token handling module.
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
contract ERC1155Module is IModule {
    bytes4 private constant ERC1155_SAFE_TRANSFER_FROM = IERC1155.safeTransferFrom.selector;
    bytes4 private constant ERC1155_SAFE_BATCH_TRANSFER_FROM = IERC1155.safeBatchTransferFrom.selector;

    event IncreaseLockedERC1155Token(address collection, uint256 tokenId, uint256 amount);
    event DecreaseLockedERC1155Token(address collection, uint256 tokenId, uint256 amount);

    /// @notice Increases locked ERC1155 tokens.
    /// @param collection Token address.
    /// @param tokenId ID of the token.
    /// @param amount Token amount to be locked.
    function increaseLockedERC1155Token(
        address collection,
        uint256 tokenId,
        uint256 amount
    ) external {
        require(_isAvailable(collection, tokenId, amount), "Cannot perform this action on locked token.");
        Lockers.getCyanPlanLockerERC1155().tokens[collection][tokenId] += amount;
        emit IncreaseLockedERC1155Token(collection, tokenId, amount);
    }

    /// @notice Decrease locked ERC1155 tokens.
    /// @param collection Token address.
    /// @param tokenId ID of the token.
    /// @param amount Token amount to be unlocked.
    function decreaseLockedERC1155Token(
        address collection,
        uint256 tokenId,
        uint256 amount
    ) external {
        require(
            Lockers.getLockedERC1155Amount(collection, tokenId) >= amount,
            "Amount must not be greater than locked amount."
        );
        Lockers.getCyanPlanLockerERC1155().tokens[collection][tokenId] -= amount;
        emit DecreaseLockedERC1155Token(collection, tokenId, amount);
    }

    /// @inheritdoc IModule
    function handleTransaction(
        address to,
        uint256 value,
        bytes calldata data
    ) external payable override returns (bytes memory) {
        bytes4 funcHash = Utils.parseFunctionSelector(data);
        if (funcHash == ERC1155_SAFE_TRANSFER_FROM) {
            (, , uint256 tokenId, uint256 amount, ) = abi.decode(data[4:], (address, address, uint256, uint256, bytes));
            require(_isAvailable(to, tokenId, amount), "Cannot perform this action on locked token.");
        }

        if (funcHash == ERC1155_SAFE_BATCH_TRANSFER_FROM) {
            (, , uint256[] memory ids, uint256[] memory amounts, ) = abi.decode(
                data[4:],
                (address, address, uint256[], uint256[], bytes)
            );
            require(ids.length == amounts.length, "IDs and amounts length mismatch");

            for (uint256 i = 0; i < ids.length; i++) {
                require(_isAvailable(to, ids[i], amounts[i]), "Cannot perform this action on locked token.");
            }
        }
        return Utils._execute(to, value, data);
    }

    /// @notice Allows operators to transfer out non locked ERC1155 tokens.
    ///     Note: Can only transfer if token is locked.
    /// @param collection Collection address.
    /// @param tokenId Token ID.
    /// @param amount Amount.
    /// @param to Receiver address.
    function transferNonLockedERC1155(
        address collection,
        uint256 tokenId,
        uint256 amount,
        address to
    ) external returns (bytes memory) {
        uint256 balance = IERC1155(collection).balanceOf(address(this), tokenId);
        require(
            (balance - Lockers.getLockedERC1155Amount(collection, tokenId)) >= amount,
            "Cannot perform this action on locked token."
        );

        bytes memory data = abi.encodeWithSelector(
            ERC1155_SAFE_TRANSFER_FROM,
            address(this),
            to,
            tokenId,
            amount,
            "0x"
        );
        return Utils._execute(collection, 0, data);
    }

    /// @dev Checks the amount of non-locked tokens available in the wallet.
    /// @param collection Address of the collection.
    /// @param tokenId Token ID.
    /// @param amount Requesting amount.
    /// @return Boolean to give truthy if requested amount of non-locked tokens are available.
    function _isAvailable(
        address collection,
        uint256 tokenId,
        uint256 amount
    ) internal view returns (bool) {
        uint256 balance = IERC1155(collection).balanceOf(address(this), tokenId);
        uint256 lockedAmount = Lockers.getLockedERC1155Amount(collection, tokenId);

        return lockedAmount + amount <= balance;
    }
}
