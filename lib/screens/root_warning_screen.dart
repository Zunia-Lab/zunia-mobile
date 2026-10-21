import 'package:flutter/material.dart';
import 'package:zunia_mobile/security/device_integrity.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// What the basic root / jailbreak checks found, in honest terms: a clean
/// result means no obvious sign, not a guarantee.
class RootWarningScreen extends StatefulWidget {
  const RootWarningScreen({super.key});

  @override
  State<RootWarningScreen> createState() => _RootWarningScreenState();
}

class _RootWarningScreenState extends State<RootWarningScreen> {
  DeviceIntegrityReport? _report;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    final report = await DeviceIntegrity.check(refresh: refresh);
    if (mounted) setState(() => _report = report);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final report = _report;
    final compromised = report?.isCompromised ?? false;

    final (title, body, icon, color) = switch (report) {
      null => ('Checking this device…', '', Icons.hourglass_empty, s.fgMuted),
      DeviceIntegrityReport(checked: false) => (
          'Not checked',
          'This build has no native integrity checks, so Zunia cannot say '
              'anything about this device.',
          Icons.help_outline,
          s.fgMuted,
        ),
      DeviceIntegrityReport(isCompromised: true) => (
          'This device looks rooted or jailbroken',
          'Apps on a rooted or jailbroken device can read other apps\' memory '
              'and storage, recovery phrases included. Use Zunia here only '
              'for amounts you can afford to lose, and keep your main funds '
              'on a device that has not been modified.',
          Icons.warning_amber_rounded,
          s.warning,
        ),
      _ => (
          'No obvious sign of root or jailbreak',
          'Zunia looked for the usual traces: su binaries and test-keys '
              'builds on Android, jailbreak files, apps and hooking libraries '
              'on iOS. A determined attacker can hide them, so this is a basic '
              'check, not a guarantee.',
          Icons.verified_user_outlined,
          s.success,
        ),
    };

    return Scaffold(
      backgroundColor: s.bg,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Device integrity',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            children: [
              Icon(icon, size: 52, color: color),
              const SizedBox(height: 16),
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: zuniaSans(
                    fontSize: 21,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.5,
                    color: s.fg,
                  ),
                ),
              ),
              if (body.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  body,
                  style: zuniaSans(fontSize: 14, height: 1.55, color: s.fgMuted),
                ),
              ],
              if (report != null && report.emulator) ...[
                const SizedBox(height: 14),
                const ZuniaCallout(
                  tone: ZuniaCalloutTone.info,
                  body: 'This is a simulator or emulator.',
                ),
              ],
              if (report != null && report.signals.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'WHAT WAS FOUND',
                  style: zuniaMono(fontSize: 9.5, letterSpacing: 1.2, color: s.fgDim),
                ),
                const SizedBox(height: 8),
                for (final signal in report.signals)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '· $signal',
                      style: zuniaMono(fontSize: 11.5, color: s.fgMuted),
                    ),
                  ),
              ],
            ],
          ),
          footer: ZuniaButton(
            label: compromised ? 'I understand' : 'Done',
            size: ZuniaButtonSize.lg,
            variant: compromised
                ? ZuniaButtonVariant.secondary
                : ZuniaButtonVariant.primary,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }
}
