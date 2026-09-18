/// Read-only Cosmos REST (LCD) queries.
///
/// Nothing here signs or broadcasts. Every call is gated on the `liveReads`
/// preference so a wallet that has never been told it may talk to public
/// endpoints stays completely offline.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';

const _defaultTimeout = Duration(seconds: 9);

/// Why a read produced no number.
///
/// This is a reason, never an amount. A failed read used to fall through to
/// '0', and the send screen reported that as the user's balance: one
/// rate-limited refresh told a funded wallet it held nothing and blocked every
/// send until the endpoint recovered. "Not read" and "read as zero" are
/// different facts and have to stay different values.
enum ChainReadFailureKind {
  /// The wallet is not allowed to talk to endpoints at all.
  readsDisabled,

  /// No REST endpoint is configured for this chain.
  noEndpoint,

  /// DNS, TLS or socket failure: the endpoint was never reached.
  unreachable,

  /// The connection was made but no answer arrived inside the budget.
  timedOut,

  /// A non-200 answer: rate limit, gateway error, chain behind a proxy.
  badStatus,

  /// A 200 whose body is not the LCD schema this call expects.
  malformedBody,

  /// One page of a longer list came back and the denom was not on it, so it
  /// cannot be ruled out from what was read.
  incompletePage,
}

@immutable
class ChainReadFailure {
  const ChainReadFailure(this.kind, {this.statusCode, this.detail});

  final ChainReadFailureKind kind;

  /// Set for [ChainReadFailureKind.badStatus].
  final int? statusCode;

  /// Raw context (socket error, parser message). Diagnostic, not user copy.
  final String? detail;

  /// One sentence naming the cause. Short enough to sit next to a disabled
  /// control, and it never implies anything about what the account holds.
  String get message => switch (kind) {
        ChainReadFailureKind.readsDisabled =>
          'Live reads are off, so the wallet has not asked any endpoint for '
              'this balance.',
        ChainReadFailureKind.noEndpoint =>
          'This network has no REST endpoint configured, so there is nothing '
              'to ask.',
        ChainReadFailureKind.unreachable =>
          'The network endpoint could not be reached.',
        ChainReadFailureKind.timedOut =>
          'The network endpoint did not answer in time.',
        ChainReadFailureKind.badStatus =>
          'The network endpoint answered HTTP ${statusCode ?? 0}.',
        ChainReadFailureKind.malformedBody =>
          'The network endpoint answered with something that is not a '
              'balance.',
        ChainReadFailureKind.incompletePage =>
          'The network endpoint returned only part of this account, so this '
              'denomination cannot be ruled out.',
      };
}

/// A balance that was actually read.
///
/// There is deliberately no `empty` instance and no failure case on this type:
/// a [ChainBalance] exists only when the endpoint answered, so every number on
/// it is a fact about the account. A read that failed is a
/// [BalanceUnavailable], never a ChainBalance full of zeros.
@immutable
class ChainBalance {
  const ChainBalance({
    required this.chainId,
    required this.available,
    required this.staked,
    required this.rewards,
    this.otherDenoms = const [],
  });

  final String chainId;

  /// All amounts are base units (uatom, usaf, …).
  final String available;
  final String staked;
  final String rewards;

  /// Denominations the account holds that are not the chain entry's
  /// coinMinimalDenom. Present so a screen can say "no ATOM here, but three
  /// other denominations" when [available] is a genuine zero that most likely
  /// means the chain entry names the wrong denom, instead of implying the
  /// account is empty.
  final List<String> otherDenoms;
}

/// Outcome of one balance read: a value, or the reason there is none.
@immutable
sealed class BalanceRead {
  const BalanceRead();
}

final class BalanceLoaded extends BalanceRead {
  const BalanceLoaded(this.balance);

  final ChainBalance balance;
}

final class BalanceUnavailable extends BalanceRead {
  const BalanceUnavailable(this.failure);

  final ChainReadFailure failure;
}

/// One HTTP read: a decoded body, or the reason there is none.
@immutable
class _JsonRead {
  const _JsonRead.ok(Map<String, dynamic> this.json) : failure = null;
  const _JsonRead.failed(ChainReadFailure this.failure) : json = null;

  final Map<String, dynamic>? json;
  final ChainReadFailure? failure;
}

@immutable
class ValidatorInfo {
  const ValidatorInfo({
    required this.operatorAddress,
    required this.moniker,
    required this.commission,
    required this.votingPower,
    required this.tokens,
    required this.jailed,
  });

