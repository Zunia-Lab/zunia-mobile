import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/add_chain_screen.dart';
import 'package:zunia_mobile/state/custom_chains.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_ui/zunia_ui.dart';

enum NetworkFilter { all, mainnet, testnet, enabled }

extension NetworkFilterLabel on NetworkFilter {
  String get label => switch (this) {
        NetworkFilter.all => 'All',
        NetworkFilter.mainnet => 'Main',
        NetworkFilter.testnet => 'Test',
        NetworkFilter.enabled => 'On',
      };
}

/// The rows of one view of the catalog, in the order they show: pinned
/// (Safrochain, Cosmos Hub, Osmosis) first, then by name; custom chains in
/// their own group, then mainnets, then testnets.
({List<ChainEntry> custom, List<ChainEntry> mainnets, List<ChainEntry> testnets})
    networkSections({
  required List<ChainEntry> all,
  required Set<String> customIds,
  required Set<String> enabled,
  NetworkFilter filter = NetworkFilter.all,
  String query = '',
}) {
  final rows = all.where((c) {
    if (!c.matches(query)) return false;
    return switch (filter) {
      NetworkFilter.all => true,
      NetworkFilter.mainnet => !c.isTestnet,
      NetworkFilter.testnet => c.isTestnet,
      NetworkFilter.enabled => enabled.contains(c.chainId),
    };
  }).toList();
  final sorted = ChainCatalog.isLoaded
      ? ChainCatalog.instance.sorted(rows)
      : rows;
  return (
    custom: [for (final c in sorted) if (customIds.contains(c.chainId)) c],
    mainnets: [
      for (final c in sorted)
        if (!customIds.contains(c.chainId) && !c.isTestnet) c,
    ],
    testnets: [
      for (final c in sorted)
        if (!customIds.contains(c.chainId) && c.isTestnet) c,
    ],
  );
}

/// One switch per network, searchable across the whole registry plus the
/// chains added by hand.
class NetworksScreen extends ConsumerStatefulWidget {
  const NetworksScreen({super.key});

  @override
  ConsumerState<NetworksScreen> createState() => _NetworksScreenState();
}

class _NetworksScreenState extends ConsumerState<NetworksScreen> {
  final _search = TextEditingController();
  String _query = '';
  NetworkFilter _filter = NetworkFilter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _apply(Set<String> next) async {
    if (next.isEmpty) {
      await showZuniaAlert<void>(
        context,
        title: 'Keep one network',
        message: 'At least one network has to stay enabled.',
        actions: const [ZuniaAlertAction(label: 'OK', isDefault: true)],
      );
      return;
    }
    // Keep the order the user enabled them in; it decides the default chain.
    final current = ref.read(walletProvider).enabledChainIds;
    final ordered = [
      for (final id in current)
        if (next.contains(id)) id,
      for (final id in next)
        if (!current.contains(id)) id,
    ];
    await ref.read(walletProvider.notifier).setEnabledChains(ordered);
  }

  Future<void> _toggle(String chainId, Set<String> enabled) => _apply(
        enabled.contains(chainId)
            ? ({...enabled}..remove(chainId))
            : {...enabled, chainId},
      );

