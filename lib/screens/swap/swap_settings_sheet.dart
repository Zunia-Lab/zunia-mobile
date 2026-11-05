/// Swap settings: slippage, the network fee speed, and whether the route's
/// hops and channels show under the form. A native sheet; values and limits
/// come from the release's `interchain.json`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/swap/swap_config.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_ui/zunia_ui.dart';

Future<void> showSwapSettingsSheet(
  BuildContext context, {
  required SwapConfig config,
  required SwapSettings settings,
  required ValueChanged<SwapSettings> onSave,
}) {
  return showZuniaSheet<void>(
    context,
    title: 'Swap settings',
    builder: (ctx) => SwapSettingsForm(
      config: config,
      settings: settings,
      onCancel: () => Navigator.of(ctx).pop(),
      onSave: (next) {
        onSave(next);
        Navigator.of(ctx).pop();
      },
    ),
  );
}

String _percent(double value) {
  final text = value.toStringAsFixed(2);
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}

class SwapSettingsForm extends StatefulWidget {
  const SwapSettingsForm({
    super.key,
    required this.config,
    required this.settings,
    required this.onSave,
    required this.onCancel,
  });

  final SwapConfig config;
  final SwapSettings settings;
  final ValueChanged<SwapSettings> onSave;
  final VoidCallback onCancel;

  @override
  State<SwapSettingsForm> createState() => _SwapSettingsFormState();
}

class _SwapSettingsFormState extends State<SwapSettingsForm> {
  late double _slippage = widget.settings.slippageOr(
    widget.config.defaultSlippagePercent,
  );
  late FeeSpeed _speed = widget.settings.feeSpeed;
  late bool _details = widget.settings.routeDetails;
  late final TextEditingController _custom = TextEditingController(
    text: _percent(_slippage),
  );
  late bool _customMode = !widget.config.slippagePresets.contains(_slippage);

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  bool get _ok => slippageAllowed(_slippage, widget.config.maxSlippagePercent);

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final config = widget.config;
    final options = <String, String>{
      for (final preset in config.slippagePresets)
        _percent(preset): '${_percent(preset)}%',
      'custom': 'Custom',
    };
    final value = _customMode || !config.slippagePresets.contains(_slippage)
        ? 'custom'
        : _percent(_slippage);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Slippage is how far the price can move before the swap is refused. '
            'The fee speed applies to this swap only.',
            style: zuniaSans(fontSize: 13, height: 1.45, color: s.fgMuted),
          ),
          const SizedBox(height: 16),
          const ZuniaSectionLabel('Slippage'),
          const SizedBox(height: 8),
          ZuniaSegmented<String>(
            options: options,
            value: value,
            onChanged: (next) {
              setState(() {
                if (next == 'custom') {
                  _customMode = true;
                  return;
                }
                _customMode = false;
                _slippage = double.parse(next);
                _custom.text = next;
              });
            },
          ),
          if (value == 'custom') ...[
            const SizedBox(height: 10),
            ZuniaInput(
              controller: _custom,
              label: 'Slippage, %',
              hint: _percent(config.defaultSlippagePercent),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              onChanged: (text) => setState(() {
                _slippage =
                    double.tryParse(text.replaceAll(',', '.')) ?? double.nan;
              }),
            ),
          ],
          if (_ok && _slippage > config.highSlippagePercent) ...[
            const SizedBox(height: 10),
            ZuniaCallout(
              tone: ZuniaCalloutTone.warning,
              body:
                  'Wide tolerance. The swap can take a price up to '
                  '${_percent(_slippage)}% worse than quoted before it is refused.',
            ),
          ],
          if (!_ok) ...[
            const SizedBox(height: 10),
            ZuniaCallout(
              tone: ZuniaCalloutTone.danger,
              body:
                  'Use a value above 0 and up to ${_percent(config.maxSlippagePercent)}%.',
            ),
          ],
          const SizedBox(height: 18),
          const ZuniaSectionLabel('Network fee'),
          const SizedBox(height: 8),
          ZuniaSegmented<FeeSpeed>(
            options: {for (final speed in FeeSpeed.values) speed: speed.label},
            value: _speed,
            onChanged: (next) => setState(() => _speed = next),
          ),
          const SizedBox(height: 18),
          ZuniaListSection(
            children: [
              MergeSemantics(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  title: Text(
                    'Route details',
                    style: zuniaSans(fontSize: 15, color: s.fg),
                  ),
                  subtitle: Text(
                    'Hops, channels and the contract, under the form.',
                    style: zuniaSans(fontSize: 12, color: s.fgMuted),
                  ),
                  trailing: ZuniaAdaptiveSwitch(
                    value: _details,
                    onChanged: (next) => setState(() => _details = next),
                  ),
                  onTap: () => setState(() => _details = !_details),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: ZuniaButton(
                  label: 'Cancel',
                  variant: ZuniaButtonVariant.secondary,
                  onPressed: widget.onCancel,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ZuniaButton(
                  label: 'Save',
                  onPressed: _ok
                      ? () {
                          ZuniaHaptics.selection();
                          widget.onSave(
                            widget.settings.copyWith(
                              slippagePercent: double.parse(
                                _slippage.toStringAsFixed(2),
                              ),
                              feeSpeed: _speed,
                              routeDetails: _details,
                            ),
                          );
                        }
                      : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
