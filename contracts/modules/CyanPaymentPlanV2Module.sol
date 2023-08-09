// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../CoreStorage.sol";
import "../Utils.sol";

interface ICyanPaymentPlanV2 {
    function pay(uint256, bool) external payable;

    function getCurrencyAddressByPlanId(uint256) external view returns (address);
}

/// @title Cyan Wallet's Cyan Payment Plan Module - A Cyan wallet's Cyan Payment Plan handling module.
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
contract CyanPaymentPlanV2Module is CoreStorage, IModule {
    /// @inheritdoc IModule
    function handleTransaction(
        address to,
        uint256 value,
        bytes calldata data
    ) external payable override returns (bytes memory) {
        return Utils._execute(to, value, data);
    }

    function autoPay(uint256 planId, uint256 payAmount) external payable {
        ICyanPaymentPlanV2 paymentPlanContract = ICyanPaymentPlanV2(msg.sender);
        address currencyAddress = paymentPlanContract.getCurrencyAddressByPlanId(planId);
        if (currencyAddress == address(0x0)) {
            require(address(this).balance >= payAmount, "Not enough ETH in the wallet.");
            paymentPlanContract.pay{value: payAmount}(planId, false);
        } else {
            require(IERC20(currencyAddress).balanceOf(address(this)) >= payAmount, "Not enough balance in the wallet.");
            IERC20(currencyAddress).approve(msg.sender, payAmount);
            paymentPlanContract.pay(planId, false);
        }
    }
}
