import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key});

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> {
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _revealed = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlockPassword() async {
    if (_password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vault =
          await ref.read(keystoreProvider).unlockWithPassword(_password.text);
      _openSession(vault, _password.text);
    } catch (_) {
      setState(() => _error = 'That password does not match this vault.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opening the sealed keyring is what puts the phrase in memory; without it
  /// no address can be derived for the session.
  void _openSession(UnlockedVault vault, String password) {
    final phrase = WalletKernel.instance.openKeyring(
      envelopeJson: vault.envelopeJson,
      password: password,
    );
    ref.read(phraseProvider.notifier).state = phrase;
    ref.read(sessionProvider.notifier).state = vault;
  }

  Future<void> _unlockBio() async {
    if (_password.text.isEmpty) {
      setState(
        () => _error =
            'Enter your password first, then confirm with biometrics.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vault = await ref
          .read(keystoreProvider)
          .unlockWithBiometrics(password: _password.text);
      _openSession(vault, _password.text);
    } catch (_) {
      setState(() => _error = 'Biometric unlock failed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final filled = _password.text.length.clamp(0, 8);

    return Scaffold(
      body: SafeArea(
        child: ZuniaScreenScaffold(
          body: Stack(
            children: [
              Positioned(
                left: MediaQuery.sizeOf(context).width / 2 - 160,
                top: 80,
                child: IgnorePointer(
                  child: Container(
                    width: 320,
                    height: 320,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          s.accent.withValues(alpha: 0.44 * s.bloom),
                          s.accent.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(26, 36, 26, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 28),
                    Center(
                      child: Container(
                        width: 92,
                        height: 92,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: s.glass,
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(color: s.lineStrong),
                        ),
                        child: Icon(
                          Icons.fingerprint,
                          size: 44,
                          color: s.fg,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Lock with biometrics',
                      textAlign: TextAlign.center,
                      style: zuniaSans(
                        fontSize: 24,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.8,
                        color: s.fg,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Biometrics unlock the wallet on this device. '
                      'Your password is the fallback.',
                      textAlign: TextAlign.center,
                      style: zuniaSans(
                        fontSize: 13.5,
                        height: 1.6,
                        color: s.fgMuted,
                      ),
                    ),
                    const SizedBox(height: 26),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < 8; i++) ...[
                          if (i > 0) const SizedBox(width: 9),
                          Container(
                            width: 13,
                            height: 13,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i < filled ? s.accent : s.glass2,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 28),
                    ZuniaInput(
                      controller: _password,
                      hint: 'Password',
                      obscureText: !_revealed,
                      autofocus: true,
                      autofillHints: const [AutofillHints.password],
                      errorText: _error,
                      onChanged: (_) => setState(() {
                        if (_error != null) _error = null;
                      }),
                      onSubmitted: (_) => _unlockPassword(),
                      trailing: GestureDetector(
                        onTap: () => setState(() => _revealed = !_revealed),
                        child: Text(
                          _revealed ? 'HIDE' : 'SHOW',
                          style: zuniaMono(
                            fontSize: 9.5,
                            letterSpacing: 1.2,
                            color: s.fgMuted,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          footer: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ZuniaButton(
                label: 'Enable biometrics',
                size: ZuniaButtonSize.lg,
                loading: _busy,
                leading: const Icon(Icons.fingerprint),
                onPressed: _busy ? null : _unlockBio,
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _busy ? null : _unlockPassword,
                child: Text(
                  'Password only',
                  style: zuniaMono(fontSize: 12, color: s.fgDim),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
