import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/pair_device.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/wallet_switcher_sheet.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Header of the root tabs other than Home: the same account header, so
/// every tab reads as one app. Scanning opens the pairing scanner, which also
/// understands addresses and payment requests.
class WalletHeader extends ConsumerWidget {
  const WalletHeader({super.key, required this.onOpenNetworks});

  /// Kept for callers; the networks manager is in the drawer and Settings.
  final VoidCallback onOpenNetworks;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      HomeHeader(onScan: () => openPairDevice(context, ref));
}

/// Home's header: the account (avatar and name, tap to switch), how many
/// networks it reads, and the three things Home does from the top: scan a
/// code, hide amounts, and open the menu.
class HomeHeader extends ConsumerWidget {
  const HomeHeader({super.key, required this.onScan});

  final VoidCallback onScan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final wallet = ref.watch(walletProvider);
    final hidden = ref.watch(preferencesProvider.select((p) => p.hideAmounts));
    final cupertino = ZuniaPlatform.isCupertino(context);
    final name = wallet.active?.name ?? 'Wallet';
    final networks = wallet.enabledChainIds.length;

    Widget action({
      required String label,
      required IconData icon,
      required VoidCallback onTap,
    }) =>
        IconButton(
          tooltip: label,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
          onPressed: onTap,
          icon: Icon(icon, size: 22, color: s.fg),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 4, 2),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: 'Account $name. Switch account',
              excludeSemantics: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () {
                  ZuniaHaptics.light();
                  showWalletSwitcher(context);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      ZuniaWalletAvatar(seed: wallet.active?.id ?? name, size: 34),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: zuniaSans(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: -0.3,
                                      color: s.fg,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 2),
                                Icon(
                                  cupertino ? CupertinoIcons.chevron_down : Icons.expand_more,
                                  size: cupertino ? 13 : 18,
                                  color: s.fgMuted,
                                ),
                              ],
                            ),
                            Text(
                              '$networks network${networks == 1 ? '' : 's'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          action(
            label: 'Scan a code',
            icon: cupertino ? CupertinoIcons.qrcode_viewfinder : Icons.qr_code_scanner,
            onTap: onScan,
          ),
          action(
            label: hidden ? 'Show amounts' : 'Hide amounts',
            icon: hidden
                ? (cupertino ? CupertinoIcons.eye_slash : Icons.visibility_off_outlined)
                : (cupertino ? CupertinoIcons.eye : Icons.visibility_outlined),
            onTap: () {
              ZuniaHaptics.selection();
              ref.read(preferencesProvider.notifier).toggleHideAmounts();
            },
          ),
          action(
            label: 'Menu',
            icon: cupertino ? CupertinoIcons.line_horizontal_3 : Icons.menu,
            onTap: Scaffold.of(context).openEndDrawer,
          ),
        ],
      ),
    );
  }
}
