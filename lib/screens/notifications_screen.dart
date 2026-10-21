import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/notifications/device_alerts.dart';
import 'package:zunia_mobile/notifications/notices.dart';
import 'package:zunia_mobile/notifications/notifications.dart';
import 'package:zunia_mobile/notifications/notify_prefs.dart';
import 'package:zunia_mobile/screens/chain_detail_screen.dart';
import 'package:zunia_mobile/screens/governance_screen.dart';
import 'package:zunia_mobile/screens/notification_settings_screen.dart';
import 'package:zunia_mobile/screens/preferences_screen.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/staking.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Root tab a notice asks to show. RootShell listens and switches to it.
final noticeTabRequestProvider = StateProvider<String?>((ref) => null);

String noticeKindLabel(NoticeKind kind) => switch (kind) {
      NoticeKind.approval => 'Approvals',
      NoticeKind.transfer => 'Transfers',
      NoticeKind.rewards => 'Rewards',
      NoticeKind.unbonding => 'Unbonding',
      NoticeKind.governance => 'Governance',
    };

bool noticeKindEnabled(NoticeKind kind, NotifyPrefs prefs) => switch (kind) {
      NoticeKind.transfer => prefs.transfers,
      NoticeKind.unbonding => prefs.unbonding,
      NoticeKind.governance => prefs.governance,
      NoticeKind.rewards => prefs.rewards != RewardReminder.off,
      NoticeKind.approval => true,
    };

/// "5m", "3h", "2d", or the date.
String relativeTime(int timestamp, BuildContext context, {DateTime? now}) {
  if (timestamp <= 0) return '';
  final at = DateTime.fromMillisecondsSinceEpoch(timestamp);
  final diff = (now ?? DateTime.now()).difference(at);
  if (diff.isNegative) {
    return MaterialLocalizations.of(context).formatShortMonthDay(at);
  }
  if (diff.inMinutes < 1) return 'now';
  if (diff.inHours < 1) return '${diff.inMinutes}m';
  if (diff.inDays < 1) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return MaterialLocalizations.of(context).formatShortMonthDay(at);
}

/// Open where a notice leads. Shared by the feed and device-notification taps.
void openNoticeTarget(BuildContext context, WidgetRef ref, NoticeTarget? target) {
  final nav = Navigator.of(context);
  switch (target?.route) {
    case null:
      return;
    case NoticeRoute.approve:
      // Requests present themselves over the wallet; showing it is enough.
      nav.popUntil((r) => r.isFirst);
    case NoticeRoute.earn:
      nav.popUntil((r) => r.isFirst);
      ref.read(noticeTabRequestProvider.notifier).state = 'earn';
    case NoticeRoute.governance:
      nav.push(MaterialPageRoute(builder: (_) => const GovernanceScreen()));
    case NoticeRoute.chain:
      final chainId = target!.chainId;
      if (chainId == null) return;
      nav.push(
        MaterialPageRoute(builder: (_) => ChainDetailScreen(chainId: chainId)),
      );
  }
}

