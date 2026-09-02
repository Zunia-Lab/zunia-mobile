import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/delegate_screen.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/rewards_screen.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/chain_picker.dart';
import 'package:zunia_mobile/widgets/wallet_header.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Staking for one chain at a time: validators to join, positions you hold and
/// unbonding still in flight.
class EarnTab extends ConsumerStatefulWidget {
  const EarnTab({super.key});

  @override
  ConsumerState<EarnTab> createState() => _EarnTabState();
}

class _EarnTabState extends ConsumerState<EarnTab> {
  String? _chainId;
  String _tab = 'validators';

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    if (accounts.isEmpty) {
      return DecoratedBox(
        decoration: BoxDecoration(gradient: s.screenGradient),
        child: Column(
          children: [
            WalletHeader(
              onOpenNetworks: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NetworksScreen()),
              ),
            ),
            const Expanded(
              child: Center(
                child: ZuniaEmptyState(
                  title: 'No networks enabled',
                  description: 'Enable a chain to browse its validators.',
                ),
              ),
            ),
          ],
        ),
      );
    }

    final chainId = accounts.any((a) => a.chain.chainId == _chainId)
        ? _chainId!
        : accounts.first.chain.chainId;
    final chain = accounts
        .firstWhere((a) => a.chain.chainId == chainId)
        .chain;
    final delegations = ref.watch(delegationsProvider(chainId));

    var staked = BigInt.zero;
    var claimable = BigInt.zero;
    for (final row in delegations.valueOrNull ?? const []) {
      staked += BigInt.tryParse(row.amount) ?? BigInt.zero;
      claimable += BigInt.tryParse(row.rewards) ?? BigInt.zero;
    }

    final stakedLabel = prefs.mask(
      formatBaseUnits(staked.toString(), decimals: chain.coinDecimals),
    );
    final claimableLabel = prefs.mask(
      formatBaseUnits(claimable.toString(), decimals: chain.coinDecimals),
    );

    return DecoratedBox(
      decoration: BoxDecoration(gradient: s.screenGradient),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WalletHeader(
            onOpenNetworks: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NetworksScreen()),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
              children: [
                Row(
                  children: [
                    Text(
                      'Earn',
                      style: zuniaSans(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.3,
                        color: s.fg,
                      ),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 160,
                      child: ChainPicker(
                        value: chainId,
                        onChanged: (v) => setState(() => _chainId = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        s.accent.withValues(alpha: 0.28),
                        s.glass,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: s.info.withValues(alpha: 0.4)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                    child: Column(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _Metric(
                                label: 'STAKED',
                                value: stakedLabel,
                                denom: chain.coinDenom,
                              ),
                            ),
                            const _Metric(
                              label: 'APR',
                              value: '—',
                              accent: true,
                              alignEnd: true,
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Container(height: 1, color: s.line),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Text(
                              'Claimable',
                              style: zuniaMono(fontSize: 11, color: s.fgMuted),
                            ),
                            const Spacer(),
                            Text(
                              '$claimableLabel ${chain.coinDenom}',
                              style: zuniaMono(fontSize: 11, color: s.info),
                            ),
                            const SizedBox(width: 10),
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const RewardsScreen(),
                                  ),
                                ),
                                borderRadius: BorderRadius.circular(999),
                                child: Ink(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: s.info.withValues(alpha: 0.5),
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 7,
                                    ),
                                    child: Text(
                                      'Claim',
                                      style: zuniaMono(
                                        fontSize: 11,
                                        color: s.info,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    for (final entry in const [
                      ('validators', 'Validators'),
                      ('positions', 'My stake'),
                      ('unbonding', 'Unbonding'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 18),
                        child: GestureDetector(
                          onTap: () => setState(() => _tab = entry.$1),
                          child: Container(
                            padding: const EdgeInsets.only(bottom: 10),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  width: 1.5,
                                  color: _tab == entry.$1
                                      ? s.fg
                                      : Colors.transparent,
                                ),
                              ),
                            ),
                            child: Text(
                              entry.$2,
                              style: zuniaSans(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: _tab == entry.$1 ? s.fg : s.fgDim,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (!prefs.liveReads)
                  const ZuniaCallout(
                    tone: ZuniaCalloutTone.info,
                    title: 'Live reads are off',
                    body:
                        'Turn on live reads in Settings to load validators and '
                        'delegations from public endpoints.',
                  )
                else
                  ..._body(chainId, chain.coinDecimals, prefs),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _body(String chainId, int decimals, AppPreferences prefs) {
    switch (_tab) {
      case 'positions':
        return [
          ref.watch(delegationsProvider(chainId)).when(
                data: (rows) => rows.isEmpty
                    ? const ZuniaEmptyState(
                        title: 'No delegations',
                        description:
                            'Pick a validator to start earning on this chain.',
                      )
                    : Column(
                        children: [
                          for (final row in rows)
                            _Row(
                              title: row.moniker,
                              meta: 'rewards '
                                  '${formatBaseUnits(row.rewards, decimals: decimals)}',
                              trailing: prefs.mask(
                                formatBaseUnits(
                                  row.amount,
                                  decimals: decimals,
                                ),
                              ),
                            ),
                        ],
                      ),
                loading: () => const _Loading(),
                error: (_, _) => const _Unavailable(),
              ),
        ];

      case 'unbonding':
        return [
          ref.watch(unbondingProvider(chainId)).when(
                data: (rows) => rows.isEmpty
                    ? const ZuniaEmptyState(
                        title: 'Nothing unbonding',
                        description:
                            'Undelegated stake in its cooldown window appears '
                            'here with its release date.',
                      )
                    : Column(
                        children: [
                          for (final row in rows)
                            _Row(
                              title: row.validatorAddress,
                              meta: row.completionTime == null
                                  ? 'pending'
                                  : 'releases '
                                      '${row.completionTime!.toLocal().toString().split(' ').first}',
                              trailing: prefs.mask(
                                formatBaseUnits(
                                  row.amount,
                                  decimals: decimals,
                                ),
                              ),
                            ),
                        ],
                      ),
                loading: () => const _Loading(),
                error: (_, _) => const _Unavailable(),
              ),
        ];

      default:
        return [
          ref.watch(validatorsProvider(chainId)).when(
                data: (rows) => rows.isEmpty
                    ? const ZuniaEmptyState(
                        title: 'No validators returned',
                        description:
                            'The public endpoint for this chain did not list a '
                            'bonded validator set.',
                      )
                    : Column(
                        children: [
                          for (final row in rows.take(40))
                            _Row(
                              title: row.moniker,
                              meta: row.jailed
                                  ? 'jailed'
                                  : '${(row.commission * 100).toStringAsFixed(1)}% '
                                      'comm · '
                                      '${(row.votingPower * 100).toStringAsFixed(2)}% power',
                              metaWarn: row.jailed,
                              trailing: row.jailed ? '—' : 'STAKE',
                              trailingAccent: !row.jailed,
                              onTap: row.jailed
                                  ? null
                                  : () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => DelegateScreen(
                                            chainId: chainId,
                                            moniker: row.moniker,
                                            operatorAddress:
                                                row.operatorAddress,
                                          ),
                                        ),
                                      ),
                            ),
                        ],
                      ),
                loading: () => const _Loading(),
                error: (_, _) => const _Unavailable(),
              ),
        ];
    }
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.denom,
    this.accent = false,
    this.alignEnd = false,
  });

  final String label;
  final String value;
  final String? denom;
  final bool accent;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Column(
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: zuniaMono(fontSize: 10, letterSpacing: 1.6, color: s.fgMuted),
        ),
        const SizedBox(height: 9),
        Text(
          value,
          style: zuniaSans(
            fontSize: accent ? 20 : 24,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.7,
            color: accent ? s.info : s.fg,
            tabular: FontFeature.tabularFigures(),
          ),
        ),
        if (denom != null) ...[
          const SizedBox(height: 4),
          Text(
            denom!,
            style: zuniaMono(fontSize: 11, color: s.fgMuted),
          ),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.title,
    required this.meta,
    required this.trailing,
    this.trailingAccent = false,
    this.metaWarn = false,
    this.onTap,
  });

  final String title;
  final String meta;
  final String trailing;
  final bool trailingAccent;
  final bool metaWarn;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final initials = title.trim().isEmpty
        ? '?'
        : title
            .trim()
            .split(RegExp(r'\s+'))
            .take(2)
            .map((w) => w.characters.first.toUpperCase())
            .join();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: s.glass,
                ),
                child: Text(
                  initials,
                  style: zuniaMono(fontSize: 10, color: s.fgMuted),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: s.fg,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      meta,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaMono(
                        fontSize: 10,
                        color: metaWarn ? s.warning : s.fgMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                trailing,
                style: zuniaMono(
                  fontSize: 12.5,
                  color: trailingAccent ? s.info : s.fgMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          ZuniaSkeleton(),
          SizedBox(height: 12),
          ZuniaSkeleton(),
          SizedBox(height: 12),
          ZuniaSkeleton(),
        ],
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) {
    return const ZuniaEmptyState(
      title: 'Endpoint unavailable',
      description:
          'The public endpoint for this chain did not answer. Try again later.',
    );
  }
}
