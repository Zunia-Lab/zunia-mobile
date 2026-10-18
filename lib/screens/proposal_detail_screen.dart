import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/governance_screen.dart';
import 'package:zunia_mobile/services/governance_client.dart';
import 'package:zunia_mobile/state/governance.dart';
import 'package:zunia_mobile/state/staking.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';
import 'package:zunia_mobile/ui/facts.dart';
import 'package:zunia_mobile/ui/markdown_text.dart';
import 'package:zunia_mobile/ui/tx_flow.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// The vote message for [option]: the option travels as its number, which is
/// what chains verify.
List<TxMsg> voteMsgs({
  required String voter,
  required String proposalId,
  required VoteOption option,
}) =>
    [TxMsg.vote(voter: voter, proposalId: proposalId, option: option.code)];

/// One proposal: what it says, how the vote stands, the user's own vote, and
/// a ballot while voting is open.
class ProposalDetailScreen extends ConsumerStatefulWidget {
  const ProposalDetailScreen({super.key, required this.proposal});

  final GovProposal proposal;

  @override
  ConsumerState<ProposalDetailScreen> createState() =>
      _ProposalDetailScreenState();
}

class _ProposalDetailScreenState extends ConsumerState<ProposalDetailScreen> {
  VoteOption? _choice;
  bool _changing = false;

  GovProposal get p => widget.proposal;

  Future<void> _review(String voter) async {
    final option = _choice;
    final chain = catalogChain(p.chainId);
    if (option == null || chain == null) return;
    final key = (chainId: p.chainId, proposalId: p.id);
    final done = await showTxReview(
      context,
      TxIntent(
        title: 'Review vote',
        action: 'Sign vote · ${option.label}',
        chain: chain,
        signer: voter,
        msgs: voteMsgs(voter: voter, proposalId: p.id, option: option),
        headlineLabel: 'Your vote',
        headline: option.label,
        headlineLine: 'Proposal #${p.id} · ${chain.chainName}',
        facts: [
          (label: 'Proposal', value: p.title),
          (label: 'Option', value: '${option.label} (${option.hint.toLowerCase()})'),
        ],
        result: const TxResultCopy(
          sending: 'Voting',
          done: 'Vote recorded',
          failed: 'Vote failed',
          doneMessage: 'Your vote counts. You can change it until voting ends.',
        ),
        onSettled: () {
          ref.invalidate(myVoteProvider(key));
          ref.invalidate(liveTallyProvider(key));
        },
      ),
    );
    if (done && mounted) {
      setState(() {
        _choice = null;
        _changing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final chain = catalogChain(p.chainId);
    final voting = p.status == GovStatus.voting;
    final ended = !voting && p.status != GovStatus.deposit;
    final key = (chainId: p.chainId, proposalId: p.id);
    final voter = ref
        .watch(chainAccountsProvider)
        .where((a) => a.chain.chainId == p.chainId)
        .firstOrNull
        ?.address;
    final myVote = voting ? ref.watch(myVoteProvider(key)) : null;
    final live = voting ? ref.watch(liveTallyProvider(key)).valueOrNull : null;
    final tally = voting ? live : p.tally;
    final voted = myVote?.valueOrNull;
    final showBallot = voting && voter != null && (voted == null || _changing);
    final deadline = endsIn(p.votingEndTime);
    final dates = MaterialLocalizations.of(context);

    return Scaffold(
      backgroundColor: s.screenMid,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Proposal #${p.id}',
          onBack: () => Navigator.of(context).maybePop(),
          footer: showBallot && _choice != null
              ? ZuniaButton(
                  label: 'Review vote · ${_choice!.label}',
                  size: ZuniaButtonSize.lg,
                  onPressed: () => _review(voter),
                )
              : null,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
            children: [
              Row(
                children: [
                  if (chain != null) ChainAvatar(chain: chain, size: 30),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          chain?.chainName ?? p.chainId,
                          style: zuniaSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: s.fg,
                          ),
                        ),
                        Text(
                          voting && deadline != null
                              ? '$deadline · '
                                  '${dates.formatMediumDate(p.votingEndTime!.toLocal())}'
                              : p.votingEndTime != null && ended
                                  ? 'Ended ${dates.formatMediumDate(p.votingEndTime!.toLocal())}'
                                  : govStatusLabel(p.status),
                          style: zuniaMono(fontSize: 11.5, color: s.fgDim),
                        ),
                      ],
                    ),
                  ),
                  ZuniaPill(
                    govStatusLabel(p.status),
                    tone: voting
                        ? ZuniaPillTone.accent
                        : p.status == GovStatus.rejected ||
                                p.status == GovStatus.failed
                            ? ZuniaPillTone.danger
                            : ZuniaPillTone.neutral,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Semantics(
                header: true,
                child: Text(
                  p.title,
                  style: zuniaSans(
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                    letterSpacing: -0.4,
                    color: s.fg,
                  ),
                ),
              ),
              if (voted != null && !_changing) ...[
                const SizedBox(height: 14),
                _YourVote(
                  vote: voted,
                  canChange: voting && voter != null,
                  onChange: () => setState(() => _changing = true),
                ),
              ],
              if (tally != null) ...[
                const SizedBox(height: 14),
                _Tally(tally: tally, ended: ended, status: p.status),
              ] else if (ended) ...[
                const SizedBox(height: 14),
                FactsCard(
                  children: [
                    FactRow(label: 'Result', value: govStatusLabel(p.status)),
                  ],
                ),
              ],
              if (showBallot) ...[
                const SectionCaption('Your vote'),
                _Ballot(
                  value: _choice,
                  onChanged: (o) => setState(() => _choice = o),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your vote carries the weight of what you stake on '
                  '${chain?.chainName ?? 'this network'}. Without stake it '
                  'counts for nothing; a validator you stake with votes for '
                  'you unless you vote yourself.',
                  style: zuniaSans(fontSize: 12.5, height: 1.45, color: s.fgDim),
                ),
              ] else if (voting && voter == null) ...[
                const SizedBox(height: 14),
                const ZuniaCallout(
                  body: 'This network is not enabled for the active account, '
                      'so there is no address to vote with.',
                ),
              ],
              const SectionCaption('Proposal'),
              if (p.summary.isEmpty)
                Text(
                  'No description was published with this proposal.',
                  style: zuniaSans(fontSize: 14, color: s.fgDim),
                )
              else
                MarkdownText(p.summary),
              if (p.messageTypes.isNotEmpty) ...[
                const SectionCaption('If it passes'),
                FactsCard(
                  children: [
                    for (final type in p.messageTypes)
                      FactRow(
                        label: 'Executes',
                        value: type.split('.').last,
                      ),
                  ],
                ),
              ],
              const SectionCaption('Dates'),
              FactsCard(
                children: [
                  if (p.submitTime != null)
                    FactRow(
                      label: 'Submitted',
                      value: dates.formatMediumDate(p.submitTime!.toLocal()),
                    ),
                  if (p.votingStartTime != null)
                    FactRow(
                      label: 'Voting opened',
                      value: dates.formatMediumDate(p.votingStartTime!.toLocal()),
                    ),
                  if (p.votingEndTime != null)
                    FactRow(
                      label: voting ? 'Voting closes' : 'Voting closed',
                      value: dates.formatMediumDate(p.votingEndTime!.toLocal()),
                    ),
                  if (p.status == GovStatus.deposit && p.depositEndTime != null)
                    FactRow(
                      label: 'Deposit period ends',
                      value: dates.formatMediumDate(p.depositEndTime!.toLocal()),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _YourVote extends StatelessWidget {
  const _YourVote({
    required this.vote,
    required this.canChange,
    required this.onChange,
  });

  final GovVote vote;
  final bool canChange;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final single = vote.single;
    final text = single != null
        ? 'You voted ${single.label}'
        : 'You split your vote: ${vote.options.map((o) => '${o.option.label} ${(o.weight * 100).round()}%').join(', ')}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: s.successFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: s.successLine),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.how_to_vote_outlined, size: 20, color: s.success),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: zuniaSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: s.successFg,
                ),
              ),
            ),
            if (canChange)
              TextButton(onPressed: onChange, child: const Text('Change')),
          ],
        ),
      ),
    );
  }
}

