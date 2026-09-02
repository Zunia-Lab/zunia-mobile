import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/receive_screen.dart';
import 'package:zunia_mobile/screens/send_screen.dart';
import 'package:zunia_mobile/security/clipboard_guard.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Everything this wallet holds and can do on one chain: balance breakdown,
/// send, receive, stake positions and recent transfers.
class ChainDetailScreen extends ConsumerStatefulWidget {
  const ChainDetailScreen({
    super.key,
    required this.chainId,
    this.initialTab = 'overview',
  });

  final String chainId;
  final String initialTab;

  @override
  ConsumerState<ChainDetailScreen> createState() => _ChainDetailScreenState();
}

class _ChainDetailScreenState extends ConsumerState<ChainDetailScreen> {
  late String _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final account = accounts
        .where((a) => a.chain.chainId == widget.chainId)
        .firstOrNull;

    if (account == null) {
      return Scaffold(
        body: SafeArea(
          child: ZuniaScreenScaffold(
            title: widget.chainId,
            onBack: () => Navigator.of(context).pop(),
            body: const ZuniaEmptyState(
              title: 'Chain not enabled',
              description:
                  'Enable this network to derive an address for it.',
            ),
          ),
        ),
      );
    }

    final chain = account.chain;
    final balance = ref.watch(balancesProvider).valueOrNull?[chain.chainId];

    String amount(String? base) => base == null
        ? '—'
        : prefs.mask(
            formatBaseUnits(base, decimals: chain.coinDecimals),
          );

    final heroAmount = amount(balance?.available);

