import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/widgets/settings_tiles.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Appearance, privacy and network-read preferences.
class PreferencesScreen extends ConsumerWidget {
  const PreferencesScreen({super.key});

  static const _currencies = ['USD', 'EUR', 'GBP', 'JPY', 'NGN', 'KES', 'ZAR'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final controller = ref.read(preferencesProvider.notifier);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Preferences',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              const ZuniaSectionLabel('Appearance'),
              const SizedBox(height: 8),
              ZuniaSegmented<ThemeMode>(
                value: prefs.themeMode,
                onChanged: controller.setTheme,
                options: const {
                  ThemeMode.dark: 'Dark',
                  ThemeMode.light: 'Light',
                  ThemeMode.system: 'System',
                },
              ),
              const SizedBox(height: 18),
              SettingsGroup(
                label: 'Privacy',
                children: [
                  SettingsRow(
                    title: 'Hide amounts',
                    description:
                        'Replaces every balance with dots until you turn it off',
                    leading: const Icon(Icons.visibility_off_outlined),
                    trailing: ZuniaSwitch(
                      value: prefs.hideAmounts,
                      onChanged: controller.setHideAmounts,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SettingsGroup(
                label: 'Network',
                children: [
                  SettingsRow(
                    title: 'Live reads',
                    description:
                        'Fetch balances, validators and history from the public '
                        'endpoints the registry lists. Off means fully offline.',
                    leading: const Icon(Icons.cloud_outlined),
                    trailing: ZuniaSwitch(
                      value: prefs.liveReads,
                      onChanged: controller.setLiveReads,
                    ),
                  ),
                  SettingsRow(
                    title: 'Alerts',
                    description: 'Surface rewards, transfers and open votes',
                    leading: const Icon(Icons.notifications_none),
                    trailing: ZuniaSwitch(
                      value: prefs.alerts,
                      onChanged: controller.setAlerts,
                    ),
                  ),
                  SettingsRow(
                    title: 'Diagnostics',
                    description: 'Keep local logs for troubleshooting',
                    leading: const Icon(Icons.bug_report_outlined),
                    trailing: ZuniaSwitch(
                      value: prefs.diagnostics,
                      onChanged: controller.setDiagnostics,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const ZuniaSectionLabel('Display currency'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final currency in _currencies)
                    GestureDetector(
                      onTap: () => controller.setCurrency(currency),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          gradient: prefs.currency == currency
                              ? s.accentGradient
                              : null,
                          color: prefs.currency == currency ? null : s.glass,
                        ),
                        child: Text(
                          currency,
                          style: zuniaMono(
                            fontSize: 11,
                            color: prefs.currency == currency
                                ? s.accentFg
                                : s.fgMuted,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'No price feed ships with the wallet, so this only labels '
                'converted values once a feed is connected.',
                style: zuniaMono(fontSize: 10, height: 1.5, color: s.fgDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
