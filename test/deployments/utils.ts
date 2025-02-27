export const deployArtifactAt = async (artifactName: string, address: string) => {
  const { artifacts, ethers } = require('hardhat');

  const artifact = await artifacts.readArtifact(artifactName);
  await ethers.provider.send('hardhat_setCode', [address, artifact.deployedBytecode]);
  const F = await ethers.getContractFactory(artifactName);
  return F.attach(address);
};
