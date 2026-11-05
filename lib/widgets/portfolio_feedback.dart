/// Small shared pieces of the portfolio screens: copying with feedback,
/// opening an explorer, and the network-fee preference sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_mobile/security/clipboard_guard.dart';
import 'package:zunia_mobile/state/fee_prefs.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Copy [value], tick the haptic, and say what was copied. The clipboard is
/// cleared after the policy's timeout, as every copy in the wallet is.
Future<void> copyWithFeedback(BuildContext context, String value, String what) async {
  await ClipboardGuard.copy(value);
  await ZuniaHaptics.selection();
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text('$what copied'),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ));
}

/// Open an explorer page in the system browser. Says so when it cannot.
Future<void> openExternal(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  final ok = uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Could not open the link'), behavior: SnackBarBehavior.floating),
    );
  }
}

/// Speed and gas adjustment, saved for every transaction. Returns true when
/// the user saved a change, so the caller re-prices its review.
Future<bool> showFeePrefsSheet(BuildContext context, WidgetRef ref) async {
  final current = ref.read(feePrefsProvider);
  final saved = await showModalBottomSheet<FeePrefs>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _FeePrefsSheet(initial: current),
  );
  if (saved == null) return false;
  await ref.read(feePrefsProvider.notifier).set(speed: saved.speed, gasAdjustment: saved.gasAdjustment);
  return saved.speed != current.speed || saved.gasAdjustment != current.gasAdjustment;
}

class _FeePrefsSheet extends StatefulWidget {
  const _FeePrefsSheet({required this.initial});

  final FeePrefs initial;

  @override
  State<_FeePrefsSheet> createState() => _FeePrefsSheetState();
}

class _FeePrefsSheetState extends State<_FeePrefsSheet> {
  late FeeSpeed _speed = widget.initial.speed;
  late double _adjustment = widget.initial.gasAdjustment;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Network fee',
            style: zuniaSans(fontSize: 18, fontWeight: FontWeight.w500, color: s.fg),
          ),
          const SizedBox(height: 4),
          Text(
            'Used on every transaction. Mid is the default.',
            style: zuniaSans(fontSize: 13, color: s.fgMuted),
          ),
          const SizedBox(height: 18),
          const ZuniaSectionLabel('Speed'),
          const SizedBox(height: 8),
          ZuniaSegmented<FeeSpeed>(
            value: _speed,
            onChanged: (value) {
              ZuniaHaptics.selection();
              setState(() => _speed = value);
            },
            options: {for (final speed in FeeSpeed.values) speed: speed.label},
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(child: ZuniaSectionLabel('Gas adjustment')),
              Text(
                '${_adjustment.toStringAsFixed(1)}×',
                style: zuniaMono(fontSize: 13, color: s.fg),
              ),
            ],
          ),
          Slider.adaptive(
            value: _adjustment,
            min: minGasAdjustment,
            max: maxGasAdjustment,
            divisions: 10,
            label: '${_adjustment.toStringAsFixed(1)}×',
            semanticFormatterCallback: (value) => 'Gas adjustment ${value.toStringAsFixed(1)} times',
            onChanged: (value) => setState(() => _adjustment = (value * 10).round() / 10),
          ),
          Text(
            'Gas is the simulated amount times this. Higher leaves more room for a busy block; '
            'what is not used is not refunded.',
            style: zuniaSans(fontSize: 12, height: 1.4, color: s.fgDim),
          ),
          const SizedBox(height: 20),
          ZuniaButton(
            label: 'Save',
            size: ZuniaButtonSize.lg,
            onPressed: () => Navigator.of(context).pop(
              FeePrefs(speed: _speed, gasAdjustment: _adjustment),
            ),
          ),
        ],
      ),
    );
  }
}
