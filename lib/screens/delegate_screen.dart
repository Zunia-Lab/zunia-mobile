import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/tabs/earn_tab.dart';
import 'package:zunia_mobile/services/staking_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/staking.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/ui/facts.dart';
import 'package:zunia_mobile/ui/tx_flow.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/validator_avatar.dart';
import 'package:zunia_ui/zunia_ui.dart';

enum DelegateMode { stake, unstake }

/// Why an amount cannot be staked or unstaked as typed; null when it can.
String? delegateAmountProblem({
  required AmountInput input,
  required BigInt? pool,
  required DelegateMode mode,
}) {
  switch (input.issue) {
    case null:
      break;
    case AmountIssue.empty:
      return null;
    case AmountIssue.tooManyDecimals:
      return 'Too many decimal places for this token';
    case AmountIssue.notPositive:
      return 'Enter more than zero';
    case AmountIssue.negative:
    case AmountIssue.notANumber:
      return 'Enter a valid amount';
  }
  final units = BigInt.parse(input.baseUnits);
  if (pool != null && units > pool) {
    return mode == DelegateMode.stake
        ? 'More than your available balance'
        : 'More than you have staked here';
  }
  return null;
}

/// Amount entry for a stake or an unstake with one validator, then review.
class DelegateScreen extends ConsumerStatefulWidget {
  const DelegateScreen({
    super.key,
    required this.chainId,
    required this.operatorAddress,
    this.mode = DelegateMode.stake,
    this.returnTo,
  });

  final String chainId;
  final String operatorAddress;
  final DelegateMode mode;

  /// Where Done on the result page goes back to; this screen by default.
  final ModalRoute<dynamic>? returnTo;

  @override
  ConsumerState<DelegateScreen> createState() => _DelegateScreenState();
}

class _DelegateScreenState extends ConsumerState<DelegateScreen> {
  final _amount = TextEditingController();

  bool get _stake => widget.mode == DelegateMode.stake;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _fill(BigInt pool, int pct, int decimals) {
    final units = pool * BigInt.from(pct) ~/ BigInt.from(100);
    _amount.text = formatBaseUnitsExact(units.toString(), decimals: decimals);
    _amount.selection = TextSelection.collapsed(offset: _amount.text.length);
    ZuniaHaptics.selection();
    setState(() {});
  }