  Future<void> _removeCustom(ChainEntry chain, Set<String> enabled) async {
    final ok = await showZuniaConfirm(
      context,
      title: 'Remove ${chain.chainName}?',
      message: 'The network leaves this wallet. Funds on it stay on the '
          'chain; add it again with the same details to see them.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok) return;
    if (enabled.contains(chain.chainId)) {
      final rest = {...enabled}..remove(chain.chainId);
      await ref
          .read(walletProvider.notifier)
          .setEnabledChains(rest.isEmpty ? const ['safrochain-1'] : rest.toList());
    }
    await ref.read(customChainsProvider.notifier).remove(chain.chainId);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    final custom = ref.watch(customChainsProvider);
    final enabled = ref.watch(walletProvider).enabledChainIds.toSet();
    final all = ChainCatalog.isLoaded
        ? ChainCatalog.instance.all
        : const <ChainEntry>[];
    final sections = networkSections(
      all: all,
      customIds: {for (final c in custom) c.chainId},
      enabled: enabled,
      filter: _filter,
      query: _query,
    );
    final inView = [
      ...sections.custom,
      ...sections.mainnets,
      ...sections.testnets,
    ];
    final onInView = inView.where((c) => enabled.contains(c.chainId)).length;
    final customIds = {for (final c in custom) c.chainId};

    List<Widget> section(String title, List<ChainEntry> rows) => [
          if (rows.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Semantics(
                  header: true,
                  child: Text(
                    '${cupertino ? title.toUpperCase() : title} · ${rows.length}',
                    style: cupertino
                        ? zuniaSans(fontSize: 12.5, color: s.fgDim)
                        : zuniaSans(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: s.accent,
                          ),
                  ),
                ),
              ),
            ),
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final chain = rows[i];
              final isCustom = customIds.contains(chain.chainId);
              return _NetworkRow(
                chain: chain,
                custom: isCustom,
                enabled: enabled.contains(chain.chainId),
                onToggle: () => unawaited(_toggle(chain.chainId, enabled)),
                onLongPress: isCustom
                    ? () => unawaited(_removeCustom(chain, enabled))
                    : null,
              );
            },
          ),
        ];

    return ZuniaLargeTitleScaffold(
      title: 'Networks',
      actions: [
        IconButton(
          tooltip: 'Add network',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AddChainScreen()),
          ),
          icon: Icon(cupertino ? CupertinoIcons.add : Icons.add, color: s.fg),
        ),
      ],
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ZuniaSearchField(
                  controller: _search,
                  hintText: 'Search name, chain ID or token',
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 10),
                ZuniaSegmented<NetworkFilter>(
                  value: _filter,
                  onChanged: (v) => setState(() => _filter = v),
                  options: {for (final f in NetworkFilter.values) f: f.label},
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${enabled.length} on · $onInView/${inView.length} in view',
                        style: zuniaMono(fontSize: 11, color: s.fgDim),
                      ),
                    ),
                    TextButton(
                      onPressed: inView.isEmpty
                          ? null
                          : () => unawaited(
                                _apply({
                                  ...enabled,
                                  for (final c in inView) c.chainId,
                                }),
                              ),
                      child: const Text('Select all'),
                    ),
                    TextButton(
                      onPressed: onInView == 0
                          ? null
                          : () => unawaited(
                                _apply({
                                  for (final id in enabled)
                                    if (!inView.any((c) => c.chainId == id)) id,
                                }),
                              ),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (inView.isEmpty)
          SliverToBoxAdapter(
            child: ZuniaEmptyState(
              title: 'No networks match',
              description: _query.trim().isEmpty
                  ? 'Nothing in this view.'
                  : 'Nothing matches “${_query.trim()}”. Add it by hand if '
                      'the registry does not carry it.',
              action: ZuniaButton(
                label: 'Add a network',
                variant: ZuniaButtonVariant.secondary,
                size: ZuniaButtonSize.sm,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AddChainScreen()),
                ),
              ),
            ),
          ),
        ...section('Custom', sections.custom),
        ...section('Mainnets', sections.mainnets),
        ...section('Testnets', sections.testnets),
      ],
    );
  }
}

class _NetworkRow extends StatelessWidget {
  const _NetworkRow({
    required this.chain,
    required this.custom,
    required this.enabled,
    required this.onToggle,
    this.onLongPress,
  });

  final ChainEntry chain;
  final bool custom;
  final bool enabled;
  final VoidCallback onToggle;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      toggled: enabled,
      label: '${chain.chainName}${custom ? ', custom' : ''}'
          '${chain.isTestnet ? ', testnet' : ''}',
      hint: custom ? 'Long press to remove' : null,
      child: InkWell(
        onTap: onToggle,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 9, 12, 9),
          child: Row(
            children: [
              ChainAvatar(chain: chain, size: 34, selected: enabled),
              const SizedBox(width: 12),
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              chain.chainName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: zuniaSans(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: s.fg,
                              ),
                            ),
                          ),
                          if (custom) ...[
                            const SizedBox(width: 6),
                            _Tag(label: 'Custom', color: s.accent),
                          ],
                          if (chain.isTestnet) ...[
                            const SizedBox(width: 6),
                            _Tag(label: 'Test', color: s.warning),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        chain.coinDenom.isEmpty
                            ? chain.chainId
                            : '${chain.chainId} · ${chain.coinDenom}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaMono(fontSize: 11.5, color: s.fgDim),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ZuniaSwitch(value: enabled, onChanged: (_) => onToggle()),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label.toUpperCase(),
        style: zuniaMono(fontSize: 9, letterSpacing: 0.6, color: color),
      ),
    );
  }
}
