/// Security settings: auto-lock delay, password on every signature, and
/// whether biometric unlock is turned on. Plain SharedPreferences: none of it
/// is secret, and every value fails safe (a lost file means a 10 minute lock
/// and no biometric unlock until it is turned on again).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Auto-lock choices. The extension offers 1/5/10/30 min; a phone also gets
/// "immediately", which locks whenever the app leaves the screen.
enum AutoLockDelay {
  immediately(Duration.zero, 'Immediately'),
  oneMinute(Duration(minutes: 1), '1 min'),
  fiveMinutes(Duration(minutes: 5), '5 min'),
  tenMinutes(Duration(minutes: 10), '10 min'),
  thirtyMinutes(Duration(minutes: 30), '30 min');

  const AutoLockDelay(this.duration, this.label);

  final Duration duration;
  final String label;

  /// Same default as extension 0.1.5 (`auto_lock.default_ms: 600000`).
  static const fallback = AutoLockDelay.tenMinutes;

  static AutoLockDelay fromMs(int? ms) {
    if (ms == null) return fallback;
    for (final d in values) {
      if (d.duration.inMilliseconds == ms) return d;
    }
    return fallback;
  }
}

@immutable
class SecuritySettings {
  const SecuritySettings({
    this.autoLock = AutoLockDelay.fallback,
    this.passwordOnSign = false,
    this.biometricUnlock = false,
    this.loaded = false,
  });

  final AutoLockDelay autoLock;

  /// Ask for biometrics or the password before every signature, in the
  /// wallet and for dApps, even while unlocked. Off by default, as in the
  /// extension.
  final bool passwordOnSign;

  /// The user turned biometric unlock on and the hardware-bound secret was
  /// stored. If the secret disappears while this is true, enrolment changed.
  final bool biometricUnlock;

  final bool loaded;

  SecuritySettings copyWith({
    AutoLockDelay? autoLock,
    bool? passwordOnSign,
    bool? biometricUnlock,
    bool? loaded,
  }) =>
      SecuritySettings(
        autoLock: autoLock ?? this.autoLock,
        passwordOnSign: passwordOnSign ?? this.passwordOnSign,
        biometricUnlock: biometricUnlock ?? this.biometricUnlock,
        loaded: loaded ?? this.loaded,
      );
}

const _kAutoLock = 'zunia.security.autoLockMs';
const _kPasswordOnSign = 'zunia.security.passwordOnSign';
const _kBiometric = 'zunia.security.biometricUnlock';

class SecuritySettingsController extends StateNotifier<SecuritySettings> {
  SecuritySettingsController() : super(const SecuritySettings()) {
    ready = _restore();
  }

  /// Completes once the stored values are in [state].
  late final Future<void> ready;

  Future<void> _restore() async {
    final store = await SharedPreferences.getInstance();
    if (!mounted) return;
    state = SecuritySettings(
      autoLock: AutoLockDelay.fromMs(store.getInt(_kAutoLock)),
      passwordOnSign: store.getBool(_kPasswordOnSign) ?? false,
      biometricUnlock: store.getBool(_kBiometric) ?? false,
      loaded: true,
    );
  }

  Future<void> setAutoLock(AutoLockDelay delay) async {
    await ready;
    state = state.copyWith(autoLock: delay);
    final store = await SharedPreferences.getInstance();
    await store.setInt(_kAutoLock, delay.duration.inMilliseconds);
  }

  Future<void> setPasswordOnSign(bool value) async {
    await ready;
    state = state.copyWith(passwordOnSign: value);
    final store = await SharedPreferences.getInstance();
    await store.setBool(_kPasswordOnSign, value);
  }

  /// Only the vault session calls this, after storing or deleting the secret.
  Future<void> setBiometricUnlock(bool value) async {
    await ready;
    state = state.copyWith(biometricUnlock: value);
    final store = await SharedPreferences.getInstance();
    await store.setBool(_kBiometric, value);
  }
}

final securitySettingsProvider =
    StateNotifierProvider<SecuritySettingsController, SecuritySettings>(
  (ref) => SecuritySettingsController(),
);
