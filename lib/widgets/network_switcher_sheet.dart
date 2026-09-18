import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Quick network switcher sheet over enabled chains.
Future<void> showNetworkSwitcher(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _NetworkSwitcherSheet(),
  );
}

class _NetworkSwitcherSheet extends ConsumerWidget {
  const _NetworkSwitcherSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final enabled = ref.watch(walletProvider).enabledChainIds;
    final networks = <({String chainId, String name, String? symbol})>[];
    for (final id in enabled) {
      final chain = ChainCatalog.isLoaded
          ? ChainCatalog.instance.find(id)
          : null;
      networks.add((
        chainId: id,
        name: chain?.chainName ?? id,
        symbol: chain?.coinDenom,
      ));
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.sheetGradient,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: s.lineStrong)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: s.lineStrong,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    'Networks',
                    style: zuniaSans(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: s.fg,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const NetworksScreen(),
                        ),
                      );
                    },
                    child: Text(
                      'Manage',
                      style: zuniaMono(fontSize: 11, color: s.info),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ZuniaNetworkPickerSheet(
                networks: networks,
                activeChainId: enabled.isEmpty ? null : enabled.first,
                onSelect: (chainId) {
                  // Pin the picked chain to the front of the enabled list so
                  // earn / send / receive default to it when they fall back
                  // to accounts.first.
                  final next = [
                    chainId,
                    ...enabled.where((id) => id != chainId),
                  ];
                  ref.read(walletProvider.notifier).setEnabledChains(next);
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
