import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/delegate_screen.dart';
import 'package:zunia_mobile/screens/tabs/earn_tab.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
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

/// One validator: its terms, and the user's position with it when there is
/// one (staked, rewards, Claim, Unstake, Stake more).
class ValidatorDetailScreen extends ConsumerWidget {
  const ValidatorDetailScreen({
    super.key,
    required this.chainId,
    required this.operatorAddress,
  });

  final String chainId;
  final String operatorAddress;

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _claim(
    BuildContext context,
    WidgetRef ref,
    ChainEntry chain,
    String delegator,
    StakingPosition position,
    String moniker,
  ) async {
    final rewards = position.rewards ?? BigInt.zero;
    final sameDenom = chain.feeMinimalDenom.isEmpty ||
        chain.feeMinimalDenom == chain.coinMinimalDenom;
    await showTxReview(
      context,
      TxIntent(
        title: 'Claim rewards',
        action: 'Sign claim',
        chain: chain,
        signer: delegator,
        msgs: claimMsgBatches(delegator: delegator, positions: [position]).first,
        headlineLabel: 'You claim',
        headline: '≈ ${stakeAmount(rewards, chain, digits: 6)}',
        headlineLine: 'From $moniker · ${chain.chainName}',
        gainBaseUnits: sameDenom ? rewards : null,
        offerNotifications: true,
        result: const TxResultCopy(
          sending: 'Claiming rewards',
          done: 'Rewards claimed',
          failed: 'Claim failed',
          doneMessage: 'The rewards are in your available balance.',
        ),
        onSettled: () {
          refreshStaking(ref, chain.chainId);
          ref.invalidate(balancesProvider);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final chain = catalogChain(chainId);
    final hide = ref.watch(preferencesProvider.select((p) => p.hideAmounts));
    final live = ref.watch(preferencesProvider.select((p) => p.liveReads));
    final key = (chainId: chainId, operator: operatorAddress);
    final validator = live ? ref.watch(stakingValidatorProvider(key)) : null;
    final positions =
        live ? ref.watch(stakingPositionsProvider(chainId)).valueOrNull : null;
    final position = positions
        ?.where((p) => p.validatorAddress == operatorAddress)
        .firstOrNull;
    final apr = live ? ref.watch(stakingAprProvider(chainId)).valueOrNull : null;
    final delegator = ref
        .watch(chainAccountsProvider)
        .where((a) => a.chain.chainId == chainId)
        .firstOrNull
        ?.address;

    final v = validator?.valueOrNull;
    final moniker = v?.moniker ?? position?.moniker ?? operatorAddress;
    final held = position != null && position.amount > BigInt.zero;
    final jailed = v?.jailed ?? position?.jailed ?? false;

    if (chain == null) {
      return const Scaffold(body: Center(child: Text('Unknown network')));
    }

    return Scaffold(
      backgroundColor: s.screenMid,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: moniker,
          onBack: () => Navigator.of(context).maybePop(),
          footer: delegator == null
              ? null
              : ZuniaButton(
                  label: jailed
                      ? 'Jailed validators cannot be staked to'
                      : held
                          ? 'Stake more'
                          : 'Stake with $moniker',
                  size: ZuniaButtonSize.lg,
                  onPressed: jailed || !live
                      ? null
                      : () => _open(
                            context,
                            DelegateScreen(
                              chainId: chainId,
                              operatorAddress: operatorAddress,
                              mode: DelegateMode.stake,
                              returnTo: ModalRoute.of(context),
                            ),
                          ),
                ),
          body: RefreshIndicator.adaptive(
            onRefresh: () async {
              refreshStaking(ref, chainId);
              ref.invalidate(stakingValidatorProvider(key));
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
              children: [
                Row(
                  children: [
                    CachedValidatorAvatar(
                      chainId: chainId,
                      chainName: chain.chainName,
                      operatorAddress: operatorAddress,
                      identity: v?.identity ?? position?.identity ?? '',
                      moniker: moniker,
                      size: 56,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            moniker,
                            style: zuniaSans(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.4,
                              color: s.fg,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              if (v != null) ...[
                                StakingBadge(v.bondState),
                                if (v.bondState != ValidatorBondState.active)
                                  const SizedBox(width: 6),
                              ],
                              Flexible(
                                child: Text(
                                  chain.chainName,
                                  overflow: TextOverflow.ellipsis,
                                  style: zuniaSans(
                                    fontSize: 13,
                                    color: s.fgMuted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _CopyOperator(address: operatorAddress),
                if (!live) ...[
                  const SizedBox(height: 12),
                  const ZuniaCallout(
                    title: 'Live reads are off',
                    body: 'Turn live reads on in Preferences to load this '
                        'validator and your stake with it.',
                  ),
                ],
                if (held && delegator != null) ...[
                  const SectionCaption('Your stake'),
                  _PositionCard(
                    chain: chain,
                    position: position,
                    hide: hide,
                    onClaim: () => _claim(
                      context,
                      ref,
                      chain,
                      delegator,
                      position,
                      moniker,
                    ),
                    onUnstake: () => _open(
                      context,
                      DelegateScreen(
                        chainId: chainId,
                        operatorAddress: operatorAddress,
                        mode: DelegateMode.unstake,
                        returnTo: ModalRoute.of(context),
                      ),
                    ),
                  ),
                ],
                const SectionCaption('Validator'),
                if (validator != null && validator.isLoading && v == null)
                  const ListSkeleton(rows: 3, label: 'Loading validator')
                else if (validator != null && validator.hasError && v == null)
                  ZuniaCallout(
                    tone: ZuniaCalloutTone.warning,
                    body: validator.error is ChainReadError
                        ? (validator.error as ChainReadError).userMessage
                        : 'This validator could not be loaded.',
                  )
                else if (v != null)
                  _ValidatorFacts(chain: chain, validator: v, apr: apr),
                if (v != null && v.details.isNotEmpty) ...[
                  const SectionCaption('About'),
                  Text(
                    v.details,
                    style: zuniaSans(
                      fontSize: 14,
                      height: 1.5,
                      color: s.fgMuted,
                    ),
                  ),
                ],
                if (v != null && v.jailed) ...[
                  const SizedBox(height: 16),
                  const ZuniaCallout(
                    tone: ZuniaCalloutTone.danger,
                    title: 'Jailed',
                    body: 'This validator was removed from the active set for '
                        'misbehaving or going offline. Stake with it earns no '
                        'rewards until it is unjailed.',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PositionCard extends StatelessWidget {
  const _PositionCard({
    required this.chain,
    required this.position,
    required this.hide,
    required this.onClaim,
    required this.onUnstake,
  });

  final ChainEntry chain;
  final StakingPosition position;
  final bool hide;
  final VoidCallback onClaim;
  final VoidCallback onUnstake;

  @override
  Widget build(BuildContext context) {
    final rewards = position.rewards;
    final canClaim = rewards != null && rewards > BigInt.zero;
    return FactsCard(
      children: [
        FactRow(
          label: 'Staked',
          value: hide ? '••••' : stakeAmount(position.amount, chain, digits: 6),
          emphasis: true,
        ),
        FactRow(
          label: 'Rewards',
          value: rewards == null
              ? 'Unknown'
              : hide
                  ? '••••'
                  : stakeAmount(rewards, chain, digits: 6),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ZuniaButton(
                label: 'Unstake',
                variant: ZuniaButtonVariant.secondary,
                onPressed: onUnstake,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ZuniaButton(
                label: canClaim ? 'Claim' : 'No rewards yet',
                variant: ZuniaButtonVariant.secondary,
                onPressed: canClaim ? onClaim : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
      ],
    );
  }
}

class _ValidatorFacts extends StatelessWidget {
  const _ValidatorFacts({
    required this.chain,
    required this.validator,
    required this.apr,
  });

  final ChainEntry chain;
  final StakingValidator validator;
  final AprEstimate? apr;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final v = validator;
    final website = v.websiteUri;
    return FactsCard(
      children: [
        FactRow(label: 'Commission', value: percent(v.commission, digits: 2)),
        if (v.maxCommission > 0)
          FactRow(
            label: 'Max commission',
            value: percent(v.maxCommission, digits: 2),
          ),
        if (v.votingPower > 0)
          FactRow(label: 'Voting power', value: percent(v.votingPower, digits: 2)),
        FactRow(
          label: 'Bonded',
          value: '${formatBaseUnits(v.tokens.toString(), decimals: chain.coinDecimals)} '
              '${chain.coinDenom}',
        ),
        if (v.minSelfDelegation > BigInt.one)
          FactRow(
            label: 'Min self-stake',
            value: stakeAmount(v.minSelfDelegation, chain, digits: 2),
          ),
        if (apr != null && !v.jailed)
          FactRow(
            label: 'Est. APR after commission',
            value: '≈ ${percent(apr!.afterCommission(v.commission))}',
          ),
        if (website != null)
          FactRow(
            label: 'Website',
            value: website.host,
            valueWidget: Semantics(
              link: true,
              label: 'Website ${website.host}',
              child: InkWell(
                onTap: () async {
                  final go = await showZuniaConfirm(
                    context,
                    title: 'Open ${website.host}?',
                    message: 'The validator wrote this address themselves.',
                    confirmLabel: 'Open',
                  );
                  if (go) {
                    await launchUrl(
                      website,
                      mode: LaunchMode.externalApplication,
                    );
                  }
                },
                child: Text(
                  website.host.replaceFirst(RegExp(r'^www\.'), ''),
                  style: zuniaMono(fontSize: 12.5, color: s.accent),
                ),
              ),
            ),
          ),
        FactRow(label: 'Status', value: switch (v.bondState) {
          ValidatorBondState.active => 'Active',
          ValidatorBondState.inactive => 'Not in the active set',
          ValidatorBondState.jailed => 'Jailed',
        }),
      ],
    );
  }
}

class _CopyOperator extends StatelessWidget {
  const _CopyOperator({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      button: true,
      label: 'Copy operator address',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: address));
          unawaited(ZuniaHaptics.selection());
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Operator address copied')),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  address,
                  style: zuniaMono(fontSize: 11.5, color: s.fgDim),
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.copy_rounded, size: 16, color: s.fgMuted),
            ],
          ),
        ),
      ),
    );
  }
}
