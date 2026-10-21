import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/notification_settings_screen.dart';
import 'package:zunia_mobile/screens/settings_screen.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/ui/option_sheet.dart';
import 'package:zunia_ui/zunia_ui.dart';

const currencyNames = <String, String>{
  'USD': 'US dollar',
  'EUR': 'Euro',
  'GBP': 'British pound',
  'JPY': 'Japanese yen',
  'CHF': 'Swiss franc',
};

/// Appearance, privacy and what the wallet may fetch.
///
/// There is no diagnostics switch: the app collects none, and a switch that
/// does nothing would say otherwise.
class PreferencesScreen extends ConsumerWidget {
  const PreferencesScreen({super.key});

  Future<void> _pickCurrency(
    BuildContext context,
    PreferencesController controller,
    String current,
  ) async {
    final next = await pickOption<String>(
      context,
      title: 'Display currency',
      message: 'Values are converted with the wallet\'s price sources. Tokens '
          'without a price show no value rather than a guess.',
      selected: current,
      options: [
        for (final code in supportedCurrencies)
          (value: code, label: '$code · ${currencyNames[code]}'),
      ],
    );
    if (next != null) await controller.setCurrency(next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(preferencesProvider);
    final controller = ref.read(preferencesProvider.notifier);
    final cupertino = ZuniaPlatform.isCupertino(context);
    IconData icon(IconData material, IconData apple) =>
        cupertino ? apple : material;

    return ZuniaLargeTitleScaffold(
      title: 'Preferences',
      slivers: [
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'Appearance',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Semantics(
                  label: 'Theme',
                  child: ZuniaSegmented<ThemeMode>(
                    value: prefs.themeMode,
                    onChanged: controller.setTheme,
                    options: {
                      for (final mode in const [
                        ThemeMode.dark,
                        ThemeMode.light,
                        ThemeMode.system,
                      ])
                        mode: themeLabel(mode),
                    },
                  ),
                ),
              ),
              ZuniaListTile(
                title: 'Currency',
                leading: icon(Icons.payments_outlined, CupertinoIcons.money_dollar_circle),
                value: prefs.currency,
                navigates: true,
                onTap: () => _pickCurrency(context, controller, prefs.currency),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'Privacy',
            footer: 'Hide amounts replaces every balance with dots until you '
                'turn it off. The eye in the header does the same.',
            children: [
              ZuniaListTile(
                title: 'Hide amounts',
                leading: icon(Icons.visibility_off_outlined, CupertinoIcons.eye_slash),
                trailing: ZuniaSwitch(
                  value: prefs.hideAmounts,
                  onChanged: controller.setHideAmounts,
                ),
                onTap: () => controller.setHideAmounts(!prefs.hideAmounts),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'Data',
            footer: prefs.liveReads
                ? 'Live reads ask each enabled network\'s public endpoint for '
                    'balances, staking, proposals and history, which tells that '
                    'host your IP address and the addresses asked about. '
                    'Artwork goes further: to whatever host each NFT names.'
                : 'Live reads are off: the wallet asks no network anything. '
                    'Addresses still derive on this device, and you can still '
                    'sign.',
            children: [
              ZuniaListTile(
                title: 'Live reads',
                subtitle: 'Balances, staking and proposals from public endpoints',
                leading: icon(Icons.cloud_outlined, CupertinoIcons.cloud),
                trailing: ZuniaSwitch(
                  value: prefs.liveReads,
                  onChanged: controller.setLiveReads,
                ),
                onTap: () => controller.setLiveReads(!prefs.liveReads),
              ),
              ZuniaListTile(
                title: 'NFT artwork and details',
                subtitle: prefs.liveReads
                    ? 'Fetched from the host each token names'
                    : 'Turn on live reads first',
                leading: icon(Icons.image_outlined, CupertinoIcons.photo),
                trailing: ZuniaSwitch(
                  value: prefs.nftMedia && prefs.liveReads,
                  onChanged: prefs.liveReads ? controller.setNftMedia : null,
                ),
                onTap: prefs.liveReads
                    ? () => controller.setNftMedia(!prefs.nftMedia)
                    : null,
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'Notifications',
            children: [
              ZuniaListTile(
                title: 'Notification settings',
                leading: icon(Icons.notifications_none, CupertinoIcons.bell),
                navigates: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NotificationSettingsScreen(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
