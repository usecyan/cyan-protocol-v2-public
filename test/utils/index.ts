import { FunctionFragment, id as _getSighash, hexDataSlice } from 'ethers/lib/utils';

export * from './accounts';

export const getSighash = (fn: FunctionFragment) => hexDataSlice(_getSighash(fn.format()), 0, 4);
