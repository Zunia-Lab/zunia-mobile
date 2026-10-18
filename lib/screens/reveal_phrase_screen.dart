import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/screens/backup_verify_screen.dart';
import 'package:zunia_mobile/security/clipboard_guard.dart';
import 'package:zunia_mobile/security/screen_security.dart';
import 'package:zunia_mobile/security/signing_gate.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// The recovery phrase of one account, behind the password (or biometrics),
/// shown only while a finger holds the button.
///
/// The phrase is read from its sealed envelope with the password, not from
/// the unlocked session, as the extension does: knowing the phone's passcode
/// and finding it unlocked is not enough. It is forgotten after a minute,
/// when the app leaves the screen, and when the wallet locks; a copy is
/// wiped from the clipboard after 30 s or when this screen closes.
class RevealPhraseScreen extends ConsumerStatefulWidget {
  const RevealPhraseScreen({super.key, this.accountId});

  /// Defaults to the active account.
  final String? accountId;

  @override
  ConsumerState<RevealPhraseScreen> createState() => _RevealPhraseScreenState();
}

class _RevealPhraseScreenState extends ConsumerState<RevealPhraseScreen>
    with WidgetsBindingObserver {
  static const _forgetAfter = Duration(seconds: 60);

  String? _phrase;
  bool _holding = false;
  bool _busy = false;
  bool _copied = false;
  String? _error;
  Timer? _forget;
  Timer? _a11yHide;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(lockEpochProvider, (_, _) => _closeForLock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _forget?.cancel();
    _a11yHide?.cancel();
    _phrase = null;
    unawaited(ClipboardGuard.clearIfArmed());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _hide();
    }
  }

  void _closeForLock() {
    _hide();
    final route = ModalRoute.of(context);
    if (mounted && route != null && route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
  }

  void _hide() {
    _forget?.cancel();
    _a11yHide?.cancel();
    if (!mounted) return;
    setState(() {
      _phrase = null;
      _holding = false;
      _copied = false;
    });
  }

  WalletAccount? _account(WalletData wallet) =>
      widget.accountId == null ? wallet.active : wallet.byId(widget.accountId!);

  Future<void> _unlock(WalletAccount account) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final password = await requestPassword(
        context,
        ref,
        title: 'Show recovery phrase',
        reason: 'Anyone who sees these words can take everything in '
            '${account.name}.',
      );
      if (password == null || !mounted) return;
      final phrase = await ref
          .read(vaultSessionProvider)
          .revealPhrase(account.phraseId, password);
      if (!mounted) return;
      setState(() => _phrase = phrase);
      _forget = Timer(_forgetAfter, _hide);
    } on WrongPasswordException catch (e) {
      setState(() => _error = e.message);
    } on PasswordThrottledException catch (e) {
      setState(() => _error = e.message);
    } on KeystoreException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setHolding(bool value) {
    if (_holding == value) return;
    if (value) unawaited(ZuniaHaptics.medium());
    setState(() => _holding = value);
  }

  Future<void> _copy() async {
    final phrase = _phrase;
    if (phrase == null) return;
    await ClipboardGuard.copy(phrase, isMnemonic: true, force: true);
    if (!mounted) return;
    unawaited(ZuniaHaptics.light());
    setState(() => _copied = true);
  }

  void _onScreenshot() {
    if (_phrase == null) return;
    showZuniaAlert<void>(
      context,
      title: 'Screenshot taken',
      message: 'If it shows your recovery phrase, delete it from Photos and '
          'from Recently Deleted. A phrase in a photo library can be synced '
          'off this phone.',
      actions: const [ZuniaAlertAction(label: 'OK', isDefault: true)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final wallet = ref.watch(walletProvider);
    final account = _account(wallet);
    final phrase = _phrase;
    final words = phrase?.split(' ') ?? const <String>[];
    final info = account == null ? null : wallet.phraseOf(account);
    final owner = account == null || !account.isHdChild
        ? null
        : wallet.accountsOf(account.phraseId).where((a) => !a.isHdChild).firstOrNull;

    return SensitiveScreen(
      onScreenshot: _onScreenshot,
      child: Scaffold(
        backgroundColor: s.bg,
        body: SafeArea(
          bottom: false,
          child: ZuniaScreenScaffold(
            title: 'Recovery phrase',
            onBack: () => Navigator.of(context).pop(),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                ZuniaCallout(
                  tone: ZuniaCalloutTone.danger,
                  title: 'Anyone with these words owns this account',
                  body: account == null
                      ? 'Never type them into a website and never share them.'
                      : 'This is the recovery phrase of ${account.name}. Each '
                          'account added with its own phrase has its own words. '
                          'Never type them into a website and never share them.',
                ),
                if (account != null && account.isHdChild) ...[
                  const SizedBox(height: 12),
                  ZuniaCallout(
                    tone: ZuniaCalloutTone.info,
                    body: '${account.name} has no phrase of its own: it is '
                        'account ${account.index} of '
                        '${owner?.name ?? 'the first account'}\'s phrase. '
                        'That phrase restores it in any wallet that derives '
                        'm/44\'/…/0\'/0/${account.index}.',
                  ),
                ],
                const SizedBox(height: 18),
                if (phrase == null) ...[
                  if (_error != null)
                    ZuniaCallout(body: _error!, tone: ZuniaCalloutTone.danger),
                ] else ...[
                  CaptureShield(
                    placeholder: const ZuniaCallout(
                      tone: ZuniaCalloutTone.warning,
                      title: 'Hidden while the screen is shared',
                      body: 'This iPhone is recording, mirroring or using '
                          'AirPlay. Stop it to see the words.',
                    ),
                    child: ZuniaMnemonicGrid(words: words, revealed: _holding),
                  ),
                  const SizedBox(height: 14),
                  _HoldToReveal(
                    holding: _holding,
                    onHold: _setHolding,
                    onA11yReveal: () {
                      _setHolding(true);
                      _a11yHide?.cancel();
                      _a11yHide = Timer(
                        const Duration(seconds: 15),
                        () => _setHolding(false),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  ZuniaButton(
                    label: _copied ? 'Copied' : 'Copy',
                    variant: ZuniaButtonVariant.ghost,
                    leading: Icon(_copied ? Icons.check : Icons.copy_outlined),
                    onPressed: _copy,
                  ),
                  if (_copied)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        ClipboardGuard.sensitiveNote,
                        style: zuniaSans(fontSize: 11.5, height: 1.45, color: s.fgDim),
                      ),
                    ),
                  if (info != null && !info.backupVerified) ...[
                    const SizedBox(height: 16),
                    ZuniaButton(
                      label: 'Verify my written copy',
                      variant: ZuniaButtonVariant.secondary,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<bool>(
                          builder: (_) => BackupVerifyScreen(phraseId: info.id),
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),
            footer: phrase != null || account == null
                ? null
                : ZuniaButton(
                    label: 'Show recovery phrase',
                    size: ZuniaButtonSize.lg,
                    loading: _busy,
                    onPressed: _busy ? null : () => _unlock(account),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Press and hold to show the words; they hide again on release. A screen
/// reader's activate shows them for 15 s instead.
class _HoldToReveal extends StatelessWidget {
  const _HoldToReveal({
    required this.holding,
    required this.onHold,
    required this.onA11yReveal,
  });

  final bool holding;
  final ValueChanged<bool> onHold;
  final VoidCallback onA11yReveal;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      button: true,
      label: holding ? 'Words shown' : 'Show the words',
      onTap: onA11yReveal,
      excludeSemantics: true,
      child: Listener(
        onPointerDown: (_) => onHold(true),
        onPointerUp: (_) => onHold(false),
        onPointerCancel: (_) => onHold(false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: holding ? s.stateSelected : s.glass,
            border: Border.all(color: holding ? s.accent : s.lineStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                holding ? Icons.visibility_outlined : Icons.touch_app_outlined,
                size: 20,
                color: s.fg,
              ),
              const SizedBox(width: 10),
              Text(
                holding ? 'Release to hide' : 'Hold to reveal',
                style: zuniaSans(fontSize: 15, fontWeight: FontWeight.w500, color: s.fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
