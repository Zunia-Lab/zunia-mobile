import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/wallet_header.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Onboarding checklist framed as missions. Progress is read from what the
/// wallet has actually done on chain, never from a score kept on a server.
class MissionsTab extends ConsumerWidget {
  const MissionsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final accounts = ref.watch(chainAccountsProvider);
    final activity = ref.watch(allActivityProvider).valueOrNull ?? const [];
    final backupVerified =
        ref.watch(backupVerifiedProvider).valueOrNull ?? false;

    final kinds = activity.map((a) => a.kind).toSet();
    final missions = <_Mission>[
      _Mission(
        icon: Icons.verified_outlined,
        title: 'Verify your recovery phrase',
        detail: 'The only way back into this wallet',
        done: backupVerified,
      ),
      _Mission(
        icon: Icons.hub_outlined,
        title: 'Enable two networks',
        detail: '${accounts.length} enabled',
        done: accounts.length >= 2,
      ),
      _Mission(
        icon: Icons.swap_horiz,
        title: 'Make your first transfer',
        detail: 'Send or receive on any chain',
        done: kinds.contains(ActivityKind.sent) ||
            kinds.contains(ActivityKind.received),
      ),
      _Mission(
        icon: Icons.diamond_outlined,
        title: 'Delegate to a validator',
        detail: 'Put idle stake to work',
        done: kinds.contains(ActivityKind.staking) ||
            kinds.contains(ActivityKind.claim),
      ),
      _Mission(
        icon: Icons.how_to_vote_outlined,
        title: 'Vote on a proposal',
        detail: 'Have a say in a chain you hold',
        done: kinds.contains(ActivityKind.governance),
      ),
    ];

    final complete = missions.where((m) => m.done).length;
    final progress = missions.isEmpty ? 0.0 : complete / missions.length;
    final remaining = missions.length - complete;

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
                Row(
                  children: [
                    Text(
                      'Missions',
                      style: zuniaSans(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.3,
                        color: s.fg,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: s.glass,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Season',
                        style: zuniaMono(fontSize: 10, color: s.fgMuted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        s.accent.withValues(alpha: 0.38),
                        s.info.withValues(alpha: 0.2),
                        s.glass,
                      ],
                      stops: const [0, 0.58, 1],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'YOUR PROGRESS',
                            style: zuniaMono(
                              fontSize: 9.5,
                              letterSpacing: 1.3,
                              color: s.fgMuted,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '$complete / ${missions.length}',
                            style: zuniaMono(fontSize: 10, color: s.fgMuted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text.rich(
                        TextSpan(
                          style: zuniaSans(
                            fontSize: 30,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -1,
                            color: s.fg,
                          ),
                          children: [
                            const TextSpan(text: 'Level '),
                            TextSpan(
                              text: '${(complete + 1).clamp(1, 5)}',
                              style: TextStyle(color: s.info),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 7,
                          backgroundColor: s.fg.withValues(alpha: 0.16),
                          valueColor: AlwaysStoppedAnimation(s.accent),
                        ),
                      ),
                      const SizedBox(height: 11),
                      Row(
                        children: [
                          Text(
                            '$complete of ${missions.length} done',
                            style: zuniaMono(fontSize: 9.5, color: s.fgMuted),
                          ),
                          const Spacer(),
                          Text(
                            remaining == 0
                                ? 'complete'
                                : '+$remaining to go',
                            style: zuniaMono(
                              fontSize: 9.5,
                              color: s.success,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const ZuniaSectionLabel('This week'),
                const SizedBox(height: 8),
                for (final mission in missions) _MissionRow(mission: mission),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Mission {
  const _Mission({
    required this.icon,
    required this.title,
    required this.detail,
    required this.done,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool done;
}

class _MissionRow extends StatelessWidget {
  const _MissionRow({required this.mission});

  final _Mission mission;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          gradient: mission.done ? s.surfaceRaisedGradient : null,
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: mission.done ? s.accentGradient : null,
                color: mission.done ? null : s.glass2,
              ),
              child: Icon(
                mission.icon,
                size: 15,
                color: mission.done ? s.accentFg : s.fgMuted,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mission.title,
                    style: zuniaSans(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: s.fg,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    mission.done
                        ? mission.detail
                        : '${mission.detail} · not started',
                    style: zuniaMono(fontSize: 9.5, color: s.fgMuted),
                  ),
                ],
              ),
            ),
            if (mission.done)
              Icon(Icons.check_circle, size: 18, color: const Color(0xFFF2913B))
            else
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: s.glass2,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'Go',
                  style: zuniaMono(fontSize: 9.5, color: s.fgMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
