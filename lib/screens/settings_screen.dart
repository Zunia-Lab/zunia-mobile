import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_mobile/config/app_identity.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/notifications/notify_prefs.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/address_book_screen.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/screens/connected_sites_screen.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/notification_settings_screen.dart';
import 'package:zunia_mobile/screens/preferences_screen.dart';
import 'package:zunia_mobile/screens/security_screen.dart';
import 'package:zunia_mobile/screens/sessions_screen.dart';
import 'package:zunia_mobile/screens/wallets_screen.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Links in About. All on zunialab.com, opened in the system browser.
abstract final class ZuniaLinks {
  static final docs = Uri.parse('https://docs.zunialab.com');
  static final terms = Uri.parse('https://zunialab.com/legal/terms');
  static final privacy = Uri.parse('https://zunialab.com/legal/privacy');
  static final support = Uri.parse('https://zunialab.com/support');
}

String themeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.dark => 'Dark',
      ThemeMode.light => 'Light',
      ThemeMode.system => 'Auto',
    };

/// The version the signing core reports, or why there is none.
String kernelVersionLabel() {
  try {
    return WalletKernel.instance.kernelVersion;
  } on Object {
    return 'not loaded';
  }
}

/// Every settings area as one grouped list; each row opens a focused screen.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _link(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    final wallet = ref.watch(walletProvider);
    final prefs = ref.watch(preferencesProvider);
    final notify = ref.watch(notifyPrefsProvider);
    final contacts = ref.watch(addressBookProvider).length;
    final wc = ref.watch(walletConnectProvider);
    final native = ref.watch(nativeConnectProvider);
    final sessions = wc.activeSessions.length + native.activeSessions.length;
    final active = wallet.active;

    IconData icon(IconData material, IconData apple) =>
        cupertino ? apple : material;

    return ZuniaLargeTitleScaffold(
      title: 'Settings',
      slivers: [
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'Wallet',
            children: [
              ZuniaListTile(
                title: 'Accounts',
                subtitle: active?.name,
                leading: icon(
                  Icons.account_balance_wallet_outlined,
                  CupertinoIcons.person_crop_circle,
                ),
                value: '${wallet.accounts.length}',
                navigates: true,
                onTap: () => _open(context, const WalletsScreen()),
              ),
              ZuniaListTile(
                title: 'Networks',
                subtitle: 'Choose which chains appear in the wallet',
                leading: icon(Icons.hub_outlined, CupertinoIcons.globe),
                value: '${wallet.enabledChainIds.length} on',
                navigates: true,
                onTap: () => _open(context, const NetworksScreen()),
              ),
              ZuniaListTile(
                title: 'Address book',
                subtitle: 'Saved recipients for sending',
                leading: icon(Icons.contacts_outlined, CupertinoIcons.book),
                value: contacts == 0 ? null : '$contacts',
                navigates: true,
                onTap: () => _open(context, const AddressBookScreen()),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'Security',
            children: [
              ZuniaListTile(
                title: 'Security',
                subtitle: 'Lock, backup, recovery phrase',
                leading: icon(Icons.shield_outlined, CupertinoIcons.lock_shield),
                navigates: true,
                onTap: () => _open(context, const SecurityScreen()),
              ),
              ZuniaListTile(
                title: 'Connected apps',
                subtitle: 'Sites paired over Zunia Connect or WalletConnect',
                leading: icon(Icons.link, CupertinoIcons.link),
                value: sessions == 0 ? null : '$sessions',
                navigates: true,
                onTap: () => _open(context, const SessionsScreen()),
              ),
              ZuniaListTile(
                title: 'Connected sites',
                subtitle: 'In-app browser permissions, blind signing',
                leading: icon(Icons.public, CupertinoIcons.globe),
                navigates: true,
                onTap: () => _open(context, const ConnectedSitesScreen()),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'App',
            children: [
              ZuniaListTile(
                title: 'Preferences',
                subtitle: 'Theme, currency, privacy, live reads',
                leading: icon(Icons.tune, CupertinoIcons.slider_horizontal_3),
                value: themeLabel(prefs.themeMode),
                navigates: true,
                onTap: () => _open(context, const PreferencesScreen()),
              ),
              ZuniaListTile(
                title: 'Notifications',
                subtitle: 'What is shown, and reward reminders',
                leading: icon(Icons.notifications_none, CupertinoIcons.bell),
                value: 'Rewards ${notify.rewards.label.toLowerCase()}',
                navigates: true,
                onTap: () =>
                    _open(context, const NotificationSettingsScreen()),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'About',
            footer: 'Matches Zunia extension $extensionParity: the same '
                'signing core, the same addresses from the same phrase.',
            children: [
              ZuniaListTile(
                title: 'Version',
                leading: icon(Icons.info_outline, CupertinoIcons.info),
                value: appVersion,
              ),
              ZuniaListTile(
                title: 'Signing core',
                subtitle: 'zunia-core, on this device',
                leading: icon(Icons.memory, CupertinoIcons.lock),
                value: kernelVersionLabel(),
              ),
              ZuniaListTile(
                title: 'Documentation',
                leading: icon(Icons.menu_book_outlined, CupertinoIcons.book),
                navigates: true,
                onTap: () => _link(ZuniaLinks.docs),
              ),
              ZuniaListTile(
                title: 'Support',
                leading: icon(Icons.support_agent, CupertinoIcons.chat_bubble),
                navigates: true,
                onTap: () => _link(ZuniaLinks.support),
              ),
              ZuniaListTile(
                title: 'Terms of use',
                leading: icon(Icons.gavel_outlined, CupertinoIcons.doc_text),
                navigates: true,
                onTap: () => _link(ZuniaLinks.terms),
              ),
              ZuniaListTile(
                title: 'Privacy',
                leading: icon(Icons.privacy_tip_outlined, CupertinoIcons.hand_raised),
                navigates: true,
                onTap: () => _link(ZuniaLinks.privacy),
              ),
              ZuniaListTile(
                title: 'Open-source licenses',
                leading: icon(Icons.description_outlined, CupertinoIcons.doc_on_doc),
                navigates: true,
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Zunia',
                  applicationVersion: appVersion,
                  applicationLegalese: 'Apache 2.0 · Zunia Lab',
                ),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ZuniaButton(
                  label: 'Lock wallet',
                  variant: ZuniaButtonVariant.secondary,
                  size: ZuniaButtonSize.lg,
                  leading: const Icon(Icons.lock_outline),
                  // The lock screen covers the app; what was open is still
                  // there after unlocking.
                  onPressed: () => ref.read(vaultSessionProvider).lock(),
                ),
                const SizedBox(height: 14),
                Semantics(
                  label: 'Zunia version $appVersion for '
                      '${cupertino ? 'iOS' : 'Android'}',
                  child: ExcludeSemantics(
                    child: Text(
                      'Zunia v$appVersion · ${cupertino ? 'iOS' : 'Android'}',
                      textAlign: TextAlign.center,
                      style: zuniaMono(
                        fontSize: 11,
                        letterSpacing: 0.6,
                        color: s.fgDim,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'LOCAL KEYS · APACHE 2.0',
                  textAlign: TextAlign.center,
                  style: zuniaMono(
                    fontSize: 10,
                    letterSpacing: 1.2,
                    color: s.fgFaint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
