import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/config/connect_config.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/address_book_screen.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/preferences_screen.dart';
import 'package:zunia_mobile/screens/security_screen.dart';
import 'package:zunia_mobile/screens/wallets_screen.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/settings_tiles.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Hub for every settings area. Each row opens a focused screen rather than
/// stacking controls into one long page.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final wallet = ref.watch(walletProvider);
    final wc = ref.watch(walletConnectProvider);
    final verified = ref.watch(backupVerifiedProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Settings & security',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              SettingsGroup(
                label: 'Wallet',
                children: [
                  SettingsRow(
                    title: 'Wallets',
                    description: '${wallet.accounts.length} account'
                        '${wallet.accounts.length == 1 ? '' : 's'}',
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, const WalletsScreen()),
                  ),
                  SettingsRow(
                    title: 'Networks',
                    description:
                        '${wallet.enabledChainIds.length} enabled',
                    leading: const Icon(Icons.hub_outlined),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, const NetworksScreen()),
                  ),
                  SettingsRow(
                    title: 'Address book',
                    description: 'Saved recipients',
                    leading: const Icon(Icons.contacts_outlined),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, const AddressBookScreen()),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SettingsGroup(
                label: 'App',
                children: [
                  SettingsRow(
                    title: 'Preferences',
                    description: 'Theme, privacy, live reads, currency',
                    leading: const Icon(Icons.tune),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, const PreferencesScreen()),
                  ),
                  SettingsRow(
                    title: 'Security',
                    description: verified.maybeWhen(
                      data: (ok) => ok
                          ? 'Backup verified'
                          : 'Backup not verified yet',
                      orElse: () => 'Backup, device checks, wipe',
                    ),
                    leading: const Icon(Icons.shield_outlined),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, const SecurityScreen()),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SettingsGroup(
                label: 'Connections',
                children: [
                  SettingsRow(
                    title: 'WalletConnect',
                    description: wc.isReady
                        ? 'Ready · $kWalletName'
                        : kWalletConnectProjectId.isEmpty
                            ? 'Set WALLETCONNECT_PROJECT_ID to enable'
                            : 'Configured, not initialized',
                    leading: const Icon(Icons.link),
                    trailing: Text(
                      wc.isReady ? 'ready' : 'off',
                      style: zuniaMono(
                        fontSize: 10.5,
                        color: wc.isReady ? s.info : s.fgMuted,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SettingsGroup(
                label: 'About',
                children: [
                  SettingsRow(
                    title: 'Signing core',
                    description: WalletKernel.instance.usingNativeCore
                        ? 'Native zunia-core kernel'
                        : 'Dart fallback (same derivation vectors)',
                    leading: const Icon(Icons.memory),
                    trailing: Text(
                      WalletKernel.instance.usingNativeCore ? 'native' : 'dart',
                      style: zuniaMono(fontSize: 10.5, color: s.info),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Center(
                child: Text(
                  'LOCAL KEYS · APACHE 2.0',
                  style: zuniaMono(
                    fontSize: 9,
                    letterSpacing: 1.2,
                    color: s.fgDim,
                  ),
                ),
              ),
            ],
          ),
          footer: ZuniaButton(
            label: 'Lock wallet',
            variant: ZuniaButtonVariant.secondary,
            size: ZuniaButtonSize.lg,
            leading: const Icon(Icons.lock_outline),
            onPressed: () {
              ref.read(phraseProvider.notifier).state = null;
              ref.read(sessionProvider.notifier).state = null;
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
        ),
      ),
    );
  }
}
