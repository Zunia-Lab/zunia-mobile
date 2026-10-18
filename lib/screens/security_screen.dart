import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/backup_verify_screen.dart';
import 'package:zunia_mobile/screens/change_password_screen.dart';
import 'package:zunia_mobile/screens/remove_wallet_screen.dart';
import 'package:zunia_mobile/screens/reveal_phrase_screen.dart';
import 'package:zunia_mobile/screens/root_warning_screen.dart';
import 'package:zunia_mobile/screens/sessions_screen.dart';
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_mobile/security/device_integrity.dart';
import 'package:zunia_mobile/security/mnemonic_security_config.dart';
import 'package:zunia_mobile/security/password_prompt.dart';
import 'package:zunia_mobile/security/signing_gate.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/security_settings.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

final _biometricAvailabilityProvider =
    FutureProvider.autoDispose<BiometricAvailability>(
  (ref) => ref.watch(biometricVaultProvider).availability(),
);

final _integrityProvider = FutureProvider.autoDispose<DeviceIntegrityReport>(
  (ref) => DeviceIntegrity.check(),
);

/// Settings > Security: how the wallet locks and unlocks, what signing asks
/// for, the keys, the device, and removing the wallet.
class SecurityScreen extends ConsumerWidget {
  const SecurityScreen({super.key});

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  Future<void> _pickAutoLock(BuildContext context, WidgetRef ref) async {
    final current = ref.read(securitySettingsProvider).autoLock;
    final choice = await showZuniaActionSheet<AutoLockDelay>(
      context,
      title: 'Auto-lock',
      message: 'Counted from your last touch, including time spent in other '
          'apps.',
      actions: [
        for (final d in AutoLockDelay.values)
          ZuniaAlertAction(
            label: d == current ? '${d.label}  ✓' : d.label,
            value: d,
            isDefault: d == current,
          ),
      ],
    );
    if (choice != null) {
      await ref.read(securitySettingsProvider.notifier).setAutoLock(choice);
    }
  }