  final String operatorAddress;
  final String moniker;

  /// 0-1 fraction.
  final double commission;

  /// Share of bonded stake, 0-1.
  final double votingPower;
  final String tokens;
  final bool jailed;
}

@immutable
class DelegationInfo {
  const DelegationInfo({
    required this.validatorAddress,
    required this.moniker,
    required this.amount,
    required this.rewards,
  });

  final String validatorAddress;
  final String moniker;
  final String amount;
  final String rewards;
}

@immutable
class UnbondingInfo {
  const UnbondingInfo({
    required this.validatorAddress,
    required this.amount,
    required this.completionTime,
  });

  final String validatorAddress;
  final String amount;
  final DateTime? completionTime;
}

enum ProposalStatus { voting, deposit, passed, rejected, failed, unknown }

@immutable
class ProposalInfo {
  const ProposalInfo({
    required this.chainId,
    required this.id,
    required this.title,
    required this.summary,
    required this.status,
    this.votingEndTime,
    this.tally,
  });

  final String chainId;
  final String id;
  final String title;
  final String summary;
  final ProposalStatus status;
  final DateTime? votingEndTime;

  /// Normalised 0-1 shares, absent when the chain reports no votes yet.
  final ({double yes, double no, double veto, double abstain})? tally;
}

enum ActivityKind { sent, received, ibc, swap, staking, claim, governance, other }

@immutable
class ActivityItem {
  const ActivityItem({
    required this.chainId,
    required this.hash,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.timestamp,
    required this.success,
    this.amount,
  });

  final String chainId;
  final String hash;
  final ActivityKind kind;
  final String title;
  final String subtitle;
  final DateTime timestamp;
  final bool success;

  /// Signed base-unit delta when it could be worked out.
  final String? amount;
}

class ChainClient {
  ChainClient({required this.enabled, this.timeout = _defaultTimeout})
      : _http = HttpClient() {
    _http.connectionTimeout = timeout;
  }

  /// Mirrors the `liveReads` preference.
  final bool enabled;

  /// Budget for each leg of a request. Tests shorten it so a hung endpoint
  /// does not cost nine seconds; nothing else should touch it.
  final Duration timeout;

  final HttpClient _http;

  static String? _restOf(ChainEntry chain) {
    final rest = chain.rest;
    if (rest == null || rest.isEmpty) return null;
    return rest.endsWith('/') ? rest.substring(0, rest.length - 1) : rest;
  }

