import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/proposal_detail_screen.dart';
import 'package:zunia_mobile/services/governance_client.dart';
import 'package:zunia_mobile/state/governance.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/ui/facts.dart';
import 'package:zunia_mobile/ui/network_sheet.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// "Ends in 3d", "Ends in 5h", or null once it has ended.
String? endsIn(DateTime? end, {DateTime? now}) {
  if (end == null) return null;
  final ms = end.difference(now ?? DateTime.now()).inMilliseconds;
  if (ms <= 0) return null;
  final days = ms ~/ 86400000;
  if (days >= 1) return 'Ends in ${days}d';
  final hours = (ms / 3600000).round().clamp(1, 24);
  return 'Ends in ${hours}h';
}

String govStatusLabel(GovStatus status) => switch (status) {
      GovStatus.voting => 'Voting',
      GovStatus.deposit => 'Deposit',
      GovStatus.passed => 'Passed',
      GovStatus.rejected => 'Rejected',
      GovStatus.failed => 'Failed',
      GovStatus.unknown => 'Closed',
    };

/// Governance across every enabled network: filter by network and status,
/// search, scroll for more. Open votes come first.
class GovernanceScreen extends ConsumerStatefulWidget {
  const GovernanceScreen({super.key});

  @override
  ConsumerState<GovernanceScreen> createState() => _GovernanceScreenState();
}

class _GovernanceScreenState extends ConsumerState<GovernanceScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String? _network;
  GovFilter _filter = GovFilter.all;
  String _query = '';
  int _visible = governancePageSize;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  /// A change of filter starts again at the first page.
  void _set(VoidCallback change) {
    setState(() {
      change();
      _visible = governancePageSize;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  List<String> _scope() {
    final ids = [
      for (final a in ref.read(chainAccountsProvider)) a.chain.chainId,
    ];
    return _network == null ? ids : ids.where((id) => id == _network).toList();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels < position.maxScrollExtent - 600) return;
    _loadNext();
  }

  void _loadNext() {
    final feed = ref.read(governanceFeedProvider);
    final scope = _scope();
    final available = _shown(feed).length;
    final next = nextGovernancePage(
      shown: _visible,
      available: available,
      chainsHaveMore: feed.hasMoreIn(scope),
    );
    if (next.count != _visible) setState(() => _visible = next.count);
    if (next.fetch && !feed.loadingIn(scope)) {
      unawaited(ref.read(governanceFeedProvider.notifier).loadMore(scope));
    }
  }

  List<GovProposal> _shown(GovernanceFeedState feed) {
    final names = {
      for (final a in ref.read(chainAccountsProvider))
        a.chain.chainId: a.chain.chainName,
    };
    return visibleProposals(
      feed.all,
      network: _network,
      filter: _filter,
      query: _query,
      chainNames: names,
    );
  }

  Future<void> _pickNetwork() async {
    final chains = [for (final a in ref.read(chainAccountsProvider)) a.chain];
    final picked = await pickNetwork(
      context,
      chains: chains,
      selected: _network ?? allNetworks,
      title: 'Show proposals on',
      allowAll: true,
    );
    if (picked == null || !mounted) return;
    _set(() => _network = picked == allNetworks ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final live = ref.watch(preferencesProvider.select((p) => p.liveReads));
    final accounts = ref.watch(chainAccountsProvider);
    final names = {for (final a in accounts) a.chain.chainId: a.chain.chainName};
    if (_network != null && !names.containsKey(_network)) _network = null;
    final feed = live ? ref.watch(governanceFeedProvider) : null;
    final shown = feed == null ? const <GovProposal>[] : _shown(feed);
    final page = shown.take(_visible).toList();
    final scope = _scope();
    final more = page.length < shown.length ||
        (feed?.hasMoreIn(scope) ?? false);
    final openCount = (feed?.all ?? const <GovProposal>[])
        .where((p) =>
            p.status == GovStatus.voting &&
            (_network == null || p.chainId == _network))
        .length;
    final failures = [
      for (final id in scope)
        if (feed?.byChain[id]?.error case final e?) (id, e),
    ];

    // Short lists never scroll, so the scroll listener would never ask for
    // the next page: ask once the frame is laid out.
    if (feed != null && more && !feed.loadingIn(scope)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        if (_scroll.position.maxScrollExtent <= 0) _loadNext();
      });
    }

    final selected = _network == null
        ? null
        : accounts.where((a) => a.chain.chainId == _network).firstOrNull?.chain;

    return Scaffold(
      backgroundColor: s.screenMid,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Governance',
          onBack: () => Navigator.of(context).maybePop(),
          trailing: openCount == 0
              ? null
              : Text(
                  '$openCount open',
                  style: zuniaMono(fontSize: 11, color: s.accent),
                ),
          body: accounts.isEmpty
              ? const ZuniaEmptyState(
                  title: 'No networks enabled',
                  description: 'Enable a network to read its proposals.',
                )
              : !live
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: ZuniaCallout(
                        title: 'Live reads are off',
                        body: 'Proposals come from the same public endpoints '
                            'as balances, so governance follows that switch '
                            'in Preferences.',
                      ),
                    )
                  : RefreshIndicator.adaptive(
                      onRefresh: () {
                        setState(() => _visible = governancePageSize);
                        return ref
                            .read(governanceFeedProvider.notifier)
                            .refresh();
                      },
                      child: CustomScrollView(
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: NetworkChipButton(
                                          chain: selected,
                                          label: 'All networks',
                                          onTap: _pickNetwork,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  ZuniaSearchField(
                                    controller: _search,
                                    hintText: 'Search title, #id or network',
                                    onChanged: (v) => _set(() => _query = v),
                                  ),
                                  const SizedBox(height: 10),
                                  _StatusChips(
                                    value: _filter,
                                    onChanged: (f) => _set(() => _filter = f),
                                  ),
                                  for (final (id, e) in failures)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 10),
                                      child: ZuniaCallout(
                                        tone: ZuniaCalloutTone.warning,
                                        body: '${names[id] ?? id}: '
                                            '${e.userMessage}',
                                      ),
                                    ),
                                  const SizedBox(height: 6),
                                ],
                              ),
                            ),
                          ),
                          if (feed!.loadingFirst)
                            const SliverPadding(
                              padding: EdgeInsets.symmetric(horizontal: 16),
                              sliver: SliverToBoxAdapter(
                                child: ListSkeleton(
                                  rows: 5,
                                  label: 'Loading proposals',
                                ),
                              ),
                            )
                          else if (page.isEmpty && !more)
                            SliverToBoxAdapter(
                              child: ZuniaEmptyState(
                                title: _query.trim().isNotEmpty ||
                                        _filter != GovFilter.all
                                    ? 'Nothing matches'
                                    : 'No proposals',
                                description: _query.trim().isNotEmpty
                                    ? 'No proposal matches “${_query.trim()}”.'
                                    : _filter != GovFilter.all
                                        ? 'No ${_filter.label.toLowerCase()} '
                                            'proposals here.'
                                        : _network == null
                                            ? 'None of the enabled networks '
                                                'returned a proposal.'
                                            : 'No proposals on '
                                                '${names[_network] ?? _network}.',
                              ),
                            )
                          else
                            SliverPadding(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 4, 16, 0),
                              sliver: SliverList.builder(
                                itemCount: page.length,
                                itemBuilder: (_, i) => Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: _ProposalCard(
                                    proposal: page[i],
                                    chainName: names[page[i].chainId] ??
                                        page[i].chainId,
                                    onOpen: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ProposalDetailScreen(
                                          proposal: page[i],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (more && !feed.loadingFirst)
                            const SliverPadding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              sliver: SliverToBoxAdapter(
                                child: ListSkeleton(
                                  rows: 1,
                                  label: 'Loading more proposals',
                                ),
                              ),
                            ),
                          const SliverPadding(
                            padding: EdgeInsets.only(bottom: 32),
                          ),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }
}

