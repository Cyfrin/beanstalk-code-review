import React, { useCallback, useMemo } from 'react';
import { Box, Divider, Stack } from '@mui/material';
import { Form, Formik, FormikHelpers, FormikProps } from 'formik';
import BigNumber from 'bignumber.js';
import {
  ERC20Token,
  Token,
  TokenSiloBalance,
  TokenValue,
} from '@beanstalk/sdk';
import FieldWrapper from '~/components/Common/Form/FieldWrapper';
import AddressInputField from '~/components/Common/Form/AddressInputField';
import {
  FormStateNew,
  FormTxnsFormState,
  SmartSubmitButton,
  TokenAdornment,
  TokenInputField,
  TxnPreview,
} from '~/components/Common/Form';
import { ZERO_BN } from '~/constants';
import { useFetchBeanstalkSilo } from '~/state/beanstalk/silo/updater';
import useSeason from '~/hooks/beanstalk/useSeason';
import TxnSeparator from '~/components/Common/Form/TxnSeparator';
import {
  displayFullBN,
  displayTokenAmount,
  tokenValueToBN,
  trimAddress,
} from '~/util';
import { FontSize } from '~/components/App/muiTheme';
import { ActionType } from '~/util/Actions';
import TransactionToast from '~/components/Common/TxnToast';
import { FC } from '~/types';
import useFormMiddleware from '~/hooks/ledger/useFormMiddleware';
import useSdk, { getNewToOldToken } from '~/hooks/sdk';
import TokenOutput from '~/components/Common/Form/TokenOutput';
import WarningAlert from '~/components/Common/Alert/WarningAlert';
import TxnAccordion from '~/components/Common/TxnAccordion';
import useAccount from '~/hooks/ledger/useAccount';
import AdditionalTxnsAccordion from '~/components/Common/Form/FormTxn/AdditionalTxnsAccordion';
import useFarmerFormTxnsActions from '~/hooks/farmer/form-txn/useFarmerFormTxnActions';
import AddPlantTxnToggle from '~/components/Common/Form/FormTxn/AddPlantTxnToggle';
import FormTxnProvider from '~/components/Common/Form/FormTxnProvider';
import useFormTxnContext from '~/hooks/sdk/useFormTxnContext';
import {
  FormTxn,
  PlantAndDoX,
  TransferFarmStep,
  WithdrawFarmStep,
} from '~/lib/Txn';
import useFarmerSiloBalancesAsync from '~/hooks/farmer/useFarmerSiloBalancesAsync';

/// tokenValueToBN is too long
/// remove me when we migrate everything to TokenValue & DecimalBigNumber
const toBN = tokenValueToBN;

export type TransferFormValues = FormStateNew &
  FormTxnsFormState & {
    to: string;
  };

const TransferForm: FC<
  FormikProps<TransferFormValues> & {
    token: Token;
    siloBalance: TokenSiloBalance | undefined;
    season: BigNumber;
    plantAndDoX: PlantAndDoX;
  }
