/// Governance reads: proposals a page at a time, a proposal's live tally, and
/// the vote the active address already cast.
///
/// Gov v1 first, falling back to v1beta1 for chains that never migrated, as
/// zunia-extension/lib/chain-queries.ts `fetchProposals` does. A chain that
/// answered v1beta1 once is remembered, so later pages go straight there.
library;

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/chain_reader.dart';

enum GovStatus { voting, deposit, passed, rejected, failed, unknown }

GovStatus govStatusFrom(String raw) => switch (raw) {
      'PROPOSAL_STATUS_VOTING_PERIOD' => GovStatus.voting,
      'PROPOSAL_STATUS_DEPOSIT_PERIOD' => GovStatus.deposit,
      'PROPOSAL_STATUS_PASSED' => GovStatus.passed,
      'PROPOSAL_STATUS_REJECTED' => GovStatus.rejected,
      'PROPOSAL_STATUS_FAILED' => GovStatus.failed,
      _ => GovStatus.unknown,
    };

/// The four answers, numbered as chains verify them in `MsgVote.option`.
enum VoteOption {
  yes(1, 'Yes', 'Support this proposal'),
  abstain(2, 'Abstain', 'Count toward quorum'),
  no(3, 'No', 'Reject this proposal'),
  veto(4, 'Veto', 'Reject as spam or harmful');

  const VoteOption(this.code, this.label, this.hint);

  /// What is signed.
  final int code;
  final String label;
  final String hint;

  static VoteOption? fromWire(Object? raw) {
    final text = asString(raw).toUpperCase();
    return switch (text) {
      'VOTE_OPTION_YES' || '1' => VoteOption.yes,
      'VOTE_OPTION_ABSTAIN' || '2' => VoteOption.abstain,
      'VOTE_OPTION_NO' || '3' => VoteOption.no,
      'VOTE_OPTION_NO_WITH_VETO' || '4' => VoteOption.veto,
      _ => null,
    };
  }
}

/// Shares of the votes counted so far, 0-1 each.
@immutable
class GovTally {
  const GovTally({
    required this.yes,
    required this.no,
    required this.veto,
    required this.abstain,
  });

  final double yes;
  final double no;
  final double veto;
  final double abstain;

  /// Null when nothing has been counted (a chain reports zeros during the
  /// voting period on gov v1 until the live tally is asked for).
  static GovTally? fromJson(Object? raw) {
    final map = asMap(raw);
    BigInt read(String a, String b) =>
        asBaseUnits(map[a] ?? map[b]) ?? BigInt.zero;
    final yes = read('yes_count', 'yes');
    final no = read('no_count', 'no');
    final veto = read('no_with_veto_count', 'no_with_veto');
    final abstain = read('abstain_count', 'abstain');
    final total = yes + no + veto + abstain;
    if (total <= BigInt.zero) return null;
    double share(BigInt part) =>
        ((part * BigInt.from(1000000)) ~/ total).toInt() / 1e6;
    return GovTally(
      yes: share(yes),
      no: share(no),
      veto: share(veto),
      abstain: share(abstain),
    );
  }

  /// The option with the largest share.
  VoteOption get leading {
    var best = VoteOption.yes;
    var top = yes;
    for (final (option, value) in [
      (VoteOption.no, no),
      (VoteOption.veto, veto),
      (VoteOption.abstain, abstain),
    ]) {
      if (value > top) {
        best = option;
        top = value;
      }
    }
    return best;
  }

  double shareOf(VoteOption option) => switch (option) {
        VoteOption.yes => yes,
        VoteOption.no => no,
        VoteOption.veto => veto,
        VoteOption.abstain => abstain,
      };
}

@immutable
class GovProposal {
  const GovProposal({
    required this.chainId,
    required this.id,
    required this.title,
    required this.summary,
    required this.status,
    this.submitTime,
    this.votingStartTime,
    this.votingEndTime,
    this.depositEndTime,
    this.tally,
    this.messageTypes = const [],
  });

  final String chainId;
  final String id;
  final String title;

  /// As the proposer wrote it: markdown, sometimes pasted HTML. Rendered by
  /// the screen as plain text, never as markup.
  final String summary;
  final GovStatus status;
  final DateTime? submitTime;
  final DateTime? votingStartTime;
  final DateTime? votingEndTime;
  final DateTime? depositEndTime;

  /// The final tally, or null while voting (see [GovTally.fromJson]).
  final GovTally? tally;

  /// `/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade`, …: what passing would do.
  final List<String> messageTypes;

  String get key => '$chainId:$id';

  int get numericId => int.tryParse(id) ?? 0;
}

@immutable
class ProposalPage {
  const ProposalPage({required this.rows, required this.nextKey});

  /// Newest first.
  final List<GovProposal> rows;

  /// Null when there is nothing older.
  final String? nextKey;
}

/// The address's recorded vote. [options] has more than one entry for a
/// weighted (split) vote.
@immutable
class GovVote {
  const GovVote(this.options);

  final List<({VoteOption option, double weight})> options;

  /// The single option, or null for a split vote.
  VoteOption? get single => options.length == 1 ? options.first.option : null;
}

String? _nonEmpty(Object? value) {
  final text = asString(value).trim();
  return text.isEmpty ? null : text;
}

DateTime? _time(Object? raw) {
  final value = DateTime.tryParse(asString(raw));
  // Unset protobuf timestamps arrive as 0001-01-01.
  if (value == null || value.year < 2000) return null;
  return value;
}

