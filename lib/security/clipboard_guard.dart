import 'dart:async';

import 'package:flutter/services.dart';
import 'package:zunia_mobile/security/mnemonic_security_config.dart';

/// Copies text and clears the system clipboard after a timeout.
class ClipboardGuard {
  ClipboardGuard._();

  static Timer? _timer;

  /// Copy [text], then clear after [MnemonicSecurityConfig.clipboardAutoClearSeconds].
  /// Returns false if mnemonic copy is disabled by policy and [force] is false.
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
    await Clipboard.setData(ClipboardData(text: text));
    _timer?.cancel();
    final seconds = MnemonicSecurityConfig.clipboardAutoClearSeconds;
    _timer = Timer(Duration(seconds: seconds), clear);
    return true;
  }

  static Future<void> clear() async {
    _timer?.cancel();
    _timer = null;
    await Clipboard.setData(const ClipboardData(text: ''));
  }
}