  Future<void> _toggleBiometrics(
    BuildContext context,
    WidgetRef ref,
    bool enable,
    String label,
  ) async {
    final session = ref.read(vaultSessionProvider);
    if (!enable) {
      await session.disableBiometrics();
      return;
    }
    final password = await showPasswordPrompt(
      context,
      title: 'Turn on $label',
      reason: 'Enter the wallet password. $label will release it from this '
          'device\'s secure hardware from now on.',
      check: session.verifyPassword,
      throttle: session.throttle,
    );
    if (password == null || !context.mounted) return;
    try {
      await session.enableBiometrics(
        password,
        BiometricPromptText(title: 'Turn on $label', subtitle: 'Unlock Zunia'),
      );
      unawaited(ZuniaHaptics.success());
    } on BiometricException catch (e) {
      if (!context.mounted) return;
      if (e.failure == BiometricFailure.cancelled) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('$label could not be turned on.')),
      );
    }
  }

  Future<void> _togglePasswordOnSign(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    // Turning a protection off is itself protected.
    if (!value &&
        !await confirmIdentity(
          context,
          ref,
          reason: 'Signatures will no longer ask for your password.',
        )) {
      return;
    }
    await ref.read(securitySettingsProvider.notifier).setPasswordOnSign(value);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final settings = ref.watch(securitySettingsProvider);
    final wallet = ref.watch(walletProvider);
    final account = wallet.active;
    final info = account == null ? null : wallet.phraseOf(account);
    final bio = ref.watch(_biometricAvailabilityProvider).valueOrNull;
    final integrity = ref.watch(_integrityProvider).valueOrNull;
    final prefs = ref.watch(preferencesProvider);
    final cupertino = ZuniaPlatform.isCupertino(context);
    final bioLabel = bio?.label(apple: cupertino) ?? 'biometrics';
    final bioTitle =
        '${bioLabel[0].toUpperCase()}${bioLabel.substring(1)} unlock';
    final wc = ref.watch(walletConnectProvider);
    final native = ref.watch(nativeConnectProvider);
    final sessions = wc.activeSessions.length + native.activeSessions.length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Security',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              ZuniaListSection(
                header: 'Session',
                footer: 'Locking wipes the recovery phrases from memory. '
                    'Whatever was open is still there after unlocking.',
                children: [
                  ZuniaListTile(
                    title: 'Auto-lock',
                    leading: Icons.lock_clock_outlined,
                    value: settings.autoLock.label,
                    navigates: true,
                    onTap: () => _pickAutoLock(context, ref),
                  ),
                  ZuniaListTile(
                    title: bioTitle,
                    leading: bio?.kind == BiometricKind.face
                        ? Icons.face_outlined
                        : Icons.fingerprint,
                    subtitle: bio == null
                        ? null
                        : bio.available
                            ? 'Bound to this device\'s secure hardware. Adding '
                                'a face or finger turns it off.'
                            : _unavailableReason(bio.reason),
                    trailing: ZuniaAdaptiveSwitch(
                      value: settings.biometricUnlock,
                      onChanged: bio?.available == true || settings.biometricUnlock
                          ? (v) => _toggleBiometrics(context, ref, v, bioLabel)
                          : null,
                    ),
                  ),
                  ZuniaListTile(
                    title: 'Password on every signature',
                    leading: Icons.draw_outlined,
                    subtitle: 'Ask again before each signature, in the wallet '
                        'and for apps, even while unlocked.',
                    trailing: ZuniaAdaptiveSwitch(
                      value: settings.passwordOnSign,
                      onChanged: (v) => _togglePasswordOnSign(context, ref, v),
                    ),
                  ),
                  ZuniaListTile(
                    title: 'Lock now',
                    leading: Icons.lock_outline,
                    onTap: () {
                      unawaited(ZuniaHaptics.light());
                      ref.read(vaultSessionProvider).lock();
                    },
                  ),
                ],
              ),
              ZuniaListSection(
                header: 'Keys',
                children: [
                  ZuniaListTile(
                    title: 'Change password',
                    leading: Icons.password_outlined,
                    navigates: true,
                    onTap: () => _open(context, const ChangePasswordScreen()),
                  ),
                  ZuniaListTile(
                    title: 'Show recovery phrase',
                    leading: Icons.key_outlined,
                    subtitle: account == null
                        ? null
                        : '${account.name} · password required',
                    navigates: true,
                    onTap: () => _open(context, const RevealPhraseScreen()),
                  ),
                  ZuniaListTile(
                    title: 'Backup',
                    leading: Icons.task_alt_outlined,
                    value: info == null
                        ? null
                        : info.backupVerified
                            ? 'Verified'
                            : 'Not verified',
                    navigates: info != null && !info.backupVerified,
                    onTap: info == null || info.backupVerified
                        ? null
                        : () => _open(
                              context,
                              BackupVerifyScreen(phraseId: info.id),
                            ),
                  ),
                  ZuniaListTile(
                    title: 'Connected apps',
                    leading: Icons.link,
                    value: '$sessions',
                    navigates: true,
                    onTap: () => _open(context, const SessionsScreen()),
                  ),
                ],
              ),
              ZuniaListSection(
                header: 'Device',
                children: [
                  ZuniaListTile(
                    title: 'Device integrity',
                    leading: Icons.verified_user_outlined,
                    subtitle: integrity == null
                        ? 'Checking…'
                        : !integrity.checked
                            ? 'Not checked on this build'
                            : integrity.isCompromised
                                ? 'Signs of root or jailbreak found'
                                : 'No obvious sign of root or jailbreak',
                    navigates: true,
                    onTap: () => _open(context, const RootWarningScreen()),
                  ),
                  ZuniaListTile(
                    title: 'Screen capture',
                    leading: Icons.screenshot_monitor_outlined,
                    subtitle: !Platform.isIOS
                        ? 'Blocked on the recovery phrase and password '
                            'screens; allowed elsewhere, so a receive code '
                            'can be shared.'
                        : 'iOS cannot block screenshots. Zunia warns after '
                            'one on a phrase screen, hides the phrase while '
                            'the screen is recorded, and covers the app in '
                            'the app switcher.',
                  ),
                  const ZuniaListTile(
                    title: 'Clipboard',
                    leading: Icons.content_paste_off_outlined,
                    subtitle: 'A copied recovery phrase is cleared after '
                        '${MnemonicSecurityConfig.clipboardAutoClearSeconds} s '
                        'and when the wallet locks.',
                  ),
                ],
              ),
              ZuniaListSection(
                header: 'Danger zone',
                children: [
                  ZuniaListTile(
                    title: 'Remove wallet from this device',
                    leading: Icons.delete_outline,
                    subtitle: 'Erases every account, connected app and site '
                        'permission',
                    destructive: true,
                    onTap: () => _open(context, const RemoveWalletScreen()),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Center(
                child: Text(
                  'AUDIT PUBLISHED · APACHE 2.0',
                  style: zuniaMono(fontSize: 9.5, letterSpacing: 1.2, color: s.fgDim),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _unavailableReason(String? reason) => switch (reason) {
        'none_enrolled' =>
          'Add a face or fingerprint in the device settings first.',
        'passcode_not_set' => 'Set a device passcode first.',
        'locked_out' => 'Locked after too many attempts. Unlock the device '
            'with its passcode, then try again.',
        'unsupported' => 'Not available in this build.',
        _ => 'This device has no biometric sensor strong enough to protect a '
            'key.',
      };
}
