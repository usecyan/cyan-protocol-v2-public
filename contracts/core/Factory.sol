// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface IWallet {
    function initiate(address) external;
}

/// @title Cyan Wallet Factory - A Cyan wallet's factory.
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
contract Factory is Initializable {
    /// @notice Router address of the wallet.
    address private _router;

    /// @notice Mapping of the owner address to the wallet address.
    mapping(address => address) private _ownerToWallets;

    /// @notice Mapping of the wallet address to the owner address.
    mapping(address => address) private _walletToOwners;

    event WalletCreated(address owner, address wallet);
    event FactoryCreated(address router);

    function initialize(address router) public initializer {
        require(router != address(0x0), "Invalid router address.");
        _router = router;
        emit FactoryCreated(router);
    }

    /// @notice Returns address of the existing or newly created wallet.
    /// @param owner Address of the owner.
    /// @return wallet Address of the wallet.
    function getOrDeployWallet(address owner) external returns (address wallet) {
        if (_walletToOwners[owner] != address(0x0)) {
            return owner;
        }

        if (_ownerToWallets[owner] != address(0x0)) {
            return _ownerToWallets[owner];
        }

        wallet = Clones.cloneDeterministic(_router, bytes32(abi.encode(owner)));
        _ownerToWallets[owner] = wallet;
        _walletToOwners[wallet] = owner;

        IWallet(wallet).initiate(owner);

        emit WalletCreated(owner, wallet);
        return wallet;
    }

    /// @notice Computes the address of a wallet deployed.
    /// @param owner Address of the owner.
    /// @return predicted Predicted address of new wallet.
    function predictDeterministicAddress(address owner) external view returns (address predicted) {
        return Clones.predictDeterministicAddress(_router, bytes32(abi.encode(owner)), address(this));
    }

    /// @notice Returns owner address of the wallet.
    /// @param wallet Address of the wallet.
    /// @return Address of the owner.
    function getWalletOwner(address wallet) external view returns (address) {
        return _walletToOwners[wallet];
    }

    /// @notice Returns wallet address of the owner.
    /// @param owner Address of the owner.
    /// @return Address of the wallet.
    function getOwnerWallet(address owner) external view returns (address) {
        return _ownerToWallets[owner];
    }

    /// @notice Returns current router address.
    /// @return Address of the router.
    function getRouter() external view returns (address) {
        return _router;
    }
}
