import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Delegate form for one validator. Signing stays off-device until a broadcast
/// endpoint is wired, so Review only validates the amount locally.
class DelegateScreen extends ConsumerStatefulWidget {
  const DelegateScreen({
    super.key,
    required this.chainId,
    required this.moniker,
    required this.operatorAddress,
  });

  final String chainId;
  final String moniker;
  final String operatorAddress;

  @override
  ConsumerState<DelegateScreen> createState() => _DelegateScreenState();
}

class _DelegateScreenState extends ConsumerState<DelegateScreen> {
  final _amount = TextEditingController();
  double _fraction = 0;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _applyFraction(double fraction, String available, int decimals) {
    final whole = double.tryParse(
          formatBaseUnitsExact(available, decimals: decimals),
        ) ??
        0;
    _fraction = fraction;
    _amount.text = (whole * fraction).toStringAsFixed(
      decimals > 6 ? 6 : decimals,
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final match = accounts.where((a) => a.chain.chainId == widget.chainId);
    final account = match.isNotEmpty
        ? match.first
        : (accounts.isEmpty ? null : accounts.first);
    if (account == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: ZuniaScreenScaffold(
            title: 'Delegate',
            onBack: () => Navigator.of(context).pop(),
            body: const ZuniaEmptyState(
              title: 'Chain not enabled',
              description: 'Enable this network before staking.',
            ),
          ),
        ),
      );
    }

    final chain = account.chain;
    final available =
        ref.watch(balancesProvider).valueOrNull?[widget.chainId]?.available ??
            '0';
    final ready = (double.tryParse(_amount.text.trim()) ?? 0) > 0;
    final availableLabel = prefs.mask(
      formatBaseUnits(available, decimals: chain.coinDecimals),
    );
    final initials = widget.moniker.trim().isEmpty
        ? '?'
        : widget.moniker
            .trim()
            .split(RegExp(r'\s+'))
            .take(2)
            .map((w) => w.characters.first.toUpperCase())
            .join();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Delegate',
          onBack: () => Navigator.of(context).pop(),
          footer: ZuniaButton(
            label: ready
                ? 'Delegate ${_amount.text.trim()} ${chain.coinDenom}'
                : 'Enter an amount',
            size: ZuniaButtonSize.lg,
            onPressed: ready
                ? () => _review(chain.coinDenom, account.address)
                : null,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: s.surfaceRaisedGradient,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: s.accent,
                        ),
                        child: Text(
                          initials,
                          style: zuniaMono(
                            fontSize: 11,
                            color: s.accentFg,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.moniker,
                              overflow: TextOverflow.ellipsis,
                              style: zuniaSans(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: s.fg,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              truncateAddress(widget.operatorAddress),
                              style:
                                  zuniaMono(fontSize: 10, color: s.fgMuted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                'DELEGATE',
                textAlign: TextAlign.center,
                style: zuniaMono(
                  fontSize: 10,
                  letterSpacing: 1.6,
                  color: s.fgMuted,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textAlign: TextAlign.center,
                      style: zuniaSans(
                        fontSize: 38,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -1.7,
                        height: 1,
                        color: s.fg,
                        tabular: FontFeature.tabularFigures(),
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '0',
                        hintStyle: zuniaSans(
                          fontSize: 38,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -1.7,
                          color: s.fgDim,
                        ),
                      ),
                      onChanged: (_) {
                        final whole = double.tryParse(
                              formatBaseUnitsExact(
                                available,
                                decimals: chain.coinDecimals,
                              ),
                            ) ??
                            0;
                        final entered =
                            double.tryParse(_amount.text.trim()) ?? 0;
                        setState(() {
                          _fraction = whole <= 0
                              ? 0
                              : (entered / whole).clamp(0.0, 1.0);
                        });
                      },
                    ),
                  ),
                  Text(
                    chain.coinDenom,
                    style: zuniaMono(fontSize: 14, color: s.fgMuted),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 40,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 13,
                  ),
                  overlayShape: SliderComponentShape.noOverlay,
                  activeTrackColor: s.accent,
                  inactiveTrackColor: s.glass,
                  thumbColor: s.fg,
                ),
                child: Slider(
                  value: _fraction,
                  onChanged: (v) =>
                      _applyFraction(v, available, chain.coinDecimals),
                ),
              ),
              Row(
                children: [
                  Text('0', style: zuniaMono(fontSize: 10, color: s.fgDim)),
                  const Spacer(),
                  Text(
                    '$availableLabel available',
                    style: zuniaMono(fontSize: 10, color: s.fgDim),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: s.glass,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const ZuniaKeyValueRow(
                        label: 'Unbonding',
                        value: 'chain period',
                      ),
                      const SizedBox(height: 11),
                      ZuniaKeyValueRow(
                        label: 'Fee denom',
                        value: chain.feeDenom,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const ZuniaCallout(
                tone: ZuniaCalloutTone.warning,
                title: 'Unbonding period applies',
                body:
                    'Staked funds are locked for the chain’s unbonding window '
                    'after undelegating.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _review(String denom, String from) {
    final s = ZuniaSemanticsExt.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: BoxDecoration(
          gradient: s.sheetGradient,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: s.line)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Review delegation',
                style: zuniaSans(
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.3,
                  color: s.fg,
                ),
              ),
              const SizedBox(height: 18),
              ZuniaKeyValueRow(
                label: 'Validator',
                value: widget.moniker,
              ),
              const SizedBox(height: 12),
              ZuniaKeyValueRow(
                label: 'Amount',
                value: '${_amount.text.trim()} $denom',
              ),
              const SizedBox(height: 12),
              ZuniaKeyValueRow(label: 'From', value: truncateAddress(from)),
              const SizedBox(height: 18),
              const ZuniaCallout(
                tone: ZuniaCalloutTone.warning,
                title: 'Nothing is broadcast',
                body:
                    'This wallet has no broadcast endpoint configured, so the '
                    'delegation stops here.',
              ),
              const SizedBox(height: 16),
              ZuniaButton(
                label: 'Close',
                variant: ZuniaButtonVariant.secondary,
                size: ZuniaButtonSize.lg,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
