import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/security/app_restart.dart';
import 'package:zunia_mobile/security/screen_security.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/ui/password_field.dart';
import 'package:zunia_ui/zunia_ui.dart';

const _confirmWord = 'REMOVE';

/// Erases the wallet from this device, as the extension's Remove wallet and
/// Forgot password screens do.
///
/// From Security it takes the password and the word REMOVE. From the unlock
/// screen ([forgotPassword]) there is no password to give: the only way back
/// in is to erase and restore from the recovery phrase, so it takes the word
/// alone and says so.
class RemoveWalletScreen extends ConsumerStatefulWidget {
  const RemoveWalletScreen({super.key, this.forgotPassword = false});

  final bool forgotPassword;

  @override
  ConsumerState<RemoveWalletScreen> createState() => _RemoveWalletScreenState();
}

class _RemoveWalletScreenState extends ConsumerState<RemoveWalletScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _ready =>
      _confirm.text.trim().toUpperCase() == _confirmWord &&
      (widget.forgotPassword || _password.text.isNotEmpty);

  Future<void> _remove() async {
    if (!_ready || _busy) return;
    final sure = await showZuniaConfirm(
      context,
      title: 'Remove this wallet?',
      message: 'Every account, its keys, connected apps and site permissions '
          'are erased from this device. Only your recovery phrases can bring '
          'the accounts back.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!sure || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(vaultSessionProvider).removeWallet(
            password: widget.forgotPassword ? null : _password.text,
          );
      unawaited(ZuniaHaptics.success());
      if (!mounted) return;
      // Fresh providers and navigation: nothing of the old wallet survives
      // in memory, and the app opens on onboarding.
      AppRestart.restart(context);
    } on WrongPasswordException catch (e) {
      _fail(e.message);
    } on PasswordThrottledException catch (e) {
      _fail(e.message);
    } on KeystoreException catch (e) {
      _fail(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fail(String message) {
    unawaited(ZuniaHaptics.error());
    if (mounted) setState(() => _error = message);
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
            title: widget.forgotPassword ? 'Reset wallet' : 'Remove wallet',
            onBack: _busy ? null : () => Navigator.of(context).pop(),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                ZuniaCallout(
                  tone: ZuniaCalloutTone.danger,
                  title: widget.forgotPassword
                      ? 'There is no password recovery'
                      : 'This erases the wallet from this device',
                  body: widget.forgotPassword
                      ? 'The password never leaves this device, so it cannot be '
                          'reset. To get back in, remove the wallet here and '
                          'restore it with your 12 or 24 word recovery phrase.'
                      : 'Only your recovery phrases can bring the accounts '
                          'back. Make sure every one is written down before '
                          'you continue.',
                ),
                const SizedBox(height: 14),
                Text(
                  widget.forgotPassword
                      ? 'Without the phrase, removing the wallet is permanent. '
                          'Each account added with its own phrase needs that '
                          'phrase to come back.'
                      : 'Connected apps are disconnected, site permissions, the '
                          'address book and biometric unlock are erased. Display '
                          'preferences stay.',
                  style: zuniaSans(fontSize: 13, height: 1.55, color: s.fgMuted),
                ),
                const SizedBox(height: 20),
                if (!widget.forgotPassword) ...[
                  ZuniaPasswordField(
                    controller: _password,
                    label: 'PASSWORD',
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() => _error = null),
                  ),
                  const SizedBox(height: 14),
                ],
                ZuniaInput(
                  controller: _confirm,
                  label: 'TYPE $_confirmWord TO CONFIRM',
                  hint: _confirmWord,
                  onChanged: (_) => setState(() => _error = null),
                  onSubmitted: (_) => _remove(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  ZuniaCallout(body: _error!, tone: ZuniaCalloutTone.danger),
                ],
              ],
            ),
            footer: ZuniaButton(
              label: widget.forgotPassword ? 'Remove and restore' : 'Remove wallet',
              variant: ZuniaButtonVariant.danger,
              size: ZuniaButtonSize.lg,
              loading: _busy,
              onPressed: _ready && !_busy ? _remove : null,
            ),
          ),
        ),
      ),
    );
  }
}
