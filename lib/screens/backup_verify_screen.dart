import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/security/mnemonic_security_config.dart';
import 'package:zunia_mobile/security/screen_security.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// "Tap word N" for 4 random positions of a 12-word phrase, 6 of a 24-word
/// one. Decoys come from the phrase itself, so the answer cannot be spotted
/// as the only real BIP-39 word.
class BackupQuiz extends StatefulWidget {
  const BackupQuiz({super.key, required this.words, required this.onPassed});

  final List<String> words;
  final VoidCallback onPassed;

  @override
  State<BackupQuiz> createState() => _BackupQuizState();
}

class _BackupQuizState extends State<BackupQuiz> {
  final _random = Random.secure();
  late List<int> _positions;
  int _cursor = 0;
  List<String> _options = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    final total = widget.words.length;
    final indices = List.generate(total, (i) => i)..shuffle(_random);
    _positions =
        indices.take(MnemonicSecurityConfig.verifyWordCount(total)).toList()
          ..sort();
    _options = _optionsFor(widget.words[_positions.first]);
  }

  List<String> _optionsFor(String word) {
    final pool = widget.words.toSet().where((w) => w != word).toList()
      ..shuffle(_random);
    return <String>[word, ...pool.take(2)]..shuffle(_random);
  }

  void _pick(String word) {
    final index = _positions[_cursor];
    if (widget.words[index] != word) {
      unawaited(ZuniaHaptics.error());
      setState(() => _error = 'Word ${index + 1} is not "$word". Check your copy.');
      return;
    }
    unawaited(ZuniaHaptics.selection());
    if (_cursor + 1 >= _positions.length) {
      unawaited(ZuniaHaptics.success());
      widget.onPassed();
      return;
    }
    setState(() {
      _error = null;
      _cursor += 1;
      _options = _optionsFor(widget.words[_positions[_cursor]]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final position = _positions[_cursor];
    final remaining = _positions.length - _cursor - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          liveRegion: true,
          child: Text.rich(
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
                  style: zuniaMono(fontSize: 20, color: s.info),
                ),
              ],
            ),
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
            for (var i = 0; i < _positions.length; i++)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: i == _cursor ? null : s.glass,
                  borderRadius: BorderRadius.circular(999),
                  border: i == _cursor
                      ? Border.all(color: s.info.withValues(alpha: 0.6))
                      : null,
                ),
                child: Text(
                  i < _cursor
                      ? '${_positions[i] + 1} ✓'
                      : i == _cursor
                          ? '${_positions[i] + 1} · now'
                          : '${_positions[i] + 1}',
                  style: zuniaMono(
                    fontSize: 11,
                    color: i == _cursor ? s.info : s.fgDim,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        ZuniaSeedVerifier(options: _options, onSelect: _pick),
        if (_error != null) ...[
          const SizedBox(height: 16),
          ZuniaCallout(body: _error!, tone: ZuniaCalloutTone.danger),
        ],
      ],
    );
  }
}

/// Verify a phrase that is already in the wallet (one that was restored, or
/// whose check was skipped): the user picks words from their written copy.
/// Pops true once verified.
class BackupVerifyScreen extends ConsumerStatefulWidget {
  const BackupVerifyScreen({super.key, required this.phraseId});

  final String phraseId;

  @override
  ConsumerState<BackupVerifyScreen> createState() => _BackupVerifyScreenState();
}

class _BackupVerifyScreenState extends ConsumerState<BackupVerifyScreen> {
  @override
  void initState() {
    super.initState();
    // Holds no secret itself, but asks about one: close on lock.
    ref.listenManual(lockEpochProvider, (_, _) {
      final route = ModalRoute.of(context);
      if (mounted && route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  Future<void> _passed() async {
    await ref.read(vaultSessionProvider).markBackupVerified(widget.phraseId);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final phrase = ref.watch(sessionProvider)?.phraseFor(widget.phraseId);
    final words = phrase?.split(' ') ?? const <String>[];
    return SensitiveScreen(
      child: Scaffold(
        backgroundColor: s.bg,
        body: SafeArea(
          bottom: false,
          child: ZuniaScreenScaffold(
            title: 'Verify backup',
            onBack: () => Navigator.of(context).pop(false),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                Text(
                  'Take out your written recovery phrase. Zunia asks for a few '
                  'of its words to make sure the copy is complete.',
                  style: zuniaSans(fontSize: 13, height: 1.55, color: s.fgMuted),
                ),
                const SizedBox(height: 22),
                if (words.isEmpty)
                  const ZuniaCallout(
                    body: 'Unlock the wallet to verify this phrase.',
                    tone: ZuniaCalloutTone.info,
                  )
                else
                  BackupQuiz(words: words, onPassed: _passed),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
