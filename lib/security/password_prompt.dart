import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/security/screen_security.dart';
import 'package:zunia_mobile/ui/password_field.dart';
import 'package:zunia_mobile/ui/shake.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Checks a password: completes when it is right, throws
/// [WrongPasswordException] / [PasswordThrottledException] when not.
typedef PasswordCheck = Future<void> Function(String password);

/// Asks for the wallet password in a sheet and returns it once [check]
/// accepted it, or null if the user backed out. Shows the backoff countdown
/// while too many wrong passwords hold the next attempt.
Future<String?> showPasswordPrompt(
  BuildContext context, {
  required String title,
  required String reason,
  required PasswordCheck check,
  Future<ThrottleState> Function()? throttle,
  String confirmLabel = 'Confirm',
  String? notice,
}) {
  return showZuniaSheet<String>(
    context,
    title: title,
    builder: (ctx) => PasswordPromptBody(
      reason: reason,
      check: check,
      throttle: throttle,
      confirmLabel: confirmLabel,
      notice: notice,
    ),
  );
}

class PasswordPromptBody extends StatefulWidget {
  const PasswordPromptBody({
    super.key,
    required this.reason,
    required this.check,
    this.throttle,
    this.confirmLabel = 'Confirm',
    this.notice,
  });

  final String reason;
  final PasswordCheck check;
  final Future<ThrottleState> Function()? throttle;
  final String confirmLabel;
  final String? notice;

  @override
  State<PasswordPromptBody> createState() => _PasswordPromptBodyState();
}

class _PasswordPromptBodyState extends State<PasswordPromptBody> {
  final _password = TextEditingController();
  final _shake = GlobalKey<ShakeState>();
  String? _error;
  bool _busy = false;
  DateTime? _retryAt;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _loadThrottle();
  }

  Future<void> _loadThrottle() async {
    final state = await widget.throttle?.call();
    if (state == null || !mounted) return;
    _holdUntil(DateTime.fromMillisecondsSinceEpoch(state.retryAtMs));
  }

  void _holdUntil(DateTime at) {
    _ticker?.cancel();
    if (!at.isAfter(DateTime.now())) {
      setState(() => _retryAt = null);
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

  @override
  void dispose() {
    _ticker?.cancel();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _password.text;
    if (password.isEmpty || _busy || _waitSeconds > 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.check(password);
      if (!mounted) return;
      unawaited(ZuniaHaptics.success());
      Navigator.of(context).pop(password);
    } on WrongPasswordException catch (e) {
      _fail(e.message, e.wait);
    } on PasswordThrottledException catch (e) {
      _fail(e.message, e.wait);
    } on KeystoreException catch (e) {
      _fail(e.message, Duration.zero);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fail(String message, Duration wait) {
    if (!mounted) return;
    unawaited(ZuniaHaptics.error());
    _shake.currentState?.shake();
    _password.clear();
    setState(() => _error = message);
    if (wait > Duration.zero) _holdUntil(DateTime.now().add(wait));
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final wait = _waitSeconds;
    return SensitiveScreen(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.reason,
                style: zuniaSans(fontSize: 13.5, height: 1.5, color: s.fgMuted),
              ),
              if (widget.notice != null) ...[
                const SizedBox(height: 12),
                ZuniaCallout(body: widget.notice!, tone: ZuniaCalloutTone.info),
              ],
              const SizedBox(height: 16),
              Shake(
                key: _shake,
                child: ZuniaPasswordField(
                  controller: _password,
                  autofocus: true,
                  errorText: _error,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(height: 18),
              ListenableBuilder(
                listenable: _password,
                builder: (context, _) => ZuniaButton(
                  label: wait > 0 ? 'Try again in $wait s' : widget.confirmLabel,
                  size: ZuniaButtonSize.lg,
                  loading: _busy,
                  onPressed: _password.text.isEmpty || wait > 0 ? null : _submit,
                ),
              ),
              const SizedBox(height: 4),
              ZuniaButton(
                label: 'Cancel',
                variant: ZuniaButtonVariant.ghost,
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
