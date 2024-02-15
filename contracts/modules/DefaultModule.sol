// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../interfaces/core/IModule.sol";
import "../helpers/Utils.sol";

/// @title Cyan Wallet Default Module - Forwards all transactions.
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
contract DefaultModule is IModule {
    /// @inheritdoc IModule
    function handleTransaction(
        address to,
        uint256 value,
        bytes memory data
    ) external payable override returns (bytes memory) {
        return Utils._execute(to, value, data);
    }
}
