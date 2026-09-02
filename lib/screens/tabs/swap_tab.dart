import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_mobile/widgets/wallet_header.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Swap between assets the wallet holds. Routing is quoted by an external
/// aggregator, so until one is connected the screen prices nothing and says so.
class SwapTab extends ConsumerStatefulWidget {
  const SwapTab({super.key});

  @override
  ConsumerState<SwapTab> createState() => _SwapTabState();
}

class _SwapTabState extends ConsumerState<SwapTab> {
  final _amount = TextEditingController();
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
      return DecoratedBox(
        decoration: BoxDecoration(gradient: s.screenGradient),
        child: Column(
          children: [
            WalletHeader(
              onOpenNetworks: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NetworksScreen()),
              ),
            ),
            Expanded(
              child: Center(
                child: ZuniaEmptyState(
                  title: 'Enable two chains',
                  description:
                      'A swap needs an asset to give and one to get. Enable at '
                      'least two networks.',
                  action: ZuniaButton(
                    label: 'Manage networks',
                    size: ZuniaButtonSize.sm,
                    variant: ZuniaButtonVariant.secondary,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const NetworksScreen()),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final from = accounts.firstWhere(
      (a) => a.chain.chainId == _fromId,
      orElse: () => accounts.first,
    );
    final to = accounts.firstWhere(
      (a) => a.chain.chainId == _toId && a.chain.chainId != from.chain.chainId,
      orElse: () => accounts.firstWhere(
        (a) => a.chain.chainId != from.chain.chainId,
      ),
    );

    String available(ChainAccount account) {
      final base = balances[account.chain.chainId]?.available;
      if (base == null) return '—';
      return prefs.mask(
        formatBaseUnits(base, decimals: account.chain.coinDecimals),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(gradient: s.screenGradient),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WalletHeader(
            onOpenNetworks: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NetworksScreen()),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
              children: [
                Text(
                  'Swap',
                  style: zuniaSans(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.3,
                    color: s.fg,
                  ),
                ),
                const SizedBox(height: 16),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Column(
                      children: [
                        _Leg(
                          label: 'From',
                          account: from,
                          available: available(from),
                          controller: _amount,
                          accounts: accounts,
                          onPick: (id) => setState(() => _fromId = id),
                        ),
                        const SizedBox(height: 8),
                        _Leg(
                          label: 'To',
                          account: to,
                          available: available(to),
                          accounts: accounts,
                          onPick: (id) => setState(() => _toId = id),
                        ),
                      ],
                    ),
                    Material(
                      color: s.accent,
                      shape: const CircleBorder(),
                      elevation: 0,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => setState(() {
                          final previous = from.chain.chainId;
                          _fromId = to.chain.chainId;
                          _toId = previous;
                        }),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: s.screenMid, width: 3),
                          ),
                          child: Icon(
                            Icons.swap_vert,
                            size: 16,
                            color: s.accentFg,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: s.glass,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        ZuniaKeyValueRow(
                          label: 'Rate',
                          value:
                              '1 ${from.chain.coinDenom} = — ${to.chain.coinDenom}',
                        ),
                        const SizedBox(height: 11),
                        ZuniaKeyValueRow(
                          label: 'Route',
                          value:
                              '${from.chain.coinDenom} → ${to.chain.coinDenom}',
                        ),
                        const SizedBox(height: 11),
                        const ZuniaKeyValueRow(
                          label: 'Price impact',
                          value: '—',
                        ),
                        const SizedBox(height: 11),
                        const ZuniaKeyValueRow(
                          label: 'Slippage',
                          value: '—',
                        ),
                        const SizedBox(height: 11),
                        const ZuniaKeyValueRow(
                          label: 'Fee',
                          value: '—',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 13),
                const ZuniaCallout(
                  tone: ZuniaCalloutTone.info,
                  title: 'No route provider connected',
                  body:
                      'Zunia quotes swaps through an external aggregator. Until '
                      'one is configured, amounts here are not priced and nothing '
                      'is signed.',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            child: ZuniaButton(
              label: 'Review swap',
              size: ZuniaButtonSize.lg,
              onPressed: null,
            ),
          ),
        ],
      ),
    );
  }
}

class _Leg extends StatelessWidget {
  const _Leg({
    required this.label,
    required this.account,
    required this.available,
    required this.accounts,
    required this.onPick,
    this.controller,
  });

  final String label;
  final ChainAccount account;
  final String available;
  final List<ChainAccount> accounts;
  final ValueChanged<String> onPick;
  final TextEditingController? controller;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.surfaceRaisedGradient,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  label.toUpperCase(),
                  style: zuniaMono(
                    fontSize: 10,
                    color: s.fgMuted,
                  ),
                ),
                const Spacer(),
                Text(
                  '$available available',
                  style: zuniaMono(fontSize: 10, color: s.fgMuted),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                PopupMenuButton<String>(
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
                          '${a.chain.coinDenom} · ${a.chain.chainName}',
                          style: zuniaSans(fontSize: 12.5, color: s.fg),
                        ),
                      ),
                  ],
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: s.glass,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(7, 7, 12, 7),
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
                          Icon(Icons.expand_more, size: 14, color: s.fgMuted),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: controller,
                    enabled: controller != null,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.right,
                    style: zuniaSans(
                      fontSize: 26,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.9,
                      color: controller == null ? s.fgMuted : s.fg,
                      tabular: FontFeature.tabularFigures(),
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: controller == null ? '—' : '0.00',
                      hintStyle: zuniaSans(
                        fontSize: 26,
                        fontWeight: FontWeight.w500,
                        color: s.fgDim,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
