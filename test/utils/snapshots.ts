import { ethers } from 'hardhat';

let _snapshots: string[] = [];

export const createSnapshot = async (): Promise<string> => {
  const snapshot = await ethers.provider.send('evm_snapshot', []);
  _snapshots.push(snapshot);
  return snapshot;
};

export const revertSnapshot = async (snapshot?: string): Promise<void> => {
  if (snapshot) {
    const index = _snapshots.indexOf(snapshot);
    if (index < 0) {
      throw new Error(`Given snapshot ${snapshot} not found.`);
    }
    _snapshots = _snapshots.slice(index, -1);

    await ethers.provider.send('evm_revert', [snapshot]);
    return;
  }

  await ethers.provider.send('evm_revert', [_snapshots.pop()]);
};
