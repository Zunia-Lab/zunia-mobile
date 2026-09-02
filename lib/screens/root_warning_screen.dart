import 'package:flutter/material.dart';
import 'package:zunia_mobile/security/device_integrity.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Warns when the device integrity stub reports a compromised environment.
class RootWarningScreen extends StatefulWidget {
  const RootWarningScreen({super.key, this.forceShow = false});

  /// When true, always show the warning (debug / settings preview).
  final bool forceShow;

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

  Future<void> _load() async {
    final report = await DeviceIntegrity.check(
      debugForceCompromised: widget.forceShow,
    );
    if (mounted) setState(() => _report = report);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final report = _report;
    final compromised = report?.isCompromised ?? widget.forceShow;

    return Scaffold(
      appBar: AppBar(title: const Text('Device security')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              compromised ? Icons.warning_amber_rounded : Icons.verified_user_outlined,
              size: 56,
              color: compromised ? Colors.amber : s.fgMuted,
            ),
            const SizedBox(height: 16),
            Text(
              compromised
                  ? 'This device may be rooted or jailbroken'
                  : 'No integrity issues detected',
              style: zuniaSans(
                fontSize: 22,
                fontWeight: FontWeight.w500,
                color: s.fg,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              compromised
                  ? 'Running a wallet on a compromised device increases the risk '
                      'of seed theft. Continue only if you accept that risk. '
                      'Play Integrity / DeviceCheck can replace this stub later.'
                  : 'Checks are currently a stub and can be upgraded to Play Integrity '
                      'or Apple DeviceCheck without changing this screen.',
              style: zuniaSans(fontSize: 14, height: 1.5, color: s.fgMuted),
            ),
            if (report != null && report.signals.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Signals: ${report.signals.join(', ')}',
                style: zuniaMono(fontSize: 12, color: s.fgDim),
              ),
            ],
            const Spacer(),
            ZuniaButton(
              label: compromised ? 'Continue anyway' : 'Done',
              onPressed: () => Navigator.of(context).pop(!compromised),
            ),
          ],
        ),
      ),
    );
  }
}