    return Scaffold(
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: chain.coinDenom,
          onBack: () => Navigator.of(context).pop(),
          trailing: IconButton(
            tooltip: 'Copy address',
            onPressed: () async {
              await ClipboardGuard.copy(account.address);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Address copied')),
              );
            },
            icon: Icon(Icons.copy_outlined, size: 18, color: s.fgMuted),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              Row(
                children: [
                  ChainAvatar(chain: chain, size: 42),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ZuniaAmount(value: heroAmount, hero: true),
                        const SizedBox(height: 5),
                        Text(
                          '${chain.chainName} · ${chain.chainId}',
                          overflow: TextOverflow.ellipsis,
                          style: zuniaMono(fontSize: 11, color: s.fgDim),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _StatRow(
                label: 'Available',
                value: amount(balance?.available),
              ),
              _StatRow(label: 'Staked', value: amount(balance?.staked)),
              _StatRow(
                label: 'Rewards',
                value: amount(balance?.rewards),
                highlight: true,
              ),
              const SizedBox(height: 12),
              _AddressCard(address: account.address),
              const SizedBox(height: 18),
              ZuniaSegmented<String>(
                value: _tab,
                onChanged: (v) => setState(() => _tab = v),
                options: const {
                  'overview': 'Activity',
                  'stake': 'Stake',
                  'about': 'About',
                },
              ),
              const SizedBox(height: 14),
              ..._body(chain.coinDecimals, prefs),
            ],
          ),
          footer: Row(
            children: [
              Expanded(
                child: ZuniaButton(
                  label: 'Send',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SendScreen(chainId: chain.chainId),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: ZuniaButton(
                  label: 'Receive',
                  variant: ZuniaButtonVariant.secondary,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ReceiveScreen(chainId: chain.chainId),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body(int decimals, AppPreferences prefs) {
    switch (_tab) {
      case 'stake':
        final delegations = ref.watch(delegationsProvider(widget.chainId));
        final unbonding = ref.watch(unbondingProvider(widget.chainId));
        return [
          delegations.when(
            data: (rows) => rows.isEmpty
                ? const ZuniaEmptyState(
                    title: 'No delegations',
                    description:
                        'Stake to a validator to start earning rewards on this '
                        'chain.',
                  )
                : Column(
                    children: [
                      for (final row in rows)
                        _PositionRow(
                          title: row.moniker,
                          amount: prefs.mask(
                            formatBaseUnits(row.amount, decimals: decimals),
                          ),
                          meta: 'rewards '
                              '${formatBaseUnits(row.rewards, decimals: decimals)}',
                        ),
                    ],
                  ),
            loading: () => const _Loading(),
            error: (_, _) => const _Unavailable(),
          ),
          unbonding.maybeWhen(
            data: (rows) => rows.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const ZuniaSectionLabel('Unbonding'),
                        const SizedBox(height: 8),
                        for (final row in rows)
                          _PositionRow(
                            title: row.validatorAddress,
                            amount: prefs.mask(
                              formatBaseUnits(row.amount, decimals: decimals),
                            ),
                            meta: row.completionTime == null
                                ? 'pending'
                                : 'available '
                                    '${row.completionTime!.toLocal().toString().split(' ').first}',
                          ),
                      ],
                    ),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ];

      case 'about':
        final chain =
            ref.watch(chainAccountsProvider).firstWhere(
                  (a) => a.chain.chainId == widget.chainId,
                );
        return [
          ZuniaKeyValueRow(label: 'Chain ID', value: chain.chain.chainId),
          const SizedBox(height: 10),
          ZuniaKeyValueRow(label: 'Prefix', value: chain.chain.bech32Prefix),
          const SizedBox(height: 10),
          ZuniaKeyValueRow(
            label: 'Coin type',
            value: "m/44'/${chain.chain.coinType}'",
          ),
          const SizedBox(height: 10),
          ZuniaKeyValueRow(label: 'Network', value: chain.chain.network),
          const SizedBox(height: 10),
          ZuniaKeyValueRow(
            label: 'REST',
            value: chain.chain.rest ?? 'not listed',
          ),
        ];

      default:
        final activity = ref.watch(activityProvider(widget.chainId));
        return [
          activity.when(
            data: (rows) => rows.isEmpty
                ? const ZuniaEmptyState(
                    title: 'No activity yet',
                    description:
                        'Transfers and signatures on this chain will show here.',
                  )
                : Column(
                    children: [
                      for (final row in rows)
                        ZuniaActivityRow(
                          kind: switch (row.kind) {
                            ActivityKind.sent => ZuniaActivityKind.sent,
                            ActivityKind.received =>
                              ZuniaActivityKind.received,
                            ActivityKind.ibc => ZuniaActivityKind.ibc,
                            ActivityKind.swap => ZuniaActivityKind.swap,
                            ActivityKind.staking => ZuniaActivityKind.staking,
                            ActivityKind.claim => ZuniaActivityKind.claim,
                            ActivityKind.governance =>
                              ZuniaActivityKind.governance,
                            ActivityKind.other => ZuniaActivityKind.other,
                          },
                          title: row.title,
                          subtitle: row.subtitle,
                          amount: row.amount == null
                              ? null
                              : prefs.mask(
                                  formatBaseUnits(
                                    row.amount!,
                                    decimals: decimals,
                                  ),
                                ),
                          failed: !row.success,
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

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: zuniaMono(fontSize: 12, color: s.fgDim)),
          Text(
            value,
            style: zuniaMono(
              fontSize: 12,
              color: highlight ? s.info : s.fg,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.surfaceRaisedGradient,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: s.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                address,
                style: zuniaMono(fontSize: 11, height: 1.5, color: s.fgMuted),
              ),
            ),
            const SizedBox(width: 10),
            IconButton(
              onPressed: () async {
                await ClipboardGuard.copy(address);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Address copied')),
                );
              },
              icon: Icon(Icons.copy_outlined, size: 20, color: s.fgMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _PositionRow extends StatelessWidget {
  const _PositionRow({
    required this.title,
    required this.amount,
    required this.meta,
  });

  final String title;
  final String amount;
  final String meta;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: s.surfaceRaisedGradient,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
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
                    Text(meta, style: zuniaMono(fontSize: 10, color: s.fgMuted)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                amount,
                style: zuniaSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.3,
                  color: s.fg,
                  tabular: FontFeature.tabularFigures(),
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
          SizedBox(height: 10),
          ZuniaSkeleton(),
          SizedBox(height: 10),
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
