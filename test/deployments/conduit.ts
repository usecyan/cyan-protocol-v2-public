import { CyanConduit } from '../../typechain';

let _conduit: CyanConduit;

export const deployConduit = async (): Promise<CyanConduit> => {
  if (_conduit) return _conduit;

  const { ethers } = require('hardhat');
  const F = await ethers.getContractFactory('CyanConduit');
  const conduit = await F.deploy();
  _conduit = conduit;
  await conduit.deployed();

  return conduit;
};

export const getConduit = (): CyanConduit => {
  return _conduit;
};
