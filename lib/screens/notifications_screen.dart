import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/chain_detail_screen.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Alerts derived from what the wallet already knows: claimable rewards,
/// unbonding about to land, incoming transfers, open votes. Nothing is pushed
/// from a server.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final balances = ref.watch(balancesProvider).valueOrNull ?? const {};
    final activity = ref.watch(allActivityProvider).valueOrNull ?? const [];
    final backupVerified =
        ref.watch(backupVerifiedProvider).valueOrNull ?? true;

    final items = <_Alert>[];

    if (!backupVerified) {
      items.add(
        const _Alert(
          icon: Icons.warning_amber_outlined,
          tone: ZuniaCalloutTone.warning,
          title: 'Recovery phrase not verified',
          body: 'Confirm your phrase before you fund this wallet.',
          unread: true,
        ),
      );
    }

    for (final account in accounts) {
      final chain = account.chain;
      final balance = balances[chain.chainId];
      if (balance == null) continue;
      if (balance.rewards != '0') {
        items.add(
          _Alert(
            icon: Icons.savings_outlined,
            title: 'Rewards ready on ${chain.chainName}',
            body:
                '${prefs.mask(formatBaseUnits(balance.rewards, decimals: chain.coinDecimals))} '
                '${chain.coinDenom} claimable',
            chainId: chain.chainId,
            unread: items.isEmpty,
          ),
        );
      }
    }

    for (final row in activity.take(20)) {
      if (row.kind != ActivityKind.received) continue;
      items.add(
        _Alert(
          icon: Icons.swap_horiz,
          title: 'Incoming transfer',
          body: '${row.subtitle} · ${row.timestamp.toLocal()}',
          chainId: row.chainId,
          unread: items.length < 2,
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Notifications',
          onBack: () => Navigator.of(context).pop(),
          trailing: items.isEmpty
              ? null
              : Text(
                  'Mark all read',
                  style: zuniaMono(fontSize: 10.5, color: s.info),
                ),
          body: !prefs.liveReads
              ? const Padding(
                  padding: EdgeInsets.fromLTRB(18, 0, 18, 0),
                  child: ZuniaCallout(
                    tone: ZuniaCalloutTone.info,
                    title: 'Live reads are off',
                    body:
                        'Most alerts come from chain state. Turn on live reads '
                        'in Settings to receive them.',
                  ),
                )
              : items.isEmpty
                  ? const ZuniaEmptyState(
                      title: 'Nothing needs you',
                      description:
                          'Claimable rewards, incoming transfers and unbonding '
                          'releases show up here.',
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                      children: [
                        for (final alert in items) ...[
                          _AlertCard(
                            alert: alert,
                            onTap: alert.chainId == null
                                ? null
                                : () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ChainDetailScreen(
                                          chainId: alert.chainId!,
                                        ),
                                      ),
                                    ),
                          ),
                          const SizedBox(height: 9),
                        ],
                        Container(
                          padding: const EdgeInsets.all(13),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: s.glass,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 18,
                                height: 18,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  color: s.accent,
                                ),
                                child: Icon(
                                  Icons.check,
                                  size: 12,
                                  color: s.accentFg,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Push alerts for transfers and governance',
                                  style: zuniaSans(
                                    fontSize: 11,
                                    height: 1.4,
                                    color: s.fgMuted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }
}

class _Alert {
  const _Alert({
    required this.icon,
    required this.title,
    required this.body,
    this.tone = ZuniaCalloutTone.info,
    this.chainId,
    this.unread = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final ZuniaCalloutTone tone;
  final String? chainId;
  final bool unread;
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, this.onTap});

  final _Alert alert;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final warn = alert.tone == ZuniaCalloutTone.warning;
    final accent = warn ? s.warning : s.accent;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: warn
                ? null
                : alert.unread
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          s.accent.withValues(alpha: 0.24),
                          s.info.withValues(alpha: 0.1),
                        ],
                      )
                    : s.surfaceRaisedGradient,
            color: warn ? s.warning.withValues(alpha: 0.1) : null,
            border: Border.all(
              color: warn
                  ? s.warning.withValues(alpha: 0.45)
                  : alert.unread
                      ? s.accent.withValues(alpha: 0.4)
                      : Colors.transparent,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: warn
                        ? s.warning.withValues(alpha: 0.12)
                        : alert.unread
                            ? s.accent
                            : s.glass,
                    border: warn
                        ? Border.all(
                            color: s.warning.withValues(alpha: 0.45),
                          )
                        : null,
                  ),
                  child: Icon(
                    alert.icon,
                    size: 15,
                    color: warn
                        ? s.warning
                        : alert.unread
                            ? s.accentFg
                            : s.fgMuted,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        alert.title,
                        style: zuniaSans(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                          color: warn
                              ? s.warning.withValues(alpha: 0.92)
                              : s.fg,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        alert.body,
                        style: zuniaMono(
                          fontSize: 10,
                          height: 1.4,
                          color: warn
                              ? s.warning.withValues(alpha: 0.85)
                              : s.fgMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (alert.unread)
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(top: 4, left: 8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
