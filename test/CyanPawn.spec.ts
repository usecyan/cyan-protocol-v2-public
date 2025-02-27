import { expect } from 'chai';
import { BigNumber } from 'ethers';

import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { CyanPaymentPlanV2, CyanVaultV2 } from '../typechain';
import { setupTest } from './deployments';
import { getNamedSigners } from './utils';

import * as Utils from './index';

describe('Cyan Pawn test', () => {
  let cyanPaymentPlan: CyanPaymentPlanV2;
  let cyanVault: CyanVaultV2;

  let user: SignerWithAddress;

  const PLAN_ID = BigNumber.from(99376603);

  const _deploy = async () => {
    const walletContracts = await setupTest();
    ({ cyanPaymentPlan, cyanVault: cyanVault } = await Utils.beforeEach());

    const { admin, users, cyanAdmin: _cyanAdmin, cyanSuperAdmin: _cyanSuperAdmin } = await getNamedSigners();
    await Utils.wait(walletContracts.core.connect(admin).setOperator(cyanPaymentPlan.address, true));

    user = users[0];
  };

  it('creating and completing pawn', async function () {
    await loadFixture(_deploy);
    await Utils.createPawn_ERC721(PLAN_ID);

    {
      const status = await cyanPaymentPlan.connect(user).getPlanStatus(PLAN_ID);
      expect(status).to.equal(Utils.PAWN_ACTIVE);
    }

    for (let i = 1; i <= 3; i++) {
      const currentPayment = await cyanPaymentPlan.connect(user).getPaymentInfoByPlanId(PLAN_ID, false);
      const payTx = await cyanPaymentPlan.connect(user).pay(PLAN_ID, false, {
        value: currentPayment[3],
      });
      await payTx.wait();

      if (i == 3) {
        const status = await cyanPaymentPlan.connect(user).getPlanStatus(PLAN_ID);
        expect(status).to.equal(Utils.PAWN_COMPLETED);
      }
    }
  });
});
