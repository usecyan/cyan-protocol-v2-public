import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { Core, CoreRouter, Factory } from '../../typechain';

import { Address } from '../types';
import { getNamedSigners } from '../utils/accounts';

const _coreContracts = new Map();

export const getCoreContract = (name: string, connect?: SignerWithAddress | Address) => {
  const contract = _coreContracts.get(name);

  if (!contract) {
    throw new Error(`Contract ${name} is not deployed.`);
  }

  if (connect) {
    return contract.connect(connect);
  }

  return contract;
};

export const deployCoreContracts = async () => {
  const { admin, operator } = await getNamedSigners();
  const core = await deployCore();

  _coreContracts.set('Core', core);
  await core.connect(admin).setOperator(operator.address, true);

  const coreRouter = await deployCoreRouter(core.address);
  _coreContracts.set('CoreRouter', coreRouter);

  const factory = await deployFactory(coreRouter.address);
  _coreContracts.set('Factory', factory);

  return { core, coreRouter, factory };
};

export const deployCore = async (): Promise<Core> => {
  const { ethers } = require('hardhat');
  const F = await ethers.getContractFactory('Core');
  const core = await F.deploy();

  return await core.deployed();
};

export const deployCoreRouter = async (core: Address): Promise<CoreRouter> => {
  const { ethers } = require('hardhat');
  const F = await ethers.getContractFactory('CoreRouter');
  const coreRouter = await F.deploy(core);
  return await coreRouter.deployed();
};

export const deployFactory = async (router: Address): Promise<Factory> => {
  const { ethers, upgrades } = require('hardhat');
  const F = await ethers.getContractFactory('Factory');
  const factory = await upgrades.deployProxy(F, [router]);
  return await factory.deployed();
};
