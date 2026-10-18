/// Create or restore a recovery phrase, for the first account (onboarding)
/// and for every account added later, as extension 0.1.5's
/// CreateWalletScreen / ImportWalletScreen do with their `onboard` and `add`
/// variants.
///
/// Create: accept the two phrase promises -> phrase (12 or 24 words) ->
/// verify (4 or 6 words) -> password, or name when adding -> networks.
/// Restore: the same promises -> phrase (pasted or typed, word count
/// detected, every word and the checksum checked) -> password / name ->
/// networks -> an offer to verify the written copy. A restored phrase is
/// never marked verified just because it was typed in. Adding an account
/// skips the promises; the wallet already asked them.
library;

import 'dart:async';

import 'package:bip39/bip39.dart' as bip39;
// ignore: implementation_imports
import 'package:bip39/src/wordlists/english.dart' show WORDLIST;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/backup_verify_screen.dart';
import 'package:zunia_mobile/screens/onboarding_screen.dart' show OnboardingMode;
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_mobile/security/clipboard_guard.dart';
import 'package:zunia_mobile/security/mnemonic_security_config.dart';
import 'package:zunia_mobile/security/screen_security.dart';
import 'package:zunia_mobile/security/seed_safety_copy.dart';
import 'package:zunia_mobile/security/signing_gate.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/ui/password_field.dart';
import 'package:zunia_mobile/ui/password_strength_meter.dart';
import 'package:zunia_mobile/widgets/seed_text_field.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// What is wrong with a phrase someone typed or pasted, in their words.
@visibleForTesting
String? importedPhraseProblem(String normalized) {
  if (normalized.isEmpty) return 'Paste or type your recovery phrase.';
  final words = normalized.split(' ');
  final unknown = <int>[
    for (var i = 0; i < words.length; i++)
      if (!_wordSet.contains(words[i])) i,
  ];
  if (unknown.length == 1) {
    final i = unknown.first;
    return 'Word ${i + 1} ("${words[i]}") is not a recovery-phrase word. '
        'Check its spelling.';
  }
  if (unknown.length > 1) {
    final list = unknown.take(4).map((i) => '${i + 1}').join(', ');
    return 'Words $list${unknown.length > 4 ? '…' : ''} are not '
        'recovery-phrase words. Check their spelling.';
  }
  if (words.length != 12 && words.length != 24) {
    return 'Recovery phrases have 12 or 24 words. This one has ${words.length}.';
  }
  if (!bip39.validateMnemonic(normalized)) {
    return 'Every word is valid, but together they fail the phrase\'s '
        'checksum. Check the order, and the last word in particular.';
  }
  return null;
}

final Set<String> _wordSet = WORDLIST.toSet();

/// Lower case, single spaces, and without the numbering a copied list often
/// carries ("1. abandon 2. ability", one per line, commas).
@visibleForTesting
String normalizeImportedPhrase(String text) {
  final tokens = text
      .toLowerCase()
      .replaceAll(RegExp(r'[,;\n\r\t]'), ' ')
      .split(RegExp(r'\s+'))
      .map((t) => t.replaceFirst(RegExp(r'^\d+[.):-]*'), ''))
      .where((t) => t.isNotEmpty);
  return tokens.join(' ');
}

enum _Step { safety, phrase, verify, password, name, networks, offerVerify, importVerify }

class WalletSetupFlow extends ConsumerStatefulWidget {
  const WalletSetupFlow({
    super.key,
    required this.mode,
    required this.onExit,
    this.adding = false,
    this.onAdded,
  });

  final OnboardingMode mode;

  /// Back from the first step.
  final VoidCallback onExit;

  /// Another account in an unlocked wallet: no password step (the password
  /// is asked for, or read with biometrics, when the phrase is sealed).
  final bool adding;

  /// After an account was added (adding only).
  final ValueChanged<WalletAccount>? onAdded;

  @override
  ConsumerState<WalletSetupFlow> createState() => _WalletSetupFlowState();
}

