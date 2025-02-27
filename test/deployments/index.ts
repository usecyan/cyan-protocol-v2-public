import { FunctionFragment } from 'ethers/lib/utils';

import { getNamedSigners, getSighash } from '../utils';
import { createSnapshot, revertSnapshot } from '../utils/snapshots';
import { addAddress, deployAddressProvider, getAddressProvider } from './addressProvider';
import { deployConduit, getConduit } from './conduit';
import { deployCoreContracts, getCoreContract } from './coreContracts';
import { deployModuleContracts, getModule } from './moduleContracts';
import { deployTestContracts, getTestContract } from './testContracts';

export * from './coreContracts';
export * from './moduleContracts';
export * from './testContracts';

export const enableInternalModule = async (func: FunctionFragment, moduleContract: string): Promise<void> => {
  const { admin } = await getNamedSigners();
  const core = getCoreContract('Core', admin);

  await core
    .connect(admin)
    .setInternalModule(getSighash(func), moduleContract)
    .then((tx) => tx.wait());
};

const _getAllSingletonContracts = () => ({
  core: getCoreContract('Core'),
  coreRouter: getCoreContract('CoreRouter'),
  factory: getCoreContract('Factory'),

  erc721Module: getModule('ERC721Module'),

  erc721Token: getTestContract('ERC721Token'),

  addressProvider: getAddressProvider(),
  conduit: getConduit(),
});

let deploymentSnapshot: string;
export const deploySingletonContracts = async () => {
  const { admin } = await getNamedSigners();
  if (deploymentSnapshot) {
    // Reverting to after deployment snapshot and returning already deployed contracts with initial state.
    await revertSnapshot(deploymentSnapshot);
    deploymentSnapshot = await createSnapshot();
    return _getAllSingletonContracts();
  }

  const conduit = await deployConduit();
  const addressProvider = await deployAddressProvider(admin.address);
  const coreContracts = await deployCoreContracts();
  const moduleContracts = await deployModuleContracts();
  const testContracts = await deployTestContracts();

  await addAddress('CYAN_CONDUIT', conduit.address);

  deploymentSnapshot = await createSnapshot();

  return { ...coreContracts, ...testContracts, ...moduleContracts, addressProvider, conduit };
};

export const setupTest = async () => {
  const contracts = await deploySingletonContracts();
  const promises = [];

  {
    const _module = contracts.erc721Module;
    promises.push(
      enableInternalModule(_module.interface.getFunction('setLockedERC721Token'), _module.address),
      enableInternalModule(_module.interface.getFunction('transferNonLockedERC721'), _module.address)
    );
  }

  await Promise.all(promises);
  return contracts;
};
