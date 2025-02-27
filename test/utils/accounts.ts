import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { Wallet } from 'ethers';

export const getNamedSigners = async (): Promise<
  Record<string, SignerWithAddress> & { users: SignerWithAddress[] }
> => {
  const { ethers } = require('hardhat');

  const [admin, operator, owner, contractOwner, cyanSuperAdmin, cyanAdmin, cyanSigner, cyanAutoOperator, ...users] =
    await ethers.getSigners();

  return {
    admin,
    operator,
    owner,
    contractOwner,
    cyanSuperAdmin,
    cyanAdmin,
    cyanSigner,
    cyanAutoOperator,
    users,
  };
};

export const getUsers = async () => (await getNamedSigners()).users;

export const createRandomAddress = () => Wallet.createRandom().address;