  Future<void> _review({
    required ChainEntry chain,
    required String delegator,
    required BigInt units,
    required String moniker,
    required StakingValidator? validator,
    required StakingParams? params,
  }) async {
    final amount = stakeAmount(units, chain, digits: chain.coinDecimals);
    final period = params?.unbondingTime;
    final periodText = period == null
        ? 'the network\'s unbonding period'
        : describeDuration(period);
    final msgs = _stake
        ? stakeMsgs(
            delegator: delegator,
            validator: widget.operatorAddress,
            denom: chain.coinMinimalDenom,
            amount: units,
          )
        : unstakeMsgs(
            delegator: delegator,
            validator: widget.operatorAddress,
            denom: chain.coinMinimalDenom,
            amount: units,
          );
    final done = await showTxReview(
      context,
      returnTo: widget.returnTo,
      TxIntent(
        title: _stake ? 'Review stake' : 'Review unstake',
        action: _stake ? 'Sign stake' : 'Sign unstake',
        chain: chain,
        signer: delegator,
        msgs: msgs,
        headlineLabel: _stake ? 'You stake' : 'You unstake',
        headline: amount,
        headlineLine:
            '${_stake ? 'With' : 'From'} $moniker · ${chain.chainName}',
        facts: [
          (label: 'Validator', value: moniker),
          if (validator != null)
            (label: 'Commission', value: percent(validator.commission, digits: 2)),
          (label: 'Unbonding period', value: period == null ? 'Unknown' : describeDuration(period)),
        ],
        notice: _stake
            ? 'Staked tokens can be unstaked at any time, but are then locked '
                'for $periodText before you can spend them.'
            : 'For $periodText these tokens earn nothing and cannot be moved '
                'or cancelled. They return to your available balance after.',
        offerNotifications: _stake,
        result: _stake
            ? const TxResultCopy(
                sending: 'Staking',
                done: 'Staked',
                failed: 'Stake failed',
                doneMessage:
                    'Your stake is active and earns rewards from now on.',
              )
            : TxResultCopy(
                sending: 'Unstaking',
                done: 'Unstaking started',
                failed: 'Unstake failed',
                doneMessage: 'The tokens unbond now and are yours to spend '
                    'after $periodText.',
              ),
        onSettled: () {
          refreshStaking(ref, chain.chainId);
          ref.invalidate(balancesProvider);
        },
      ),
    );
    if (done && mounted) _amount.clear();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final chain = catalogChain(widget.chainId);
    final hide = ref.watch(preferencesProvider.select((p) => p.hideAmounts));
    final delegator = ref
        .watch(chainAccountsProvider)
        .where((a) => a.chain.chainId == widget.chainId)
        .firstOrNull
        ?.address;
    if (chain == null || delegator == null) {
      return Scaffold(
        backgroundColor: s.screenMid,
        body: SafeArea(
          child: ZuniaScreenScaffold(
            title: _stake ? 'Stake' : 'Unstake',
            onBack: () => Navigator.of(context).maybePop(),
            body: const ZuniaEmptyState(
              title: 'Network not enabled',
              description: 'Enable this network to stake on it.',
            ),
          ),
        ),
      );
    }

    final validator = ref
        .watch(stakingValidatorProvider(
          (chainId: widget.chainId, operator: widget.operatorAddress),
        ))
        .valueOrNull;
    final position = ref
        .watch(stakingPositionsProvider(widget.chainId))
        .valueOrNull
        ?.where((p) => p.validatorAddress == widget.operatorAddress)
        .firstOrNull;
    final params =
        ref.watch(stakingParamsProvider(widget.chainId)).valueOrNull;
    final moniker =
        validator?.moniker ?? position?.moniker ?? widget.operatorAddress;

    // The pool the amount comes out of: the spendable balance for a stake,
    // the position for an unstake. Null when it was not read: then there is
    // no MAX and no limit, and the simulation catches an overspend.
    BigInt? pool;
    var reserve = BigInt.zero;
    if (_stake) {
      final available = BigInt.tryParse(
        ref.watch(balancesProvider).valueOrNull?[widget.chainId]?.available ??
            '',
      );
      if (available != null) {
        reserve = feeReserveFor(chain);
        pool = available;
      }
    } else {
      pool = position?.amount;
    }
    final spendable = pool == null
        ? null
        : _stake
            ? maxStakeable(pool, reserve)
            : pool;

    final input = parseAmount(_amount.text, decimals: chain.coinDecimals);
    final problem = delegateAmountProblem(
      input: input,
      pool: pool,
      mode: widget.mode,
    );
    final ready = input.isValid && problem == null;
    final units = ready ? BigInt.parse(input.baseUnits) : null;

    return Scaffold(
      backgroundColor: s.screenMid,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: _stake ? 'Stake' : 'Unstake',
          onBack: () => Navigator.of(context).maybePop(),
          footer: ZuniaButton(
            label: ready ? 'Review' : 'Enter an amount',
            size: ZuniaButtonSize.lg,
            onPressed: !ready
                ? null
                : () => _review(
                      chain: chain,
                      delegator: delegator,
                      units: units!,
                      moniker: moniker,
                      validator: validator,
                      params: params,
                    ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
            children: [
              Row(
                children: [
                  CachedValidatorAvatar(
                    chainId: chain.chainId,
                    chainName: chain.chainName,
                    operatorAddress: widget.operatorAddress,
                    identity: validator?.identity ?? position?.identity ?? '',
                    moniker: moniker,
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_stake ? 'With' : 'From'} $moniker',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: s.fg,
                          ),
                        ),
                        Text(
                          validator == null
                              ? chain.chainName
                              : '${percent(validator.commission)} commission · '
                                  '${chain.chainName}',
                          style: zuniaMono(fontSize: 11.5, color: s.fgDim),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Semantics(
                label: 'Amount in ${chain.coinDenom}',
                textField: true,
                child: TextField(
                  controller: _amount,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: const [DecimalDigitFormatter()],
                  textAlign: TextAlign.center,
                  onChanged: (_) => setState(() {}),
                  style: zuniaSans(
                    fontSize: 40,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -1.6,
                    color: s.fg,
                    tabular: const FontFeature.tabularFigures(),
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    hintText: '0',
                    hintStyle: zuniaSans(
                      fontSize: 40,
                      fontWeight: FontWeight.w500,
                      color: s.fgFaint,
                    ),
                    suffixText: chain.coinDenom,
                    suffixStyle: zuniaMono(fontSize: 14, color: s.fgMuted),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                problem ??
                    (spendable == null
                        ? (_stake
                            ? 'Available balance not read yet'
                            : 'Staked amount not read yet')
                        : hide
                            ? '•••• ${_stake ? 'available' : 'staked'}'
                            : '${stakeAmount(spendable, chain, digits: 6)} '
                                '${_stake ? 'available' : 'staked'}'),
                textAlign: TextAlign.center,
                style: zuniaSans(
                  fontSize: 13,
                  color: problem != null ? s.dangerFg : s.fgMuted,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  for (final pct in const [25, 50, 75, 100]) ...[
                    if (pct != 25) const SizedBox(width: 8),
                    Expanded(
                      child: Semantics(
                        button: true,
                        label: pct == 100 ? 'Maximum' : '$pct percent',
                        child: OutlinedButton(
                          onPressed: spendable == null ||
                                  spendable <= BigInt.zero
                              ? null
                              : () => _fill(spendable, pct, chain.coinDecimals),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: s.fg,
                            side: BorderSide(color: s.lineStrong),
                            shape: const StadiumBorder(),
                            minimumSize: const Size(0, 40),
                            padding: EdgeInsets.zero,
                          ),
                          child: Text(
                            pct == 100 ? 'MAX' : '$pct%',
                            style: zuniaMono(fontSize: 12, color: s.fg),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (_stake && reserve > BigInt.zero && pool != null) ...[
                const SizedBox(height: 10),
                Text(
                  'MAX keeps ${stakeAmount(reserve, chain, digits: 6)} for '
                  'network fees.',
                  textAlign: TextAlign.center,
                  style: zuniaSans(fontSize: 12, color: s.fgDim),
                ),
              ],
              const SizedBox(height: 22),
              FactsCard(
                children: [
                  FactRow(
                    label: 'Unbonding period',
                    value: params?.unbondingTime == null
                        ? 'Unknown'
                        : describeDuration(params!.unbondingTime!),
                  ),
                  if (position != null && _stake)
                    FactRow(
                      label: 'Already staked here',
                      value: hide
                          ? '••••'
                          : stakeAmount(position.amount, chain, digits: 6),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              ZuniaCallout(
                tone: _stake ? ZuniaCalloutTone.info : ZuniaCalloutTone.warning,
                body: _stake
                    ? 'Rewards start with the next block. Unstaking later '
                        'locks the tokens for the unbonding period.'
                    : 'Unstaked tokens stop earning at once and stay locked '
                        'for the unbonding period. An unstake cannot be '
                        'cancelled.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
