import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/wallet_switcher_sheet.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Header shared by every root tab: wallet switcher, network count, privacy
/// toggle and the drawer handle.
class WalletHeader extends ConsumerWidget {
  const WalletHeader({super.key, required this.onOpenNetworks});

  final VoidCallback onOpenNetworks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final wallet = ref.watch(walletProvider);
    final prefs = ref.watch(preferencesProvider);
    final name = wallet.active?.name ?? 'Wallet';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Row(
        children: [
          Flexible(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: s.surfaceRaisedGradient,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
                child: ZuniaWalletChip(
                  name: name,
                  onTap: () => showWalletSwitcher(context),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ZuniaNetworkChip(
            label: 'Mainnet',
            count: wallet.enabledChainIds.length,
            onTap: onOpenNetworks,
          ),
          const Spacer(),
          IconButton(
            tooltip: prefs.hideAmounts ? 'Show amounts' : 'Hide amounts',
            onPressed: () =>
                ref.read(preferencesProvider.notifier).toggleHideAmounts(),
            icon: Icon(
              prefs.hideAmounts
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 19,
              color: s.fgMuted,
            ),
          ),
          IconButton(
            tooltip: 'Menu',
            onPressed: Scaffold.of(context).openEndDrawer,
            icon: Icon(Icons.menu, size: 20, color: s.fg),
          ),
        ],
      ),
    );
  }
}
