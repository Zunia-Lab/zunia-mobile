import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/remove_wallet_screen.dart';
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_mobile/security/screen_security.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/state/security_settings.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/ui/password_field.dart';
import 'package:zunia_mobile/ui/shake.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Unlocks the vault: biometrics first when they are on (asked for as soon
/// as the screen is on screen), the password always.
///
/// Wrong passwords back off as in the extension (three free, then 2 s
/// doubling up to 5 minutes, kept across restarts); the countdown shows on
/// the button. [overlay] is the lock screen drawn over an app that was
/// unlocked before (see `SecurityShell`); otherwise this is the cold start.
class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key, this.overlay = false});

  final bool overlay;

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen>
    with WidgetsBindingObserver {
  final _password = TextEditingController();
  final _focus = FocusNode();
  final _shake = GlobalKey<ShakeState>();

  String? _error;
  String? _notice;
  bool _busy = false;
  bool _leaving = false;
  bool _bioReady = false;
  BiometricAvailability _bio = BiometricAvailability.unavailable;
  bool _legacy = false;

  /// Biometrics were offered automatically since the app last came to the
  /// foreground. Cancelling must not bring the prompt straight back.
  bool _autoPrompted = false;

  DateTime? _retryAt;
  Timer? _ticker;

  VaultSession get _session => ref.read(vaultSessionProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    final session = _session;
    final format = await ref.read(keystoreProvider).format();
    final availability = await session.biometricAvailability();
    final ready = availability.available && await session.biometricsReady();
    final throttle = await session.throttle();
    if (!mounted || _leaving) return;
    setState(() {
      _legacy = format == VaultFormat.legacy;
      _bio = availability;
      _bioReady = ready;
      if (session.biometricsWereInvalidated) {
        _notice = '${_bioLabel(capital: true)} changed on this device, so '
            'biometric unlock was turned off. Unlock with your password, then '
            'turn it back on in Security.';
      } else if (_legacy) {
        _notice = 'Zunia now keeps your wallet in this device\'s secure '
            'storage. Enter your password once to move it there. Biometric '
            'unlock needs to be turned on again afterwards.';
      }
    });
    _holdUntil(DateTime.fromMillisecondsSinceEpoch(throttle.retryAtMs));
    if (ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoPrompt());
    } else if (!widget.overlay ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _focus.requestFocus();
    }
  }

  /// Offers biometrics once per return to the foreground, never while the
  /// app is in the background (an "immediately" lock happens there).
  void _autoPrompt() {
    if (!mounted || _leaving || _busy || !_bioReady || _autoPrompted) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _autoPrompted = true;
    _unlockBio();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _autoPrompted = false;
    } else if (state == AppLifecycleState.resumed) {
      _autoPrompt();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _focus.dispose();
    _password.dispose();
    super.dispose();
  }

  String _bioLabel({bool capital = false}) {
    final label = _bio.label(apple: ZuniaPlatform.isCupertino(context));
    return capital ? label[0].toUpperCase() + label.substring(1) : label;
  }

  void _holdUntil(DateTime at) {
    _ticker?.cancel();
    if (!at.isAfter(DateTime.now())) {
      if (_retryAt != null && mounted) setState(() => _retryAt = null);
      return;
    }
    setState(() => _retryAt = at);
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!mounted) return t.cancel();
      if (!DateTime.now().isBefore(_retryAt!)) {
        t.cancel();
        setState(() => _retryAt = null);
      } else {
        setState(() {});
      }
    });
  }

  int get _waitSeconds {
    final at = _retryAt;
    if (at == null) return 0;
    final ms = at.difference(DateTime.now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  /// The gate swaps this screen out as soon as the session is set. Take the
  /// text field down first: a TextField still mounted that frame would
  /// attach to a controller State.dispose is about to dispose.
  Future<void> _begin(VaultUnlock result) async {
    unawaited(ZuniaHaptics.success());
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _leaving = true);
    await Future<void>.delayed(Duration.zero);
    try {
      await _session.begin(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _leaving = false;
        _error = 'Could not open the wallet: $e';
      });
    }
  }

  Future<void> _unlockPassword({bool thenEnableBio = false}) async {
    final password = _password.text;
    if (password.isEmpty || _busy || _leaving || _waitSeconds > 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (thenEnableBio) {
        try {
          await _session.enableBiometrics(password, _prompt('Turn on ${_bioLabel()}'));
        } on BiometricException {
          // Unlocking still goes ahead; Security has the switch to retry.
        }
      }
      // Throws before the session changes, so the screen is still here to
      // show what went wrong.
      final result = await _session.openVault(password);
      await _begin(result);
    } on WrongPasswordException catch (e) {
      _fail(e.message, e.wait);
    } on PasswordThrottledException catch (e) {
      _fail(e.message, e.wait);
    } on KeystoreException catch (e) {
      _fail(e.message, Duration.zero);
    } finally {
      if (mounted && !_leaving) setState(() => _busy = false);
    }
  }

  BiometricPromptText _prompt(String title) => BiometricPromptText(
        title: title,
        subtitle: 'Your password still works',
      );

  Future<void> _unlockBio() async {
    if (_busy || _leaving) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final password =
          await _session.passwordFromBiometrics(_prompt('Unlock Zunia'));
      final result = await _session.openVault(password);
      await _begin(result);
    } on BiometricException catch (e) {
      if (!mounted) return;
      switch (e.failure) {
        case BiometricFailure.cancelled:
          _focus.requestFocus();
        case BiometricFailure.invalidated:
          setState(() {
            _bioReady = false;
            _notice = '${_bioLabel(capital: true)} changed on this device, so '
                'biometric unlock was turned off. Unlock with your password, '
                'then turn it back on in Security.';
          });
          _focus.requestFocus();
        case BiometricFailure.lockout:
          setState(() => _notice = '${_bioLabel(capital: true)} is locked '
              'after too many attempts. Use your password.');
          _focus.requestFocus();
        default:
          setState(() => _notice =
              '${_bioLabel(capital: true)} did not work. Use your password.');
          _focus.requestFocus();
      }
    } on WrongPasswordException {
      // The stored password no longer opens the vault.
      await _session.disableBiometrics();
      if (!mounted) return;
      setState(() {
        _bioReady = false;
        _notice = 'Biometric unlock was out of date and is now off. Use your '
            'password.';
      });
    } on PasswordThrottledException catch (e) {
      _fail(e.message, e.wait);
    } on KeystoreException catch (e) {
      _fail(e.message, Duration.zero);
    } finally {
      if (mounted && !_leaving) setState(() => _busy = false);
    }
  }

  void _fail(String message, Duration wait) {
    if (!mounted || _leaving) return;
    unawaited(ZuniaHaptics.error());
    _shake.currentState?.shake();
    _password.clear();
    setState(() => _error = message);
    if (wait > Duration.zero) _holdUntil(DateTime.now().add(wait));
    _focus.requestFocus();
  }

  void _forgot() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const RemoveWalletScreen(forgotPassword: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);

    if (_leaving) return Scaffold(backgroundColor: s.bg);

    final wallet = ref.watch(walletProvider);
    final account = wallet.active;
    final autoLock = ref.watch(securitySettingsProvider).autoLock;
    final wait = _waitSeconds;
    final throttled = wait > 0;
    final cupertino = ZuniaPlatform.isCupertino(context);

    return SensitiveScreen(
      child: PopScope(
        // The lock screen has nowhere to go back to.
        canPop: !widget.overlay,
        child: Scaffold(
          backgroundColor: widget.overlay ? s.bg : Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: ZuniaScreenScaffold(
              body: Stack(
                children: [
                  Positioned(
                    left: MediaQuery.sizeOf(context).width / 2 - 160,
                    top: 60,
                    child: IgnorePointer(
                      child: Container(
                        width: 320,
                        height: 320,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              s.accent.withValues(alpha: 0.38 * s.bloom),
                              s.accent.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: account == null
                              ? Icon(Icons.lock_outline, size: 44, color: s.fg)
                              : ZuniaWalletAvatar(
                                  seed: account.avatar,
                                  size: 72,
                                  semanticLabel: account.name,
                                ),
                        ),
                        const SizedBox(height: 20),
                        Semantics(
                          header: true,
                          child: Text(
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
                        ),
                        const SizedBox(height: 8),
                        Text(
                          account == null
                              ? 'Enter your password to unlock this wallet.'
                              : wallet.accounts.length > 1
                                  ? '${account.name} and ${wallet.accounts.length - 1} '
                                      'more. One password unlocks them all.'
                                  : 'Enter your password to unlock ${account.name}.',
                          textAlign: TextAlign.center,
                          style: zuniaSans(
                            fontSize: 13.5,
                            height: 1.5,
                            color: s.fgMuted,
                          ),
                        ),
                        if (_notice != null) ...[
                          const SizedBox(height: 18),
                          ZuniaCallout(
                            body: _notice!,
                            tone: ZuniaCalloutTone.info,
                          ),
                        ],
                        const SizedBox(height: 26),
                        Shake(
                          key: _shake,
                          child: ZuniaPasswordField(
                            controller: _password,
                            focusNode: _focus,
                            errorText: _error,
                            onChanged: (_) {
                              if (_error != null) setState(() => _error = null);
                            },
                            onSubmitted: (_) => _unlockPassword(),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Center(
                          child: TextButton(
                            onPressed: _busy ? null : _forgot,
                            child: Text(
                              'Forgot password? Restore with your phrase',
                              textAlign: TextAlign.center,
                              style: zuniaSans(fontSize: 12.5, color: s.fgDim),
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
                  ListenableBuilder(
                    listenable: _password,
                    builder: (context, _) => ZuniaButton(
                      label: throttled ? 'Try again in $wait s' : 'Unlock',
                      size: ZuniaButtonSize.lg,
                      loading: _busy,
                      onPressed: _password.text.isEmpty || throttled
                          ? null
                          : () => _unlockPassword(),
                    ),
                  ),
                  if (_bioReady) ...[
                    const SizedBox(height: 10),
                    ZuniaButton(
                      label: 'Unlock with ${_bioLabel()}',
                      size: ZuniaButtonSize.lg,
                      variant: ZuniaButtonVariant.secondary,
                      leading: Icon(
                        _bio.kind == BiometricKind.face
                            ? (cupertino ? Icons.face_outlined : Icons.face_retouching_natural)
                            : Icons.fingerprint,
                      ),
                      onPressed: _busy || throttled ? null : _unlockBio,
                    ),
                  ] else if (_bio.available && !_legacy) ...[
                    const SizedBox(height: 4),
                    ListenableBuilder(
                      listenable: _password,
                      builder: (context, _) => TextButton(
                        onPressed: _busy || throttled || _password.text.isEmpty
                            ? null
                            : () => _unlockPassword(thenEnableBio: true),
                        child: Text(
                          'Unlock and turn on ${_bioLabel()}',
                          style: zuniaSans(fontSize: 13, color: s.fgMuted),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock_clock_outlined, size: 14, color: s.fgDim),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          autoLock == AutoLockDelay.immediately
                              ? 'LOCKS WHEN YOU LEAVE THE APP'
                              : 'LOCKS AFTER ${autoLock.label.toUpperCase()} IDLE',
                          style: zuniaMono(
                            fontSize: 9.5,
                            letterSpacing: 1.1,
                            color: s.fgDim,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