> = ({
  // Formik
  values,
  isSubmitting,
  // Custom
  token: whitelistedToken,
  siloBalance,
  season,
  plantAndDoX,
}) => {
  const sdk = useSdk();
  const { BEAN, STALK, SEEDS } = sdk.tokens;

  /// Claim and Plant
  const txnActions = useFarmerFormTxnsActions();
  const isUsingPlant = Boolean(
    values.farmActions.primary?.includes(FormTxn.PLANT) &&
      BEAN.equals(whitelistedToken)
  );

  // Results
  const withdrawResult = useMemo(() => {
    const amount = BEAN.amount(values.tokens[0].amount?.toString() || '0');
    const crates = siloBalance?.deposited.crates || [];

    if (!isUsingPlant && (amount.lte(0) || !crates.length)) return null;
    if (isUsingPlant && plantAndDoX.getAmount().lte(0)) return null;

    return WithdrawFarmStep.calculateWithdraw(
      sdk.silo.siloWithdraw,
      whitelistedToken,
      crates,
      amount,
      season.toNumber()
    );
  }, [
    BEAN,
    isUsingPlant,
    plantAndDoX,
    sdk.silo.siloWithdraw,
    season,
    siloBalance?.deposited.crates,
    values.tokens,
    whitelistedToken,
  ]);

  const disabledActions = useMemo(
    () => (whitelistedToken.isUnripe ? [FormTxn.ENROOT] : undefined),
    [whitelistedToken.isUnripe]
  );

  // derived
  const depositedBalance = siloBalance?.deposited.amount;
  const isReady = withdrawResult && !withdrawResult.amount.lt(0);

  // Input props
  const InputProps = useMemo(
    () => ({
      endAdornment: <TokenAdornment token={whitelistedToken} />,
    }),
    [whitelistedToken]
  );

  const TokenOutputs = () => {
    if (!isReady) return null;
    if (
      !withdrawResult.amount ||
      !withdrawResult.seeds ||
      !withdrawResult.stalk
    ) {
      return null;
    }

    return (
      <TokenOutput>
        <TokenOutput.Row
          token={whitelistedToken}
          amount={withdrawResult.amount.mul(-1)}
        />
        <TokenOutput.Row
          token={STALK}
          amount={withdrawResult.stalk.mul(-1)}
          amountTooltip={
            <>
              <div>
                Withdrawing from {withdrawResult.crates.length} Deposit
                {withdrawResult.crates.length === 1 ? '' : 's'}:
              </div>
              <Divider sx={{ opacity: 0.2, my: 1 }} />
              {withdrawResult.crates.map((_crate, i) => (
                <div key={i}>
                  Season {_crate.season.toString()}:{' '}
                  {displayFullBN(_crate.bdv, whitelistedToken.displayDecimals)}{' '}
                  BDV, {displayFullBN(_crate.stalk, STALK.displayDecimals)}{' '}
                  STALK, {displayFullBN(_crate.seeds, SEEDS.displayDecimals)}{' '}
                  SEEDS
                </div>
              ))}
            </>
          }
        />
        <TokenOutput.Row token={SEEDS} amount={withdrawResult.seeds.mul(-1)} />
      </TokenOutput>
    );
  };

  return (
    <Form autoComplete="off">
      <Stack gap={1}>
        {/* Input Field */}
        <TokenInputField
          name="tokens.0.amount"
          token={whitelistedToken}
          disabled={!depositedBalance || depositedBalance.eq(0)}
          balance={toBN(depositedBalance || TokenValue.ZERO)}
          balanceLabel="Deposited Balance"
          InputProps={InputProps}
        />
        <AddPlantTxnToggle />
        {depositedBalance?.gt(0) && (
          <>
            <FieldWrapper label="Transfer to">
              <AddressInputField name="to" />
            </FieldWrapper>
            {values.to !== '' && withdrawResult?.amount.abs().gt(0) && (
              <>
                <TxnSeparator />
                <TokenOutputs />
                <WarningAlert>
                  More recent Deposits are Transferred first.
                </WarningAlert>
                <AdditionalTxnsAccordion filter={disabledActions} />
                <Box>
                  <TxnAccordion>
                    <TxnPreview
                      actions={[
                        {
                          type: ActionType.TRANSFER,
                          amount: withdrawResult
                            ? toBN(withdrawResult.amount.abs())
                            : ZERO_BN,
                          token: getNewToOldToken(whitelistedToken),
                          stalk: withdrawResult
                            ? toBN(withdrawResult.stalk.abs())
                            : ZERO_BN,
                          seeds: withdrawResult
                            ? toBN(withdrawResult?.seeds.abs())
                            : ZERO_BN,
                          to: values.to,
                        },
                        {
                          type: ActionType.BASE,
                          message: (
                            <>
                              The following Deposits will be used:
                              <br />
                              <ul
                                css={{
                                  paddingLeft: '25px',
                                  marginTop: '10px',
                                  marginBottom: 0,
                                  fontSize: FontSize.sm,
                                }}
                              >
                                {withdrawResult.crates.map((crate, index) => (
                                  <li key={index}>
                                    {displayTokenAmount(
                                      crate.amount,
                                      whitelistedToken
                                    )}{' '}
                                    from Deposits in Season{' '}
                                    {crate.season.toString()}
                                  </li>
                                ))}
                              </ul>
                            </>
                          ),
                        },
                        {
                          type: ActionType.END_TOKEN,
                          token: getNewToOldToken(whitelistedToken),
                        },
                      ]}
                      {...txnActions}
                    />
                  </TxnAccordion>
                </Box>
              </>
            )}
          </>
        )}
        <SmartSubmitButton
          loading={isSubmitting}
          disabled={
            !isReady ||
            !depositedBalance ||
            depositedBalance.eq(0) ||
            isSubmitting ||
            values.to === ''
          }
          type="submit"
          variant="contained"
          color="primary"
          size="large"
          tokens={[]}
          mode="auto"
        >
          {!depositedBalance || depositedBalance.eq(0)
            ? 'Nothing to Transfer'
            : 'Transfer'}
        </SmartSubmitButton>
      </Stack>
    </Form>
  );
};

