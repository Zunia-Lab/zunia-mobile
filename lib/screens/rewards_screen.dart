import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Cross-chain claimable rewards. Claiming is listed honestly as unsigned
/// until a broadcast endpoint exists.
class RewardsScreen extends ConsumerWidget {
  const RewardsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final balances = ref.watch(balancesProvider).valueOrNull ?? const {};

    final rows = <({
      ChainEntry chain,
      String chainId,
      String name,
      String denom,
      int decimals,
      String rewards
    })>[];
    for (final account in accounts) {
      final rewards = balances[account.chain.chainId]?.rewards ?? '0';
      final parsed = BigInt.tryParse(rewards);
      if (parsed == null || parsed == BigInt.zero) continue;
      rows.add((
        chain: account.chain,
        chainId: account.chain.chainId,
        name: account.chain.chainName,
        denom: account.chain.coinDenom,
        decimals: account.chain.coinDecimals,
        rewards: rewards,
      ));
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Rewards',
          onBack: () => Navigator.of(context).pop(),
          trailing: Text(
            '${rows.length} ${rows.length == 1 ? 'chain' : 'chains'}',
            style: zuniaMono(fontSize: 11, color: s.fgDim),
          ),
          body: Stack(
            children: [
              Positioned(
                right: -40,
                top: 20,
                child: IgnorePointer(
                  child: Container(
                    width: 220,
                    height: 220,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          s.accent.withValues(alpha: 0.35),
                          s.accent.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              ListView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                children: [
                  Text(
                    'CLAIMABLE TOTAL',
                    textAlign: TextAlign.center,
                    style: zuniaMono(
                      fontSize: 10,
                      letterSpacing: 1.6,
                      color: s.fgMuted,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    rows.isEmpty
                        ? '—'
                        : prefs.mask('${rows.length} networks'),
                    textAlign: TextAlign.center,
                    style: zuniaSans(
                      fontSize: 33,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -1.2,
                      color: s.fg,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    rows.isEmpty
                        ? 'Rewards stay on-chain until you sign a claim.'
                        : 'across ${rows.length} networks · one signature',
                    textAlign: TextAlign.center,
                    style: zuniaMono(fontSize: 11, color: s.info),
                  ),
                  const SizedBox(height: 28),
                  if (rows.isEmpty)
                    const ZuniaEmptyState(
                      title: 'Nothing to claim',
                      description:
                          'Delegations with outstanding rewards appear here once live reads are on.',
                    )
                  else
                    for (final row in rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          child: Row(
                            children: [
                              ChainAvatar(chain: row.chain, size: 28),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Text(
                                  row.chainId,
                                  style: zuniaMono(
                                    fontSize: 12,
                                    color: s.fgMuted,
                                  ),
                                ),
                              ),
                              Text(
                                '${prefs.mask(formatBaseUnits(row.rewards, decimals: row.decimals))} ${row.denom}',
                                style: zuniaMono(
                                  fontSize: 12.5,
                                  color: s.fg,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  const SizedBox(height: 16),
                  const ZuniaCallout(
                    title: 'Claim stays on device',
                    body:
                        'A claim transaction is not broadcast from this build. '
                        'The list is the current on-chain picture only.',
                  ),
                ],
              ),
            ],
          ),
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ZuniaButton(
                label: 'Claim all',
                size: ZuniaButtonSize.lg,
                onPressed: rows.isEmpty
                    ? null
                    : () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Claiming needs a broadcast endpoint. Nothing left the device.',
                            ),
                          ),
                        );
                      },
              ),
              const SizedBox(height: 10),
              Text(
                'Fees: unsigned until a broadcast endpoint is configured',
                textAlign: TextAlign.center,
                style: zuniaMono(fontSize: 11.5, color: s.fgDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
