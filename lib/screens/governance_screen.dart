import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/chain_picker.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Proposals for one chain, open votes first.
class GovernanceScreen extends ConsumerStatefulWidget {
  const GovernanceScreen({super.key});

  @override
  ConsumerState<GovernanceScreen> createState() => _GovernanceScreenState();
}

class _GovernanceScreenState extends ConsumerState<GovernanceScreen> {
  String? _chainId;

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);

    if (accounts.isEmpty) {
      return _shell(
        const ZuniaEmptyState(
          title: 'No networks enabled',
          description: 'Enable a chain to read its governance proposals.',
        ),
      );
    }

    final chainId = accounts.any((a) => a.chain.chainId == _chainId)
        ? _chainId!
        : accounts.first.chain.chainId;

    if (!prefs.liveReads) {
      return _shell(
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
          child: Column(
            children: [
              ChainPicker(
                value: chainId,
                onChanged: (v) => setState(() => _chainId = v),
              ),
              const SizedBox(height: 16),
              const ZuniaCallout(
                tone: ZuniaCalloutTone.info,
                title: 'Live reads are off',
                body:
                    'Turn on live reads in Settings to load proposals from '
                    'public endpoints.',
              ),
            ],
          ),
        ),
      );
    }

    final proposals = ref.watch(proposalsProvider(chainId));

    return _shell(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
            child: ChainPicker(
              value: chainId,
              onChanged: (v) => setState(() => _chainId = v),
            ),
          ),
          Expanded(
            child: proposals.when(
              data: (rows) {
                if (rows.isEmpty) {
                  return const ZuniaEmptyState(
                    title: 'No proposals',
                    description:
                        'This chain has no governance history the endpoint '
                        'will share.',
                  );
                }
                final sorted = [...rows]..sort((a, b) {
                    final av = a.status == ProposalStatus.voting ? 0 : 1;
                    final bv = b.status == ProposalStatus.voting ? 0 : 1;
                    if (av != bv) return av - bv;
                    return (int.tryParse(b.id) ?? 0) -
                        (int.tryParse(a.id) ?? 0);
                  });
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                  itemCount: sorted.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => _ProposalCard(proposal: sorted[i]),
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.all(18),
                child: Column(
                  children: [
                    ZuniaSkeleton(height: 72),
                    SizedBox(height: 12),
                    ZuniaSkeleton(height: 72),
                    SizedBox(height: 12),
                    ZuniaSkeleton(height: 72),
                  ],
                ),
              ),
              error: (_, _) => const ZuniaEmptyState(
                title: 'Endpoint unavailable',
                description:
                    'The public endpoint for this chain did not answer.',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _shell(Widget body) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Governance',
          onBack: () => Navigator.of(context).pop(),
          body: body,
        ),
      ),
    );
  }
}

class _ProposalCard extends StatefulWidget {
  const _ProposalCard({required this.proposal});

  final ProposalInfo proposal;

  @override
  State<_ProposalCard> createState() => _ProposalCardState();
}

class _ProposalCardState extends State<_ProposalCard> {
  String? _vote;

  static String _label(ProposalStatus status) {
    switch (status) {
      case ProposalStatus.voting:
        return 'VOTING';
      case ProposalStatus.deposit:
        return 'DEPOSIT';
      case ProposalStatus.passed:
        return 'PASSED';
      case ProposalStatus.rejected:
        return 'REJECTED';
      case ProposalStatus.failed:
        return 'FAILED';
      case ProposalStatus.unknown:
        return 'UNKNOWN';
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final proposal = widget.proposal;
    final voting = proposal.status == ProposalStatus.voting;
    final tally = proposal.tally;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.surfaceRaisedGradient,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: voting ? s.infoLine : s.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Proposal ${proposal.id}',
                  style: zuniaSans(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: s.fg,
                  ),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: voting
                          ? s.info.withValues(alpha: 0.45)
                          : s.line,
                    ),
                  ),
                  child: Text(
                    _label(proposal.status),
                    style: zuniaMono(
                      fontSize: 10,
                      color: voting ? s.info : s.fgMuted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              proposal.title,
              style: zuniaSans(
                fontSize: 19,
                fontWeight: FontWeight.w500,
                height: 1.25,
                letterSpacing: -0.4,
                color: s.fg,
              ),
            ),
            if (proposal.summary.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                proposal.summary,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: zuniaSans(
                  fontSize: 12,
                  height: 1.55,
                  color: s.fgMuted,
                ),
              ),
            ],
            if (tally != null) ...[
              const SizedBox(height: 14),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: s.surfaceRaisedGradient,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'TALLY',
                            style: zuniaMono(
                              fontSize: 10,
                              color: s.fgMuted,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'quorum',
                            style: zuniaMono(
                              fontSize: 10,
                              color: s.fgMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      ZuniaTallyBar(
                        yes: tally.yes,
                        no: tally.no,
                        veto: tally.veto,
                        abstain: tally.abstain,
                      ),
                      const SizedBox(height: 14),
                      ZuniaKeyValueRow(
                        label: 'Yes',
                        value: '${(tally.yes * 100).toStringAsFixed(1)}%',
                      ),
                      const SizedBox(height: 9),
                      ZuniaKeyValueRow(
                        label: 'No',
                        value: '${(tally.no * 100).toStringAsFixed(1)}%',
                      ),
                      const SizedBox(height: 9),
                      ZuniaKeyValueRow(
                        label: 'No with veto',
                        value: '${(tally.veto * 100).toStringAsFixed(1)}%',
                      ),
                      const SizedBox(height: 9),
                      ZuniaKeyValueRow(
                        label: 'Abstain',
                        value: '${(tally.abstain * 100).toStringAsFixed(1)}%',
                      ),
                      if (proposal.votingEndTime != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Ends ${proposal.votingEndTime!.toLocal().toString().split(' ').first}',
                          style: zuniaMono(fontSize: 10.5, color: s.fgDim),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
            if (voting) ...[
              const SizedBox(height: 14),
              const ZuniaSectionLabel('Your vote'),
              const SizedBox(height: 10),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.6,
                children: [
                  for (final option in const ['Yes', 'No', 'Veto', 'Abstain'])
                    _VoteCell(
                      label: option,
                      selected: _vote == option,
                      onTap: () => setState(() => _vote = option),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              ZuniaButton(
                label: 'Sign vote',
                size: ZuniaButtonSize.lg,
                onPressed: _vote == null
                    ? null
                    : () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Voting needs a signing endpoint. Nothing left the device.',
                            ),
                          ),
                        );
                      },
              ),
              const SizedBox(height: 8),
              Text(
                'Voting needs a signing endpoint; reads are enabled, writes are not.',
                style: zuniaMono(fontSize: 9, height: 1.5, color: s.fgDim),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VoteCell extends StatelessWidget {
  const _VoteCell({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            color: selected
                ? s.accent.withValues(alpha: 0.22)
                : s.glass,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? s.info.withValues(alpha: 0.7)
                  : Colors.transparent,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: zuniaSans(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: selected ? s.fg : s.fgMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
