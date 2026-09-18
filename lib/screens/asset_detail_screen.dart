import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/receive_screen.dart';
import 'package:zunia_mobile/screens/send_screen.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Asset detail for one enabled chain's native denom.
class AssetDetailScreen extends ConsumerWidget {
  const AssetDetailScreen({super.key, required this.chainId});

  final String chainId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final account = accounts.where((a) => a.chain.chainId == chainId).firstOrNull;
    if (account == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: ZuniaScreenScaffold(
            title: 'Asset',
            onBack: () => Navigator.of(context).pop(),
            body: const ZuniaEmptyState(
              title: 'Chain not enabled',
              description: 'Enable this network to view its balance.',
            ),
          ),
        ),
      );
    }

    final chain = account.chain;
    final balance = ref.watch(balancesProvider).valueOrNull?[chainId];
    final amount = prefs.mask(
      formatBaseUnits(
        balance?.available ?? '0',
        decimals: chain.coinDecimals,
      ),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: chain.coinDenom,
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: s.glass,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: s.line),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ZuniaAssetDetail(
                    name: chain.chainName,
                    symbol: chain.coinDenom,
                    amount: amount,
                    chainLabel: chain.chainName,
                    actions: Row(
                      children: [
                        Expanded(
                          child: ZuniaButton(
                            label: 'Send',
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => SendScreen(chainId: chainId),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ZuniaButton(
                            label: 'Receive',
                            variant: ZuniaButtonVariant.secondary,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    ReceiveScreen(chainId: chainId),
                              ),
                            ),
                          ),
                        ),
                      ],
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
}
