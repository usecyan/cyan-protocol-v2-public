import { ERC721Module } from '../../typechain';

const _moduleContracts = new Map();

export const getModule = (name: string) => {
  return _moduleContracts.get(name);
};

export const deployModuleContracts = async () => {
  const erc721Module = await deployERC721Module();
  _moduleContracts.set('ERC721Module', erc721Module);

  return { erc721Module };
};

export const deployERC721Module = async (): Promise<ERC721Module> => {
  const { ethers } = require('hardhat');

  const F = await ethers.getContractFactory('ERC721Module');
  const erc721Module = await F.deploy();
  await erc721Module.deployed();

  return erc721Module;
};
