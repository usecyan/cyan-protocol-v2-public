import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import { ERC721Token } from '../../typechain';
import { Address } from '../types';

const _testContracts = new Map();

export const getTestContract = (name: string, connect?: SignerWithAddress | Address) => {
  const contract = _testContracts.get(name);

  if (!contract) {
    throw new Error(`Contract ${name} is not deployed.`);
  }

  if (connect) {
    return contract.connect(connect);
  }

  return contract;
};

export const deployTestContracts = async () => {
  const erc721Token = await deployERC721();

  _testContracts.set('ERC721Token', erc721Token);

  return { erc721Token };
};

export const deployERC721 = async (name = 'Dummy', symbol = 'DMY'): Promise<ERC721Token> => {
  const { ethers } = require('hardhat');
  const F = await ethers.getContractFactory('ERC721Token');
  const erc721 = await F.deploy(name, symbol);
  return await erc721.deployed();
};
