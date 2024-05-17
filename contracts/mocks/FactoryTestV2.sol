// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../core/Factory.sol";

/// @title Cyan Wallet Test Factory - Testing purpose factory
contract FactoryTestV2 is Factory {
    uint256 private _counter;

    function getCounter() external view returns (uint256) {
        return _counter;
    }

    function increment() external {
        _counter++;
    }
}