class _Tally extends StatelessWidget {
  const _Tally({required this.tally, required this.ended, required this.status});

  final GovTally tally;
  final bool ended;
  final GovStatus status;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final leading = tally.leading;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: s.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: s.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              ended ? 'RESULT' : 'TALLY SO FAR',
              style: zuniaMono(fontSize: 10.5, letterSpacing: 1.4, color: s.fgDim),
            ),
            const SizedBox(height: 6),
            Text(
              ended
                  ? govStatusLabel(status)
                  : '${leading.label} leading',
              style: zuniaSans(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                color: s.fg,
              ),
            ),
            const SizedBox(height: 12),
            TallyBar(
              yes: tally.yes,
              no: tally.no,
              veto: tally.veto,
              abstain: tally.abstain,
            ),
            const SizedBox(height: 10),
            for (final option in VoteOption.values)
              FactRow(
                label: option.label,
                value: '${(tally.shareOf(option) * 100).toStringAsFixed(1)}%',
              ),
            if (!ended)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Shares of the votes cast so far. Quorum and thresholds are '
                  'checked when voting closes.',
                  style: zuniaSans(fontSize: 12, color: s.fgDim),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Ballot extends StatelessWidget {
  const _Ballot({required this.value, required this.onChanged});

  final VoteOption? value;
  final ValueChanged<VoteOption> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    // Displayed in the order people read a ballot; signed by number.
    const order = [VoteOption.yes, VoteOption.no, VoteOption.veto, VoteOption.abstain];
    return Column(
      children: [
        for (final option in order)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Semantics(
              selected: option == value,
              button: true,
              label: '${option.label}. ${option.hint}',
              child: ExcludeSemantics(
                child: Material(
                  color: option == value ? s.stateSelected : s.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: option == value ? s.accent : s.line,
                      width: option == value ? 1.5 : 1,
                    ),
                  ),
                  child: InkWell(
                    customBorder: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    onTap: () {
                      ZuniaHaptics.selection();
                      onChanged(option);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  option.label,
                                  style: zuniaSans(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w600,
                                    color: s.fg,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  option.hint,
                                  style: zuniaSans(
                                    fontSize: 12.5,
                                    color: s.fgMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            option == value
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: option == value ? s.accent : s.fgDim,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
