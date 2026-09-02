import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Dropdown over enabled chains (or an optional explicit list). Overlay menu
/// so the page underneath never reflows.
class ChainPicker extends ConsumerWidget {
  const ChainPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.chains,
  });

  final String value;
  final ValueChanged<String> onChanged;

  /// Optional mono caption under the chain name (e.g. available balance).
  final String? subtitle;

  /// When set, only these chains appear (still must be in the catalog).
  final List<ChainEntry>? chains;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final accounts = ref.watch(chainAccountsProvider);
    final options = chains ?? accounts.map((a) => a.chain).toList();
    if (options.isEmpty) return const SizedBox.shrink();

    final current = options.where((c) => c.chainId == value).firstOrNull ??
        options.first;

    return PopupMenuButton<String>(
      onSelected: onChanged,
      color: s.surfaceRaised,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: s.line),
      ),
      itemBuilder: (_) => [
        for (final chain in options)
          PopupMenuItem<String>(
            value: chain.chainId,
            child: Row(
              children: [
                ChainAvatar(chain: chain, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    chain.chainName,
                    overflow: TextOverflow.ellipsis,
                    style: zuniaSans(fontSize: 13, color: s.fg),
                  ),
                ),
                if (chain.chainId == current.chainId)
                  Icon(Icons.check, size: 20, color: s.accent),
              ],
            ),
          ),
      ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: s.surfaceRaisedGradient,
          color: s.glass,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: s.line),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ChainAvatar(chain: current, size: 26),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      current.chainName,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: s.fg,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle ?? current.chainId,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaMono(fontSize: 10, color: s.fgMuted),
                    ),
                  ],
                ),
              ),
              Icon(Icons.expand_more, size: 18, color: s.fgMuted),
            ],
          ),
        ),
      ),
    );
  }
}
