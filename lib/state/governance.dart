/// Governance across every enabled network: the proposal feed, its filters
/// and paging, and the per-proposal reads the detail screen needs.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/governance_client.dart';
import 'package:zunia_mobile/state/staking.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

/// Rows shown per step of the infinite list, as the extension's "Load more".
const governancePageSize = 10;

/// Proposals asked of each chain per request.
const proposalsPerRequest = 20;

enum GovFilter { all, voting, passed, rejected, deposit }

extension GovFilterLabel on GovFilter {
  String get label => switch (this) {
        GovFilter.all => 'All',
        GovFilter.voting => 'Voting',
        GovFilter.passed => 'Passed',
        GovFilter.rejected => 'Rejected',
        GovFilter.deposit => 'Deposit',
      };
}

final governanceClientProvider = Provider<GovernanceClient>(
  (ref) => GovernanceClient(ref.watch(chainReaderProvider)),
);

/// What one chain has answered so far.
@immutable
class ChainProposals {
  const ChainProposals({
    this.rows = const [],
    this.nextKey,
    this.loading = false,
    this.error,
    this.loaded = false,
  });

  final List<GovProposal> rows;

  /// Null when nothing older is left, or before the first page.
  final String? nextKey;
  final bool loading;
  final ChainReadError? error;

  /// The first page has answered (rows or error).
  final bool loaded;

  bool get hasMore => nextKey != null;

  ChainProposals copyWith({
    List<GovProposal>? rows,
    String? Function()? nextKey,
    bool? loading,
    ChainReadError? Function()? error,
    bool? loaded,
  }) =>
      ChainProposals(
        rows: rows ?? this.rows,
        nextKey: nextKey == null ? this.nextKey : nextKey(),
        loading: loading ?? this.loading,
        error: error == null ? this.error : error(),
        loaded: loaded ?? this.loaded,
      );
}

@immutable
class GovernanceFeedState {
  const GovernanceFeedState(this.byChain);

  final Map<String, ChainProposals> byChain;

  List<GovProposal> get all => [
        for (final chain in byChain.values) ...chain.rows,
      ];

  /// No chain has answered its first page yet.
  bool get loadingFirst =>
      byChain.isNotEmpty && byChain.values.every((c) => !c.loaded);

  bool loadingIn(Iterable<String> chainIds) =>
      chainIds.any((id) => byChain[id]?.loading ?? false);

  bool hasMoreIn(Iterable<String> chainIds) =>
      chainIds.any((id) => byChain[id]?.hasMore ?? false);
}

/// The proposal feed for [chainIds], loaded a page per chain at a time.
class GovernanceFeed extends StateNotifier<GovernanceFeedState> {
  GovernanceFeed(this._client, this._chainIds)
      : super(GovernanceFeedState({
          for (final id in _chainIds) id: const ChainProposals(loading: true),
        })) {
    for (final id in _chainIds) {
      unawaited(_load(id, null));
    }
  }

  final GovernanceClient _client;
  final List<String> _chainIds;

  Future<void> _load(String chainId, String? key) async {
    final chain = catalogChain(chainId);
    if (chain == null) {
      _put(chainId, const ChainProposals(loaded: true));
      return;
    }
    final before = state.byChain[chainId] ?? const ChainProposals();
    _put(chainId, before.copyWith(loading: true, error: () => null));
    try {
      final page = await _client.proposals(
        chain,
        key: key,
        limit: proposalsPerRequest,
      );
      if (!mounted) return;
      final current = state.byChain[chainId] ?? const ChainProposals();
      final seen = {for (final p in current.rows) p.id};
      _put(
        chainId,
        current.copyWith(
          rows: [
            if (key != null) ...current.rows,
            for (final p in page.rows)
              if (key == null || !seen.contains(p.id)) p,
          ],
          nextKey: () => page.nextKey,
          loading: false,
          loaded: true,
        ),
      );
    } on ChainReadError catch (e) {
      if (!mounted) return;
      final current = state.byChain[chainId] ?? const ChainProposals();
      _put(
        chainId,
        current.copyWith(loading: false, loaded: true, error: () => e),
      );
    }
  }

