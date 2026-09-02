import 'package:flutter/services.dart';

/// FLAG_SECURE / screenshot-blocking bridge.
///
/// Android: implement in [MainActivity] by handling `setFlagSecure` and calling
/// `window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, ...)`.
/// iOS: Flutter cannot fully block screenshots; pair with blur overlays and
/// `UIScreen.capturedDidChangeNotification` listeners in AppDelegate when needed.
class FlagSecure {
  FlagSecure._();

  static const MethodChannel _channel = MethodChannel('com.zuniawallet.zunia_mobile/secure');

  /// Enable or disable FLAG_SECURE. No-ops if the native side is not wired yet.
  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setFlagSecure', {'enabled': enabled});
    } on MissingPluginException {
      // Stub until MainActivity / AppDelegate handlers ship.
    } on PlatformException {
      // Ignore; screen security is defense-in-depth.
    }
  }
}
