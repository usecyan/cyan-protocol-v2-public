import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { use } from 'chai';
import { BigNumber, BigNumberish, Contract, ContractTransaction, constants } from 'ethers';
import { parseEther } from 'ethers/lib/utils';
import { CyanConduit, CyanPaymentPlanV2, CyanVaultTokenV1, CyanVaultV2, ERC721Token, Factory } from '../typechain';
import { ItemStruct, PlanStruct } from '../typechain/contracts/main/payment-plan/PaymentPlanV2Logic';
import { getCoreContract, getTestContract } from './deployments';
import { getConduit } from './deployments/conduit';
import { getNamedSigners } from './utils';
import { IMainContract, IMainContracts } from './types';

export const CYAN_ROLE = '0x321163fcbab3bac890d4fb1f03b22c5c6bd95bc472ee55584937974a1db03356';
export const CYAN_PAYMENT_PLAN_ROLE = '0x507793b6688804c17fc033a24c049858152fd713503d8768de9c67313c5a3afd';
export const CYAN_VAULT_ROLE = '0x616e9a3ec0fb1277faa49faadf89ce57fdcf7e0fcf6bf708965dcc385ea9505d';

export const SAFETY_FUND_PERCENT = 2000; // 20%
export const SERVICE_FEE_PERCENT = 30; // 0.3%

export const tokenId = BigNumber.from(101);
export const tokenIdUser = BigNumber.from(102);

export const TOKEN_AMOUNT = BigNumber.from(1001);

export const DOWN_PAYMENT_PERCENT: number = 2500;
export const INTEREST_RATE: number = 1800;
export const BNPL_TOTAL_PAYMENT_NUM: number = 4;
export const PAWN_TOTAL_PAYMENT_NUM: number = 3;
export const TERM: number = 31 * 24 * 60;
export const DEFAULT_SERVICE_FEE_RATE: number = 100;
export const DEFAULT_APE_POOL_INTEREST_RATE: number = 4500;
export const SIGNATURE_TERM: number = 24 * 60;
const WEEK = 7 * 24 * 60 * 60;
const chainId = 31337;

export enum ItemTypes {
  ERC721 = 1,
  ERC1155 = 2,
  CryptoPunks = 3,
}

export const AUTO_REPAY_STATUS = {
  DISABLED: 0,
  ENABLED: 1,
  ENABLED_FROM_MAIN: 2,
};
export type IAutoRepayStatus = typeof AUTO_REPAY_STATUS[keyof typeof AUTO_REPAY_STATUS];

const _mainContracts: Map<IMainContracts, IMainContract> = new Map();
export const getMainContract = <T extends IMainContract>(
  name: IMainContracts,
  connect?: SignerWithAddress | string
): T => {
  const contract = _mainContracts.get(name);

  if (!contract) {
    throw new Error(`Contract ${name} is not deployed.`);
  }

  if (connect) {
    return contract.connect(connect) as T;
  }

  return contract as T;
};

export const deployCyanPaymentPlanContract = async (walletFactory: Factory): Promise<CyanPaymentPlanV2> => {
  const { ethers, upgrades } = require('hardhat');
  const { cyanSigner, cyanSuperAdmin } = await getNamedSigners();

  const CyanWalletLogic = await ethers.getContractFactory('CyanWalletLogic');
  const cyanWalletLogic = await CyanWalletLogic.deploy();
  await cyanWalletLogic.deployed();

  const PaymentPlanV2Logic = await ethers.getContractFactory('PaymentPlanV2Logic');
  const paymentPlanV2Logic = await PaymentPlanV2Logic.deploy();
  await paymentPlanV2Logic.deployed();

  const PaymentPlan = await ethers.getContractFactory('CyanPaymentPlanV2', {
    libraries: {
      CyanWalletLogic: cyanWalletLogic.address,
      PaymentPlanV2Logic: paymentPlanV2Logic.address,
    },
  });
  const cyanPaymentPlan = await upgrades.deployProxy(
    PaymentPlan,
    [cyanSigner.address, cyanSuperAdmin.address, walletFactory.address],
    {
      unsafeAllowLinkedLibraries: true,
    }
  );
  await cyanPaymentPlan.deployed();

  _mainContracts.set('CyanPaymentPlanV2', cyanPaymentPlan);
  _mainContracts.set('PaymentPlanV2Logic', paymentPlanV2Logic);

  const conduit = getConduit();
  await conduit.updateChannel(cyanPaymentPlan.address, true).then((tx) => tx.wait());

  use((chai) => {
    const Assertion = chai.Assertion;

    Assertion.addMethod('revertedWithPaymentPlanError', function (err) {
      const obj = this._obj;

      try {
        return new Assertion(obj).revertedWithCustomError(paymentPlanV2Logic, err);
      } catch (e: any) {
        if (e.message.startsWith("The given contract doesn't have a custom error named")) {
          return new Assertion(obj).to.be.revertedWithCustomError(cyanPaymentPlan, err);
        }

        throw e;
      }
    });
  });
  return cyanPaymentPlan;
};

