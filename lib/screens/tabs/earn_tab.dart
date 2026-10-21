import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/preferences_screen.dart';
import 'package:zunia_mobile/screens/validator_detail_screen.dart';
import 'package:zunia_mobile/screens/validator_list_screen.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/staking_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/staking.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/ui/facts.dart';
import 'package:zunia_mobile/ui/network_sheet.dart';
import 'package:zunia_mobile/ui/tx_flow.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_mobile/widgets/validator_avatar.dart';
import 'package:zunia_mobile/widgets/wallet_header.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Amount of [base] units on [chain], up to [digits] decimals.
String stakeAmount(BigInt base, ChainEntry chain, {int digits = 4}) =>
    '${formatBaseUnitsExact(base.toString(), decimals: chain.coinDecimals, maxFractionDigits: digits)} '
    '${chain.coinDenom}';

/// "3 days left", "less than a day", "ready".
String timeLeft(DateTime? at, {DateTime? now}) {
  if (at == null) return 'pending';
  final ms = at.difference(now ?? DateTime.now()).inMilliseconds;
  if (ms <= 0) return 'complete';
  final days = (ms / 86400000).ceil();
  return days > 1 ? '$days days left' : 'less than a day left';
}

String percent(double share, {int digits = 1}) =>
    '${(share * 100).toStringAsFixed(digits)}%';

/// Staking for one network at a time: what you have staked and can claim,
/// what is unbonding and when it lands, and the way in to stake more.
class EarnTab extends ConsumerStatefulWidget {
  const EarnTab({super.key});

  @override
  ConsumerState<EarnTab> createState() => _EarnTabState();
}

enum _EarnView { stake, unbonding }

class _EarnTabState extends ConsumerState<EarnTab> {
  String? _chainId;
  _EarnView _view = _EarnView.stake;

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _pickChain(List<ChainEntry> chains, String current) async {
    final picked = await pickNetwork(
      context,
      chains: chains,
      selected: current,
      title: 'Staking network',
    );
    if (picked != null && picked != allNetworks && mounted) {
      setState(() => _chainId = picked);
    }
  }

  Future<void> _refresh(String chainId) async {
    refreshStaking(ref, chainId);
    ref.invalidate(stakingAprProvider(chainId));
    ref.invalidate(balancesProvider);
    try {
      await ref.read(stakingPositionsProvider(chainId).future);
    } on Object {
      // The list shows the error itself.
    }
  }

  Future<void> _claimAll(ChainAccount account, List<StakingPosition> rows) async {
    final chain = account.chain;
    final batches = claimMsgBatches(delegator: account.address, positions: rows);
    if (batches.isEmpty) return;
    final first = batches.first;
    final claimed = rows
        .where((p) => (p.rewards ?? BigInt.zero) > BigInt.zero)
        .toList()
      ..sort((a, b) => b.rewards!.compareTo(a.rewards!));
    final included = claimed.take(first.length).toList();
    var total = BigInt.zero;
    for (final p in included) {
      total += p.rewards!;
    }
    final sameDenom = chain.feeMinimalDenom.isEmpty ||
        chain.feeMinimalDenom == chain.coinMinimalDenom;
    await showTxReview(
      context,
      TxIntent(
        title: 'Claim rewards',
        action: 'Sign claim',
        chain: chain,
        signer: account.address,
        msgs: first,
        headlineLabel: 'You claim',
        headline: '≈ ${stakeAmount(total, chain, digits: 6)}',
        headlineLine: included.length == 1
            ? 'From ${included.first.moniker} · ${chain.chainName}'
            : 'From ${included.length} validators · ${chain.chainName}',
        facts: [
          for (final p in included)
            (label: p.moniker, value: stakeAmount(p.rewards!, chain, digits: 6)),
        ],
        notice: batches.length > 1
            ? 'This claims from the ${first.length} validators with the most '
                'rewards. Claim again for the other '
                '${claimed.length - first.length}: one transaction holding '
                'them all could run past the network\'s gas limit.'
            : null,
        gainBaseUnits: sameDenom ? total : null,
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
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);

    Widget shell(Widget child) => ZuniaBackdrop(
      child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              WalletHeader(
                onOpenNetworks: () => _open(const NetworksScreen()),
              ),
              Expanded(child: child),
            ],
          ),
        );

    if (accounts.isEmpty) {
      return shell(
        Center(
          child: ZuniaEmptyState(
            title: 'No networks enabled',
            description: 'Enable a network to stake on it.',
            action: ZuniaButton(
              label: 'Manage networks',
              variant: ZuniaButtonVariant.secondary,
              onPressed: () => _open(const NetworksScreen()),
            ),
          ),
        ),
      );
    }

