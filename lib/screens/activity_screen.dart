/// History across every enabled network, newest first, grouped by day, with
/// the transfers still in flight on top.
///
/// Read from each chain's public tx search, a few chains at a time, chains
/// holding something first; rows show as each chain answers. A chain that
/// could not be read is named, not hidden.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/activity/activity_model.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/send_result_screen.dart';
import 'package:zunia_mobile/screens/tx_detail_screen.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/services/interchain/tracking.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/transfer_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/transfers/pending_transfers.dart';
import 'package:zunia_mobile/widgets/activity_row.dart';
import 'package:zunia_mobile/widgets/pickers.dart';
import 'package:zunia_mobile/widgets/search_field.dart';
import 'package:zunia_mobile/widgets/token_widgets.dart';
import 'package:zunia_ui/zunia_ui.dart';

class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key, this.embedded = false});

  /// Shown as a root tab: no back control.
  final bool embedded;

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  ActivityFilter _filter = ActivityFilter.all;
  String? _network;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static String _dayLabel(DateTime when) {
    if (when.millisecondsSinceEpoch == 0) return 'Undated';
    final local = when.toLocal();
    final now = DateTime.now();
    final day = DateTime(local.year, local.month, local.day);
    final today = DateTime(now.year, now.month, now.day);
    final delta = today.difference(day).inDays;
    if (delta <= 0) return 'Today';
    if (delta == 1) return 'Yesterday';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[local.month - 1]} ${local.day}${local.year == now.year ? '' : ', ${local.year}'}';
  }

  Future<void> _pickNetwork(List<ChainAccount> accounts) async {
    final picked = await showChainSheet(
      context,
      title: 'Network',
      selectedId: _network,
      options: [for (final account in accounts) ChainOption(chain: account.chain)],
    );
    if (picked == null || !mounted) return;
    setState(() => _network = picked);
  }

  Future<void> _refresh() async {
    if (_network != null) {
      ref.invalidate(activityProvider(_network!));
      try {
        await ref.read(activityProvider(_network!).future);
      } on Object {
        // The screen shows why from the provider's error.
      }
    } else {
      await ref.read(activityFeedProvider.notifier).refresh();
    }
    await ref.read(pendingTransfersProvider.notifier).pollNow();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final pending = ref.watch(pendingTransfersProvider);
    ref.watch(identityGenerationProvider);
    final network = accounts.any((a) => a.chain.chainId == _network) ? _network : null;
    final networkName = network == null ? null : ChainCatalog.instance.find(network)?.chainName;

    // One network reads its own longer history; all networks read the feed.
    List<ActivityItem> items;
    var loading = false;
    String? failure;
    Map<String, String> failed = const {};
    if (network != null) {
      final single = ref.watch(activityProvider(network));
      items = single.valueOrNull ?? const [];
      loading = single.isLoading && items.isEmpty;
      if (single.hasError) {
        final error = single.error;
        failure = error is ChainReadException
            ? '$networkName did not return its history. ${error.failure.message}'
            : '$networkName did not return its history.';
      }
    } else {
      final feed = ref.watch(activityFeedProvider);
      items = feed.items;
      loading = feed.loading && items.isEmpty;
      failed = feed.failed;
    }
    final inFlight = [
      for (final record in pending.records)
        if (network == null || record.chainId == network) record,
    ];
    final inFlightHashes = {for (final r in inFlight) r.txHash.toUpperCase()};
    final query = _search.text.trim();
    final visible = [
      for (final item in items)
        if (activityMatches(item, _filter) &&
            !inFlightHashes.contains(item.hash.toUpperCase()) &&
            activitySearchMatches(item, query,
                chainName: ChainCatalog.isLoaded ? ChainCatalog.instance.find(item.chainId)?.chainName : null))
          item,
    ];

    final children = <Widget>[];
    if (inFlight.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
        child: Text('IN FLIGHT', style: zuniaMono(fontSize: 10, letterSpacing: 1.3, color: s.fgDim)),
      ));
      for (final record in inFlight) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _InFlightRow(
            record: record,
            tracked: pending.tracked[record.txHash],
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SendResultScreen.tracked(record: record)),
            ),
          ),
        ));
      }
    }
    String? lastDay;
    for (final item in visible) {
      final day = _dayLabel(item.timestamp);
      if (day != lastDay) {
        lastDay = day;
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: Text(day.toUpperCase(), style: zuniaMono(fontSize: 10, letterSpacing: 1.3, color: s.fgDim)),
        ));
      }
      children.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: ActivityRow(
          item: item,
          hidden: prefs.hideAmounts,
          showChain: network == null,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TxDetailScreen(item: item))),
        ),
      ));
    }

    Widget list;
    if (!prefs.liveReads) {
      list = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const ZuniaCallout(
            tone: ZuniaCalloutTone.info,
            title: 'Live reads are off',
            body: 'History is read from each chain\'s public endpoint only when you allow it.',
          ),
          const SizedBox(height: 8),
          ZuniaButton(
            label: 'Turn on live reads',
            size: ZuniaButtonSize.sm,
            variant: ZuniaButtonVariant.secondary,
            onPressed: () => ref.read(preferencesProvider.notifier).setLiveReads(true),
          ),
        ],
      );
    } else if (loading) {
      list = ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: const [ListSkeleton(count: 6, label: 'Loading activity')],
      );
    } else if (children.isEmpty) {
      list = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (failure != null)
            ZuniaCallout(tone: ZuniaCalloutTone.warning, title: 'History unavailable', body: failure)
          else
            ZuniaEmptyState(
              title: items.isEmpty ? 'No activity yet' : 'Nothing here',
              description: items.isEmpty
                  ? 'Transfers and signatures from this wallet are listed here.'
                  : 'Nothing matches these filters.',
            ),
        ],
      );
    } else {
      list = ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ...children,
          if (failed.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                '${failed.length} network${failed.length == 1 ? '' : 's'} did not return '
                'history: ${failed.keys.map((id) => ChainCatalog.instance.find(id)?.chainName ?? id).take(4).join(', ')}'
                '${failed.length > 4 ? '…' : ''}.',
                style: zuniaSans(fontSize: 12, color: s.fgDim),
              ),
            ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Activity',
          onBack: widget.embedded ? null : () => Navigator.of(context).pop(),
          trailing: TextButton.icon(
            onPressed: accounts.isEmpty ? null : () => _pickNetwork(accounts),
            icon: const Icon(Icons.filter_list_rounded, size: 18),
            label: Text(networkName ?? 'All networks', overflow: TextOverflow.ellipsis),
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: AdaptiveSearchField(
                  controller: _search,
                  placeholder: 'Search activity',
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    if (network != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: InputChip(
                          label: Text(networkName ?? network),
                          onDeleted: () => setState(() => _network = null),
                          deleteButtonTooltipMessage: 'Show all networks',
                        ),
                      ),
                    for (final filter in ActivityFilter.values)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ChoiceChip(
                          label: Text(filter.label),
                          selected: _filter == filter,
                          onSelected: (_) {
                            ZuniaHaptics.selection();
                            setState(() => _filter = filter);
                          },
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(child: ZuniaRefresh(onRefresh: _refresh, child: list)),
            ],
          ),
        ),
      ),
    );
  }
}