export const deployCyanVaultTokenContract = async (name: string, symbol: string) => {
  const { ethers } = require('hardhat');
  const { cyanSuperAdmin } = await getNamedSigners();
  const CyanVaultToken = await ethers.getContractFactory('CyanVaultTokenV1');
  const cyanVaultToken = await CyanVaultToken.deploy(name, symbol, cyanSuperAdmin.address);
  await cyanVaultToken.deployed();
  _mainContracts.set('CyanVaultTokenV1', cyanVaultToken);
  return cyanVaultToken;
};

export const deployCyanVaultContract = async (
  cyanVaultTokenAddress: string,
  currencyTokenAddress: string,
  cyanPaymentPlanAddress: string,
  safetyFundPercent: number,
  serviceFeePercent: number,
  factoryAddress?: string,
  cyanSignerAddress?: string
): Promise<CyanVaultV2> => {
  const { ethers, upgrades } = require('hardhat');
  const { cyanSuperAdmin, cyanSigner } = await getNamedSigners();
  const CyanVault = await ethers.getContractFactory('CyanVaultV2');
  const _factoryAddress = factoryAddress ?? getCoreContract('Factory').address;
  const _cyanSignerAddress = cyanSignerAddress ?? cyanSigner.address;

  const cyanVault = await upgrades.deployProxy(
    CyanVault,
    [
      cyanVaultTokenAddress,
      currencyTokenAddress,
      cyanPaymentPlanAddress,
      cyanSuperAdmin.address,
      _factoryAddress,
      safetyFundPercent,
      serviceFeePercent,
      WEEK,
      false,
      _cyanSignerAddress,
    ],
    { initializer: 'initializeV3' }
  );
  await cyanVault.deployed();
  if (currencyTokenAddress === constants.AddressZero) {
    _mainContracts.set('CyanVaultV2', cyanVault);
  }
  return cyanVault;
};

export const mintSampleErc721Token = async (contract: ERC721Token, userAddress: string, tokenId: BigNumber) => {
  const mintTx = await contract.mint(userAddress, tokenId);
  await mintTx.wait();
  return {
    contract,
    userAddress,
    tokenId,
  };
};

export const approve = async (cyanAdmin: SignerWithAddress, sampleNFT: ERC721Token, conduit: CyanConduit) => {
  await sampleNFT
    .connect(cyanAdmin)
    .setApprovalForAll(conduit.address, true)
    .then((tx) => tx.wait());
};

export const getSignature = async (
  item: ItemStruct,
  plan: PlanStruct,
  planId: BigNumber,
  signatureExpiryDate: number,
  cyanSigner: SignerWithAddress
) => {
  const { ethers } = require('hardhat');
  const itemHash = ethers.utils.solidityKeccak256(
    ['address', 'address', 'uint256', 'uint256', 'uint8'],
    [item.cyanVaultAddress, item.contractAddress, item.tokenId, item.amount, item.itemType]
  );
  const planHash = ethers.utils.solidityKeccak256(
    ['uint256', 'uint32', 'uint32', 'uint32', 'uint32', 'uint8', 'uint8', 'uint8'],
    [
      plan.amount,
      plan.downPaymentPercent,
      plan.interestRate,
      plan.serviceFeeRate,
      plan.term,
      plan.totalNumberOfPayments,
      plan.counterPaidPayments,
      plan.autoRepayStatus,
    ]
  );
  const messageHash = ethers.utils.solidityKeccak256(
    ['bytes32', 'bytes32', 'uint256', 'uint256', 'uint256'],
    [itemHash, planHash, planId, signatureExpiryDate, chainId]
  );
  const messageHashBinary = ethers.utils.arrayify(messageHash);
  return await cyanSigner.signMessage(messageHashBinary);
};

export const getCollectionSignature = async (
  collectionAddress: string,
  version: number,
  cyanSigner: SignerWithAddress
) => {
  const { ethers } = require('hardhat');

  const messageHash = ethers.utils.solidityKeccak256(
    ['address', 'uint256', 'uint256'],
    [collectionAddress, chainId, version]
  );
  return await cyanSigner.signMessage(ethers.utils.arrayify(messageHash));
};

export const grantRole = async (contract: Contract, admin: SignerWithAddress, address: string, role: string) => {
  const txn = await contract.connect(admin).grantRole(role, address);
  await txn.wait();
};

