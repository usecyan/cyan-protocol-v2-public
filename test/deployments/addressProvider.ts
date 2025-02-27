import { setStorageAt } from '@nomicfoundation/hardhat-network-helpers';
import { formatBytes32String } from 'ethers/lib/utils';
import { AddressProvider } from '../../typechain';
import { deployArtifactAt } from './utils';

let _addressProvider: AddressProvider;

export const deployAddressProvider = async (ownerAddress: string): Promise<AddressProvider> => {
  if (_addressProvider) {
    return _addressProvider;
  }
  const address = '0xCF9A19D879769aDaE5e4f31503AAECDa82568E55';
  const addressProvider = (await deployArtifactAt('AddressProvider', address)) as AddressProvider;

  // Setting owner address
  await setStorageAt(addressProvider.address, 0, ownerAddress);

  _addressProvider = addressProvider;
  return addressProvider;
};

export const getAddressProvider = (): AddressProvider => {
  return _addressProvider;
};

export const addAddress = async (id: string, address: string): Promise<void> => {
  await _addressProvider.setAddress(formatBytes32String(id), address).then((tx) => tx.wait());
};
