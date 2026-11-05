/// "Is it really you?" before a signature, a reveal or a removal.
///
/// - [confirmSigning]: what every signing flow calls just before it signs.
///   Returns true at once unless Settings > Security > "Password on every
///   signature" is on; then it asks for biometrics (when biometric unlock is
///   on) or the password, as the extension's `requirePasswordOnSign` does.
/// - [confirmIdentity]: always asks. For revealing a phrase and other acts
///   that do not depend on the setting.
/// - [requestPassword]: always asks and returns the password itself, for
///   the operations that need it (sealing a new account's phrase).
/// - [SigningGate.confirm]: the same as [confirmSigning] for code without a
///   `BuildContext` (TxEngine, services). The app installs it at start.
///
/// Every password typed here goes through the keystore's throttle.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_mobile/security/password_prompt.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/state/security_settings.dart';

/// Asks for biometrics or the password before a signature when the user
/// turned "Password on every signature" on. True when the user confirmed or
/// the setting is off; false when they backed out (do not sign).
///
/// [reason] is shown in the prompt, e.g. "Sign: send 12 OSMO".
Future<bool> confirmSigning(
  BuildContext context,
  WidgetRef ref, {
  required String reason,
}) async {
  final settings = ref.read(securitySettingsProvider.notifier);
  await settings.ready;
  if (!ref.read(securitySettingsProvider).passwordOnSign) return true;
  if (!context.mounted) return false;
  return confirmIdentity(context, ref, reason: reason);
}

/// Always asks (biometrics if on, else the password). True when confirmed.
Future<bool> confirmIdentity(
  BuildContext context,
  WidgetRef ref, {
  required String reason,
  String title = 'Confirm it\'s you',
}) async {
  final password = await requestPassword(
    context,
    ref,
    reason: reason,
    title: title,
  );
  return password != null;
}

/// The wallet password: from the hardware-bound biometric store when
/// biometric unlock is on (falling back to typing it if the user prefers or
/// the sensor fails), else typed and checked. Null when the user backed out.
Future<String?> requestPassword(
  BuildContext context,
  WidgetRef ref, {
  required String reason,
  String title = 'Enter password',
  bool allowBiometrics = true,
}) {
  return _requestPassword(
    context: context,
    session: ref.read(vaultSessionProvider),
    reason: reason,
    title: title,
    allowBiometrics: allowBiometrics,
  );
}

Future<String?> _requestPassword({
  required BuildContext context,
  required VaultSession session,
  required String reason,
  required String title,
  required bool allowBiometrics,
}) async {
  String? notice;
  if (allowBiometrics && await session.biometricsReady()) {
    try {
      final password = await session.passwordFromBiometrics(
        BiometricPromptText(title: title, subtitle: reason),
      );
      // Cheap next to a signature, and catches a secret left from before a
      // password change made elsewhere.
      await session.verifyPassword(password);
      return password;
    } on BiometricException catch (e) {
      notice = switch (e.failure) {
        BiometricFailure.cancelled => null,
        BiometricFailure.lockout =>
          'Biometrics are locked after too many attempts. Use your password.',
        BiometricFailure.invalidated =>
          'Biometrics changed on this device, so biometric unlock was turned '
              'off. Use your password, then turn it on again in Security.',
        _ => 'Biometrics did not work. Use your password.',
      };
    } on WrongPasswordException {
      await session.disableBiometrics();
      notice = 'Biometric unlock was out of date and is now off. Use your '
          'password.';
    } on PasswordThrottledException catch (e) {
      notice = e.message;
    }
  }
  if (!context.mounted) return null;
  return showPasswordPrompt(
    context,
    title: title,
    reason: reason,
    notice: notice,
    check: session.verifyPassword,
    throttle: session.throttle,
  );
}

/// [confirmSigning] for code that has no `BuildContext` (TxEngine, the
/// Connect services). `SecurityShell` installs the handler when the app
/// starts, with the app's navigator; tests that never build the shell sign
/// without asking, as the setting is off by default.
abstract final class SigningGate {
  static Future<bool> Function(String reason)? _handler;

  /// Installed by `SecurityShell`.
  static void install(Future<bool> Function(String reason)? handler) =>
      _handler = handler;

  /// True when the user confirmed or the setting is off.
  static Future<bool> confirm({required String reason}) =>
      _handler?.call(reason) ?? Future.value(true);
}

/// The handler `SecurityShell` installs: reads the setting from [container]
/// and asks over whatever [navigator] shows.
Future<bool> confirmSigningWith({
  required ProviderContainer container,
  required GlobalKey<NavigatorState> navigator,
  required String reason,
}) async {
  final settings = container.read(securitySettingsProvider.notifier);
  await settings.ready;
  if (!container.read(securitySettingsProvider).passwordOnSign) return true;
  final context = navigator.currentState?.overlay?.context;
  if (context == null || !context.mounted) return false;
  final password = await _requestPassword(
    context: context,
    session: container.read(vaultSessionProvider),
    reason: reason,
    title: 'Confirm it\'s you',
    allowBiometrics: true,
  );
  return password != null;
}
