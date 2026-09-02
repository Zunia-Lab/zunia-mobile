import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/security/clipboard_guard.dart';
import 'package:zunia_mobile/security/mnemonic_security_config.dart';
import 'package:zunia_mobile/security/seed_safety_copy.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/seed_text_field.dart';
import 'package:zunia_ui/zunia_ui.dart';

enum _Step {
  welcome,
  createPhrase,
  createVerify,
  createPassword,
  createNetworks,
  importPhrase,
  importPassword,
  importNetworks,
}

const _createSteps = 4;
const _importSteps = 3;

/// Create or restore a wallet in discrete steps.
/// Safety acknowledgements appear only on the welcome step.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _walletName = TextEditingController(text: 'Main');
  final _importPhrase = TextEditingController();
  final _chainSearch = TextEditingController();
  final _random = Random.secure();

  _Step _step = _Step.welcome;
  String? _pendingMnemonic;
  String? _error;
  bool _busy = false;
  int _wordCount = 12;
  bool _revealed = false;
  bool _copied = false;
  bool _ackUnderstand = false;
  bool _ackBackup = false;

  List<int> _verifyPositions = const [];
  int _verifyCursor = 0;
  List<String> _verifyOptions = const [];
  Timer? _autoHideTimer;

  String _chainQuery = '';
  String _chainFilter = 'mainnet';
  Set<String> _selectedChains = {'safrochain-1', 'cosmoshub-4', 'osmosis-1'};

  bool get _acksOk => _ackUnderstand && _ackBackup;

  List<String> get _words =>
      _pendingMnemonic?.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList() ??
      const [];

  @override
  void initState() {
    super.initState();
    _importPhrase.addListener(_syncImportWordCount);
    _regenerate();
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _importPhrase.removeListener(_syncImportWordCount);
    _password.dispose();
    _confirm.dispose();
    _walletName.dispose();
    _importPhrase.dispose();
    _chainSearch.dispose();
    super.dispose();
  }

  /// Match the 12 / 24 segmented control to the pasted or typed phrase.
  void _syncImportWordCount() {
    final n = _importPhrase.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .length;
    final next = n > 12 ? 24 : n == 12 ? 12 : null;
    if (next != null && next != _wordCount) {
      setState(() => _wordCount = next);
    }
  }

  void _setError(String? message) => setState(() => _error = message);

  /// Reveal is never sticky: policy re-hides the phrase after a timeout.
  void _toggleReveal() {
    _autoHideTimer?.cancel();
    final next = !_revealed;
    setState(() => _revealed = next);
    if (!next) return;
    _autoHideTimer = Timer(
      const Duration(seconds: MnemonicSecurityConfig.autoHideAfterSeconds),
      () {
        if (mounted) setState(() => _revealed = false);
      },
    );
  }

  void _regenerate() {
    final phrase = WalletKernel.instance.generateMnemonic(words: _wordCount);
    _autoHideTimer?.cancel();
    setState(() {
      _pendingMnemonic = phrase;
      _revealed = false;
      _copied = false;
    });
  }

  Future<void> _copyPhrase() async {
    final mnemonic = _pendingMnemonic;
    if (mnemonic == null) return;
    await ClipboardGuard.copy(mnemonic, isMnemonic: true, force: true);
    if (!mounted) return;
    setState(() {
      _copied = true;
      _error = null;
    });
  }

  void _startVerification() {
    final total = _words.length;
    final indices = List.generate(total, (i) => i)..shuffle(_random);
    final positions =
        indices.take(MnemonicSecurityConfig.verifyWordCount(total)).toList()
          ..sort();
    setState(() {
      _verifyPositions = positions;
      _verifyCursor = 0;
      _verifyOptions = _optionsFor(_words[positions.first]);
      _error = null;
      _step = _Step.createVerify;
    });
  }

  /// Decoys come from the phrase itself, so a shoulder-surfer cannot spot the
  /// answer by recognising an off-list word.
  List<String> _optionsFor(String word) {
    final pool = _words.toSet().where((w) => w != word).toList()
      ..shuffle(_random);
    return <String>[word, ...pool.take(2)]..shuffle(_random);
  }

  void _onVerifyPick(String word) {
    final index = _verifyPositions[_verifyCursor];
    if (_words[index] != word) {
      _setError('Word ${index + 1} is incorrect');
      return;
    }
    if (_verifyCursor + 1 >= _verifyPositions.length) {
      setState(() {
        _error = null;
        _step = _Step.createPassword;
      });
      return;
    }
    setState(() {
      _error = null;
      _verifyCursor += 1;
      _verifyOptions = _optionsFor(_words[_verifyPositions[_verifyCursor]]);
    });
  }

  bool _passwordValid() {
    if (_walletName.text.trim().isEmpty) {
      _setError('Give this wallet a name');
      return false;
    }
    if (_password.text.length < 8) {
      _setError('Password must be at least 8 characters');
      return false;
    }
    if (_password.text != _confirm.text) {
      _setError('Passwords do not match');
      return false;
    }
    return true;
  }

  Future<void> _sealVault({required String phrase, required bool verified}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final password = _password.text;
      final kernel = WalletKernel.instance;
      final envelope = kernel.sealKeyring(
        phrase: phrase,
        password: password,
        metadata: {'name': _walletName.text.trim()},
      );
      final keystore = ref.read(keystoreProvider);
      await keystore.createVault(password: password, envelopeJson: envelope);
      await keystore.setBackupVerified(verified);
      final vault = await keystore.unlockWithPassword(password);
      await ref.read(walletProvider.notifier).initialise(
            walletName: _walletName.text,
            enabledChainIds: _orderedSelection(),
          );
      if (!mounted) return;
      ref.read(phraseProvider.notifier).state = phrase;
      ref.read(sessionProvider.notifier).state = vault;
    } catch (e) {
      _setError(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Keep the pinned chains at the front so the home list opens on Safrochain.
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

  Future<void> _finishCreate() async {
    final phrase = _pendingMnemonic;
    if (phrase == null) return;
    await _sealVault(phrase: phrase, verified: true);
  }

  Future<void> _finishImport() async {
    final phrase = _importPhrase.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    await _sealVault(phrase: phrase, verified: true);
  }

  void _goBack() {
    setState(() {
      _error = null;
      switch (_step) {
        case _Step.welcome:
          break;
        case _Step.createPhrase:
        case _Step.importPhrase:
          _step = _Step.welcome;
        case _Step.createVerify:
          _step = _Step.createPhrase;
        case _Step.createPassword:
          _step = _Step.createVerify;
        case _Step.createNetworks:
          _step = _Step.createPassword;
        case _Step.importPassword:
          _step = _Step.importPhrase;
        case _Step.importNetworks:
          _step = _Step.importPassword;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          body: _step == _Step.createNetworks || _step == _Step.importNetworks
              ? _networksBody()
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _body(),
                  ),
                ),
          footer: _footer(),
        ),
      ),
    );
  }

  Widget _errorBlock() {
    if (_error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ZuniaCallout(
        body: _error!,
        tone: ZuniaCalloutTone.danger,
      ),
    );
  }

  List<Widget> _body() {
    switch (_step) {
      case _Step.welcome:
        return _welcomeBody();
      case _Step.createPhrase:
        return _phraseBody();
      case _Step.createVerify:
        return _verifyBody();
      case _Step.createPassword:
        return _passwordBody(
          current: 3,
          total: _createSteps,
          subtitle:
              'Unlocks Zunia on this device only. It never recovers your phrase.',
        );
      case _Step.importPhrase:
        return _importPhraseBody();
      case _Step.importPassword:
        return _passwordBody(
          current: 2,
          total: _importSteps,
          subtitle:
              'Unlocks Zunia on this device only. It never recovers your phrase.',
        );
      case _Step.createNetworks:
      case _Step.importNetworks:
        return const [];
    }
  }

  List<Widget> _welcomeBody() {
    final s = ZuniaSemanticsExt.of(context);
    return [
      const SizedBox(height: 48),
      Center(
        child: Image.asset('assets/brand/icon.png', width: 66, height: 61),
      ),
      const SizedBox(height: 26),
      Text(
        'Your keys.\nEvery chain.',
        textAlign: TextAlign.center,
        style: zuniaSans(
          fontSize: 27,
          height: 1.15,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.9,
          color: s.fg,
        ),
      ),
      const SizedBox(height: 14),
      Text(
        'One wallet for the Cosmos ecosystem. Nothing leaves this device.',
        textAlign: TextAlign.center,
        style: zuniaSans(fontSize: 13.5, height: 1.6, color: s.fgMuted),
      ),
      const SizedBox(height: 28),
      ZuniaCallout(
        title: SeedSafetyCopy.title,
        body: SeedSafetyCopy.summary,
        tone: ZuniaCalloutTone.warning,
      ),
      const SizedBox(height: 16),
      _ackTile(
        value: _ackUnderstand,
        label: SeedSafetyCopy.ackUnderstand,
        onChanged: (v) => setState(() => _ackUnderstand = v ?? false),
      ),
      const SizedBox(height: 10),
      _ackTile(
        value: _ackBackup,
        label: SeedSafetyCopy.ackBackup,
        onChanged: (v) => setState(() => _ackBackup = v ?? false),
      ),
      _errorBlock(),
    ];
  }

  List<Widget> _phraseBody() {
    final s = ZuniaSemanticsExt.of(context);
    return [
      const ZuniaStepProgress(
        current: 1,
        total: _createSteps,
        label: 'Recovery phrase',
      ),
      const SizedBox(height: 20),
      Text(
        'Write these ${_wordCount == 12 ? 'twelve' : 'twenty-four'} words '
        'down in order. They are the only way back into this wallet.',
        style: zuniaSans(fontSize: 13, height: 1.6, color: s.fgMuted),
      ),
      const SizedBox(height: 16),
      ZuniaSegmented<int>(
        value: _wordCount,
        onChanged: (v) {
          setState(() => _wordCount = v);
          _regenerate();
        },
        options: const {12: '12 words', 24: '24 words'},
      ),
      const SizedBox(height: 16),
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
      const SizedBox(height: 16),
      ZuniaMnemonicGrid(words: _words, revealed: _revealed),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: s.glass,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: s.glass2,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.block, size: 12, color: s.fgMuted),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Screenshots are blocked on this screen',
                style: zuniaSans(fontSize: 11.5, height: 1.45, color: s.fgMuted),
              ),
            ),
          ],
        ),
      ),
      _errorBlock(),
    ];
  }

  List<Widget> _verifyBody() {
    final s = ZuniaSemanticsExt.of(context);
    final position = _verifyPositions.isEmpty
        ? 0
        : _verifyPositions[_verifyCursor];
    final remaining = _verifyPositions.length - _verifyCursor - 1;
    return [
      const ZuniaStepProgress(
        current: 2,
        total: _createSteps,
        label: 'Verify',
      ),
      const SizedBox(height: 22),
      Text.rich(
        TextSpan(
          text: 'Tap word ',
          style: zuniaSans(
            fontSize: 20,
            height: 1.25,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.6,
            color: s.fg,
          ),
          children: [
            TextSpan(
              text: '${position + 1}',
              style: zuniaSans(
                fontSize: 20,
                fontWeight: FontWeight.w500,
                color: s.info,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text(
        remaining <= 0
            ? 'Last check.'
            : remaining == 1
                ? 'One more check after this one.'
                : '$remaining more checks after this one.',
        style: zuniaSans(fontSize: 13, height: 1.6, color: s.fgMuted),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          for (var i = 0; i < _verifyPositions.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: i == _verifyCursor ? null : s.glass,
                borderRadius: BorderRadius.circular(999),
                border: i == _verifyCursor
                    ? Border.all(color: s.info.withValues(alpha: 0.6))
                    : null,
              ),
              child: Text(
                i < _verifyCursor
                    ? '${_verifyPositions[i] + 1} ✓'
                    : i == _verifyCursor
                        ? '${_verifyPositions[i] + 1} · now'
                        : '${_verifyPositions[i] + 1}',
                style: zuniaMono(
                  fontSize: 11,
                  color: i == _verifyCursor ? s.info : s.fgDim,
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 16),
      ZuniaSeedVerifier(
        options: _verifyOptions,
        onSelect: _onVerifyPick,
      ),
      _errorBlock(),
    ];
  }

  List<Widget> _passwordBody({
    required int current,
    required int total,
    required String subtitle,
  }) {
    return [
      ZuniaStepProgress(current: current, total: total, label: 'Password'),
      const SizedBox(height: 20),
      ZuniaStepHeading(title: 'Name and password', subtitle: subtitle),
      const SizedBox(height: 24),
      ZuniaInput(
        controller: _walletName,
        label: 'Wallet name',
        hint: 'Main',
      ),
      const SizedBox(height: 14),
      ZuniaInput(
        controller: _password,
        label: 'Password',
        hint: 'At least 8 characters',
        obscureText: true,
      ),
      const SizedBox(height: 14),
      ZuniaInput(
        controller: _confirm,
        label: 'Confirm password',
        hint: 'Repeat password',
        obscureText: true,
      ),
      _errorBlock(),
    ];
  }

  List<Widget> _importPhraseBody() {
    return [
      const ZuniaStepProgress(
        current: 1,
        total: _importSteps,
        label: 'Phrase',
      ),
      const SizedBox(height: 20),
      const ZuniaStepHeading(
        title: 'Restore wallet',
        subtitle: 'Enter your existing 12 or 24 word recovery phrase, '
            'separated by spaces.',
      ),
      const SizedBox(height: 20),
      ZuniaSegmented<int>(
        value: _wordCount,
        onChanged: (v) => setState(() => _wordCount = v),
        options: const {12: '12 words', 24: '24 words'},
      ),
      const SizedBox(height: 16),
      SeedTextField(
        controller: _importPhrase,
        label: '$_wordCount-word recovery phrase',
      ),
      _errorBlock(),
    ];
  }

  /// The chain list can run to hundreds of rows, so this step scrolls its own
  /// list under a fixed search and filter header rather than inside the page.
  Widget _networksBody() {
    final importing = _step == _Step.importNetworks;
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
              ZuniaStepProgress(
                current: importing ? 3 : 4,
                total: importing ? _importSteps : _createSteps,
                label: 'Networks',
              ),
              const SizedBox(height: 20),
              ZuniaStepHeading(
                title: 'Choose networks',
                subtitle:
                    '${_selectedChains.length} selected. You can add or remove '
                    'chains at any time from Settings.',
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
                      onPressed: () => setState(
                        () => _selectedChains = {'safrochain-1'},
                      ),
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

  Widget _ackTile({
    required bool value,
    required String label,
    required ValueChanged<bool?> onChanged,
  }) {
    final s = ZuniaSemanticsExt.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: value ? s.accent : s.line),
          color: s.stateHover,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: value,
                onChanged: onChanged,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
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
    );
  }

  Widget _footer() {
    switch (_step) {
      case _Step.welcome:
        return Column(
          children: [
            ZuniaButton(
              label: 'Create a new wallet',
              size: ZuniaButtonSize.lg,
              onPressed: !_acksOk
                  ? null
                  : () {
                      _regenerate();
                      setState(() {
                        _error = null;
                        _step = _Step.createPhrase;
                      });
                    },
            ),
            const SizedBox(height: 10),
            ZuniaButton(
              label: 'I have a recovery phrase',
              size: ZuniaButtonSize.lg,
              variant: ZuniaButtonVariant.secondary,
              onPressed: !_acksOk
                  ? null
                  : () => setState(() {
                        _error = null;
                        _step = _Step.importPhrase;
                      }),
            ),
          ],
        );

      case _Step.createPhrase:
        return _actions(
          primaryLabel: 'I have written it down',
          onPrimary: (_copied || _revealed) ? _startVerification : null,
        );

      case _Step.createVerify:
        return _actions();

      case _Step.createPassword:
        return _actions(
          primaryLabel: 'Continue',
          onPrimary: () {
            if (!_passwordValid()) return;
            setState(() {
              _error = null;
              _step = _Step.createNetworks;
            });
          },
        );

      case _Step.createNetworks:
        return _actions(
          primaryLabel: _busy ? 'Working…' : 'Create wallet',
          onPrimary: _busy ? null : _finishCreate,
        );

      case _Step.importPhrase:
        return _actions(
          primaryLabel: 'Continue',
          onPrimary: () {
            final phrase =
                _importPhrase.text.trim().replaceAll(RegExp(r'\s+'), ' ');
            final parts =
                phrase.split(' ').where((w) => w.isNotEmpty).toList();
            if (parts.length != _wordCount) {
              _setError('Expected $_wordCount words, found ${parts.length}');
              return;
            }
            if (!WalletKernel.instance.validateMnemonic(phrase)) {
              _setError(
                'That phrase fails its checksum. Check for typos or swapped words.',
              );
              return;
            }
            setState(() {
              _error = null;
              _step = _Step.importPassword;
            });
          },
        );

      case _Step.importPassword:
        return _actions(
          primaryLabel: 'Continue',
          onPrimary: () {
            if (!_passwordValid()) return;
            setState(() {
              _error = null;
              _step = _Step.importNetworks;
            });
          },
        );

      case _Step.importNetworks:
        return _actions(
          primaryLabel: _busy ? 'Working…' : 'Restore wallet',
          onPrimary: _busy ? null : _finishImport,
        );
    }
  }

  Widget _actions({String? primaryLabel, VoidCallback? onPrimary}) {
    if (primaryLabel == null) {
      return ZuniaButton(
        label: 'Back',
        variant: ZuniaButtonVariant.secondary,
        onPressed: _busy ? null : _goBack,
      );
    }
    return Row(
      children: [
        Expanded(
          child: ZuniaButton(
            label: 'Back',
            variant: ZuniaButtonVariant.secondary,
            onPressed: _busy ? null : _goBack,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 3,
          child: ZuniaButton(
            label: primaryLabel,
            loading: _busy,
            onPressed: onPrimary,
          ),
        ),
      ],
    );
  }
}
