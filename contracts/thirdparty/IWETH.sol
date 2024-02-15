// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Wrapped Etheruem Contract interface
interface IWETH is IERC20 {
    function withdraw(uint256 wad) external;

    function deposit() external payable;
}