    final account = accounts.firstWhere(
      (a) => a.chain.chainId == _chainId,
      orElse: () => accounts.first,
    );
    final chain = account.chain;
    final chainId = chain.chainId;
    final live = prefs.liveReads;
    final positions =
        live ? ref.watch(stakingPositionsProvider(chainId)) : null;
    final rows = positions?.valueOrNull ?? const <StakingPosition>[];

    var staked = BigInt.zero;
    for (final p in rows) {
      staked += p.amount;
    }
    final claimable = claimableTotal(rows);
    final canClaim = rows.any((p) => (p.rewards ?? BigInt.zero) > BigInt.zero);

    final elsewhere = <(ChainEntry, BigInt)>[];
    if (live) {
      final balances = ref.watch(balancesProvider).valueOrNull ?? const {};
      for (final a in accounts) {
        if (a.chain.chainId == chainId) continue;
        final amount = BigInt.tryParse(balances[a.chain.chainId]?.staked ?? '');
        if (amount != null && amount > BigInt.zero) {
          elsewhere.add((a.chain, amount));
        }
      }
    }

    return shell(
      ZuniaRefresh(
        onRefresh: () => _refresh(chainId),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          'Earn',
                          style: zuniaSans(
                            fontSize: 28,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.8,
                            color: s.fg,
                          ),
                        ),
                      ),
                    ),
                    Flexible(
                      child: NetworkChipButton(
                        chain: chain,
                        onTap: () => _pickChain(
                          [for (final a in accounts) a.chain],
                          chainId,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              sliver: SliverToBoxAdapter(
                child: _Hero(
                  chain: chain,
                  live: live,
                  loading: positions?.isLoading ?? false,
                  staked: positions?.hasValue ?? false ? staked : null,
                  claimable: positions?.hasValue ?? false ? claimable : null,
                  hide: prefs.hideAmounts,
                  canClaim: canClaim,
                  onClaim: () => _claimAll(account, rows),
                  onStake: () =>
                      _open(ValidatorListScreen(chainId: chainId)),
                ),
              ),
            ),
            if (!live)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: _ReadsOff(
                    onOpen: () => _open(const PreferencesScreen()),
                  ),
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
                sliver: SliverToBoxAdapter(
                  child: ZuniaSegmented<_EarnView>(
                    value: _view,
                    onChanged: (v) => setState(() => _view = v),
                    options: const {
                      _EarnView.stake: 'My stake',
                      _EarnView.unbonding: 'Unbonding',
                    },
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: _view == _EarnView.stake
                      ? _Positions(
                          chain: chain,
                          value: positions!,
                          hide: prefs.hideAmounts,
                          onOpen: (p) => _open(
                            ValidatorDetailScreen(
                              chainId: chainId,
                              operatorAddress: p.validatorAddress,
                            ),
                          ),
                          onRetry: () => _refresh(chainId),
                        )
                      : _Unbonding(chain: chain, hide: prefs.hideAmounts),
                ),
              ),
              if (elsewhere.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionCaption('Staked on other networks'),
                        for (final (other, amount) in elsewhere)
                          _Row(
                            leading: ChainAvatar(chain: other, size: 32),
                            title: other.chainName,
                            subtitle: other.chainId,
                            trailing: prefs.mask(stakeAmount(amount, other, digits: 2)),
                            onTap: () =>
                                setState(() => _chainId = other.chainId),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
            const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
          ],
        ),
      ),
    );
  }
}

class _Hero extends ConsumerWidget {
  const _Hero({
    required this.chain,
    required this.live,
    required this.loading,
    required this.staked,
    required this.claimable,
    required this.hide,
    required this.canClaim,
    required this.onClaim,
    required this.onStake,
  });

  final ChainEntry chain;
  final bool live;
  final bool loading;

  /// Null when not read.
  final BigInt? staked;
  final BigInt? claimable;
  final bool hide;
  final bool canClaim;
  final VoidCallback onClaim;
  final VoidCallback onStake;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final apr = live ? ref.watch(stakingAprProvider(chain.chainId)) : null;
    String show(BigInt? v, {int digits = 2}) {
      if (hide) return '••••';
      if (v == null) return '—';
      return formatBaseUnitsExact(
        v.toString(),
        decimals: chain.coinDecimals,
        maxFractionDigits: digits,
      );
    }

