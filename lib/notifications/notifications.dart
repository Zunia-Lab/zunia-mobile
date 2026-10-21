/// Riverpod wiring for notifications.
///
/// Stable API for other workstreams:
///
/// ```dart
/// ref.watch(unreadNoticeCountProvider)       // int: the bell badge on Home
/// ref.watch(noticeFeedProvider).notices      // List<Notice>, unread first
/// ref.read(noticeEngineProvider.notifier).markRead([id])
/// await enableDeviceNotifications(ref)       // asks the OS, stores the choice
/// ```
///
/// Watching any of them starts the engine; it watches chains only while the
/// wallet is unlocked with live reads on.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/notifications/device_alerts.dart';
import 'package:zunia_mobile/notifications/notice_engine.dart';
import 'package:zunia_mobile/notifications/notices.dart';
import 'package:zunia_mobile/notifications/notify_prefs.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

export 'package:zunia_mobile/notifications/notices.dart'
    show Notice, NoticeKind, NoticeRoute, NoticeTarget;
export 'package:zunia_mobile/notifications/notice_engine.dart' show NoticeFeed;

final deviceAlertsProvider = Provider<DeviceAlerts>((ref) {
  final alerts = PluginDeviceAlerts();
  unawaited(alerts.init());
  return alerts;
});

/// Sites waiting for the user (Zunia Connect requests), as feed rows.
final pendingApprovalsProvider =
    StreamProvider<List<ApprovalNoticeInput>>((ref) async* {
  final native = ref.watch(nativeConnectProvider);
  List<ApprovalNoticeInput> read() => [
        for (final request in native.pendingRequests)
          ApprovalNoticeInput(
            id: request.id,
            origin: request.dapp.verifiedOrigin ?? request.dapp.metadata.url,
            title: switch (request) {
              NativeConnectRequest() =>
                '${request.dapp.metadata.name} wants to connect',
              NativeSignRequest() =>
                '${request.dapp.metadata.name} asks for a signature',
            },
            createdAt: request.receivedAt.millisecondsSinceEpoch,
          ),
      ];
  yield read();
  await for (final _ in native.changes) {
    yield read();
  }
});

final noticeEngineProvider =
    StateNotifierProvider<NoticeEngine, NoticeFeed>((ref) {
  final engine = NoticeEngine(
    alerts: ref.watch(deviceAlertsProvider),
    // Read the switch on every request rather than rebuilding the engine
    // (and dropping its sockets) each time it changes.
    reader: ChainReader(
      readsAllowed: () => ref.read(preferencesProvider).liveReads,
    ),
    onBalancesMoved: (_) => ref.invalidate(balancesProvider),
  );

  void push() {
    final prefs = ref.read(preferencesProvider);
    unawaited(
      engine.update(
        NoticeEngineInputs(
          accounts: [
            for (final a in ref.read(chainAccountsProvider))
              WatchedChain(a.chain, a.address),
          ],
          accountIndex: ref.read(walletProvider).active?.index,
          liveReads: prefs.liveReads,
          deviceAlerts: prefs.alerts,
          prefs: ref.read(notifyPrefsProvider),
          approvals:
              ref.read(pendingApprovalsProvider).valueOrNull ?? const [],
        ),
      ),
    );
  }

  ref.listen(chainAccountsProvider, (_, _) => push());
  ref.listen(
    preferencesProvider.select((p) => (p.liveReads, p.alerts, p.loaded)),
    (_, _) => push(),
  );
  ref.listen(notifyPrefsProvider, (_, _) => push());
  ref.listen(pendingApprovalsProvider, (_, _) => push());
  scheduleMicrotask(push);
  return engine;
});

final noticeFeedProvider = Provider<NoticeFeed>(
  (ref) => ref.watch(noticeEngineProvider),
);

/// Unread notices: the count on the bell.
final unreadNoticeCountProvider = Provider<int>(
  (ref) => ref.watch(noticeEngineProvider.select((feed) => feed.unread)),
);

/// Device notifications the user tapped, with where each leads.
final noticeTapsProvider = StreamProvider<NoticeTarget?>(
  (ref) => ref.watch(noticeEngineProvider.notifier).taps,
);

final alertPermissionProvider = FutureProvider.autoDispose<AlertPermission>(
  (ref) => ref.watch(deviceAlertsProvider).permission(),
);

/// Ask the OS for notifications and remember that the user wants them.
/// Returns whether they may now be shown. Call it from a tap, never on its
/// own: the prompt is a one-time chance on iOS.
Future<bool> enableDeviceNotifications(WidgetRef ref) async {
  final granted = await ref.read(deviceAlertsProvider).requestPermission();
  await ref.read(preferencesProvider.notifier).setAlerts(granted);
  ref.invalidate(alertPermissionProvider);
  return granted;
}
