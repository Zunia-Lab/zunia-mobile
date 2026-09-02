import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/security/clipboard_guard.dart';
import 'package:zunia_mobile/security/mnemonic_security_config.dart';
import 'package:zunia_mobile/security/seed_safety_copy.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Shows the recovery phrase behind a password re-entry, and re-hides it on a
/// timer so it never sits on screen.
class RevealPhraseScreen extends ConsumerStatefulWidget {
  const RevealPhraseScreen({super.key});

  @override
  ConsumerState<RevealPhraseScreen> createState() => _RevealPhraseScreenState();
}

class _RevealPhraseScreenState extends ConsumerState<RevealPhraseScreen> {
  final _password = TextEditingController();
  bool _unlocked = false;
  bool _revealed = false;
  bool _busy = false;
  String? _error;
  Timer? _autoHide;

  @override
  void dispose() {
    _autoHide?.cancel();
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(keystoreProvider).unlockWithPassword(_password.text);
      if (!mounted) return;
      setState(() => _unlocked = true);
    } catch (_) {
      setState(() => _error = 'That password does not match this vault.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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

  @override
  Widget build(BuildContext context) {
    final phrase = ref.watch(phraseProvider);
    final words = phrase == null
        ? const <String>[]
        : phrase.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

    return Scaffold(
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Recovery phrase',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              const ZuniaCallout(
                tone: ZuniaCalloutTone.warning,
                title: SeedSafetyCopy.title,
                body: SeedSafetyCopy.summary,
              ),
              const SizedBox(height: 18),
              if (!_unlocked) ...[
                ZuniaInput(
                  controller: _password,
                  label: 'Password',
                  hint: 'Confirm to continue',
                  obscureText: true,
                  errorText: _error,
                  onSubmitted: (_) => _confirm(),
                ),
              ] else ...[
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
                        label: 'Copy',
                        size: ZuniaButtonSize.sm,
                        variant: ZuniaButtonVariant.secondary,
                        leading: const Icon(Icons.copy_outlined),
                        onPressed: phrase == null
                            ? null
                            : () => ClipboardGuard.copy(
                                  phrase,
                                  isMnemonic: true,
                                  force: true,
                                ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ZuniaMnemonicGrid(words: words, revealed: _revealed),
              ],
            ],
          ),
          footer: _unlocked
              ? null
              : ZuniaButton(
                  label: 'Confirm password',
                  size: ZuniaButtonSize.lg,
                  loading: _busy,
                  onPressed: _busy ? null : _confirm,
                ),
        ),
      ),
    );
  }
}