export const revokeRole = async (contract: Contract, admin: SignerWithAddress, address: string, role: string) => {
  const txn = await contract.connect(admin).revokeRole(role, address);
  await txn.wait();
};

const defaultOptions = {
  vaultTokenName: 'CyanBlueChipPFPVaultToken',
  vaultTokenSymbol: 'CV01',
  vaultSafetyFundPercent: SAFETY_FUND_PERCENT,
  vaultServiceFeePercent: SERVICE_FEE_PERCENT,
};
export const deployContracts = async (
  vaultInitialAmount: BigNumber,
  walletFactory: Factory,
  sampleNFT?: ERC721Token,
  options: Record<string, any> = defaultOptions
) => {
  const _options = Object.assign({}, defaultOptions, options);
  const { cyanAdmin, cyanSuperAdmin } = await getNamedSigners();
  const cyanPaymentPlan = await deployCyanPaymentPlanContract(walletFactory);
  const conduit = getConduit();

  // Deploying native currency Vault
  const cyanVaultToken = await deployCyanVaultTokenContract(_options.vaultTokenName, _options.vaultTokenSymbol);
  const cyanVault = await deployCyanVaultContract(
    cyanVaultToken.address,
    constants.AddressZero,
    cyanPaymentPlan.address,
    _options.vaultSafetyFundPercent,
    _options.vaultServiceFeePercent,
    walletFactory.address
  );

  if (sampleNFT) {
    // Approve cyanAdmin address to transfer ERC721 tokens to Cyan Conduit contract
    await approve(cyanAdmin, sampleNFT, conduit);
  }

  // Granting admin roles by contract owner
  await grantRole(cyanVaultToken, cyanSuperAdmin, cyanVault.address, CYAN_VAULT_ROLE);
  await grantRole(cyanPaymentPlan, cyanSuperAdmin, cyanAdmin.address, CYAN_ROLE);

  const initialDepositNativeTx = await cyanVault.deposit(vaultInitialAmount, {
    value: vaultInitialAmount,
  });
  await initialDepositNativeTx.wait();

  return {
    sampleNFT,
    cyanPaymentPlan,
    cyanVaultToken,
    cyanVault,
  };
};

export const beforeEach = async (options?: {
  vaultInitialAmount?: BigNumber;
  vaultAutoLiquidationEnabled?: boolean;
  walletFactory?: Factory;

  isErc721Disabled?: boolean;
  erc721Token?: ERC721Token;
}): Promise<{
  sampleNFT?: ERC721Token;
  cyanPaymentPlan: CyanPaymentPlanV2;

  cyanVaultToken: CyanVaultTokenV1;
  cyanVault: CyanVaultV2;

  tokenId: BigNumberish;
}> => {
  const { cyanAdmin, users } = await getNamedSigners();
  const factory = options?.walletFactory ?? getCoreContract('Factory');
  const erc721Token = options?.isErc721Disabled ? undefined : options?.erc721Token ?? getTestContract('ERC721Token');

  const { cyanPaymentPlan, cyanVaultToken, cyanVault } = await deployContracts(parseEther('100'), factory, erc721Token);

  await mintSampleErc721Token(erc721Token, cyanAdmin.address, tokenId);
  await mintSampleErc721Token(erc721Token, users[0].address, tokenIdUser);

  return {
    sampleNFT: erc721Token,
    cyanPaymentPlan,

    cyanVaultToken,
    cyanVault,

    tokenId,
  };
};

export const rollForwardBySeconds = async (seconds: number) => {
  const { ethers } = require('hardhat');
  const lastBlockNum_2 = await ethers.provider.getBlockNumber();
  const lastBlock_2 = await ethers.provider.getBlock(lastBlockNum_2);
  const lastTimestamp_2 = lastBlock_2.timestamp;

  await ethers.provider.send('evm_mine', [lastTimestamp_2 + seconds]);
};

export const createBNPL_ERC721 = async (o?: {
  item?: Partial<ItemStruct>;
  plan?: Partial<PlanStruct>;
  options?: ICreatePlanOptions & {
    mint?: boolean;
    approveToken?: boolean;
    tokenContract?: ERC721Token;
    downPayment?: BigNumberish;
  };
}) => {
  const tokenContract = o?.options?.tokenContract ?? getTestContract('ERC721Token');
  const vaultAddress = o?.item?.cyanVaultAddress ?? getMainContract('CyanVaultV2').address;

  const item = {
    cyanVaultAddress: vaultAddress,
    contractAddress: tokenContract.address,
    tokenId,
    amount: 0,
    itemType: ItemTypes.ERC721,
    ...o?.item,
  };

  const downPayment = o?.options?.downPayment ?? parseEther('2.7775');
  return await _createBNPL(item, o?.plan, { ...o?.options, downPayment });
};

