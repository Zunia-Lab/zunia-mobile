import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/amino_tx.dart';
import 'package:zunia_mobile/services/wallet_tx_service.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_mobile/widgets/transfer_sent_sheet.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Cross-chain claimable rewards with wallet-originated MsgWithdrawDelegationReward.
class RewardsScreen extends ConsumerStatefulWidget {
  const RewardsScreen({super.key});

  @override
  ConsumerState<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends ConsumerState<RewardsScreen> {
  bool _busy = false;

  Future<void> _claimAll(
    List<
            ({
              ChainEntry chain,
              String chainId,
              String name,
              String denom,
              int decimals,
              String rewards
            })>
        rows,
  ) async {
    final phrase = ref.read(phraseProvider);
    final wallet = ref.read(walletProvider);
    final active = wallet.active;
    if (phrase == null || active == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unlock the wallet to claim.')),
      );
      return;
    }

    setState(() => _busy = true);
    String? lastHash;
    try {
      for (final row in rows) {
        final account = ref
            .read(chainAccountsProvider)
            .where((a) => a.chain.chainId == row.chainId)
            .firstOrNull;
        if (account == null) continue;

        final delegations =
            await ref.read(delegationsProvider(row.chainId).future);
        final claimable = delegations
            .where((d) => (BigInt.tryParse(d.rewards) ?? BigInt.zero) > BigInt.zero)
            .toList();
        if (claimable.isEmpty) continue;

        lastHash = await WalletTxService.instance.signAndBroadcast(
          phrase: phrase,
          chain: account.chain,
          signerAddress: account.address,
          accountIndex: active.index,
          msgs: [
            for (final d in claimable)
              msgWithdrawReward(
                delegatorAddress: account.address,
                validatorAddress: d.validatorAddress,
              ),
          ],
          gasLimit: (claimable.length * 120000).clamp(250000, 2000000),
        );
      }
      if (!mounted) return;
      if (lastHash == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No claimable rewards found on-chain.')),
        );
        return;
      }
      await showTransferSent(
        context,
        txHash: lastHash,
        title: 'Rewards claimed',
        onDone: () => Navigator.of(context).pop(),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$err')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
        bottom: false,
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
                        : 'across ${rows.length} networks · signed per chain',
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
                    title: 'Signed on this device',
                    body:
                        'Claim builds MsgWithdrawDelegationReward amino, signs '
                        'with the unlocked keyring, and posts to each chain REST.',
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
                label: _busy ? 'Signing…' : 'Claim all',
                size: ZuniaButtonSize.lg,
                onPressed: rows.isEmpty || _busy
                    ? null
                    : () => _claimAll(rows),
              ),
              const SizedBox(height: 10),
              Text(
                'One broadcast per chain with claimable rewards',
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