class _InFlightRow extends StatelessWidget {
  const _InFlightRow({required this.record, required this.tracked, required this.onTap});

  final PendingTransfer record;
  final TrackedTransfer? tracked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    String name(String chainId) =>
        (ChainCatalog.isLoaded ? ChainCatalog.instance.find(chainId)?.chainName : null) ?? chainId;
    final dest = name(record.plan.destChainId);
    final source = name(record.chainId);
    final trace = tracked?.trace;
    final (label, detail, color) = switch (tracked?.outcome) {
      RouteOutcome.delivered => ('Confirmed', 'Arrived on $dest', s.success),
      RouteOutcome.recoverable => ('Action needed', 'Recover the tokens on Osmosis', s.warning),
      RouteOutcome.refunded => (
          trace?.failure == PacketFailureKind.timeout ? 'Timed out' : 'Refunded',
          'Tokens go back to $source',
          s.danger,
        ),
      RouteOutcome.failed => ('Failed', 'Rejected on $source', s.danger),
      null => trace == null
          ? (tracked?.error != null
              ? ('Unknown', 'Could not read its status', s.fgDim)
              : ('Checking', '$source to $dest', s.fgDim))
          : trace.stalled
              ? ('Slow', 'Step ${trace.currentHopIndex + 1} of ${trace.hops.length} is taking longer than usual', s.warning)
              : ('In flight', 'Step ${trace.currentHopIndex + 1} of ${trace.hops.length}, $source to $dest', s.info),
    };
    return Semantics(
      button: true,
      label: '${record.label}, $label, $detail',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: s.infoFill, border: Border.all(color: s.infoLine)),
                child: tracked?.outcome == null
                    ? const ZuniaActivityIndicator(size: 16)
                    : Icon(Icons.sync_alt_rounded, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(record.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaSans(fontSize: 14, fontWeight: FontWeight.w500, color: s.fg)),
                    Text(detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaMono(fontSize: 10.5, color: s.fgMuted)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(label, style: zuniaMono(fontSize: 11, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}