/// Everything waiting on the user: approvals, transfers, rewards, unbonding
/// and votes. Tapping a row marks it read and opens where it leads.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  NoticeKind? _filter;

  @override
  void initState() {
    super.initState();
    // History is read only while this screen is open, as the extension's
    // popup does: the engine's own sources are the sockets and the slow pass.
    ref.listenManual<AsyncValue<List<ActivityItem>>>(
      allActivityProvider,
      (_, next) => _feedHistory(next.valueOrNull ?? const []),
      fireImmediately: true,
    );
  }

  void _feedHistory(List<ActivityItem> items) {
    final rows = <ReceivedNoticeInput>[];
    for (final item in items) {
      if (item.kind != ActivityKind.received || !item.success) continue;
      final chain = catalogChain(item.chainId);
      final amount = item.amount;
      final meta = chain != null && amount != null && !amount.startsWith('-')
          ? '${formatBaseUnitsExact(amount, decimals: chain.coinDecimals, maxFractionDigits: 6)} '
              '${chain.coinDenom}'
          : item.subtitle;
      rows.add(
        ReceivedNoticeInput(
          chainId: item.chainId,
          hash: item.hash,
          meta: meta,
          timestamp: item.timestamp.millisecondsSinceEpoch,
        ),
      );
    }
    // Never during a build: the first call comes from initState, and the
    // engine's state is a provider other widgets are building from.
    scheduleMicrotask(() {
      if (mounted) ref.read(noticeEngineProvider.notifier).setReceived(rows);
    });
  }

  Future<void> _refresh() async {
    ref.invalidate(allActivityProvider);
    ref.invalidate(alertPermissionProvider);
    await ref.read(noticeEngineProvider.notifier).refreshNow();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const NotificationSettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    final feed = ref.watch(noticeFeedProvider);
    final notify = ref.watch(notifyPrefsProvider);
    final live = ref.watch(preferencesProvider.select((p) => p.liveReads));
    final permission = ref.watch(alertPermissionProvider).valueOrNull;
    final engine = ref.read(noticeEngineProvider.notifier);

    final filters = [
      for (final kind in NoticeKind.values)
        if (noticeKindEnabled(kind, notify)) kind,
    ];
    final active =
        _filter != null && filters.contains(_filter) ? _filter : null;
    final visible = active == null
        ? feed.notices
        : feed.notices.where((n) => n.kind == active).toList();

    return ZuniaLargeTitleScaffold(
      title: 'Notifications',
      onRefresh: _refresh,
      actions: [
        if (feed.unread > 0)
          TextButton(
            onPressed: () {
              ZuniaHaptics.selection();
              unawaited(engine.markAllRead());
            },
            child: const Text('Mark all read'),
          ),
        IconButton(
          tooltip: 'Notification settings',
          onPressed: _openSettings,
          icon: Icon(
            cupertino ? CupertinoIcons.gear : Icons.settings_outlined,
            color: s.fg,
          ),
        ),
      ],
      slivers: [
        if (permission == AlertPermission.off && feed.notices.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            sliver: SliverToBoxAdapter(
              child: _DeviceOffer(onEnable: () async {
                await enableDeviceNotifications(ref);
              }),
            ),
          ),
        if (feed.notices.isNotEmpty)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                children: [
                  _Chip(
                    label: 'All',
                    selected: active == null,
                    onTap: () => setState(() => _filter = null),
                  ),
                  for (final kind in filters)
                    _Chip(
                      label: noticeKindLabel(kind),
                      selected: active == kind,
                      onTap: () => setState(() => _filter = kind),
                    ),
                ],
              ),
            ),
          ),
        if (!live && feed.notices.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: ZuniaEmptyState(
                title: 'Live reads are off',
                description: 'Turn live reads on in Preferences to be told '
                    'about transfers, rewards and votes.',
                action: ZuniaButton(
                  label: 'Open Preferences',
                  variant: ZuniaButtonVariant.secondary,
                  size: ZuniaButtonSize.sm,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const PreferencesScreen(),
                    ),
                  ),
                ),
              ),
            ),
          )
        else if (feed.notices.isEmpty)
          const SliverPadding(
            padding: EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: ZuniaEmptyState(
                title: 'Nothing waiting',
                description: 'Tokens arriving, rewards ready to claim and '
                    'sites waiting for you land here.',
              ),
            ),
          )
        else if (visible.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(24),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Nothing here with this filter.',
                textAlign: TextAlign.center,
                style: zuniaSans(fontSize: 14, color: s.fgMuted),
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (_, i) => _NoticeRow(
              notice: visible[i],
              onTap: () {
                final notice = visible[i];
                if (!notice.read) unawaited(engine.markRead([notice.id]));
                openNoticeTarget(context, ref, notice.target);
              },
            ),
          ),
        if (feed.running && !feed.live && feed.health.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Text(
                'No live connection to a network right now; checking every '
                'minute instead.',
                textAlign: TextAlign.center,
                style: zuniaSans(fontSize: 12, color: s.fgDim),
              ),
            ),
          ),
      ],
    );
  }
}

class _DeviceOffer extends StatelessWidget {
  const _DeviceOffer({required this.onEnable});

  final Future<void> Function() onEnable;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: s.infoFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: s.infoLine),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Get these on your lock screen too.',
                style: zuniaSans(fontSize: 13.5, color: s.fg),
              ),
            ),
            TextButton(onPressed: onEnable, child: const Text('Turn on')),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        selected: selected,
        button: true,
        label: 'Show $label',
        child: ExcludeSemantics(
          child: ChoiceChip(
            label: Text(label),
            selected: selected,
            showCheckmark: false,
            onSelected: (_) {
              ZuniaHaptics.selection();
              onTap();
            },
            labelStyle: zuniaSans(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: selected ? s.fg : s.fgMuted,
            ),
            selectedColor: s.stateSelected,
            backgroundColor: Colors.transparent,
            side: BorderSide(color: selected ? s.accent : s.line),
            shape: const StadiumBorder(),
          ),
        ),
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.notice, required this.onTap});

  final Notice notice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final icon = switch (notice.kind) {
      NoticeKind.approval => Icons.front_hand_outlined,
      NoticeKind.transfer => Icons.south_west_rounded,
      NoticeKind.rewards => Icons.savings_outlined,
      NoticeKind.unbonding => Icons.hourglass_bottom_rounded,
      NoticeKind.governance => Icons.how_to_vote_outlined,
    };
    final time = relativeTime(notice.timestamp, context);
    return Semantics(
      button: notice.target != null,
      label: '${notice.read ? '' : 'Unread. '}${notice.title}. ${notice.meta}',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: notice.read ? s.glass : s.accent.withValues(alpha: 0.16),
                  ),
                  child: Icon(
                    icon,
                    size: 18,
                    color: notice.read ? s.fgMuted : s.accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        notice.title,
                        style: zuniaSans(
                          fontSize: 15,
                          fontWeight:
                              notice.read ? FontWeight.w400 : FontWeight.w600,
                          color: s.fg,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        notice.meta,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaMono(fontSize: 12, color: s.fgMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(time, style: zuniaMono(fontSize: 11, color: s.fgDim)),
                    if (!notice.read) ...[
                      const SizedBox(height: 6),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: s.accent,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