  void _put(String chainId, ChainProposals value) {
    if (!mounted) return;
    state = GovernanceFeedState({...state.byChain, chainId: value});
  }

  /// Ask the next page of every chain in [chainIds] that has one and is not
  /// already loading.
  Future<void> loadMore(Iterable<String> chainIds) async {
    final pending = <Future<void>>[];
    for (final id in chainIds) {
      final chain = state.byChain[id];
      if (chain == null || chain.loading || !chain.hasMore) continue;
      pending.add(_load(id, chain.nextKey));
    }
    await Future.wait(pending);
  }

  Future<void> refresh() async {
    await Future.wait([for (final id in _chainIds) _load(id, null)]);
  }
}

final governanceFeedProvider =
    StateNotifierProvider.autoDispose<GovernanceFeed, GovernanceFeedState>(
  (ref) {
    final chainIds = [
      for (final a in ref.watch(chainAccountsProvider)) a.chain.chainId,
    ];
    return GovernanceFeed(ref.watch(governanceClientProvider), chainIds);
  },
);

/// Filter, search and order the feed the way the extension does: open votes
/// first, then newest id first; search covers title, `#id`, network name and
/// id, status and the start of the summary.
List<GovProposal> visibleProposals(
  Iterable<GovProposal> rows, {
  String? network,
  GovFilter filter = GovFilter.all,
  String query = '',
  Map<String, String> chainNames = const {},
}) {
  final q = query.trim().toLowerCase();
  final out = rows.where((p) {
    if (network != null && p.chainId != network) return false;
    switch (filter) {
      case GovFilter.all:
        break;
      case GovFilter.voting:
        if (p.status != GovStatus.voting) return false;
      case GovFilter.passed:
        if (p.status != GovStatus.passed) return false;
      case GovFilter.rejected:
        if (p.status != GovStatus.rejected) return false;
      case GovFilter.deposit:
        if (p.status != GovStatus.deposit) return false;
    }
    if (q.isEmpty) return true;
    final name = (chainNames[p.chainId] ?? '').toLowerCase();
    final summary = p.summary.length > 280
        ? p.summary.substring(0, 280).toLowerCase()
        : p.summary.toLowerCase();
    final bareId = q.startsWith('#') ? q.substring(1) : q;
    return p.title.toLowerCase().contains(q) ||
        p.id == bareId ||
        p.chainId.toLowerCase().contains(q) ||
        name.contains(q) ||
        p.status.name.contains(q) ||
        summary.contains(q);
  }).toList();
  out.sort((a, b) {
    final ra = a.status == GovStatus.voting ? 0 : 1;
    final rb = b.status == GovStatus.voting ? 0 : 1;
    if (ra != rb) return ra - rb;
    final byId = b.numericId.compareTo(a.numericId);
    return byId != 0 ? byId : a.chainId.compareTo(b.chainId);
  });
  return out;
}

/// How many rows to show after the user reached the end of [shown] rows, and
/// whether more pages must be asked of the chains first.
({int count, bool fetch}) nextGovernancePage({
  required int shown,
  required int available,
  required bool chainsHaveMore,
}) {
  if (shown < available) {
    final next = shown + governancePageSize;
    return (count: next > available ? available : next, fetch: false);
  }
  return (count: shown, fetch: chainsHaveMore);
}

/// The vote the active address cast on a proposal, read from the chain.
final myVoteProvider = FutureProvider.autoDispose
    .family<GovVote?, ({String chainId, String proposalId})>((ref, key) async {
  final chain = catalogChain(key.chainId);
  final address = activeAddressOn(ref, key.chainId);
  if (chain == null || address == null) return null;
  return ref
      .watch(governanceClientProvider)
      .vote(chain, key.proposalId, address);
});

/// The running tally of a proposal in its voting period.
final liveTallyProvider = FutureProvider.autoDispose
    .family<GovTally?, ({String chainId, String proposalId})>((ref, key) async {
  final chain = catalogChain(key.chainId);
  if (chain == null) return null;
  return ref.watch(governanceClientProvider).liveTally(chain, key.proposalId);
});
