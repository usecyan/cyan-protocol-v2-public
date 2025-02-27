import { expect } from 'chai';
import { ethers } from 'hardhat';

import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { BigNumber } from 'ethers';
import { CyanPaymentPlanV2 } from '../typechain';
import { setupTest } from './deployments';
import { getNamedSigners } from './utils';

import * as Utils from './index';

describe('Cyan BNPL test', () => {
  let cyanPaymentPlan: CyanPaymentPlanV2;

  let cyanAdmin: SignerWithAddress;
  let user: SignerWithAddress;

  const PLAN_ID = BigNumber.from(123456);
  const EXPECTED_SINGLE_PAYMENT = ethers.utils.parseEther('3.2725');

  const _deploy = async () => {
    const walletContracts = await setupTest();
    ({ cyanPaymentPlan } = await Utils.beforeEach());

    const { admin, users, cyanAdmin: _cyanAdmin } = await getNamedSigners();
    await Utils.wait(walletContracts.core.connect(admin).setOperator(cyanPaymentPlan.address, true));

    user = users[0];
    cyanAdmin = _cyanAdmin;
  };

  it('create and complete bnpl plan', async () => {
    await loadFixture(_deploy);
    await Utils.createBNPL_ERC721();

    const firstPayment = await cyanPaymentPlan.connect(user).getPaymentInfoByPlanId(PLAN_ID, false);
    expect(firstPayment[3]).to.equal(EXPECTED_SINGLE_PAYMENT);

    {
      const status = await cyanPaymentPlan.connect(user).getPlanStatus(PLAN_ID);
      expect(status).to.equal(Utils.BNPL_CREATED);
    }

    const lendTx = await cyanPaymentPlan.connect(cyanAdmin).fundBNPL([PLAN_ID]);
    await lendTx.wait();

    // Activating BNPL payment plan
    const activateTx = await cyanPaymentPlan.connect(cyanAdmin).activateBNPL([PLAN_ID]);
    await activateTx.wait();

    // Activate funcation is called, so payment plan must be active
    const status = await cyanPaymentPlan.connect(user).getPlanStatus(PLAN_ID);
    expect(status).to.equal(Utils.BNPL_ACTIVE);

    for (let i = 2; i <= Utils.BNPL_TOTAL_PAYMENT_NUM; i++) {
      const currentPayment = await cyanPaymentPlan.connect(user).getPaymentInfoByPlanId(PLAN_ID, false);
      const payTx = await cyanPaymentPlan.connect(user).pay(PLAN_ID, false, {
        value: currentPayment[3],
      });
      await payTx.wait();
    }

    {
      // All payment is completed
      const status = await cyanPaymentPlan.connect(user).getPlanStatus(PLAN_ID);
      expect(status).to.equal(Utils.BNPL_COMPLETED);
    }
  });
});
