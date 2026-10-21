/// Biometric unlock whose secret only the hardware will release.
///
/// The wallet password is kept behind a key the operating system hands out
/// after a successful biometric check, and to nothing else:
/// - **iOS**: a Keychain item with `SecAccessControl(.biometryCurrentSet)`,
///   `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`. The Secure Enclave
///   gates the read; enrolling another face or finger, or removing the
///   passcode, makes the item unreadable for good.
/// - **Android**: an AES-256-GCM key in the Android Keystore with
///   `setUserAuthenticationRequired(true)`, valid for one use per
///   authentication (`AUTH_BIOMETRIC_STRONG`, timeout 0), invalidated on new
///   enrolment, used through `BiometricPrompt` with a `CryptoObject`. The
///   ciphertext sits in app-private storage; without the key it is noise.
///
/// Native side: `AppDelegate.swift` (`ZuniaBiometricVault`) and
/// `MainActivity.kt` (`BiometricVault`), on the `zunia/security` channel.
/// There is no software fallback: a build without the native code reports
/// biometrics as unavailable, and the password always works.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What kind of sensor the device offers, for labels ("Face ID", "fingerprint").
enum BiometricKind { face, fingerprint, iris, optic, generic, none }

@immutable
class BiometricAvailability {
  const BiometricAvailability({
    required this.available,
    this.kind = BiometricKind.none,
    this.reason,
  });

  static const unavailable = BiometricAvailability(available: false);

  /// A strong biometric is enrolled and can unlock a hardware-bound key.
  final bool available;
  final BiometricKind kind;

  /// Why not, when [available] is false: `none_enrolled`, `no_hardware`,
  /// `passcode_not_set`, `locked_out`, `unsupported`.
  final String? reason;

  /// "Face ID", "Touch ID", "fingerprint"... for button labels.
  String label({required bool apple}) {
    switch (kind) {
      case BiometricKind.face:
        return apple ? 'Face ID' : 'face';
      case BiometricKind.fingerprint:
        return apple ? 'Touch ID' : 'fingerprint';
      case BiometricKind.optic:
        return 'Optic ID';
      case BiometricKind.iris:
        return 'iris';
      case BiometricKind.generic:
      case BiometricKind.none:
        return 'biometrics';
    }
  }
}

/// Why a biometric read or write did not produce the secret.
enum BiometricFailure {
  /// The user dismissed the prompt or chose the password.
  cancelled,

  /// Enrolled biometrics changed (or the passcode was removed); the stored
  /// secret is gone for good and biometric unlock must be set up again.
  invalidated,

  /// Too many failed attempts; the system locked biometrics for now.
  lockout,

  /// No stored secret.
  notFound,

  /// No strong biometric, or no native support in this build.
  unavailable,

  /// Anything else the platform reported.
  failed,
}

class BiometricException implements Exception {
  const BiometricException(this.failure, [this.detail]);

  final BiometricFailure failure;
  final String? detail;

  @override
  String toString() => 'BiometricException($failure${detail == null ? '' : ': $detail'})';
}

/// Text of the system prompt.
@immutable
class BiometricPromptText {
  const BiometricPromptText({
    required this.title,
    this.subtitle,
    this.cancel = 'Use password',
  });

  final String title;
  final String? subtitle;

  /// Android's negative button. iOS shows its own Cancel.
  final String cancel;

  Map<String, Object?> toMap() =>
      {'title': title, 'subtitle': subtitle, 'cancel': cancel};
}

/// The one secret biometric unlock keeps: the wallet password.
abstract class BiometricVault {
  Future<BiometricAvailability> availability();

  /// Whether a secret is stored, without prompting.
  Future<bool> hasSecret();

  /// Stores [secret] behind the biometric key. Prompts on both platforms:
  /// Android needs the authentication to encrypt, iOS reads the item back
  /// once so turning the feature on is a deliberate act and proven to work.
  Future<void> store(String secret, BiometricPromptText prompt);

  /// The stored secret, after a successful biometric check.
  Future<String> read(BiometricPromptText prompt);

  Future<void> delete();

