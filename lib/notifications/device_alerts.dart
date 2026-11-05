/// Device notifications: the banner and lock-screen entry for a new notice.
///
/// Local only. The app raises them itself while it runs (the notice engine
/// decides what is new); nothing comes from a push server, so nothing about
/// this wallet's addresses leaves the device for it.
///
/// Permission is never asked at launch. On iOS the engine asks for
/// *provisional* authorization when it first runs, which shows no prompt and
/// delivers quietly to Notification Center, where the user can keep or turn
/// them off from the notification itself. The full prompt (iOS) and Android
/// 13's POST_NOTIFICATIONS prompt come from [DeviceAlerts.requestPermission],
/// which the app calls when the user asks for notifications: the switch in
/// Notification settings, or the offer after a stake goes through.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:zunia_mobile/notifications/notices.dart';

enum AlertPermission {
  /// Banners and lock screen.
  granted,

  /// iOS provisional: delivered quietly to Notification Center only.
  provisional,

  /// Refused, or not asked yet (iOS cannot tell those apart).
  off,

  /// The platform plugin is missing (a test, an unsupported host).
  unavailable,
}

/// A notice the user tapped in the system tray.
@immutable
class AlertTap {
  const AlertTap(this.noticeId, this.target);

  final String noticeId;
  final NoticeTarget? target;

  String encode() => '$noticeId|${target?.encode() ?? ''}';

  static AlertTap? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    final split = payload.lastIndexOf('|');
    if (split <= 0) return AlertTap(payload, null);
    return AlertTap(
      payload.substring(0, split),
      NoticeTarget.decode(payload.substring(split + 1)),
    );
  }
}

abstract class DeviceAlerts {
  Future<void> init();
  Future<AlertPermission> permission();

  /// Show the system prompt. True when notifications may now be shown.
  Future<bool> requestPermission();

  /// iOS: ask for provisional authorization, which shows no prompt. Elsewhere
  /// a no-op.
  Future<void> requestProvisional();
  Future<void> show(Notice notice);

  /// Taps on a notification while the app is running, or the one that
  /// launched it (replayed once [init] completes).
  Stream<AlertTap> get taps;
}

/// FNV-1a over the notice id: a stable 31-bit notification id, so the same
/// notice replaces itself rather than stacking.
int alertIdFor(String noticeId) {
  var hash = 0x811c9dc5;
  for (final unit in noticeId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

// High importance: a heads-up banner, as people expect for money arriving.
// A channel's importance is fixed once created, hence the new id.
const _androidChannel = AndroidNotificationDetails(
  'zunia.alerts',
  'Wallet notifications',
  channelDescription:
      'Tokens arriving, staking rewards ready to claim, governance deadlines '
      'and sites waiting for your approval.',
  importance: Importance.high,
  priority: Priority.high,
  category: AndroidNotificationCategory.status,
);

class PluginDeviceAlerts implements DeviceAlerts {
  PluginDeviceAlerts([FlutterLocalNotificationsPlugin? plugin])
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final _taps = StreamController<AlertTap>.broadcast();
  Future<bool>? _initialized;

  bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;
  bool get _android => defaultTargetPlatform == TargetPlatform.android;

  @override
  Stream<AlertTap> get taps => _taps.stream;

  @override
  Future<void> init() async {
    await (_initialized ??= _init());
  }

  Future<bool> _init() async {
    if (!_ios && !_android) return false;
    try {
      await _plugin.initialize(
        const InitializationSettings(
          // The launcher icon until a monochrome status-bar glyph exists.
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          // Nothing is requested here: initialising must never prompt.
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: (response) {
          final tap = AlertTap.decode(response.payload);
          if (tap != null) _taps.add(tap);
        },
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        final tap = AlertTap.decode(launch!.notificationResponse?.payload);
        if (tap != null) {
          // After the listeners the caller attaches once init returns.
          scheduleMicrotask(() => _taps.add(tap));
        }
      }
      return true;
    } on Object catch (e) {
      debugPrint('device alerts unavailable: $e');
      return false;
    }
  }

  @override
  Future<AlertPermission> permission() async {
    if (!await (_initialized ??= _init())) return AlertPermission.unavailable;
    try {
      if (_ios) {
        final options = await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.checkPermissions();
        if (options == null) return AlertPermission.unavailable;
        // Status .provisional: quiet delivery until the user allows banners.
        if (options.isProvisionalEnabled) return AlertPermission.provisional;
        return options.isEnabled ? AlertPermission.granted : AlertPermission.off;
      }
      final enabled = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.areNotificationsEnabled();
      if (enabled == null) return AlertPermission.unavailable;
      return enabled ? AlertPermission.granted : AlertPermission.off;
    } on Object {
      return AlertPermission.unavailable;
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!await (_initialized ??= _init())) return false;
    try {
      if (_ios) {
        final ok = await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: false, sound: true);
        return ok ?? false;
      }
      // Android 13+ shows the POST_NOTIFICATIONS prompt; older versions
      // answer true without one.
      final ok = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      return ok ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> requestProvisional() async {
    if (!_ios || !await (_initialized ??= _init())) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(
            alert: true,
            badge: false,
            sound: false,
            provisional: true,
          );
    } on Object {
      // Quiet delivery is a nicety; without it the feed still works.
    }
  }

  @override
  Future<void> show(Notice notice) async {
    if (!await (_initialized ??= _init())) return;
    try {
      await _plugin.show(
        alertIdFor(notice.id),
        notice.title,
        notice.meta,
        const NotificationDetails(
          android: _androidChannel,
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
            presentSound: false,
            threadIdentifier: 'zunia.notices',
          ),
        ),
        payload: AlertTap(notice.id, notice.target).encode(),
      );
    } on Object catch (e) {
      // A notification the system refused must not take the engine down.
      debugPrint('device alert not shown: $e');
    }
  }
}

/// For tests and hosts without notifications: records what would be shown.
class RecordingDeviceAlerts implements DeviceAlerts {
  RecordingDeviceAlerts({this.granted = true});

  bool granted;
  final shown = <Notice>[];
  int prompts = 0;
  int provisionalRequests = 0;
  final _taps = StreamController<AlertTap>.broadcast();

  void tap(AlertTap tap) => _taps.add(tap);

  @override
  Stream<AlertTap> get taps => _taps.stream;

  @override
  Future<void> init() async {}

  @override
  Future<AlertPermission> permission() async =>
      granted ? AlertPermission.granted : AlertPermission.off;

  @override
  Future<bool> requestPermission() async {
    prompts += 1;
    return granted;
  }

  @override
  Future<void> requestProvisional() async {
    provisionalRequests += 1;
  }

  @override
  Future<void> show(Notice notice) async {
    if (granted) shown.add(notice);
  }
}
