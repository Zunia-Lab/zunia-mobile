import 'dart:async';

import 'package:flutter/services.dart';
import 'package:zunia_mobile/security/mnemonic_security_config.dart';

/// Copies text; a recovery phrase is cleared again after 30 s (as in the
/// extension's `useSensitiveClipboard`), when its screen closes, and when the
/// wallet locks.
///
/// A phrase goes through the native `clipboard.copySensitive`: on iOS it is
/// marked local-only (Universal Clipboard does not send it to the user's
/// other devices) and expires on its own; on Android 13+ it is flagged
/// sensitive, so the system's copy preview does not print it on screen.
/// The clear is an unconditional overwrite: reading the clipboard back to
/// check would show iOS's paste prompt.
class ClipboardGuard {
  ClipboardGuard._();

  static const _channel = MethodChannel('zunia/security');
  static Timer? _timer;
  static bool _armed = false;

  /// What the screens say after a sensitive copy.
  static const sensitiveNote =
      'Copied. Zunia clears the clipboard after 30 seconds, when you leave '
      'this screen, or when the wallet locks.';

  /// Copy [text]. With [isMnemonic], the copy is sensitive and cleared after
  /// [MnemonicSecurityConfig.clipboardAutoClearSeconds]. Returns false if
  /// mnemonic copy is disabled by policy and [force] is false.
  static Future<bool> copy(
    String text, {
    bool force = false,
    bool isMnemonic = false,
  }) async {
    if (isMnemonic &&
        !MnemonicSecurityConfig.allowMnemonicCopyDefault &&
        !force) {
      return false;
    }
    _timer?.cancel();
    if (!isMnemonic) {
      // Whatever was armed is no longer on the clipboard.
      _armed = false;
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    }
    const seconds = MnemonicSecurityConfig.clipboardAutoClearSeconds;
    var native = false;
    try {
      await _channel.invokeMethod<void>('clipboard.copySensitive', {
        'text': text,
        'expiresInSeconds': seconds,
      });
      native = true;
    } on MissingPluginException {
      native = false;
    } on PlatformException {
      native = false;
    }
    if (!native) await Clipboard.setData(ClipboardData(text: text));
    _armed = true;
    _timer = Timer(const Duration(seconds: seconds), clear);
    return true;
  }

  /// Clears now if a sensitive copy is still pending.
  static Future<void> clearIfArmed() async {
    if (_armed) await clear();
  }

  static Future<void> clear() async {
    _timer?.cancel();
    _timer = null;
    _armed = false;
    await Clipboard.setData(const ClipboardData(text: ''));
  }
}
