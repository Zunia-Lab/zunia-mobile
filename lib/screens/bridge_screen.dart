import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Move an asset between two chains this wallet already controls.
class BridgeScreen extends ConsumerStatefulWidget {
  const BridgeScreen({super.key});

  @override
  ConsumerState<BridgeScreen> createState() => _BridgeScreenState();
}

class _BridgeScreenState extends ConsumerState<BridgeScreen> {
  final _amount = TextEditingController();
  String _rail = 'ibc';
  String? _fromId;
  String? _toId;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final balances = ref.watch(balancesProvider).valueOrNull ?? const {};

    if (accounts.length < 2) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: ZuniaScreenScaffold(
            title: 'Bridge',
            onBack: () => Navigator.of(context).pop(),
            trailing: const _ExternalPill(),
            body: const ZuniaEmptyState(
              title: 'Enable two chains',
              description:
                  'A bridge needs a source and a destination. Enable at least '
                  'two networks first.',
            ),
          ),
        ),
      );
    }

    final from = accounts.firstWhere(
      (a) => a.chain.chainId == _fromId,
      orElse: () => accounts.first,
    );
    final to = accounts.firstWhere(
      (a) => a.chain.chainId == _toId && a.chain.chainId != from.chain.chainId,
      orElse: () =>
          accounts.firstWhere((a) => a.chain.chainId != from.chain.chainId),
    );

    final available = balances[from.chain.chainId]?.available;
    final availableLabel = available == null
        ? '—'
        : prefs.mask(
            formatBaseUnits(available, decimals: from.chain.coinDecimals),
          );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Bridge',
          onBack: () => Navigator.of(context).pop(),
          trailing: const _ExternalPill(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
            children: [
              ZuniaSegmented<String>(
                value: _rail,
                onChanged: (v) => setState(() => _rail = v),
                options: const {
                  'ibc': 'IBC',
                  'evm': 'EVM',
                  'solana': 'Solana',
                },
              ),
              const SizedBox(height: 14),
              _Leg(
                label: 'From ${from.chain.chainName}',
                account: from,
                accounts: accounts,
                onPick: (id) => setState(() => _fromId = id),
                trailing: Text(
                  '$availableLabel available',
                  style: zuniaMono(fontSize: 10, color: s.fgMuted),
                ),
                amountField: TextField(
                  controller: _amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.right,
                  style: zuniaSans(
                    fontSize: 24,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.8,
                    height: 1,
                    color: s.fg,
                    tabular: FontFeature.tabularFigures(),
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '0.00',
                    hintStyle: zuniaSans(
                      fontSize: 24,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.8,
                      color: s.fgDim,
                    ),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: Divider(color: s.line, height: 1)),
                  const SizedBox(width: 10),
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: s.accent,
                    ),
                    child: Icon(
                      Icons.arrow_downward,
                      size: 16,
                      color: s.accentFg,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Divider(color: s.line, height: 1)),
                ],
              ),
              const SizedBox(height: 10),
              _Leg(
                label: 'To ${to.chain.chainName}',
                account: to,
                accounts: accounts,
                onPick: (id) => setState(() => _toId = id),
                trailing: Text(
                  truncateAddress(to.address, left: 10),
                  style: zuniaMono(fontSize: 10, color: s.fgMuted),
                ),
                amountField: Text(
                  _amount.text.trim().isEmpty ? '0.00' : _amount.text.trim(),
                  textAlign: TextAlign.right,
                  style: zuniaSans(
                    fontSize: 24,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.8,
                    height: 1,
                    color: s.fgMuted,
                    tabular: FontFeature.tabularFigures(),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: s.glass,
                ),
                child: Column(
                  children: [
                    ZuniaKeyValueRow(
                      label: 'Rail',
                      value: _rail.toUpperCase(),
                    ),
                    const SizedBox(height: 9),
                    ZuniaKeyValueRow(
                      label: 'Asset',
                      value: from.chain.coinDenom,
                    ),
                    const SizedBox(height: 9),
                    ZuniaKeyValueRow(
                      label: 'Est. arrival',
                      value: _rail == 'ibc' ? '~seconds' : 'provider-dependent',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (_rail == 'ibc')
                const ZuniaCallout(
                  tone: ZuniaCalloutTone.warning,
                  title: 'Channels must match the asset',
                  body:
                      'An IBC transfer down the wrong channel produces a token '
                      'the destination chain does not recognise. Zunia only '
                      'offers routes the registry lists for this pair.',
                )
              else
                ZuniaCallout(
                  tone: ZuniaCalloutTone.warning,
                  title: 'Third-party bridge',
                  body:
                      'The ${_rail.toUpperCase()} rail needs an external bridge '
                      'provider. Funds are not custodied in transit. Only IBC '
                      'routes are native to the wallet.',
                ),
            ],
          ),
          footer: const ZuniaButton(
            label: 'Review bridge',
            size: ZuniaButtonSize.lg,
            onPressed: null,
          ),
        ),
      ),
    );
  }
}

class _ExternalPill extends StatelessWidget {
  const _ExternalPill();

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: s.glass,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'EXTERNAL',
        style: zuniaMono(fontSize: 10, color: s.fgDim),
      ),
    );
  }
}

class _Leg extends StatelessWidget {
  const _Leg({
    required this.label,
    required this.account,
    required this.accounts,
    required this.onPick,
    required this.trailing,
    this.amountField,
  });

  final String label;
  final ChainAccount account;
  final List<ChainAccount> accounts;
  final ValueChanged<String> onPick;
  final Widget trailing;
  final Widget? amountField;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return PopupMenuButton<String>(
      onSelected: onPick,
      color: s.surfaceRaised,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: s.line),
      ),
      itemBuilder: (_) => [
        for (final a in accounts)
          PopupMenuItem<String>(
            value: a.chain.chainId,
            child: Text(
              a.chain.chainName,
              style: zuniaSans(fontSize: 12.5, color: s.fg),
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: s.surfaceRaisedGradient,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label.toUpperCase(),
                    overflow: TextOverflow.ellipsis,
                    style: zuniaMono(
                      fontSize: 10,
                      letterSpacing: 0.8,
                      color: s.fgMuted,
                    ),
                  ),
                ),
                trailing,
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(7, 7, 12, 7),
                  decoration: BoxDecoration(
                    color: s.glass,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ChainAvatar(chain: account.chain, size: 24),
                      const SizedBox(width: 8),
                      Text(
                        account.chain.coinDenom,
                        style: zuniaSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: s.fg,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.expand_more, size: 14, color: s.fgMuted),
                    ],
                  ),
                ),
                if (amountField != null) ...[
                  const SizedBox(width: 12),
                  Expanded(child: amountField!),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
