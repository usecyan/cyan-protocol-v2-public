export type Address = string;

import { CyanPaymentPlanV2, CyanVaultTokenV1, CyanVaultV2, PaymentPlanV2Logic } from '../typechain';

export type IMainContract = CyanPaymentPlanV2 | PaymentPlanV2Logic | CyanVaultV2 | CyanVaultTokenV1;
const MainContracts = ['CyanPaymentPlanV2', 'CyanVaultV2', 'CyanVaultTokenV1', 'PaymentPlanV2Logic'] as const;
export type IMainContracts = (typeof MainContracts)[number];

declare global {
  export namespace Chai {
    interface Assertion {
      revertedWithPaymentPlanError(err: string): Promise<void>;
    }
  }
}