const _createBNPL = async (
  item: ItemStruct,
  plan?: Partial<PlanStruct>,
  options?: ICreatePlanOptions & { downPayment: BigNumberish }
) => {
  const { ethers } = require('hardhat');
  const _plan = fillDefaultPlanOptions(true, plan);
  const _options = await fillDefaultPaymenPlanOptions(options);
  const lastBlockNum = await ethers.provider.getBlockNumber();
  const lastBlock = await ethers.provider.getBlock(lastBlockNum);
  const expiryDate = lastBlock.timestamp + 60;

  const signature = await getSignature(item, _plan, _options.planId, expiryDate, _options.cyanSigner);
  await _options.paymentPlan
    .connect(_options.user)
    .createBNPL(
      item,
      _plan,
      _options.planId,
      { expiryDate, signature },
      {
        // TODO: use correct method for fetching currency address
        value: getMainContract<CyanVaultV2>('CyanVaultV2').address === item.cyanVaultAddress ? options?.downPayment : 0,
      }
    )
    .then((tx) => tx.wait());
  return {
    item,
    plan: _plan,
    options: _options,
  };
};

export const createPawn_ERC721 = async (planId: BigNumber) => {
  const { users } = await getNamedSigners();

  const cyanVaultAddress = getMainContract('CyanVaultV2').address;
  const tokenContract = getTestContract('ERC721Token');

  const conduit = getConduit();
  await wait(tokenContract.connect(users[0]).approve(conduit.address, tokenIdUser));

  const item = {
    cyanVaultAddress: cyanVaultAddress,
    contractAddress: tokenContract.address,
    tokenId: tokenIdUser,
    amount: 0,
    itemType: ItemTypes.ERC721,
  };

  return await _createPawn(item, planId);
};

type ICreatePlanOptions = {
  paymentPlan?: CyanPaymentPlanV2;
  cyanVault?: CyanVaultV2;
  user?: SignerWithAddress;
  planId?: BigNumberish;
  tokenContract?: ERC721Token;
};
const fillDefaultPlanOptions = (isBNPL: boolean, plan?: Partial<PlanStruct>) => {
  const defaults = {
    amount: parseEther('11'),
    downPaymentPercent: isBNPL ? DOWN_PAYMENT_PERCENT : 0,
    interestRate: INTEREST_RATE,
    serviceFeeRate: DEFAULT_SERVICE_FEE_RATE,
    term: TERM,
    totalNumberOfPayments: isBNPL ? BNPL_TOTAL_PAYMENT_NUM : PAWN_TOTAL_PAYMENT_NUM,
    counterPaidPayments: isBNPL ? 1 : 0,
    autoRepayStatus: AUTO_REPAY_STATUS.DISABLED,
  };
  return Object.assign({}, defaults, plan);
};

const fillDefaultPaymenPlanOptions = async (options?: Partial<ICreatePlanOptions>) => {
  const { cyanSigner, users } = await getNamedSigners();
  const defaults = {
    paymentPlan: getMainContract<CyanPaymentPlanV2>('CyanPaymentPlanV2'),
    cyanVault: getMainContract<CyanVaultV2>('CyanVaultV2'),
    cyanSigner,
    user: users[0],
    planId: BigNumber.from(123456),
  };
  return Object.assign({}, defaults, options);
};
const _createPawn = async (item: ItemStruct, planId: BigNumber) => {
  const { ethers } = require('hardhat');
  const _plan = fillDefaultPlanOptions(false, {});
  const _options = await fillDefaultPaymenPlanOptions({ planId });

  const lastBlockNum = await ethers.provider.getBlockNumber();
  const lastBlock = await ethers.provider.getBlock(lastBlockNum);
  const expiryDate = lastBlock.timestamp + 60;

  const signature = await getSignature(item, _plan, _options.planId, expiryDate, _options.cyanSigner);
  await wait(
    _options.paymentPlan.connect(_options.user).createPawn(item, _plan, _options.planId, { expiryDate, signature })
  );
  return {
    item,
    plan: _plan,
    options: _options,
  };
};

export const wait = async (promise: Promise<ContractTransaction>) => {
  const tx = await promise;
  return await tx.wait();
};

export const BNPL_CREATED = 0;
export const BNPL_FUNDED = 1;
export const BNPL_ACTIVE = 2;
export const BNPL_DEFAULTED = 3;
export const BNPL_REJECTED = 4;
export const BNPL_COMPLETED = 5;
export const BNPL_LIQUIDATED = 6;
export const PAWN_ACTIVE = 7;
export const PAWN_DEFAULTED = 8;
export const PAWN_COMPLETED = 9;
export const PAWN_LIQUIDATED = 10;