const TransferPropProvider: FC<{
  token: ERC20Token;
  /// temporary. will be remove when sdk types are moved to redux
  siloBalance: ReturnType<typeof useFarmerSiloBalancesAsync>;
}> = ({ token, siloBalance }) => {
  const sdk = useSdk();
  const account = useAccount();

  /// Beanstalk
  const season = useSeason();

  /// Farmer
  const [refetchSilo] = useFetchBeanstalkSilo();
  const [farmerBalances, refetchFarmerBalances] = siloBalance;

  /// Form
  const middleware = useFormMiddleware();
  const { txnBundler, plantAndDoX, refetch } = useFormTxnContext();

  const initialValues: TransferFormValues = useMemo(
    () => ({
      tokens: [
        {
          token: token,
          amount: undefined,
        },
      ],
      to: '',
      farmActions: {
        preset: sdk.tokens.BEAN.equals(token) ? 'plant' : 'noPrimary',
        primary: undefined,
        secondary: undefined,
        implied: [FormTxn.MOW],
      },
    }),
    [sdk.tokens.BEAN, token]
  );

  const onSubmit = useCallback(
    async (
      values: TransferFormValues,
      formActions: FormikHelpers<TransferFormValues>
    ) => {
      let txToast;
      try {
        middleware.before();
        if (!account) throw new Error('Missing signer');
        if (!values.to) {
          throw new Error('Please enter a valid recipient address.');
        }

        if (!farmerBalances?.deposited.crates) {
          throw new Error('No balances found');
        }

        const formData = values.tokens[0];
        const primaryActions = values.farmActions.primary;

        const isPlanting =
          primaryActions?.includes(FormTxn.PLANT) &&
          sdk.tokens.BEAN.equals(token);

        const baseAmount = token.amount((formData?.amount || 0).toString());

        const totalAmount = isPlanting
          ? baseAmount.add(plantAndDoX.getAmount())
          : baseAmount;

        if (totalAmount.lte(0)) throw new Error('Invalid amount.');

        const transferTxn = new TransferFarmStep(sdk, token, account, [
          ...farmerBalances.deposited.crates,
        ]);

        transferTxn.build(
          values.to,
          baseAmount,
          season.toNumber(),
          isPlanting ? plantAndDoX : undefined
        );

        if (!transferTxn.withdrawResult) {
          throw new Error('Nothing to withdraw');
        }

        const withdrawAmtStr = displayFullBN(
          transferTxn.withdrawResult.amount.abs(),
          token.displayDecimals,
          token.displayDecimals
        );

        txToast = new TransactionToast({
          loading: `Transferring ${withdrawAmtStr} ${
            token.name
          } to ${trimAddress(values.to, true)}.`,
          success: 'Transfer successful.',
        });

        const actionsPerformed = txnBundler.setFarmSteps(values.farmActions);

        const { execute } = await txnBundler.bundle(
          transferTxn,
          // we can pass in 0 here b/c TransferFarmStep already receives it's input amount in build();
          token.amount(0),
          0.1
        );
        const txn = await execute();
        txToast.confirming(txn);

        const receipt = await txn.wait();
        await refetch(actionsPerformed, { farmerSilo: true }, [
          refetchSilo,
          refetchFarmerBalances,
        ]);

        txToast.success(receipt);

        formActions.resetForm();
      } catch (err) {
        if (txToast) {
          txToast.error(err);
        } else {
          const toast = new TransactionToast({});
          toast.error(err);
        }
        formActions.setSubmitting(false);
      }
    },
    [
      middleware,
      account,
      farmerBalances?.deposited.crates,
      token,
      sdk,
      season,
      plantAndDoX,
      txnBundler,
      refetch,
      refetchSilo,
      refetchFarmerBalances,
    ]
  );

  return (
    <Formik initialValues={initialValues} onSubmit={onSubmit}>
      {(formikProps: FormikProps<TransferFormValues>) => (
        <TransferForm
          token={token}
          siloBalance={farmerBalances}
          season={season}
          plantAndDoX={plantAndDoX}
          {...formikProps}
        />
      )}
    </Formik>
  );
};

const Transfer: React.FC<{
  token: ERC20Token;
  /// temporary. will be remove when sdk types are moved to redux
  siloBalance: ReturnType<typeof useFarmerSiloBalancesAsync>;
}> = (props) => (
  <FormTxnProvider>
    <TransferPropProvider {...props} />
  </FormTxnProvider>
);

export default Transfer;
