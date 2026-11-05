/// Firebase Cloud Messaging: the token Zunia's server wakes this device with,
/// and what a push does once it lands.
///
/// A push carries `notification: {title: "Zunia", body: "New activity in
/// your wallet"}`, which the system shows while the app is closed, and
/// `data: {event: "tx_update", chainId, txHash}`. No amount, no address.
///
/// - In the foreground the system shows nothing; [messages] tells the notice
///   engine to read that chain again, and the engine raises its own notice.
/// - Tapped, the app opens on the Notifications screen ([opens]; the one that
///   launched the app waits in [takePendingOpen] until the shell listens).
///
/// Privacy: auto-init is off in AndroidManifest.xml and Info.plist, so no
/// Firebase token exists, and nothing is sent to Firebase, until the user has
/// opted in and [FirebasePushTokens.token] is first asked for one.
library;

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/firebase_options.dart';
import 'package:zunia_mobile/notifications/push_registration.dart';

/// What a push said.
@immutable
class PushEvent {
  const PushEvent({this.chainId, this.txHash});

  factory PushEvent.fromData(Map<String, dynamic> data) {
    String? text(String key) {
      final value = data[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return PushEvent(chainId: text('chainId'), txHash: text('txHash'));
  }

  final String? chainId;
  final String? txHash;
}

/// Runs in a background isolate when a push arrives while the app is not in
/// the foreground. The system shows the notification itself, and the wallet
/// is locked there, so there is nothing to read.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

abstract final class PushMessaging {
  static bool _available = false;
  static Future<void>? _init;
  static PushEvent? _pendingOpen;
  static final _messages = StreamController<PushEvent>.broadcast();
  static final _opens = StreamController<PushEvent>.broadcast();
  static final _tokens = StreamController<String>.broadcast();

  /// Firebase is set up on this device.
  static bool get available => _available;

  /// Pushes received while the app is in the foreground.
  static Stream<PushEvent> get messages => _messages.stream;

  /// Pushes the user tapped while the app was running in the background.
  static Stream<PushEvent> get opens => _opens.stream;

  /// New Firebase tokens.
  static Stream<String> get tokenRefreshes => _tokens.stream;

  /// The tapped push that launched the app, once.
  static PushEvent? takePendingOpen() {
    final event = _pendingOpen;
    _pendingOpen = null;
    return event;
  }

  /// Sets Firebase up. Never prompts, never creates a token, never throws.
  static Future<void> init() => _init ??= _setUp();

  static Future<void> _setUp() async {
    final mobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (!mobile) return;
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      FirebaseMessaging.onMessage
          .listen((m) => _messages.add(PushEvent.fromData(m.data)));
      FirebaseMessaging.onMessageOpenedApp.listen(
        (m) => _opened(PushEvent.fromData(m.data)),
      );
      // ignore: deprecated_member_use (see FirebasePushTokens)
      FirebaseMessaging.instance.onTokenRefresh.listen(_tokens.add);
      _available = true;
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _opened(PushEvent.fromData(initial.data));
    } on Object catch (e) {
      debugPrint('push unavailable: $e');
    }
  }

  static void _opened(PushEvent event) {
    if (_opens.hasListener) {
      _opens.add(event);
    } else {
      _pendingOpen = event;
    }
  }
}

/// The Firebase token, for [PushRegistrar].
///
/// firebase_messaging 17 deprecates the registration token for the
/// installation-ID (FID) direct-send model. Zunia's server sends with the
/// FCM HTTP v1 API, whose `message.token` is this registration token, so the
/// token API stays until the server moves to direct send.
class FirebasePushTokens implements PushTokens {
  @override
  Stream<String> get refreshed => PushMessaging.tokenRefreshes;

  @override
  Future<String?> token() async {
    await PushMessaging.init();
    if (!PushMessaging.available) return null;
    try {
      final messaging = FirebaseMessaging.instance;
      // The user opted in: from now on Firebase keeps the token fresh.
      await messaging.setAutoInitEnabled(true);
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        // The Firebase token needs the APNs one. Asking for provisional
        // authorization never prompts (the user already chose), and makes
        // sure the app is registered with APNs; the token follows shortly.
        await messaging.requestPermission(
          badge: false,
          provisional: true,
        );
        for (var i = 0; i < 20; i++) {
          if (await messaging.getAPNSToken() != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        if (await messaging.getAPNSToken() == null) return null;
      }
      // ignore: deprecated_member_use
      return await messaging.getToken();
    } on Object catch (e) {
      debugPrint('push token: $e');
      return null;
    }
  }

  @override
  Future<void> delete() async {
    if (!PushMessaging.available) return;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.setAutoInitEnabled(false);
      // ignore: deprecated_member_use
      await messaging.deleteToken();
    } on Object catch (e) {
      debugPrint('push token delete: $e');
    }
  }
}
