import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Transfers and signatures across every enabled chain, grouped by day.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  String _filter = 'all';

  static const _filters = {
    'all': 'All',
    'transfers': 'Transfers',
    'staking': 'Staking',
    'ibc': 'IBC',
    'swap': 'Swap',
    'governance': 'Gov',
  };

  bool _matches(ActivityItem item) {
    switch (_filter) {
      case 'transfers':
        return item.kind == ActivityKind.sent ||
            item.kind == ActivityKind.received;
      case 'staking':
        return item.kind == ActivityKind.staking ||
            item.kind == ActivityKind.claim;
      case 'ibc':
        return item.kind == ActivityKind.ibc;
      case 'swap':
        return item.kind == ActivityKind.swap;
      case 'governance':
        return item.kind == ActivityKind.governance;
      default:
        return true;
    }
  }

  static ZuniaActivityKind _uiKind(ActivityKind kind) {
    switch (kind) {
      case ActivityKind.sent:
        return ZuniaActivityKind.sent;
      case ActivityKind.received:
        return ZuniaActivityKind.received;
      case ActivityKind.ibc:
        return ZuniaActivityKind.ibc;
      case ActivityKind.swap:
        return ZuniaActivityKind.swap;
      case ActivityKind.staking:
        return ZuniaActivityKind.staking;
      case ActivityKind.claim:
        return ZuniaActivityKind.claim;
      case ActivityKind.governance:
        return ZuniaActivityKind.governance;
      case ActivityKind.other:
        return ZuniaActivityKind.other;
    }
  }

  static String _dayLabel(DateTime when) {
    final now = DateTime.now();
    final day = DateTime(when.year, when.month, when.day);
    final today = DateTime(now.year, now.month, now.day);
    final delta = today.difference(day).inDays;
    if (delta == 0) return 'Today';
    if (delta == 1) return 'Yesterday';
    return '${day.year}-${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final activity = ref.watch(allActivityProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Activity',
          onBack: () => Navigator.of(context).pop(),
          trailing: Text(
            'All chains',
            style: zuniaMono(fontSize: 11, color: s.info),
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final entry in _filters.entries) ...[
                        GestureDetector(
                          onTap: () => setState(() => _filter = entry.key),
                          child: Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              gradient: _filter == entry.key
                                  ? s.accentGradient
                                  : null,
                              color: _filter == entry.key ? null : s.glass,
                            ),
                            child: Text(
                              entry.value.toUpperCase(),
                              style: zuniaMono(
                                fontSize: 10,
                                color: _filter == entry.key
                                    ? s.accentFg
                                    : s.fgMuted,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Expanded(
                child: !prefs.liveReads
                    ? const Padding(
                        padding: EdgeInsets.fromLTRB(18, 8, 18, 0),
                        child: ZuniaCallout(
                          tone: ZuniaCalloutTone.info,
                          title: 'Live reads are off',
                          body:
                              'Turn on live reads in Settings to load history '
                              'from public endpoints.',
                        ),
                      )
                    : activity.when(
                        data: (rows) => _list(
                          rows.where(_matches).toList(),
                          prefs,
                        ),
                        loading: () => const Padding(
                          padding: EdgeInsets.fromLTRB(18, 16, 18, 0),
                          child: Column(
                            children: [
                              ZuniaSkeleton(height: 52),
                              SizedBox(height: 12),
                              ZuniaSkeleton(height: 52),
                              SizedBox(height: 12),
                              ZuniaSkeleton(height: 52),
                            ],
                          ),
                        ),
                        error: (_, _) => const ZuniaEmptyState(
                          title: 'Endpoints unavailable',
                          description:
                              'No public endpoint answered for your enabled '
                              'chains. Try again later.',
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(List<ActivityItem> rows, AppPreferences prefs) {
    final s = ZuniaSemanticsExt.of(context);
    if (rows.isEmpty) {
      return const ZuniaEmptyState(
        title: 'No activity yet',
        description:
            'Transfers and signatures made with this wallet will show up here.',
      );
    }

    final children = <Widget>[];
    String? lastDay;
    for (final row in rows) {
      final day = _dayLabel(row.timestamp);
      if (day != lastDay) {
        lastDay = day;
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: ZuniaSectionLabel(day),
          ),
        );
      }
      final chain = ChainCatalog.isLoaded
          ? ChainCatalog.instance.find(row.chainId)
          : null;
      final time =
          '${row.timestamp.hour.toString().padLeft(2, '0')}:'
          '${row.timestamp.minute.toString().padLeft(2, '0')}';
      final kind = _uiKind(row.kind);
      final presentation = zuniaActivityPresentation(
        context,
        kind: kind,
        success: row.success,
      );
      final amount = row.amount == null || chain == null
          ? null
          : prefs.mask(
              formatBaseUnits(
                row.amount!,
                decimals: chain.coinDecimals,
              ),
            );
      final amountColor = zuniaActivityAmountColor(
        context,
        kind: kind,
        success: row.success,
        amount: amount,
      );

      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: presentation.border),
                  color: presentation.bg,
                ),
                child: Text(
                  presentation.icon,
                  style: TextStyle(
                    color: presentation.fg,
                    fontSize: 14,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.title,
                      style: zuniaSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        height: 1.2,
                        color: s.fg,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${chain?.chainName ?? row.chainId} · ${row.subtitle} · $time',
                      overflow: TextOverflow.ellipsis,
                      style: zuniaMono(fontSize: 10, color: s.fgMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    amount == null
                        ? '—'
                        : row.kind == ActivityKind.received ||
                                row.kind == ActivityKind.claim
                            ? '+$amount ${chain?.coinDenom ?? ''}'.trim()
                            : row.success
                                ? '-$amount ${chain?.coinDenom ?? ''}'.trim()
                                : '—',
                    style: zuniaMono(
                      fontSize: 12.5,
                      color: amount == null
                          ? s.fgMuted
                          : amountColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    row.success ? 'confirmed' : 'reverted',
                    style: zuniaMono(
                      fontSize: 9.5,
                      color: row.success ? s.info : s.danger,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(allActivityProvider),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: children,
      ),
    );
  }
}
