import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_mobile/security/screen_security.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/ui/password_field.dart';
import 'package:zunia_mobile/ui/password_strength_meter.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Re-seals every account's phrase under a new password, in one write.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  final _nextFocus = FocusNode();
  final _confirmFocus = FocusNode();
  String? _currentError;
  String? _nextError;
  String? _confirmError;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    _nextFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  bool _validate() {
    String? nextError;
    String? confirmError;
    if (_next.text.length < kMinPasswordLength) {
      nextError = 'Use at least $kMinPasswordLength characters';
    } else if (_next.text == _current.text) {
      nextError = 'Choose a password different from the current one';
    }
    if (_confirm.text != _next.text) confirmError = 'Passwords do not match';
    setState(() {
      _nextError = nextError;
      _confirmError = confirmError;
    });
    return nextError == null && confirmError == null;
  }

  Future<void> _save() async {
    if (_busy || _current.text.isEmpty || !_validate()) return;
    setState(() {
      _busy = true;
      _currentError = null;
    });
    try {
      final outcome = await ref.read(vaultSessionProvider).changePassword(
            current: _current.text,
            next: _next.text,
            prompt: const BiometricPromptText(
              title: 'Keep biometric unlock',
              subtitle: 'Confirm to use it with the new password',
              cancel: 'Turn it off',
            ),
          );
      unawaited(ZuniaHaptics.success());
      if (!mounted) return;
      await showZuniaAlert<void>(
        context,
        title: 'Password changed',
        message: switch (outcome) {
          BiometricOutcome.turnedOff =>
            'Every account now opens with the new password. Biometric unlock '
                'was turned off; turn it on again in Security.',
          _ => 'Every account now opens with the new password.',
        },
        actions: const [ZuniaAlertAction(label: 'OK', isDefault: true)],
      );
      if (mounted) Navigator.of(context).pop();
    } on WrongPasswordException catch (e) {
      _failCurrent(e.message);
    } on PasswordThrottledException catch (e) {
      _failCurrent(e.message);
    } on KeystoreException catch (e) {
      _failCurrent(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _failCurrent(String message) {
    unawaited(ZuniaHaptics.error());
    if (!mounted) return;
    _current.clear();
    setState(() => _currentError = message);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return SensitiveScreen(
      child: Scaffold(
        backgroundColor: s.bg,
        body: SafeArea(
          bottom: false,
          child: ZuniaScreenScaffold(
            title: 'Change password',
            onBack: _busy ? null : () => Navigator.of(context).pop(),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                Text(
                  'The password unlocks every account on this device. It '
                  'never recovers a phrase: keep the phrases written down.',
                  style: zuniaSans(fontSize: 13, height: 1.55, color: s.fgMuted),
                ),
                const SizedBox(height: 20),
                ZuniaPasswordField(
                  controller: _current,
                  label: 'CURRENT PASSWORD',
                  errorText: _currentError,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() => _currentError = null),
                  onSubmitted: (_) => _nextFocus.requestFocus(),
                ),
                const SizedBox(height: 16),
                ZuniaPasswordField(
                  controller: _next,
                  focusNode: _nextFocus,
                  label: 'NEW PASSWORD',
                  hint: 'At least $kMinPasswordLength characters',
                  newPassword: true,
                  errorText: _nextError,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() => _nextError = null),
                  onSubmitted: (_) => _confirmFocus.requestFocus(),
                ),
                const SizedBox(height: 12),
                PasswordStrengthMeter(password: _next.text),
                const SizedBox(height: 16),
                ZuniaPasswordField(
                  controller: _confirm,
                  focusNode: _confirmFocus,
                  label: 'CONFIRM NEW PASSWORD',
                  newPassword: true,
                  errorText: _confirmError,
                  onChanged: (_) => setState(() => _confirmError = null),
                  onSubmitted: (_) => _save(),
                ),
              ],
            ),
            footer: ZuniaButton(
              label: _busy ? 'Re-sealing…' : 'Change password',
              size: ZuniaButtonSize.lg,
              loading: _busy,
              onPressed: _busy ||
                      _current.text.isEmpty ||
                      _next.text.isEmpty ||
                      _confirm.text.isEmpty
                  ? null
                  : _save,
            ),
          ),
        ),
      ),
    );
  }
}
