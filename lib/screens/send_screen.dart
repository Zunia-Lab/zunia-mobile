import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/ibc_route_screen.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/chain_picker.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Send (same chain) or Cross-send (IBC) with a simple two-step flow.
class SendScreen extends ConsumerStatefulWidget {
  const SendScreen({super.key, this.chainId});

  final String? chainId;

  @override
  ConsumerState<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends ConsumerState<SendScreen> {
  final _amount = TextEditingController();
  late String? _chainId = widget.chainId;
  String? _destChainId;
  String _mode = 'send';

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _setPercent(double fraction, String available, int decimals) {
    final whole = double.tryParse(
          formatBaseUnitsExact(available, decimals: decimals),
        ) ??
        0;
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

    if (accounts.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: ZuniaScreenScaffold(
            title: 'Send',
            onBack: () => Navigator.of(context).pop(),
            body: const ZuniaEmptyState(
              title: 'No networks enabled',
              description: 'Enable a chain before sending.',
            ),
          ),
        ),
      );
    }

    final chainId = accounts.any((a) => a.chain.chainId == _chainId)
        ? _chainId!
        : accounts.first.chain.chainId;
    final account = accounts.firstWhere((a) => a.chain.chainId == chainId);
    final chain = account.chain;
    final destOptions =
        accounts.where((a) => a.chain.chainId != chainId).toList();
    final destId = destOptions.any((a) => a.chain.chainId == _destChainId)
        ? _destChainId!
        : (destOptions.isEmpty ? null : destOptions.first.chain.chainId);
    final available =
        ref.watch(balancesProvider).valueOrNull?[chainId]?.available;
    final cross = _mode == 'cross';
    final ready = (double.tryParse(_amount.text.trim()) ?? 0) > 0 &&
        (!cross || destId != null);
    final availableLabel = available == null
        ? '—'
        : prefs.mask(
            formatBaseUnits(available, decimals: chain.coinDecimals),
          );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Send',
          onBack: () => Navigator.of(context).pop(),
          trailing: Text(
            '1 / 2',
            style: zuniaMono(fontSize: 11, color: s.fgDim),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              ZuniaSegmented<String>(
                value: _mode,
                onChanged: (v) => setState(() => _mode = v),
                options: const {
                  'send': 'Send',
                  'cross': 'Cross-send',
                },
              ),
              const SizedBox(height: 28),
              Text(
                'AMOUNT',
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
                        fontSize: 40,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -1.8,
                        height: 1,
                        color: s.fg,
                        tabular: FontFeature.tabularFigures(),
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '0.00',
                        hintStyle: zuniaSans(
                          fontSize: 40,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -1.8,
                          color: s.fgDim,
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  Text(
                    chain.coinDenom,
                    style: zuniaMono(fontSize: 15, color: s.fgMuted),
                  ),
                ],
              ),
              if (available != null) ...[
                const SizedBox(height: 22),
                Row(
                  children: [
                    for (final fraction in const [0.25, 0.5, 0.75, 1.0])
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: fraction == 1.0 ? 0 : 7,
                          ),
                          child: _PercentChip(
                            label: fraction == 1.0
                                ? 'MAX'
                                : '${(fraction * 100).round()}%',
                            accent: fraction == 1.0,
                            onTap: () => _setPercent(
                              fraction,
                              available,
                              chain.coinDecimals,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 26),
              Text(
                cross ? 'From' : 'Network',
                style: zuniaMono(fontSize: 10, color: s.fgDim),
              ),
              const SizedBox(height: 8),
              ChainPicker(
                value: chainId,
                subtitle: '$availableLabel available',
                onChanged: (v) => setState(() {
                  _chainId = v;
                  if (_destChainId == v) _destChainId = null;
                }),
              ),
              if (cross) ...[
                const SizedBox(height: 12),
                Text(
                  'To network',
                  style: zuniaMono(fontSize: 10, color: s.fgDim),
                ),
                const SizedBox(height: 8),
                if (destOptions.isEmpty)
                  Text(
                    'Enable a second network for Cross-send.',
                    style: zuniaSans(fontSize: 13, color: s.fgDim),
                  )
                else
                  ChainPicker(
                    value: destId!,
                    chains: destOptions.map((a) => a.chain).toList(),
                    onChanged: (v) => setState(() => _destChainId = v),
                  ),
              ],
              const SizedBox(height: 16),
              ZuniaCard(
                tone: ZuniaCardTone.glass,
                padding: const EdgeInsets.all(14),
                radius: 14,
                child: Column(
                  children: [
                    ZuniaKeyValueRow(
                      label: 'From',
                      value: truncateAddress(account.address),
                    ),
                    const SizedBox(height: 10),
                    ZuniaKeyValueRow(label: 'Chain', value: chain.chainId),
                    const SizedBox(height: 10),
                    ZuniaKeyValueRow(
                      label: 'Fee denom',
                      value: chain.feeDenom,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              ZuniaCallout(
                tone: ZuniaCalloutTone.info,
                title: cross ? 'IBC transfer' : 'Same-chain send',
                body: cross
                    ? 'Next you pick a recipient on the destination chain and '
                        'confirm an open IBC channel.'
                    : 'Next you pick a recipient on this network.',
              ),
            ],
          ),
          footer: ZuniaButton(
            label: 'Choose recipient',
            size: ZuniaButtonSize.lg,
            onPressed: ready
                ? () {
                    final dest = destId == null
                        ? null
                        : ChainCatalog.instance.find(destId);
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => IbcRouteScreen(
                          chainId: chain.chainId,
                          denom: chain.coinDenom,
                          amount: _amount.text.trim(),
                          fromAddress: account.address,
                          sourcePrefix: chain.bech32Prefix,
                          destChainId: cross ? destId : null,
                          destPrefix: cross ? dest?.bech32Prefix : null,
                          forceIbc: cross,
                        ),
                      ),
                    );
                  }
                : null,
          ),
        ),
      ),
    );
  }
}

class _PercentChip extends StatelessWidget {
  const _PercentChip({
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          decoration: BoxDecoration(
            color: accent ? Colors.transparent : s.glass,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: accent ? s.info.withValues(alpha: 0.55) : Colors.transparent,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: zuniaMono(
                fontSize: 10.5,
                color: accent ? s.info : s.fgMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