  /// True while a system biometric prompt is on screen. The privacy cover
  /// stays down for it, since the app only looks inactive.
  bool get promptActive;
}

class PlatformBiometricVault implements BiometricVault {
  PlatformBiometricVault({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('zunia/security');

  final MethodChannel _channel;
  bool _promptActive = false;

  @override
  bool get promptActive => _promptActive;

  @override
  Future<BiometricAvailability> availability() async {
    try {
      final map = await _channel
          .invokeMapMethod<String, Object?>('biometric.availability');
      if (map == null) return BiometricAvailability.unavailable;
      return BiometricAvailability(
        available: map['available'] == true,
        kind: _kind(map['kind'] as String?),
        reason: map['reason'] as String?,
      );
    } on MissingPluginException {
      return const BiometricAvailability(available: false, reason: 'unsupported');
    } on PlatformException {
      return BiometricAvailability.unavailable;
    }
  }

  @override
  Future<bool> hasSecret() async {
    try {
      return await _channel.invokeMethod<bool>('biometric.exists') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> store(String secret, BiometricPromptText prompt) =>
      _prompting(() => _channel.invokeMethod<void>('biometric.store', {
            'secret': secret,
            ...prompt.toMap(),
          }));

  @override
  Future<String> read(BiometricPromptText prompt) async {
    final value = await _prompting(
      () => _channel.invokeMethod<String>('biometric.read', prompt.toMap()),
    );
    if (value == null) throw const BiometricException(BiometricFailure.notFound);
    return value;
  }

  @override
  Future<void> delete() async {
    try {
      await _channel.invokeMethod<void>('biometric.delete');
    } on MissingPluginException {
      // Nothing native, nothing stored.
    }
  }

  Future<T> _prompting<T>(Future<T> Function() call) async {
    _promptActive = true;
    try {
      return await call();
    } on MissingPluginException {
      throw const BiometricException(BiometricFailure.unavailable);
    } on PlatformException catch (e) {
      throw BiometricException(_failure(e.code), e.message);
    } finally {
      // The scene becomes active again a moment after the prompt closes.
      Timer(const Duration(milliseconds: 600), () => _promptActive = false);
    }
  }

  static BiometricKind _kind(String? value) => switch (value) {
        'face' => BiometricKind.face,
        'fingerprint' => BiometricKind.fingerprint,
        'iris' => BiometricKind.iris,
        'optic' => BiometricKind.optic,
        'biometric' => BiometricKind.generic,
        _ => BiometricKind.none,
      };

  static BiometricFailure _failure(String code) => switch (code) {
        'cancelled' => BiometricFailure.cancelled,
        'invalidated' => BiometricFailure.invalidated,
        'lockout' => BiometricFailure.lockout,
        'not_found' => BiometricFailure.notFound,
        'unavailable' => BiometricFailure.unavailable,
        _ => BiometricFailure.failed,
      };
}

/// For tests: a "sensor" that succeeds, or fails with [nextFailure] once.
class FakeBiometricVault implements BiometricVault {
  FakeBiometricVault({this.available = true, this.kind = BiometricKind.face});

  bool available;
  BiometricKind kind;
  String? secret;
  BiometricFailure? nextFailure;
  int prompts = 0;

  @override
  bool get promptActive => false;

  @override
  Future<BiometricAvailability> availability() async =>
      BiometricAvailability(available: available, kind: kind);

  @override
  Future<bool> hasSecret() async => secret != null;

  @override
  Future<void> store(String value, BiometricPromptText prompt) async {
    prompts++;
    _fail();
    secret = value;
  }

  @override
  Future<String> read(BiometricPromptText prompt) async {
    prompts++;
    _fail();
    final value = secret;
    if (value == null) throw const BiometricException(BiometricFailure.notFound);
    return value;
  }

  @override
  Future<void> delete() async => secret = null;

  void _fail() {
    if (!available) throw const BiometricException(BiometricFailure.unavailable);
    final failure = nextFailure;
    if (failure == null) return;
    nextFailure = null;
    if (failure == BiometricFailure.invalidated) secret = null;
    throw BiometricException(failure);
  }
}
