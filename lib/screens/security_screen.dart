import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/reveal_phrase_screen.dart';
import 'package:zunia_mobile/screens/root_warning_screen.dart';
import 'package:zunia_mobile/security/mnemonic_security_config.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/settings_tiles.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Backup state, device checks and the destructive wipe.
class SecurityScreen extends ConsumerWidget {
  const SecurityScreen({super.key});

  Future<void> _wipe(BuildContext context, WidgetRef ref) async {
    final confirm = TextEditingController();
    final s = ZuniaSemanticsExt.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: s.surfaceRaised,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: s.danger.withValues(alpha: 0.45)),
          ),
          title: Text(
            'Remove this wallet?',
            style: zuniaSans(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: s.fg,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The sealed vault is erased from this device. Only your recovery '
                'phrase can bring it back.',
                style: zuniaSans(fontSize: 12, height: 1.6, color: s.fgMuted),
              ),
              const SizedBox(height: 14),
              ZuniaInput(
                controller: confirm,
                label: 'Type ERASE to confirm',
                hint: 'ERASE',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                'Cancel',
                style: zuniaSans(fontSize: 13, color: s.fgMuted),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                'Remove',
                style: zuniaSans(fontSize: 13, color: s.danger),
              ),
            ),
          ],
        );
      },
    );

    final typed = confirm.text.trim().toUpperCase();
    confirm.dispose();
    if (ok != true || typed != 'ERASE') return;

    await ref.read(keystoreProvider).wipe();
    await ref.read(walletProvider.notifier).clear();
    ref.read(phraseProvider.notifier).state = null;
    ref.read(sessionProvider.notifier).state = null;
    ref.invalidate(appGateProvider);
    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final verified = ref.watch(backupVerifiedProvider);
    final prefs = ref.watch(preferencesProvider);
    final wc = ref.watch(walletConnectProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Security',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              SettingsGroup(
                label: 'Device',
                children: [
                  SettingsRow(
                    title: 'Device integrity',
                    description: 'Root and jailbreak check',
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const RootWarningScreen(),
                      ),
                    ),
                  ),
                  const SettingsRow(
                    title: 'Screen capture',
                    description:
                        'Sensitive screens stay secure on Android and blur '
                        'in the app switcher on iOS',
                  ),
                  SettingsRow(
                    title: 'Clipboard',
                    description:
                        'Copied phrases clear after '
                        '${MnemonicSecurityConfig.autoHideAfterSeconds}s',
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SettingsGroup(
                label: 'Keys',
                children: [
                  SettingsRow(
                    title: 'Reveal recovery phrase',
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const RevealPhraseScreen(),
                      ),
                    ),
                  ),
                  SettingsRow(
                    title: 'Backup status',
                    trailing: Text(
                      verified.maybeWhen(
                        data: (ok) => ok ? 'verified' : 'not verified',
                        orElse: () => '…',
                      ),
                      style: zuniaMono(
                        fontSize: 10.5,
                        color: verified.maybeWhen(
                          data: (ok) => ok ? s.info : s.warning,
                          orElse: () => s.fgMuted,
                        ),
                      ),
                    ),
                  ),
                  SettingsRow(
                    title: 'Connected dApps',
                    trailing: Text(
                      wc.isReady ? 'ready' : '0 sessions',
                      style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SettingsGroup(
                label: 'Privacy',
                children: [
                  SettingsRow(
                    title: 'Anonymous diagnostics',
                    description: 'Keep local logs for troubleshooting',
                    trailing: ZuniaSwitch(
                      value: prefs.diagnostics,
                      onChanged: (v) => ref
                          .read(preferencesProvider.notifier)
                          .setDiagnostics(v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              OutlinedButton(
                onPressed: () => _wipe(context, ref),
                style: OutlinedButton.styleFrom(
                  foregroundColor: s.danger,
                  side: BorderSide(color: s.danger.withValues(alpha: 0.45)),
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                child: Text(
                  'Remove wallet from device',
                  style: zuniaSans(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: s.danger,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  'audit published · Apache 2.0',
                  style: zuniaMono(fontSize: 10, color: s.fgDim),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
