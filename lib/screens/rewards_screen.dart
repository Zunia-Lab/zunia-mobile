import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/staking_client.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/staking.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/ui/facts.dart';
import 'package:zunia_mobile/ui/claim_review.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Claimable staking rewards on every enabled network. Each network is its
/// own transaction with its own signature, so each has its own Claim.
class RewardsScreen extends ConsumerWidget {
  const RewardsScreen({super.key});

  Future<void> _claim(
    BuildContext context,
    WidgetRef ref,
    ChainAccount account,
    List<StakingPosition> rows,
  ) =>
      reviewClaim(
        context,
        ref,
        chain: account.chain,
        delegator: account.address,
        positions: rows,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);

    final rows = <(ChainAccount, List<StakingPosition>, BigInt?)>[];
    var loading = false;
    var failed = 0;
    if (prefs.liveReads) {
      for (final account in accounts) {
        final value = ref.watch(stakingPositionsProvider(account.chain.chainId));
        if (value.isLoading && !value.hasValue) loading = true;
        if (value.hasError && !value.hasValue) failed++;
        final positions = value.valueOrNull;
        if (positions == null) continue;
        final total = claimableTotal(positions);
        if (positions.any((p) => (p.rewards ?? BigInt.zero) > BigInt.zero)) {
          rows.add((account, positions, total));
        }
      }
    }

    return Scaffold(
      backgroundColor: zuniaGroundTop(context),
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Rewards',
          onBack: () => Navigator.of(context).maybePop(),
          body: RefreshIndicator.adaptive(
            onRefresh: () async {
              for (final a in accounts) {
                ref.invalidate(stakingPositionsProvider(a.chain.chainId));
              }
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
              children: [
                Text(
                  'Rewards stay on each network until you claim them. Each '
                  'network is a separate transaction and fee.',
                  style: zuniaSans(fontSize: 13.5, height: 1.45, color: s.fgMuted),
                ),
                const SizedBox(height: 12),
                if (!prefs.liveReads)
                  const ZuniaCallout(
                    title: 'Live reads are off',
                    body: 'Turn live reads on in Preferences to see what you '
                        'can claim.',
                  )
                else if (rows.isEmpty && loading)
                  const ListSkeleton(rows: 3, label: 'Loading rewards')
                else if (rows.isEmpty)
                  ZuniaEmptyState(
                    title: 'Nothing to claim',
                    description: failed > 0
                        ? '$failed network${failed == 1 ? '' : 's'} did not '
                            'answer, so there may be rewards this list cannot '
                            'show yet.'
                        : 'Staking rewards show here as they accrue.',
                  )
                else ...[
                  for (final (account, positions, total) in rows)
                    _ChainRewards(
                      chain: account.chain,
                      total: total,
                      validators: positions
                          .where((p) => (p.rewards ?? BigInt.zero) > BigInt.zero)
                          .length,
                      hide: prefs.hideAmounts,
                      onClaim: () => _claim(context, ref, account, positions),
                    ),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: ListSkeleton(rows: 1, label: 'Loading more networks'),
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

class _ChainRewards extends StatelessWidget {
  const _ChainRewards({
    required this.chain,
    required this.total,
    required this.validators,
    required this.hide,
    required this.onClaim,
  });

  final ChainEntry chain;
  final BigInt? total;
  final int validators;
  final bool hide;
  final VoidCallback onClaim;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: s.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: s.line),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              ChainAvatar(chain: chain, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: MergeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chain.chainName,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaSans(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: s.fg,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        hide
                            ? '••••'
                            : total == null
                                ? 'from $validators validators'
                                : '${stakeAmount(total!, chain, digits: 6)} · '
                                    '$validators validator${validators == 1 ? '' : 's'}',
                        style: zuniaMono(fontSize: 12, color: s.fgMuted),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ZuniaButton(
                label: 'Claim',
                size: ZuniaButtonSize.sm,
                onPressed: onClaim,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
