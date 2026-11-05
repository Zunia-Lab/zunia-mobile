import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_mobile/notifications/device_alerts.dart';
import 'package:zunia_mobile/notifications/notifications.dart';
import 'package:zunia_mobile/notifications/notify_prefs.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Which notices show (in the feed, on the count and on the device), how
/// often reward reminders come back, and whether the device shows them at
/// all. The defaults are quiet: tokens arriving and one rewards notice per
/// cycle; governance and unbonding stay off until asked for.
class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  Future<void> _toggleDevice(
    BuildContext context,
    WidgetRef ref,
    bool on,
  ) async {
    if (!on) {
      await ref.read(preferencesProvider.notifier).setAlerts(false);
      return;
    }
    final granted = await enableDeviceNotifications(ref);
    if (granted || !context.mounted) return;
    final open = await showZuniaConfirm(
      context,
      title: 'Notifications are off for Zunia',
      message: 'Turn them on for Zunia in the system settings, then come back.',
      confirmLabel: 'Open settings',
    );
    if (!open) return;
    try {
      // `app-settings:` opens this app's page in iOS Settings. Android has no
      // URL for it; the user finds the switch under Settings > Apps.
      await launchUrl(Uri.parse('app-settings:'));
    } on Object {
      // Nothing more to do than what the dialog already said.
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notify = ref.watch(notifyPrefsProvider);
    final controller = ref.read(notifyPrefsProvider.notifier);
    final prefs = ref.watch(preferencesProvider);
    final permission = ref.watch(alertPermissionProvider).valueOrNull;
    final cupertino = ZuniaPlatform.isCupertino(context);
    IconData icon(IconData material, IconData apple) =>
        cupertino ? apple : material;

    final deviceOn = prefs.alerts &&
        (permission == AlertPermission.granted ||
            permission == AlertPermission.provisional);
    final deviceFooter = switch (permission) {
      AlertPermission.unavailable =>
        'This device cannot show notifications from Zunia.',
      AlertPermission.provisional when prefs.alerts =>
        'Delivered quietly to Notification Center. Turn the switch off and on '
            'to allow banners.',
      AlertPermission.off when prefs.alerts =>
        'The system has not allowed notifications from Zunia yet. Turn the '
            'switch on to ask, or allow them in system settings.',
      _ =>
        'Raised by the app while it runs. Nothing is sent to a server for '
            'them, and nothing arrives once the system has suspended Zunia.',
    };

    return ZuniaLargeTitleScaffold(
      title: 'Notifications',
      slivers: [
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'Show',
            footer: 'Approvals always show: a site is waiting on each one.',
            children: [
              ZuniaListTile(
                title: 'Transfers',
                subtitle: 'Tokens arriving in this wallet',
                leading: icon(Icons.south_west, CupertinoIcons.arrow_down_left),
                trailing: ZuniaSwitch(
                  value: notify.transfers,
                  onChanged: (v) =>
                      controller.update((p) => p.copyWith(transfers: v)),
                ),
              ),
              ZuniaListTile(
                title: 'Governance',
                subtitle: 'Proposals still open for your vote',
                leading: icon(Icons.how_to_vote_outlined, CupertinoIcons.checkmark_seal),
                trailing: ZuniaSwitch(
                  value: notify.governance,
                  onChanged: (v) =>
                      controller.update((p) => p.copyWith(governance: v)),
                ),
              ),
              ZuniaListTile(
                title: 'Unbonding',
                subtitle: 'Stake you are unbonding, with the days left',
                leading: icon(Icons.hourglass_bottom, CupertinoIcons.hourglass),
                trailing: ZuniaSwitch(
                  value: notify.unbonding,
                  onChanged: (v) =>
                      controller.update((p) => p.copyWith(unbonding: v)),
                ),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'Staking rewards',
            footer: notify.rewards.hint,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Semantics(
                  label: 'Reward reminders',
                  child: ZuniaSegmented<RewardReminder>(
                    value: notify.rewards,
                    onChanged: (v) =>
                        controller.update((p) => p.copyWith(rewards: v)),
                    options: {
                      for (final r in RewardReminder.values) r: r.label,
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'On this device',
            footer: deviceFooter,
            children: [
              ZuniaListTile(
                title: 'Device notifications',
                subtitle: 'Banners and lock screen',
                leading: icon(Icons.phone_iphone, CupertinoIcons.device_phone_portrait),
                trailing: ZuniaSwitch(
                  value: deviceOn,
                  onChanged: permission == AlertPermission.unavailable
                      ? null
                      : (v) => _toggleDevice(context, ref, v),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
