/// Keeping secrets off screenshots, recordings and the app switcher.
///
/// - **Android**: FLAG_SECURE while a sensitive screen (recovery phrase,
///   unlock, password entry) is mounted; not app-wide, so a receive QR or a
///   transaction can still be screenshotted and shared. The recents
///   thumbnail is turned off natively on Android 13+
///   (`setRecentsScreenshotEnabled(false)`) and covered by [SecurityShell]
///   on older versions.
/// - **iOS** cannot block a screenshot. It reports one after the fact
///   (`userDidTakeScreenshotNotification`), which a phrase screen answers
///   with a warning, and it reports recording / mirroring / AirPlay
///   (`UIScreen.isCaptured`), during which [CaptureShield] hides the phrase.
///   The app-switcher cover is native (AppDelegate), since a Flutter frame
///   drawn while the app resigns active is not reliably in the snapshot.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zunia_mobile/security/flag_secure.dart';

/// iOS capture state and screenshot events, from `zunia/security/capture`.
class ScreenCaptureMonitor {
  ScreenCaptureMonitor._();

  static const _events = EventChannel('zunia/security/capture');

  /// The screen is being recorded, mirrored or sent over AirPlay.
  static final ValueNotifier<bool> captured = ValueNotifier(false);

  static final StreamController<void> _screenshots =
      StreamController<void>.broadcast();

  /// A screenshot was just taken (iOS only; Android blocks them where it
  /// matters).
  static Stream<void> get screenshots => _screenshots.stream;

  static StreamSubscription<dynamic>? _subscription;

  /// Starts listening. Only iOS reports anything.
  static void start() {
    if (_subscription != null || kIsWeb || !Platform.isIOS) return;
    _subscription = _events.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        switch (event['type']) {
          case 'captured':
            captured.value = event['value'] == true;
          case 'screenshot':
            _screenshots.add(null);
        }
      },
      onError: (Object _) {},
    );
  }

  @visibleForTesting
  static void debugEmit({bool? isCaptured, bool screenshot = false}) {
    if (isCaptured != null) captured.value = isCaptured;
    if (screenshot) _screenshots.add(null);
  }
}

/// Marks a screen that shows or takes a secret. While it is mounted Android
/// keeps the window out of screenshots and recordings; on iOS [onScreenshot]
/// runs after the user took one.
class SensitiveScreen extends StatefulWidget {
  const SensitiveScreen({super.key, required this.child, this.onScreenshot});

  final Widget child;

  /// Called when iOS reports a screenshot while this screen is on top.
  final VoidCallback? onScreenshot;

  @override
  State<SensitiveScreen> createState() => _SensitiveScreenState();
}

class _SensitiveScreenState extends State<SensitiveScreen> {
  StreamSubscription<void>? _screenshots;

  @override
  void initState() {
    super.initState();
    FlagSecure.claim();
    _screenshots = ScreenCaptureMonitor.screenshots.listen((_) {
      if (!mounted) return;
      // Only the screen the user is looking at answers.
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      widget.onScreenshot?.call();
    });
  }

  @override
  void dispose() {
    _screenshots?.cancel();
    FlagSecure.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Shows [placeholder] instead of [child] while iOS reports the screen as
/// captured (recording, mirroring, AirPlay).
class CaptureShield extends StatelessWidget {
  const CaptureShield({
    super.key,
    required this.child,
    required this.placeholder,
  });

  final Widget child;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ScreenCaptureMonitor.captured,
      builder: (context, captured, _) => captured ? placeholder : child,
    );
  }
}
