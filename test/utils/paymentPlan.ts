import { BigNumber } from 'ethers';

export const getExpectedPlanSync = (plan: FnGetExpectedPlanSync['params']): FnGetExpectedPlanSync['result'] => {
  if (plan.totalNumberOfPayments == 0) throw new Error('Invalid total number of payments');

  const {
    singleLoanAmount,
    singleInterestFee,
    singleServiceFee,
    totalInterestFee,
    totalServiceFee,
    downpaymentAmount,
  } = calculatePaymentInfoSync(plan);

  const totalFinancingAmount = plan.amount.add(totalInterestFee).add(totalServiceFee);

  return [
    plan.downPaymentPercent > 0 ? downpaymentAmount.add(singleServiceFee) : BigNumber.from(0),
    totalInterestFee,
    totalServiceFee,
    singleLoanAmount.add(singleInterestFee).add(singleServiceFee),
    totalFinancingAmount,
  ];
};

const calculatePaymentInfoSync = (plan: FnCalculatePaymenInfoSync['params']): FnCalculatePaymenInfoSync['result'] => {
  const { amount, downPaymentPercent, interestRate, serviceFeeRate, totalNumberOfPayments } = plan;

  if (totalNumberOfPayments < 1) throw new Error('Invalid total number of payments');

  const payCountWithoutDownPayment = totalNumberOfPayments - (downPaymentPercent > 0 ? 1 : 0);
  const downpaymentAmount = amount.mul(downPaymentPercent).div(10000);

  const totalLoanAmount = amount.sub(downpaymentAmount);
  const totalInterestFee = totalLoanAmount.mul(interestRate).div(10000);
  const totalServiceFee = amount.mul(serviceFeeRate).div(10000);

  const singleLoanAmount = totalLoanAmount.div(payCountWithoutDownPayment);
  const singleInterestFee = totalInterestFee.div(payCountWithoutDownPayment);
  const singleServiceFee = totalServiceFee.div(totalNumberOfPayments);

  return {
    singleLoanAmount,
    singleInterestFee,
    singleServiceFee,
    totalLoanAmount,
    totalInterestFee,
    totalServiceFee,
    downpaymentAmount,
    payCountWithoutDownPayment,
  };
};

export type FnCalculatePaymenInfoSync = {
  params: {
    amount: BigNumber;
    downPaymentPercent: number;
    interestRate: number;
    serviceFeeRate: number;
    totalNumberOfPayments: number;
  };
  result: {
    singleLoanAmount: BigNumber;
    singleInterestFee: BigNumber;
    singleServiceFee: BigNumber;
    totalLoanAmount: BigNumber;
    totalInterestFee: BigNumber;
    totalServiceFee: BigNumber;
    downpaymentAmount: BigNumber;
    payCountWithoutDownPayment: number;
  };
};

export type FnGetExpectedPlanSync = {
  params: {
    amount: BigNumber;
    downPaymentPercent: number;
    interestRate: number;
    serviceFeeRate: number;
    totalNumberOfPayments: number;
    term?: number;
    counterPaidPayments?: number;
    autoRepayStatus?: number;
  };
  result: [BigNumber, BigNumber, BigNumber, BigNumber, BigNumber];
};