    final estimate = apr?.valueOrNull;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [s.accent.withValues(alpha: 0.22), s.surface],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: s.lineStrong),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: MergeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'STAKED',
                          style: zuniaMono(
                            fontSize: 10.5,
                            letterSpacing: 1.4,
                            color: s.fgDim,
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (loading && staked == null && !hide)
                          const ZuniaSkeleton(width: 120, height: 26)
                        else
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: show(staked),
                                  style: zuniaSans(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: -1,
                                    color: s.fg,
                                    tabular: const FontFeature.tabularFigures(),
                                  ),
                                ),
                                if (!hide && staked != null)
                                  TextSpan(
                                    text: '  ${chain.coinDenom}',
                                    style: zuniaMono(
                                      fontSize: 12,
                                      color: s.fgMuted,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (estimate != null)
                  _AprBadge(chain: chain, estimate: estimate),
              ],
            ),
            const SizedBox(height: 14),
            Divider(height: 1, color: s.line),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: MergeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Claimable',
                          style: zuniaSans(fontSize: 12.5, color: s.fgMuted),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${show(claimable, digits: 6)}'
                          '${!hide && claimable != null ? ' ${chain.coinDenom}' : ''}',
                          overflow: TextOverflow.ellipsis,
                          style: zuniaMono(fontSize: 13, color: s.fg),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ZuniaButton(
                  label: 'Claim all',
                  size: ZuniaButtonSize.sm,
                  variant: ZuniaButtonVariant.secondary,
                  onPressed: live && canClaim ? onClaim : null,
                ),
              ],
            ),
            const SizedBox(height: 14),
            ZuniaButton(
              label: 'Stake',
              size: ZuniaButtonSize.lg,
              leading: const Icon(Icons.add),
              onPressed: onStake,
            ),
          ],
        ),
      ),
    );
  }
}

class _AprBadge extends StatelessWidget {
  const _AprBadge({required this.chain, required this.estimate});

  final ChainEntry chain;
  final AprEstimate estimate;

