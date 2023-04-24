import { createReducer, createSelector } from '@reduxjs/toolkit';
import { NEW_BN, ZERO_BN } from '~/constants';
import { BeanstalkField } from '.';
import {
  resetBeanstalkField,
  updateBeanstalkField,
  updateHarvestableIndex,
  updateScaledTemperature,
} from './actions';

const initialState: BeanstalkField = {
  harvestableIndex: NEW_BN,
  podIndex: NEW_BN,
  podLine: ZERO_BN,
  soil: NEW_BN,
  weather: {
    lastDSoil: NEW_BN,
    lastSowTime: NEW_BN,
    thisSowTime: NEW_BN,
  },
  temperature: {
    max: NEW_BN,
    scaled: NEW_BN,
  },
};

export default createReducer(initialState, (builder) =>
  builder
    .addCase(resetBeanstalkField, () => initialState)
    .addCase(updateBeanstalkField, (state, { payload }) => {
      Object.keys(payload).forEach((key) => {
        const _k = key as keyof Omit<BeanstalkField, 'morningBlock'>;
        const _p = payload[_k];
        // @ts-ignore
        state[_k] = _p;
      });
    })
    .addCase(updateHarvestableIndex, (state, { payload }) => {
      state.harvestableIndex = payload;
    })
    .addCase(updateScaledTemperature, (state, { payload }) => {
      state.temperature.scaled = payload;
    })
);

export const selectBeanstalkField = (state: {
  _beanstalk: { field: BeanstalkField };
}) => state._beanstalk.field;

export const selectFieldTemperature = createSelector(
  selectBeanstalkField,
  (state) => ({
    scaled: state.temperature.scaled,
    max: state.temperature.max,
  })
);