/// One gov v1 proposal. Older proposals put title and description in a
/// legacy content message instead of the top-level fields.
GovProposal proposalFromV1(String chainId, Map<String, dynamic> p) {
  final messages = asList(p['messages']).map(asMap).toList();
  final content = messages.isEmpty
      ? const <String, dynamic>{}
      : asMap(messages.first['content']);
  final id = asString(p['id']);
  return GovProposal(
    chainId: chainId,
    id: id,
    title: _nonEmpty(p['title']) ??
        _nonEmpty(content['title']) ??
        'Proposal $id',
    summary: _nonEmpty(p['summary']) ?? _nonEmpty(content['description']) ?? '',
    status: govStatusFrom(asString(p['status'])),
    submitTime: _time(p['submit_time']),
    votingStartTime: _time(p['voting_start_time']),
    votingEndTime: _time(p['voting_end_time']),
    depositEndTime: _time(p['deposit_end_time']),
    tally: GovTally.fromJson(p['final_tally_result']),
    messageTypes: [for (final m in messages) ?_nonEmpty(m['@type'])],
  );
}

GovProposal proposalFromV1beta1(String chainId, Map<String, dynamic> p) {
  final content = asMap(p['content']);
  final id = asString(p['proposal_id']);
  return GovProposal(
    chainId: chainId,
    id: id,
    title: _nonEmpty(content['title']) ?? 'Proposal $id',
    summary: _nonEmpty(content['description']) ?? '',
    status: govStatusFrom(asString(p['status'])),
    submitTime: _time(p['submit_time']),
    votingStartTime: _time(p['voting_start_time']),
    votingEndTime: _time(p['voting_end_time']),
    depositEndTime: _time(p['deposit_end_time']),
    tally: GovTally.fromJson(p['final_tally_result']),
    messageTypes: [?_nonEmpty(content['@type'])],
  );
}

/// A vote record from either gov version.
GovVote? voteFrom(Object? raw) {
  final vote = asMap(raw);
  if (vote.isEmpty) return null;
  final options = <({VoteOption option, double weight})>[];
  for (final row in asList(vote['options'])) {
    final map = asMap(row);
    final option = VoteOption.fromWire(map['option']);
    if (option == null) continue;
    options.add((option: option, weight: asDecimal(map['weight']) ?? 1));
  }
  if (options.isEmpty) {
    final option = VoteOption.fromWire(vote['option']);
    if (option != null) options.add((option: option, weight: 1));
  }
  return options.isEmpty ? null : GovVote(options);
}

class GovernanceClient {
  GovernanceClient(this._reader);

  final ChainReader _reader;

  /// Chains that answered only v1beta1.
  final Set<String> _legacy = {};

  /// Proposals newest first, [limit] at a time. Pass the previous page's
  /// [ProposalPage.nextKey] for the next one.
  Future<ProposalPage> proposals(
    ChainEntry chain, {
    String? key,
    int limit = 20,
  }) async {
    final query = {
      'pagination.limit': limit,
      'pagination.reverse': 'true',
      'pagination.key': key,
    };
    if (!_legacy.contains(chain.chainId)) {
      try {
        final body =
            await _reader.get(chain, '/cosmos/gov/v1/proposals', query: query);
        final rows = body['proposals'];
        if (rows is List) {
          return ProposalPage(
            rows: [
              for (final row in rows) proposalFromV1(chain.chainId, asMap(row)),
            ],
            nextKey: _nonEmpty(asMap(body['pagination'])['next_key']),
          );
        }
      } on ChainReadError catch (e) {
        if (e.kind != ChainReadErrorKind.notFound &&
            e.kind != ChainReadErrorKind.malformed) {
          rethrow;
        }
      }
      _legacy.add(chain.chainId);
    }
    final body =
        await _reader.get(chain, '/cosmos/gov/v1beta1/proposals', query: query);
    final rows = body['proposals'];
    if (rows is! List) {
      throw ChainReadError(
        ChainReadErrorKind.malformed,
        '${chain.chainId}: proposals is not a list',
      );
    }
    return ProposalPage(
      rows: [
        for (final row in rows) proposalFromV1beta1(chain.chainId, asMap(row)),
      ],
      nextKey: _nonEmpty(asMap(body['pagination'])['next_key']),
    );
  }

  /// The running tally of a proposal still in its voting period.
  Future<GovTally?> liveTally(ChainEntry chain, String proposalId) async {
    final version = _legacy.contains(chain.chainId) ? 'v1beta1' : 'v1';
    final body = await _reader.get(
      chain,
      '/cosmos/gov/$version/proposals/$proposalId/tally',
    );
    return GovTally.fromJson(body['tally']);
  }

  /// The vote [voter] cast, or null when there is none. Chains delete votes
  /// once a proposal is tallied, so this only answers during voting.
  Future<GovVote?> vote(
    ChainEntry chain,
    String proposalId,
    String voter,
  ) async {
    final version = _legacy.contains(chain.chainId) ? 'v1beta1' : 'v1';
    try {
      final body = await _reader.get(
        chain,
        '/cosmos/gov/$version/proposals/$proposalId/votes/$voter',
      );
      return voteFrom(body['vote']);
    } on ChainReadError catch (e) {
      // "vote not found" comes back as a 4xx (or a 500 on some SDK
      // versions): no vote, not an outage.
      if (e.kind == ChainReadErrorKind.notFound) return null;
      if (e.kind == ChainReadErrorKind.unreachable && e.status == 500) {
        return null;
      }
      rethrow;
    }
  }
}
