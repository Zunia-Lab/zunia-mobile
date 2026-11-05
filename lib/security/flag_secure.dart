import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android FLAG_SECURE: the window is left out of screenshots, screen
/// recordings, casting and the recents thumbnail.
///
/// Counted, not toggled: each sensitive screen holds a claim while it is
/// mounted, so closing one (a reveal sheet over the unlock screen, say) does
/// not drop the flag the other still needs. iOS has no equivalent; see
/// `SensitiveScreen` for what it does there.
class FlagSecure {
  FlagSecure._();

  static const MethodChannel _channel =
      MethodChannel('com.zuniawallet.zunia_mobile/secure');

  static int _claims = 0;
  static bool? _applied;

  @visibleForTesting
  static int get claims => _claims;

  /// A sensitive screen appeared.
  static void claim() {
    _claims++;
    _apply();
  }

  /// That screen went away.
  static void release() {
    if (_claims > 0) _claims--;
    _apply();
  }

  static void _apply() {
    final want = _claims > 0;
    if (_applied == want) return;
    _applied = want;
    setEnabled(want);
  }

  /// Sets the flag directly. Prefer [claim] / [release].
  static Future<void> setEnabled(bool enabled) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setFlagSecure', {'enabled': enabled});
    } on MissingPluginException {
      // No native side (tests).
    } on PlatformException {
      // Defence in depth; the screen still works without it.
    }
  }
}
