// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { PaymentPlanStatus } from "../../main/payment-plan/PaymentPlanTypes.sol";

interface ICyanPaymentPlanV2 {
    function pay(uint256, bool) external payable;

    function getPlanStatus(uint256) external view returns (PaymentPlanStatus);

    function getCurrencyAddressByPlanId(uint256) external view returns (address);

    function earlyUnwindOpensea(
        uint256,
        uint256[2] calldata,
        uint256,
        bytes memory,
        uint256,
        bytes memory
    ) external;

    function earlyUnwindCyan(
        uint256,
        uint256[2] calldata,
        uint256,
        address,
        uint256,
        bytes memory
    ) external;

    function liquidate(
        uint256,
        uint256[2] calldata,
        uint256
    ) external;
}
