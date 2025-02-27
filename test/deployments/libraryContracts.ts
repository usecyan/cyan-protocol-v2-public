import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import { Address } from '../types';

const _libraryContracts = new Map();

export const getLibraryContract = (name: string, connect?: SignerWithAddress | Address) => {
  const contract = _libraryContracts.get(name);

  if (!contract) {
    throw new Error(`Contract ${name} is not deployed.`);
  }

  if (connect) {
    return contract.connect(connect);
  }

  return contract;
};

export const deployLibraryContracts = async () => {
  const paymentPlanV2Logic = await deployAndSaveLibrary('PaymentPlanV2Logic');
  const cyanWalletLogic = await deployAndSaveLibrary('CyanWalletLogic');

  return { paymentPlanV2Logic, cyanWalletLogic };
};

export const deployLibrary = async (name: string) => {
  const { ethers } = require('hardhat');

  const F = await ethers.getContractFactory(name);
  const contract = await F.deploy();

  return await contract.deployed();
};

export const deployAndSaveLibrary = async (name: string) => {
  if (_libraryContracts.get(name)) {
    return _libraryContracts.get(name);
  }

  const library = await deployLibrary(name);
  _libraryContracts.set(name, library);
  return library;
};