class _StatusChips extends StatelessWidget {
  const _StatusChips({required this.value, required this.onChanged});

  final GovFilter value;
  final ValueChanged<GovFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final filter in GovFilter.values) ...[
            Semantics(
              selected: filter == value,
              button: true,
              label: 'Show ${filter.label.toLowerCase()} proposals',
              child: ExcludeSemantics(
                child: ChoiceChip(
                  label: Text(filter.label),
                  selected: filter == value,
                  showCheckmark: false,
                  onSelected: (_) {
                    ZuniaHaptics.selection();
                    onChanged(filter);
                  },
                  labelStyle: zuniaSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: filter == value ? s.fg : s.fgMuted,
                  ),
                  selectedColor: s.stateSelected,
                  backgroundColor: Colors.transparent,
                  side: BorderSide(
                    color: filter == value ? s.accent : s.line,
                  ),
                  shape: const StadiumBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _ProposalCard extends ConsumerWidget {
  const _ProposalCard({
    required this.proposal,
    required this.chainName,
    required this.onOpen,
  });

  final GovProposal proposal;
  final String chainName;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final voting = proposal.status == GovStatus.voting;
    final deadline = voting ? endsIn(proposal.votingEndTime) : null;
    final vote = voting
        ? ref
            .watch(myVoteProvider(
              (chainId: proposal.chainId, proposalId: proposal.id),
            ))
            .valueOrNull
        : null;
    final tally = proposal.tally;

    final String tag;
    final Color tagColor;
    if (vote != null) {
      tag = vote.single == null ? 'Voted (split)' : 'Voted ${vote.single!.label}';
      tagColor = s.success;
    } else if (deadline != null) {
      tag = deadline;
      tagColor = s.accent;
    } else {
      tag = govStatusLabel(proposal.status);
      tagColor = switch (proposal.status) {
        GovStatus.passed => s.success,
        GovStatus.rejected || GovStatus.failed => s.danger,
        GovStatus.voting => s.accent,
        _ => s.fgMuted,
      };
    }

    return Material(
      color: s.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: voting ? s.lineStrong : s.line),
      ),
      child: InkWell(
        customBorder: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '#${proposal.id} · $chainName',
                        overflow: TextOverflow.ellipsis,
                        style: zuniaMono(fontSize: 11.5, color: s.fgDim),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      tag.toUpperCase(),
                      style: zuniaMono(
                        fontSize: 10.5,
                        letterSpacing: 0.8,
                        color: tagColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  proposal.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: zuniaSans(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                    color: s.fg,
                  ),
                ),
                if (tally != null) ...[
                  const SizedBox(height: 10),
                  ZuniaTallyBar(
                    yes: tally.yes,
                    no: tally.no,
                    veto: tally.veto,
                    abstain: tally.abstain,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Yes ${_pct(tally.yes)} · No ${_pct(tally.no)} · '
                    'Veto ${_pct(tally.veto)} · Abstain ${_pct(tally.abstain)}',
                    style: zuniaMono(fontSize: 10.5, color: s.fgDim),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  voting ? 'Open to vote' : 'Open details',
                  style: zuniaSans(fontSize: 12.5, color: s.accent),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _pct(double share) => '${(share * 100).round()}%';
