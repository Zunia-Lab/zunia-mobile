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
  bool _leaving = false;
  bool? _bioAvailable;
  bool? _bioEnabled;

  @override
  void initState() {
    super.initState();
    _loadBioState();
  }

  Future<void> _loadBioState() async {
    final keystore = ref.read(keystoreProvider);
    final available = await keystore.biometricsAvailable;
    final enabled = available && await keystore.hasBiometricUnlock;
    if (!mounted || _leaving) return;
    setState(() {
      _bioAvailable = available;
      _bioEnabled = enabled;
    });
    if (enabled) {
      // Offer Face ID / fingerprint immediately on cold start.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_busy && !_leaving) _unlockBio();
      });
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  /// Opens the session only after the password field is off-screen.
  ///
  /// Setting [sessionProvider] swaps [_AppGate] to [RootShell], which disposes
  /// this State (and `_password`). If a [TextField] is still mounted that
  /// frame, Flutter tries to attach listeners to the disposed controller and
  /// blows the layout (huge RenderFlex overflow). Tear the field down first.
  Future<void> _openSession(UnlockedVault vault, String password) async {
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _leaving = true);
    // Let the TextField unmount before we dispose its controller via State.dispose.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    final phrase = WalletKernel.instance.openKeyring(
      envelopeJson: vault.envelopeJson,
      password: password,
    );
    ref.read(phraseProvider.notifier).state = phrase;
    ref.read(sessionProvider.notifier).state = vault;
    // Repair account metadata wiped by an earlier restore race.
    await ref.read(walletProvider.notifier).ensureDefaultAccount();
  }

  Future<void> _unlockPassword() async {
    if (_password.text.isEmpty || _leaving) return;
    final password = _password.text;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vault =
          await ref.read(keystoreProvider).unlockWithPassword(password);
      await _openSession(vault, password);
    } catch (_) {
      if (!mounted || _leaving) return;
      setState(() => _error = 'That password does not match this vault.');
    } finally {
      if (mounted && !_leaving) setState(() => _busy = false);
    }
  }

  Future<void> _unlockBio() async {
    if (_leaving) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final keystore = ref.read(keystoreProvider);
      if (_bioEnabled == true) {
        final vault = await keystore.unlockWithBiometrics();
        final password = await keystore.readBiometricPassword();
        if (password == null) {
          throw KeystoreException('Biometrics not enabled');
        }
        await _openSession(vault, password);
        return;
      }

      // First-time enrollment: password required, then store for next launch.
      if (_password.text.isEmpty) {
        if (!mounted || _leaving) return;
        setState(
          () => _error =
              'Enter your password, then confirm with biometrics to enable.',
        );
        return;
      }
      final password = _password.text;
      await keystore.enableBiometricUnlock(password);
      final vault = await keystore.unlockWithPassword(password);
      await _openSession(vault, password);
      if (mounted && !_leaving) setState(() => _bioEnabled = true);
    } on KeystoreException catch (e) {
      if (!mounted || _leaving) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted || _leaving) return;
      setState(() => _error = 'Biometric unlock failed.');
    } finally {
      if (mounted && !_leaving) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);

    // Keep a stable dark shell while AppGate swaps to RootShell so the
    // password TextField is already gone before State.dispose runs.
    if (_leaving) {
      return Scaffold(backgroundColor: s.bg);
    }

    final filled = _password.text.length.clamp(0, 8);
    final bioReady = _bioEnabled == true;
    final bioAvailable = _bioAvailable == true;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
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
                          bioReady ? Icons.lock_open_outlined : Icons.lock_outline,
                          size: 44,
                          color: s.fg,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Welcome back',
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
                      bioReady
                          ? 'Unlock with biometrics, or enter your password.'
                          : 'Enter your password to unlock this wallet.',
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
                      autofocus: !bioReady,
                      autofillHints: const [AutofillHints.password],
                      errorText: _error,
                      onChanged: (_) {
                        if (!mounted || _leaving) return;
                        setState(() {
                          if (_error != null) _error = null;
                        });
                      },
                      onSubmitted: (_) => _unlockPassword(),
                      trailing: GestureDetector(
                        onTap: () {
                          if (!mounted || _leaving) return;
                          setState(() => _revealed = !_revealed);
                        },
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (bioReady) ...[
                ZuniaButton(
                  label: 'Unlock with biometrics',
                  size: ZuniaButtonSize.lg,
                  loading: _busy,
                  leading: const Icon(Icons.fingerprint),
                  onPressed: _busy ? null : _unlockBio,
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _busy ? null : _unlockPassword,
                  child: Text(
                    'Use password',
                    style: zuniaMono(fontSize: 12, color: s.fgDim),
                  ),
                ),
              ] else ...[
                ZuniaButton(
                  label: 'Unlock',
                  size: ZuniaButtonSize.lg,
                  loading: _busy,
                  onPressed: _busy ? null : _unlockPassword,
                ),
                if (bioAvailable) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy ? null : _unlockBio,
                    child: Text(
                      'Enable biometrics',
                      style: zuniaMono(fontSize: 12, color: s.fgDim),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