  void _explain(BuildContext context) {
    showZuniaSheet<void>(
      context,
      title: 'Estimated APR',
      builder: (ctx) => SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Worked out from ${chain.chainName}\'s own parameters: '
              'inflation × (1 − community tax) ÷ share of tokens staked. '
              'It is before your validator\'s commission, leaves out fees, '
              'and assumes the chain keeps its configured block rate, so '
              'what you earn can differ.',
              style: zuniaSans(
                fontSize: 14,
                height: 1.5,
                color: ZuniaSemanticsExt.of(ctx).fgMuted,
              ),
            ),
            const SizedBox(height: 14),
            FactsCard(
              children: [
                FactRow(label: 'Inflation', value: percent(estimate.inflation, digits: 2)),
                FactRow(
                  label: 'Community tax',
                  value: percent(estimate.communityTax, digits: 2),
                ),
                FactRow(
                  label: 'Staked share',
                  value: percent(estimate.bondedRatio, digits: 2),
                ),
                FactRow(
                  label: 'Estimated APR',
                  value: percent(estimate.apr, digits: 2),
                  emphasis: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      button: true,
      label: 'Estimated APR ${percent(estimate.apr)}. How it is worked out',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _explain(context),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'EST. APR',
                      style: zuniaMono(
                        fontSize: 10.5,
                        letterSpacing: 1.4,
                        color: s.fgDim,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.info_outline, size: 13, color: s.fgDim),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  percent(estimate.apr),
                  style: zuniaSans(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    color: s.accent,
                    tabular: const FontFeature.tabularFigures(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadsOff extends StatelessWidget {
  const _ReadsOff({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ZuniaCallout(
          title: 'Live reads are off',
          body: 'Your stake, rewards and validators come from each network\'s '
              'public endpoint. Turn live reads on in Preferences to load them.',
        ),
        const SizedBox(height: 10),
        ZuniaButton(
          label: 'Open Preferences',
          variant: ZuniaButtonVariant.secondary,
          onPressed: onOpen,
        ),
      ],
    );
  }
}

class _Positions extends StatelessWidget {
  const _Positions({
    required this.chain,
    required this.value,
    required this.hide,
    required this.onOpen,
    required this.onRetry,
  });

  final ChainEntry chain;
  final AsyncValue<List<StakingPosition>> value;
  final bool hide;
  final ValueChanged<StakingPosition> onOpen;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnRefresh: true,
      loading: () => const ListSkeleton(rows: 3, label: 'Loading your stake'),
      error: (e, _) => _ReadFailed(error: e, onRetry: onRetry),
      data: (rows) {
        final held = rows.where((p) => p.amount > BigInt.zero).toList();
        if (held.isEmpty) {
          return ZuniaEmptyState(
            title: 'Nothing staked on ${chain.chainName}',
            description:
                'Tap Stake to pick a validator and start earning rewards.',
          );
        }
        return Column(
          children: [
            for (final p in held)
              _Row(
                leading: CachedValidatorAvatar(
                  chainId: chain.chainId,
                  chainName: chain.chainName,
                  operatorAddress: p.validatorAddress,
                  identity: p.identity,
                  moniker: p.moniker,
                  size: 36,
                ),
                title: p.moniker,
                badge: _bondBadge(p.bondState),
                subtitle: p.rewards == null
                    ? 'rewards unknown'
                    : hide
                        ? 'rewards ••••'
                        : '+${stakeAmount(p.rewards!, chain, digits: 4)} rewards',
                trailing: hide ? '••••' : stakeAmount(p.amount, chain, digits: 2),
                onTap: () => onOpen(p),
              ),
          ],
        );
      },
    );
  }
}

String? _bondBadge(ValidatorBondState state) => switch (state) {
      ValidatorBondState.active => null,
      ValidatorBondState.inactive => 'Inactive',
      ValidatorBondState.jailed => 'Jailed',
    };

class _Unbonding extends ConsumerWidget {
  const _Unbonding({required this.chain, required this.hide});

  final ChainEntry chain;
  final bool hide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(stakingUnbondingProvider(chain.chainId));
    final params = ref.watch(stakingParamsProvider(chain.chainId)).valueOrNull;
    return value.when(
      skipLoadingOnRefresh: true,
      loading: () => const ListSkeleton(rows: 2, label: 'Loading unbonding'),
      error: (e, _) => _ReadFailed(
        error: e,
        onRetry: () => ref.invalidate(stakingUnbondingProvider(chain.chainId)),
      ),
      data: (rows) {
        if (rows.isEmpty) {
          final period = params?.unbondingTime;
          return ZuniaEmptyState(
            title: 'Nothing unbonding',
            description: period == null
                ? 'Unstaked tokens show here until the network releases them.'
                : 'Unstaked tokens show here for ${describeDuration(period)} '
                    'until ${chain.chainName} releases them.',
          );
        }
        return Column(
          children: [
            for (final u in rows)
              _Row(
                leading: CachedValidatorAvatar(
                  chainId: chain.chainId,
                  chainName: chain.chainName,
                  operatorAddress: u.validatorAddress,
                  moniker: u.moniker,
                  size: 36,
                ),
                title: u.moniker,
                subtitle: u.completionTime == null
                    ? 'release date unknown'
                    : '${timeLeft(u.completionTime)} · '
                        '${MaterialLocalizations.of(context).formatMediumDate(u.completionTime!.toLocal())}',
                trailing: hide ? '••••' : stakeAmount(u.amount, chain, digits: 2),
                muted: true,
              ),
          ],
        );
      },
    );
  }
}

class _ReadFailed extends StatelessWidget {
  const _ReadFailed({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is ChainReadError
        ? (error as ChainReadError).userMessage
        : 'This network\'s endpoint did not answer.';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: ZuniaEmptyState(
        title: 'Could not load',
        description: message,
        action: ZuniaButton(
          label: 'Try again',
          variant: ZuniaButtonVariant.secondary,
          size: ZuniaButtonSize.sm,
          onPressed: onRetry,
        ),
      ),
    );
  }
}

/// One list row: avatar, name with an optional badge, a mono subtitle, and a
/// mono amount on the right that keeps its width while the name ellipsises.
class _Row extends StatelessWidget {
  const _Row({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.badge,
    this.onTap,
    this.muted = false,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final String trailing;
  final String? badge;
  final VoidCallback? onTap;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return MergeSemantics(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: zuniaSans(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: s.fg,
                            ),
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: 6),
                          _Badge(label: badge!),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaMono(fontSize: 11.5, color: s.fgDim),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.42,
                ),
                child: Text(
                  trailing,
                  textAlign: TextAlign.end,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: zuniaMono(
                    fontSize: 13,
                    color: muted ? s.fgMuted : s.fg,
                  ),
                ),
              ),
              if (onTap != null && ZuniaPlatform.isCupertino(context)) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 18, color: s.fgFaint),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final danger = label == 'Jailed';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: danger ? s.dangerLine : s.warningLine),
      ),
      child: Text(
        label.toUpperCase(),
        style: zuniaMono(
          fontSize: 9,
          letterSpacing: 0.8,
          color: danger ? s.danger : s.warning,
        ),
      ),
    );
  }
}

/// Shared by the validator list and detail screens.
class StakingBadge extends StatelessWidget {
  const StakingBadge(this.state, {super.key});

  final ValidatorBondState state;

  @override
  Widget build(BuildContext context) {
    final label = _bondBadge(state);
    return label == null ? const SizedBox.shrink() : _Badge(label: label);
  }
}