class _WalletSetupFlowState extends ConsumerState<WalletSetupFlow> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  late final TextEditingController _name;
  final _importPhrase = TextEditingController();
  final _chainSearch = TextEditingController();
  final _confirmFocus = FocusNode();

  _Step _step = _Step.safety;
  String? _mnemonic;
  String? _error;
  bool _busy = false;
  int _wordCount = 12;
  bool _revealed = false;
  bool _copied = false;
  bool _ackUnderstand = false;
  bool _ackBackup = false;
  bool _verified = false;
  Timer? _autoHide;

  String _chainQuery = '';
  String _chainFilter = 'mainnet';
  late Set<String> _selectedChains;

  bool get _create => widget.mode == OnboardingMode.create;
  bool get _acksOk => widget.adding || (_ackUnderstand && _ackBackup);

  List<String> get _words =>
      _mnemonic?.split(' ').where((w) => w.isNotEmpty).toList() ?? const [];

  String get _imported => normalizeImportedPhrase(_importPhrase.text);

  List<_Step> get _steps => [
        if (!widget.adding) _Step.safety,
        _Step.phrase,
        if (_create) _Step.verify,
        widget.adding ? _Step.name : _Step.password,
        _Step.networks,
      ];

  @override
  void initState() {
    super.initState();
    final wallet = ref.read(walletProvider);
    _name = TextEditingController(
      text: widget.adding ? 'Account ${wallet.accounts.length + 1}' : 'Account 1',
    );
    _selectedChains = widget.adding
        ? {...wallet.enabledChainIds}
        : {'safrochain-1', 'cosmoshub-4', 'osmosis-1'};
    if (widget.adding) _step = _Step.phrase;
    _importPhrase.addListener(_followImportedWordCount);
    if (_create) _regenerate();
    if (widget.adding) {
      // A phrase on screen goes away with the session.
      ref.listenManual(lockEpochProvider, (_, _) => widget.onExit());
    }
  }

  @override
  void dispose() {
    _autoHide?.cancel();
    _importPhrase.removeListener(_followImportedWordCount);
    _password.dispose();
    _confirm.dispose();
    _name.dispose();
    _importPhrase.dispose();
    _chainSearch.dispose();
    _confirmFocus.dispose();
    _mnemonic = null;
    unawaited(ClipboardGuard.clearIfArmed());
    super.dispose();
  }

  /// The 12 / 24 control follows what was typed or pasted; under 12 words it
  /// keeps the user's choice.
  void _followImportedWordCount() {
    final n = _imported.isEmpty ? 0 : _imported.split(' ').length;
    final next = n > 12 ? 24 : n == 12 ? 12 : null;
    setState(() {
      if (next != null) _wordCount = next;
      _error = null;
    });
  }

  void _setError(String? message) {
    if (message != null) unawaited(ZuniaHaptics.error());
    setState(() => _error = message);
  }

  void _regenerate() {
    _autoHide?.cancel();
    final phrase = WalletKernel.instance.generateMnemonic(words: _wordCount);
    setState(() {
      _mnemonic = phrase;
      _revealed = false;
      _copied = false;
    });
  }

  /// Reveal is never sticky: the phrase hides again after a minute.
  void _toggleReveal() {
    _autoHide?.cancel();
    final next = !_revealed;
    setState(() => _revealed = next);
    if (!next) return;
    _autoHide = Timer(
      const Duration(seconds: MnemonicSecurityConfig.autoHideAfterSeconds),
      () {
        if (mounted) setState(() => _revealed = false);
      },
    );
  }

  Future<void> _copyPhrase() async {
    final mnemonic = _mnemonic;
    if (mnemonic == null) return;
    await ClipboardGuard.copy(mnemonic, isMnemonic: true, force: true);
    if (!mounted) return;
    setState(() {
      _copied = true;
      _error = null;
    });
  }

  void _onScreenshot() {
    if (_step != _Step.phrase || !_create) return;
    showZuniaAlert<void>(
      context,
      title: 'Screenshot taken',
      message: 'A recovery phrase in your photo library can be synced off '
          'this phone. Delete the screenshot from Photos and Recently '
          'Deleted, and write the words on paper instead.',
      actions: const [ZuniaAlertAction(label: 'OK', isDefault: true)],
    );
  }

  void _go(_Step step) => setState(() {
        _error = null;
        _step = step;
      });

  void _back() {
    FocusManager.instance.primaryFocus?.unfocus();
    switch (_step) {
      case _Step.safety:
        widget.onExit();
      case _Step.phrase:
        if (widget.adding) {
          widget.onExit();
        } else {
          _go(_Step.safety);
        }
      case _Step.verify:
        _go(_Step.phrase);
      case _Step.password:
      case _Step.name:
        _go(_create ? _Step.verify : _Step.phrase);
      case _Step.networks:
        _go(widget.adding ? _Step.name : _Step.password);
      case _Step.offerVerify:
      case _Step.importVerify:
        _go(_Step.networks);
    }
  }

  void _phraseContinue() {
    if (_create) {
      if (!_revealed && !_copied) {
        _setError('Reveal or copy your phrase before continuing.');
        return;
      }
      _autoHide?.cancel();
      setState(() => _revealed = false);
      _go(_Step.verify);
      return;
    }
    final problem = importedPhraseProblem(_imported);
    if (problem != null) {
      _setError(problem);
      return;
    }
    _go(widget.adding ? _Step.name : _Step.password);
  }

  void _passwordContinue() {
    if (_name.text.trim().isEmpty) {
      _setError('Give this account a name.');
      return;
    }
    if (!widget.adding) {
      if (_password.text.length < kMinPasswordLength) {
        _setError('Password must be at least $kMinPasswordLength characters.');
        return;
      }
      if (_password.text != _confirm.text) {
        _setError('Passwords do not match.');
        return;
      }
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _go(_Step.networks);
  }

  void _networksContinue() {
    if (_selectedChains.isEmpty) {
      _setError('Select at least one network.');
      return;
    }
    if (_create || _verified) {
      _finish();
    } else {
      _go(_Step.offerVerify);
    }
  }

  /// Pinned chains first, so the home list opens on Safrochain.
  List<String> _orderedSelection() {
    if (!ChainCatalog.isLoaded) return _selectedChains.toList();
    return ChainCatalog.instance
        .sorted(
          ChainCatalog.instance.all
              .where((c) => _selectedChains.contains(c.chainId))
              .toList(),
        )
        .map((c) => c.chainId)
        .toList();
  }

  Future<void> _finish() async {
    final phrase =
        _create ? _mnemonic : WalletKernel.normalizePhrase(_imported);
    if (phrase == null || _busy) return;
    final verified = _create || _verified;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.adding) {
        await _finishAdding(phrase, verified);
      } else {
        await _finishOnboarding(phrase, verified);
      }
    } on WrongPasswordException catch (e) {
      _setError(e.message);
    } on PasswordThrottledException catch (e) {
      _setError(e.message);
    } on KeystoreException catch (e) {
      _setError(e.message);
    } on KernelUnavailableException catch (e) {
      _setError(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishAdding(String phrase, bool verified) async {
    final password = await requestPassword(
      context,
      ref,
      title: 'Add ${_name.text.trim()}',
      reason: 'The new account is sealed with the password that unlocks the '
          'others.',
    );
    if (password == null || !mounted) return;
    final account = await ref.read(vaultSessionProvider).addAccount(
          phrase: phrase,
          password: password,
          name: _name.text,
          enabledChainIds: _orderedSelection(),
          backupVerified: verified,
        );
    unawaited(ZuniaHaptics.success());
    widget.onAdded?.call(account);
  }

  Future<void> _finishOnboarding(String phrase, bool verified) async {
    final password = _password.text;
    final keystore = ref.read(keystoreProvider);
    final session = ref.read(vaultSessionProvider);
    final phraseId = await keystore.createVault(phrase: phrase, password: password);
    await ref.read(walletProvider.notifier).initialise(
          walletName: _name.text,
          enabledChainIds: _orderedSelection(),
          phraseId: phraseId,
          wordCount: phrase.split(' ').length,
          backupVerified: verified,
        );
    await _offerBiometrics(session, password);
    if (!mounted) return;
    unawaited(ZuniaHaptics.success());
    FocusManager.instance.primaryFocus?.unfocus();
    // Take the text fields down before the gate swaps this screen out.
    setState(() => _step = _Step.networks);
    await Future<void>.delayed(Duration.zero);
    await session.begin(VaultUnlock(phrases: {phraseId: phrase}));
    // Opened from a welcome screen as a pushed route: the gate below is the
    // wallet now, so go back to it.
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _offerBiometrics(VaultSession session, String password) async {
    final availability = await session.biometricAvailability();
    if (!availability.available || !mounted) return;
    final label = availability.label(apple: ZuniaPlatform.isCupertino(context));
    final yes = await showZuniaConfirm(
      context,
      title: 'Unlock with $label?',
      message: 'Your password stays the key and always works. $label only '
          'releases this phone\'s copy of it, and stops working if anyone '
          'adds a face or fingerprint to the device.',
      confirmLabel: 'Turn on',
      cancelLabel: 'Not now',
    );
    if (!yes || !mounted) return;
    try {
      await session.enableBiometrics(
        password,
        BiometricPromptText(title: 'Turn on $label', subtitle: 'Unlock Zunia'),
      );
    } on BiometricException {
      // Security has the switch to try again.
    }
  }

  @override
  Widget build(BuildContext context) {
    return SensitiveScreen(
      onScreenshot: _onScreenshot,
      child: ZuniaScreenScaffold(
        title: widget.adding
            ? (_create ? 'New account' : 'Restore account')
            : null,
        // Back lives in the header on every step (iOS chevron, Android
        // arrow), so the footer holds one full-width action that fits at
        // 320 dp with large text.
        onBack: _busy ? null : _back,
        body: _step == _Step.networks
            ? _networksBody()
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _body(),
                ),
              ),
        footer: _footer(),
      ),
    );
  }

  Widget _progress(_Step step, String label) {
    final i = _steps.indexOf(step);
    return ZuniaStepProgress(
      current: i < 0 ? _steps.length : i + 1,
      total: _steps.length,
      label: label,
    );
  }

  Widget _errorBlock() {
    if (_error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Semantics(
        liveRegion: true,
        child: ZuniaCallout(body: _error!, tone: ZuniaCalloutTone.danger),
      ),
    );
  }

  List<Widget> _body() {
    switch (_step) {
      case _Step.safety:
        return _safetyBody();
      case _Step.phrase:
        return _create ? _createPhraseBody() : _importPhraseBody();
      case _Step.verify:
        return [
          _progress(_Step.verify, 'Verify'),
          const SizedBox(height: 22),
          BackupQuiz(
            words: _words,
            onPassed: () => _go(widget.adding ? _Step.name : _Step.password),
          ),
          _errorBlock(),
        ];
      case _Step.password:
        return _passwordBody();
      case _Step.name:
        return _nameBody();
      case _Step.offerVerify:
        return _offerVerifyBody();
      case _Step.importVerify:
        return [
          const ZuniaStepHeading(
            title: 'Check your written copy',
            subtitle: 'Pick the words Zunia asks for from the copy you keep '
                'offline, not from memory.',
          ),
          const SizedBox(height: 22),
          BackupQuiz(
            words: WalletKernel.normalizePhrase(_imported).split(' '),
            onPassed: () {
              setState(() => _verified = true);
              _finish();
            },
          ),
          _errorBlock(),
        ];
      case _Step.networks:
        return const [];
    }
  }

  Widget _ackTile({
    required bool value,
    required String label,
    required ValueChanged<bool> onChanged,
  }) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      checked: value,
      label: label,
      excludeSemantics: true,
      onTap: () => onChanged(!value),
      child: InkWell(
        onTap: () {
          ZuniaHaptics.selection();
          onChanged(!value);
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: value ? s.accent : s.line),
            color: s.stateHover,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                value ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 20,
                color: value ? s.accent : s.fgDim,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: zuniaSans(fontSize: 13, height: 1.4, color: s.fgMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _acks() {
    if (widget.adding) return const [];
    return [
      const SizedBox(height: 14),
      _ackTile(
        value: _ackUnderstand,
        label: SeedSafetyCopy.ackUnderstand,
        onChanged: (v) => setState(() {
          _ackUnderstand = v;
          _error = null;
        }),
      ),
      const SizedBox(height: 8),
      _ackTile(
        value: _ackBackup,
        label: SeedSafetyCopy.ackBackup,
        onChanged: (v) => setState(() {
          _ackBackup = v;
          _error = null;
        }),
      ),
    ];
  }

  List<Widget> _safetyBody() {
    return [
      _progress(_Step.safety, 'Protect'),
      const SizedBox(height: 22),
      const ZuniaStepHeading(
        title: SeedSafetyCopy.title,
        subtitle: SeedSafetyCopy.summary,
      ),
      ..._acks(),
    ];
  }

  List<Widget> _createPhraseBody() {
    final s = ZuniaSemanticsExt.of(context);
    return [
      _progress(_Step.phrase, 'Recovery phrase'),
      const SizedBox(height: 20),
      Text(
        'Write these ${_wordCount == 12 ? 'twelve' : 'twenty-four'} words down '
        'in order, on paper. They are the only way back into this '
        '${widget.adding ? 'account' : 'wallet'}.',
        style: zuniaSans(fontSize: 13.5, height: 1.6, color: s.fgMuted),
      ),
      const SizedBox(height: 14),
      const ZuniaCallout(
        title: SeedSafetyCopy.title,
        body: SeedSafetyCopy.summary,
        tone: ZuniaCalloutTone.warning,
      ),
      const SizedBox(height: 16),
      ZuniaSegmented<int>(
        value: _wordCount,
        onChanged: (v) {
          if (v == _wordCount) return;
          setState(() => _wordCount = v);
          _regenerate();
        },
        options: const {12: '12 words', 24: '24 words'},
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: ZuniaButton(
              label: _revealed ? 'Hide' : 'Reveal',
              size: ZuniaButtonSize.sm,
              variant: ZuniaButtonVariant.secondary,
              leading: Icon(
                _revealed
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
              onPressed: _toggleReveal,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ZuniaButton(
              label: _copied ? 'Copied' : 'Copy',
              size: ZuniaButtonSize.sm,
              variant: ZuniaButtonVariant.secondary,
              leading: Icon(_copied ? Icons.check : Icons.copy_outlined),
              onPressed: _copyPhrase,
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      CaptureShield(
        placeholder: const ZuniaCallout(
          tone: ZuniaCalloutTone.warning,
          title: 'Hidden while the screen is shared',
          body: 'This iPhone is recording, mirroring or using AirPlay. Stop '
              'it to see the words.',
        ),
        child: ZuniaMnemonicGrid(words: _words, revealed: _revealed),
      ),
      if (_copied) ...[
        const SizedBox(height: 10),
        Text(
          ClipboardGuard.sensitiveNote,
          style: zuniaSans(fontSize: 11.5, height: 1.45, color: s.fgDim),
        ),
      ],
      const SizedBox(height: 12),
      Text(
        ZuniaPlatform.isCupertino(context)
            ? 'Zunia warns you if a screenshot is taken here, and hides the '
                'words while the screen is recorded.'
            : 'Screenshots and screen recordings are blocked on this screen.',
        style: zuniaSans(fontSize: 11.5, height: 1.45, color: s.fgDim),
      ),
      _errorBlock(),
    ];
  }

  List<Widget> _importPhraseBody() {
    final s = ZuniaSemanticsExt.of(context);
    final normalized = _imported;
    final count = normalized.isEmpty ? 0 : normalized.split(' ').length;
    final problem = count == 0 ? null : importedPhraseProblem(normalized);
    final complete = count == 12 || count == 24;
    return [
      _progress(_Step.phrase, 'Phrase'),
      const SizedBox(height: 20),
      ZuniaStepHeading(
        title: widget.adding ? 'Restore an account' : 'Restore wallet',
        subtitle: 'Enter the 12 or 24 words of a recovery phrase, in order. '
            'Pasting a numbered list works too.',
      ),
      const SizedBox(height: 16),
      ZuniaSegmented<int>(
        value: _wordCount,
        onChanged: (v) => setState(() => _wordCount = v),
        options: const {12: '12 words', 24: '24 words'},
      ),
      const SizedBox(height: 14),
      SeedTextField(
        controller: _importPhrase,
        label: '$_wordCount-word recovery phrase',
        maxLines: _wordCount == 24 ? 6 : 4,
      ),
      const SizedBox(height: 8),
      Semantics(
        liveRegion: true,
        child: Text(
          count == 0
              ? '0 / $_wordCount words'
              : problem == null
                  ? '$count words · checksum OK'
                  : complete || problem.startsWith('Word')
                      ? '$count words · $problem'
                      : '$count / $_wordCount words',
          style: zuniaMono(
            fontSize: 11,
            color: count == 0
                ? s.fgDim
                : problem == null
                    ? s.success
                    : complete || problem.startsWith('Word')
                        ? s.danger
                        : s.fgDim,
          ),
        ),
      ),
      _errorBlock(),
    ];
  }

  List<Widget> _passwordBody() {
    final s = ZuniaSemanticsExt.of(context);
    return [
      _progress(_Step.password, 'Password'),
      const SizedBox(height: 20),
      const ZuniaStepHeading(
        title: 'Name and password',
        subtitle: 'The password unlocks Zunia on this device and every '
            'account you add later. It never recovers a phrase.',
      ),
      const SizedBox(height: 22),
      ZuniaInput(controller: _name, label: 'ACCOUNT NAME', hint: 'Account 1'),
      const SizedBox(height: 14),
      ZuniaPasswordField(
        controller: _password,
        label: 'PASSWORD',
        hint: 'At least $kMinPasswordLength characters',
        newPassword: true,
        textInputAction: TextInputAction.next,
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: (_) => _confirmFocus.requestFocus(),
      ),
      const SizedBox(height: 12),
      PasswordStrengthMeter(password: _password.text),
      const SizedBox(height: 14),
      ZuniaPasswordField(
        controller: _confirm,
        focusNode: _confirmFocus,
        label: 'CONFIRM PASSWORD',
        hint: 'Repeat password',
        newPassword: true,
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: (_) => _passwordContinue(),
      ),
      const SizedBox(height: 10),
      Text(
        'There is no password reset. If you forget it, remove the wallet '
        'and restore it from the recovery phrase.',
        style: zuniaSans(fontSize: 11.5, height: 1.45, color: s.fgDim),
      ),
      _errorBlock(),
    ];
  }

  List<Widget> _nameBody() {
    return [
      _progress(_Step.name, 'Name'),
      const SizedBox(height: 20),
      const ZuniaStepHeading(
        title: 'Name this account',
        subtitle: 'Only shown on this device. The same password unlocks every '
            'account.',
      ),
      const SizedBox(height: 22),
      ZuniaInput(
        controller: _name,
        label: 'ACCOUNT NAME',
        hint: 'Account name',
        autofocus: true,
        onSubmitted: (_) => _passwordContinue(),
      ),
      _errorBlock(),
    ];
  }

  List<Widget> _offerVerifyBody() {
    return [
      const ZuniaStepHeading(
        title: 'Check your written copy?',
        subtitle: 'A restored phrase starts as not verified. Zunia can ask for '
            'a few words from the copy you keep offline, to make sure it is '
            'complete. You can also do it later from Security.',
      ),
      _errorBlock(),
    ];
  }

  /// The chain list can run to hundreds of rows, so this step scrolls its own
  /// list under a fixed search and filter header rather than inside the page.
  Widget _networksBody() {
    final rows = ChainCatalog.isLoaded
        ? ChainCatalog.instance.search(_chainQuery, filter: _chainFilter)
        : const <ChainEntry>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _progress(_Step.networks, 'Networks'),
              const SizedBox(height: 20),
              ZuniaStepHeading(
                title: 'Choose networks',
                subtitle:
                    '${_selectedChains.length} selected. You can add or remove '
                    'networks at any time.',
              ),
              const SizedBox(height: 18),
              ZuniaSearchField(
                controller: _chainSearch,
                hintText: 'Search ${rows.length}+ chains',
                onChanged: (v) => setState(() => _chainQuery = v),
              ),
              const SizedBox(height: 12),
              ZuniaSegmented<String>(
                value: _chainFilter,
                onChanged: (v) => setState(() => _chainFilter = v),
                options: const {
                  'mainnet': 'Mainnet',
                  'testnet': 'Testnet',
                  'all': 'All',
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ZuniaButton(
                      label: 'Select all',
                      size: ZuniaButtonSize.sm,
                      variant: ZuniaButtonVariant.ghost,
                      onPressed: () => setState(() {
                        _selectedChains = {
                          ..._selectedChains,
                          ...rows.map((c) => c.chainId),
                        };
                      }),
                    ),
                  ),
                  Expanded(
                    child: ZuniaButton(
                      label: 'Clear',
                      size: ZuniaButtonSize.sm,
                      variant: ZuniaButtonVariant.ghost,
                      onPressed: () =>
                          setState(() => _selectedChains = {'safrochain-1'}),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final chain = rows[i];
              return ZuniaNetworkOptionCard(
                name: chain.chainName,
                chainId: chain.chainId,
                symbol: chain.coinDenom.isEmpty ? null : chain.coinDenom,
                iconUrl: chain.iconUrl,
                testnet: chain.isTestnet,
                verified: chain.inCosmosRegistry,
                selected: _selectedChains.contains(chain.chainId),
                onToggle: () => setState(() {
                  if (!_selectedChains.remove(chain.chainId)) {
                    _selectedChains.add(chain.chainId);
                  }
                }),
              );
            },
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: ZuniaCallout(body: _error!, tone: ZuniaCalloutTone.danger),
          ),
      ],
    );
  }

  Widget _footer() {
    switch (_step) {
      case _Step.safety:
        return _actions(
          primaryLabel: 'Continue',
          onPrimary: _acksOk ? () => _go(_Step.phrase) : null,
        );
      case _Step.phrase:
        if (_create) {
          return _actions(
            primaryLabel: 'I have written it down',
            onPrimary: (_copied || _revealed) ? _phraseContinue : null,
          );
        }
        return ListenableBuilder(
          listenable: _importPhrase,
          builder: (context, _) => _actions(
            primaryLabel: 'Continue',
            onPrimary: _imported.isNotEmpty ? _phraseContinue : null,
          ),
        );
      case _Step.verify:
      case _Step.importVerify:
        return const SizedBox.shrink();
      case _Step.password:
      case _Step.name:
        return _actions(primaryLabel: 'Continue', onPrimary: _passwordContinue);
      case _Step.networks:
        final last = _create || _verified;
        return _actions(
          primaryLabel: !last
              ? 'Continue · ${_selectedChains.length}'
              : widget.adding
                  ? 'Add account · ${_selectedChains.length}'
                  : 'Create wallet · ${_selectedChains.length}',
          onPrimary: _busy ? null : _networksContinue,
        );
      case _Step.offerVerify:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ZuniaButton(
              label: 'Verify now',
              size: ZuniaButtonSize.lg,
              onPressed: _busy ? null : () => _go(_Step.importVerify),
            ),
            const SizedBox(height: 8),
            ZuniaButton(
              label: 'Skip for now',
              size: ZuniaButtonSize.lg,
              variant: ZuniaButtonVariant.secondary,
              loading: _busy,
              onPressed: _busy ? null : _finish,
            ),
          ],
        );
    }
  }

  Widget _actions({required String primaryLabel, VoidCallback? onPrimary}) {
    return ZuniaButton(
      label: primaryLabel,
      size: ZuniaButtonSize.lg,
      loading: _busy,
      onPressed: onPrimary,
    );
  }
}

/// Another account in an unlocked wallet: its own phrase, created or
/// restored, sealed with the same password.
class AddAccountScreen extends StatelessWidget {
  const AddAccountScreen({super.key, required this.mode});

  final OnboardingMode mode;

  /// Asks "create or restore" the native way, then opens the flow.
  static Future<void> start(BuildContext context) async {
    final mode = await showZuniaActionSheet<OnboardingMode>(
      context,
      title: 'Add account',
      message: 'A new account has its own recovery phrase, not another '
          'address from the first one. The same password unlocks every '
          'account.',
      actions: const [
        ZuniaAlertAction(
          label: 'Create new account',
          value: OnboardingMode.create,
          isDefault: true,
        ),
        ZuniaAlertAction(
          label: 'Restore with a recovery phrase',
          value: OnboardingMode.import,
        ),
      ],
    );
    if (mode == null || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AddAccountScreen(mode: mode)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Scaffold(
      backgroundColor: s.bg,
      body: SafeArea(
        bottom: false,
        child: WalletSetupFlow(
          mode: mode,
          adding: true,
          onExit: () {
            final route = ModalRoute.of(context);
            if (route == null || !route.isActive) return;
            // Under the lock screen the route is not on top: remove it
            // without animating it out over the lock.
            if (route.isCurrent) {
              Navigator.of(context).pop();
            } else {
              Navigator.of(context).removeRoute(route);
            }
          },
          onAdded: (account) {
            Navigator.of(context).pop();
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text('${account.name} added and selected')),
            );
          },
        ),
      ),
    );
  }
}

/// Opens [BackupVerifyScreen] for the active account's phrase.
Future<void> verifyActiveBackup(BuildContext context, WidgetRef ref) async {
  final wallet = ref.read(walletProvider);
  final account = wallet.active;
  if (account == null) return;
  await Navigator.of(context).push(
    MaterialPageRoute<bool>(
      builder: (_) => BackupVerifyScreen(phraseId: account.phraseId),
    ),
  );
}