  Future<_JsonRead> _readJson(String url) async {
    if (!enabled) {
      return const _JsonRead.failed(
        ChainReadFailure(ChainReadFailureKind.readsDisabled),
      );
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return _JsonRead.failed(
        ChainReadFailure(ChainReadFailureKind.noEndpoint, detail: url),
      );
    }
    try {
      final request = await _http.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        try {
          // Release the socket. The status is the answer either way.
          await response.drain<void>().timeout(timeout);
        } on Exception {
          // A body we could not read does not change the status we got.
        }
        return _JsonRead.failed(
          ChainReadFailure(
            ChainReadFailureKind.badStatus,
            statusCode: response.statusCode,
          ),
        );
      }
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return _JsonRead.failed(
          ChainReadFailure(
            ChainReadFailureKind.malformedBody,
            detail: 'top level ${decoded.runtimeType}',
          ),
        );
      }
      return _JsonRead.ok(decoded);
    } on TimeoutException {
      return _JsonRead.failed(
        ChainReadFailure(
          ChainReadFailureKind.timedOut,
          detail: '${timeout.inSeconds}s budget',
        ),
      );
    } on FormatException catch (e) {
      return _JsonRead.failed(
        ChainReadFailure(
          ChainReadFailureKind.malformedBody,
          detail: e.message,
        ),
      );
    } on IOException catch (e) {
      return _JsonRead.failed(
        ChainReadFailure(
          ChainReadFailureKind.unreachable,
          detail: e.toString(),
        ),
      );
    }
  }

  /// Reason-less form for the read paths that already degrade to an empty
  /// list. A missing validator list renders as "nothing to show", which is not
  /// a claim about the chain; a missing balance rendered as 0 is a claim about
  /// the user's money, which is why [balance] uses [_readJson] directly.
  Future<Map<String, dynamic>?> _getJson(String url) async =>
      (await _readJson(url)).json;

  /// LCD amounts are integer strings, except distribution totals which carry a
  /// decimal tail ('1234.500000000000000000'). The tail is dropped rather than
  /// rounded up: the chain never pays out more than the integer part.
  /// Returns null for anything that is not a number, so the caller reports a
  /// malformed body instead of quietly counting it as zero.
  static BigInt? _amountOf(Object? raw) {
    if (raw == null) return BigInt.zero;
    return BigInt.tryParse(raw.toString().split('.').first);
  }

  static String _sumDenom(Object? rows, String denom) {
    if (rows is! List) return '0';
    var total = BigInt.zero;
    for (final row in rows) {
      if (row is! Map) continue;
      if (row['denom'] != denom) continue;
      final raw = (row['amount'] as String? ?? '0').split('.').first;
      total += BigInt.tryParse(raw) ?? BigInt.zero;
    }
    return total.toString();
  }

  static BalanceUnavailable _malformed(String detail) => BalanceUnavailable(
        ChainReadFailure(
          ChainReadFailureKind.malformedBody,
          detail: detail,
        ),
      );

  /// Spendable, bonded and claimable in one round trip set.
  ///
  /// All three legs have to answer. A [ChainBalance] carries three numbers the
  /// screens print as fact, so tolerating a failed leg would mean inventing a
  /// zero for it - the false claim this whole type exists to prevent. When one
  /// leg fails the caller gets [BalanceUnavailable] with the reason, and the
  /// screens say the balance is unknown rather than that it is zero.
  Future<BalanceRead> balance(ChainEntry chain, String address) async {
    if (!enabled) {
      return const BalanceUnavailable(
        ChainReadFailure(ChainReadFailureKind.readsDisabled),
      );
    }
    final rest = _restOf(chain);
    if (rest == null) {
      return const BalanceUnavailable(
        ChainReadFailure(ChainReadFailureKind.noEndpoint),
      );
    }
    final denom = chain.coinMinimalDenom;

    final reads = await Future.wait([
      // A high page limit because the denom we want can sit behind the default
      // 100-row page on an account holding many IBC vouchers, and "not on the
      // page I read" must never be reported as zero.
      _readJson(
        '$rest/cosmos/bank/v1beta1/balances/$address?pagination.limit=1000',
      ),
      _readJson('$rest/cosmos/staking/v1beta1/delegations/$address'),
      _readJson('$rest/cosmos/distribution/v1beta1/delegators/$address/rewards'),
    ]);
    for (final read in reads) {
      final failure = read.failure;
      if (failure != null) return BalanceUnavailable(failure);
    }

    final rows = reads[0].json?['balances'];
    if (rows is! List) return _malformed('balances is not a list');

    var available = BigInt.zero;
    var matchedDenom = false;
    final otherDenoms = <String>[];
    for (final row in rows) {
      if (row is! Map) return _malformed('balances row is not an object');
      final rowDenom = row['denom'];
      if (rowDenom != denom) {
        if (rowDenom is String && rowDenom.isNotEmpty) {
          otherDenoms.add(rowDenom);
        }
        continue;
      }
      final amount = _amountOf(row['amount']);
      if (amount == null) return _malformed('balance amount is not a number');
      matchedDenom = true;
      available += amount;
    }
    if (!matchedDenom) {
      // Nothing for this denom on the page we read. That is a real zero only
      // if there was no further page.
      final nextKey = (reads[0].json?['pagination'] as Map?)?['next_key'];
      if (nextKey is String && nextKey.isNotEmpty) {
        return const BalanceUnavailable(
          ChainReadFailure(ChainReadFailureKind.incompletePage),
        );
      }
    }

    var staked = BigInt.zero;
    final delegations = reads[1].json?['delegation_responses'];
    // An LCD may omit an empty collection entirely; a present non-list means
    // the body is not the schema we asked for.
    if (delegations is List) {
      for (final row in delegations) {
        if (row is! Map) return _malformed('delegation row is not an object');
        final balance = row['balance'];
        if (balance is! Map || balance['denom'] != denom) continue;
        final amount = _amountOf(balance['amount']);
        if (amount == null) {
          return _malformed('delegation amount is not a number');
        }
        staked += amount;
      }
    } else if (delegations != null) {
      return _malformed('delegation_responses is not a list');
    }

    var rewards = BigInt.zero;
    final totals = reads[2].json?['total'];
    if (totals is List) {
      for (final row in totals) {
        if (row is! Map) return _malformed('rewards row is not an object');
        if (row['denom'] != denom) continue;
        final amount = _amountOf(row['amount']);
        if (amount == null) return _malformed('reward amount is not a number');
        rewards += amount;
      }
    } else if (totals != null) {
      return _malformed('rewards total is not a list');
    }

    return BalanceLoaded(
      ChainBalance(
        chainId: chain.chainId,
        available: available.toString(),
        staked: staked.toString(),
        rewards: rewards.toString(),
        otherDenoms: List.unmodifiable(otherDenoms),
      ),
    );
  }

  Future<List<ValidatorInfo>> validators(ChainEntry chain) async {
    final rest = _restOf(chain);
    if (rest == null) return const [];
    final body = await _getJson(
      '$rest/cosmos/staking/v1beta1/validators'
      '?status=BOND_STATUS_BONDED&pagination.limit=150',
    );
    final rows = body?['validators'];
    if (rows is! List) return const [];

    var total = BigInt.zero;
    for (final row in rows) {
      total += BigInt.tryParse((row as Map)['tokens'] as String? ?? '0') ??
          BigInt.zero;
    }

    final out = <ValidatorInfo>[];
    for (final row in rows) {
      final map = row as Map;
      final tokens = BigInt.tryParse(map['tokens'] as String? ?? '0') ??
          BigInt.zero;
      final rate = (map['commission'] as Map?)?['commission_rates'] as Map?;
      out.add(
        ValidatorInfo(
          operatorAddress: map['operator_address'] as String? ?? '',
          moniker: (map['description'] as Map?)?['moniker'] as String? ??
              map['operator_address'] as String? ??
              'Validator',
          commission: double.tryParse(rate?['rate'] as String? ?? '0') ?? 0,
          votingPower: total > BigInt.zero
              ? tokens / total
              : 0,
          tokens: tokens.toString(),
          jailed: map['jailed'] == true,
        ),
      );
    }
    out.sort((a, b) => b.votingPower.compareTo(a.votingPower));
    return out;
  }

  Future<List<DelegationInfo>> delegations(
    ChainEntry chain,
    String address,
  ) async {
    final rest = _restOf(chain);
    if (rest == null) return const [];
    final denom = chain.coinMinimalDenom;

    final results = await Future.wait([
      _getJson('$rest/cosmos/staking/v1beta1/delegations/$address'),
      _getJson('$rest/cosmos/distribution/v1beta1/delegators/$address/rewards'),
    ]);

    final rewardByValidator = <String, String>{};
    final rewardRows = results[1]?['rewards'];
    if (rewardRows is List) {
      for (final row in rewardRows) {
        final map = row as Map;
        final validator = map['validator_address'] as String?;
        if (validator == null) continue;
        rewardByValidator[validator] = _sumDenom(map['reward'], denom);
      }
    }

    final rows = results[0]?['delegation_responses'];
    if (rows is! List) return const [];

    final out = <DelegationInfo>[];
    for (final row in rows) {
      final map = row as Map;
      final validator =
          (map['delegation'] as Map?)?['validator_address'] as String? ?? '';
      final balance = map['balance'] as Map?;
      out.add(
        DelegationInfo(
          validatorAddress: validator,
          moniker: validator,
          amount: balance?['denom'] == denom
              ? (balance?['amount'] as String? ?? '0')
              : '0',
          rewards: rewardByValidator[validator] ?? '0',
        ),
      );
    }
    return out;
  }

  Future<List<UnbondingInfo>> unbonding(
    ChainEntry chain,
    String address,
  ) async {
    final rest = _restOf(chain);
    if (rest == null) return const [];
    final body = await _getJson(
      '$rest/cosmos/staking/v1beta1/delegators/$address/unbonding_delegations',
    );
    final rows = body?['unbonding_responses'];
    if (rows is! List) return const [];

    final out = <UnbondingInfo>[];
    for (final row in rows) {
      final map = row as Map;
      final entries = map['entries'];
      if (entries is! List) continue;
      for (final entry in entries) {
        final e = entry as Map;
        out.add(
          UnbondingInfo(
            validatorAddress: map['validator_address'] as String? ?? '',
            amount: e['balance'] as String? ?? '0',
            completionTime:
                DateTime.tryParse(e['completion_time'] as String? ?? ''),
          ),
        );
      }
    }
    out.sort((a, b) {
      final at = a.completionTime;
      final bt = b.completionTime;
      if (at == null || bt == null) return 0;
      return at.compareTo(bt);
    });
    return out;
  }

  static ProposalStatus _status(String raw) {
    switch (raw) {
      case 'PROPOSAL_STATUS_VOTING_PERIOD':
        return ProposalStatus.voting;
      case 'PROPOSAL_STATUS_DEPOSIT_PERIOD':
        return ProposalStatus.deposit;
      case 'PROPOSAL_STATUS_PASSED':
        return ProposalStatus.passed;
      case 'PROPOSAL_STATUS_REJECTED':
        return ProposalStatus.rejected;
      case 'PROPOSAL_STATUS_FAILED':
        return ProposalStatus.failed;
      default:
        return ProposalStatus.unknown;
    }
  }

  static ({double yes, double no, double veto, double abstain})? _tally(
    Object? raw,
  ) {
    if (raw is! Map) return null;
    double read(String a, String b) =>
        double.tryParse((raw[a] ?? raw[b] ?? '0').toString()) ?? 0;
    final yes = read('yes_count', 'yes');
    final no = read('no_count', 'no');
    final veto = read('no_with_veto_count', 'no_with_veto');
    final abstain = read('abstain_count', 'abstain');
    final total = yes + no + veto + abstain;
    if (total <= 0) return null;
    return (
      yes: yes / total,
      no: no / total,
      veto: veto / total,
      abstain: abstain / total,
    );
  }

  /// Gov v1 where available, falling back to v1beta1 for chains that never
  /// migrated.
  Future<List<ProposalInfo>> proposals(ChainEntry chain) async {
    final rest = _restOf(chain);
    if (rest == null) return const [];

    final v1 = await _getJson(
      '$rest/cosmos/gov/v1/proposals?pagination.limit=20&pagination.reverse=true',
    );
    final v1Rows = v1?['proposals'];
    if (v1Rows is List) {
      return [
        for (final row in v1Rows)
          ProposalInfo(
            chainId: chain.chainId,
            id: (row as Map)['id'] as String? ?? '',
            title: (row['title'] as String?)?.trim().isNotEmpty == true
                ? row['title'] as String
                : 'Proposal ${row['id'] ?? ''}',
            summary: row['summary'] as String? ?? '',
            status: _status(row['status'] as String? ?? ''),
            votingEndTime:
                DateTime.tryParse(row['voting_end_time'] as String? ?? ''),
            tally: _tally(row['final_tally_result']),
          ),
      ];
    }

    final legacy = await _getJson(
      '$rest/cosmos/gov/v1beta1/proposals'
      '?pagination.limit=20&pagination.reverse=true',
    );
    final rows = legacy?['proposals'];
    if (rows is! List) return const [];
    return [
      for (final row in rows)
        ProposalInfo(
          chainId: chain.chainId,
          id: (row as Map)['proposal_id'] as String? ?? '',
          title: (row['content'] as Map?)?['title'] as String? ??
              'Proposal ${row['proposal_id'] ?? ''}',
          summary: (row['content'] as Map?)?['description'] as String? ?? '',
          status: _status(row['status'] as String? ?? ''),
          votingEndTime:
              DateTime.tryParse(row['voting_end_time'] as String? ?? ''),
          tally: _tally(row['final_tally_result']),
        ),
    ];
  }

  static ({ActivityKind kind, String title, String subtitle, String? amount})
      _describe(Map<dynamic, dynamic> message, String address, String denom) {
    final type = (message['@type'] ?? '').toString();
    final short = type.split('.').last;

    if (type.endsWith('MsgSend')) {
      final from = message['from_address']?.toString() ?? '';
      final to = message['to_address']?.toString() ?? '';
      final amount = _sumDenom(message['amount'], denom);
      final outgoing = from == address;
      return (
        kind: outgoing ? ActivityKind.sent : ActivityKind.received,
        title: outgoing ? 'Sent' : 'Received',
        subtitle: outgoing ? 'to $to' : 'from $from',
        amount: outgoing ? '-$amount' : amount,
      );
    }
    if (type.endsWith('MsgTransfer')) {
      final token = message['token'];
      return (
        kind: ActivityKind.ibc,
        title: 'IBC transfer',
        subtitle: message['source_channel']?.toString() ?? 'ibc',
        amount: token is Map && token['denom'] == denom
            ? '-${token['amount']}'
            : null,
      );
    }
    if (type.contains('MsgSwap') ||
        type.endsWith('MsgSwapExactAmountIn') ||
        type.endsWith('MsgSwapExactAmountOut') ||
        type.endsWith('MsgJoinPool') ||
        type.endsWith('MsgExitPool')) {
      return (
        kind: ActivityKind.swap,
        title: short.replaceFirst(RegExp(r'^Msg'), ''),
        subtitle: type,
        amount: null,
      );
    }
    if (type.endsWith('MsgDelegate') || type.endsWith('MsgBeginRedelegate')) {
      final amount = message['amount'];
      return (
        kind: ActivityKind.staking,
        title: type.endsWith('MsgDelegate') ? 'Delegate' : 'Redelegate',
        subtitle: (message['validator_address'] ??
                message['validator_dst_address'] ??
                '')
            .toString(),
        amount: amount is Map ? amount['amount']?.toString() : null,
      );
    }
    if (type.endsWith('MsgUndelegate')) {
      final amount = message['amount'];
      return (
        kind: ActivityKind.staking,
        title: 'Undelegate',
        subtitle: message['validator_address']?.toString() ?? '',
        amount: amount is Map ? amount['amount']?.toString() : null,
      );
    }
    if (type.endsWith('MsgWithdrawDelegatorReward')) {
      return (
        kind: ActivityKind.claim,
        title: 'Claim rewards',
        subtitle: message['validator_address']?.toString() ?? '',
        amount: null,
      );
    }
    if (type.endsWith('MsgVote')) {
      return (
        kind: ActivityKind.governance,
        title: 'Vote on #${message['proposal_id'] ?? ''}',
        subtitle: (message['option'] ?? '')
            .toString()
            .replaceAll('VOTE_OPTION_', '')
            .toLowerCase(),
        amount: null,
      );
    }
    return (
      kind: ActivityKind.other,
      title: short,
      subtitle: type,
      amount: null,
    );
  }

  /// Recent transactions touching an address, newest first. Limited to what the
  /// node still has indexed.
  Future<List<ActivityItem>> activity(
    ChainEntry chain,
    String address, {
    int limit = 15,
  }) async {
    final rest = _restOf(chain);
    if (rest == null) return const [];
    final denom = chain.coinMinimalDenom;

    // Newer SDKs take `query`, older ones `events`; ask both, both directions.
    final queries = [
      "message.sender='$address'",
      "transfer.recipient='$address'",
    ];
    final responses = await Future.wait([
      for (final q in queries) ...[
        _getJson(
          '$rest/cosmos/tx/v1beta1/txs?query=${Uri.encodeComponent(q)}'
          '&order_by=ORDER_BY_DESC&limit=$limit',
        ),
        _getJson(
          '$rest/cosmos/tx/v1beta1/txs?events=${Uri.encodeComponent(q)}'
          '&order_by=ORDER_BY_DESC&limit=$limit',
        ),
      ],
    ]);

    final seen = <String>{};
    final items = <ActivityItem>[];
    for (final body in responses) {
      final rows = body?['tx_responses'];
      if (rows is! List) continue;
      for (final row in rows) {
        final map = row as Map;
        final hash = map['txhash'] as String? ?? '';
        if (hash.isEmpty || !seen.add(hash)) continue;
        final messages =
            ((map['tx'] as Map?)?['body'] as Map?)?['messages'];
        if (messages is! List || messages.isEmpty) continue;
        final described =
            _describe(messages.first as Map, address, denom);
        items.add(
          ActivityItem(
            chainId: chain.chainId,
            hash: hash,
            kind: described.kind,
            title: described.title,
            subtitle: described.subtitle,
            amount: described.amount,
            timestamp:
                DateTime.tryParse(map['timestamp'] as String? ?? '') ??
                    DateTime.fromMillisecondsSinceEpoch(0),
            success: (map['code'] as num?)?.toInt() == 0 || map['code'] == null,
          ),
        );
      }
    }

    items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return items.take(limit).toList();
  }

  /// IBC channel discovery, validation and state parsing used to live here.
  /// It now lives in `lib/services/interchain/channels.dart`, the Dart mirror
  /// of `@zunialab/interchain`'s `channels.ts`, because three clients had three
  /// copies of it and they disagreed: this one tested a channel state for OPEN
  /// before TRYOPEN, so `STATE_TRYOPEN` — a channel still mid-handshake —
  /// reported as ready to receive funds.
  void close() => _http.close(force: true);
}

