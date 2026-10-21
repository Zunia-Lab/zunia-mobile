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
import 'package:zunia_mobile/activity/activity_model.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';


export 'package:zunia_mobile/activity/activity_model.dart'
    show ActivityItem, ActivityKind, TxDetailInfo;

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

/// One non-zero bank balance, as the chain spelled it.
///
/// The name, ticker, logo and decimals come from the token identity
/// (`lib/tokens/token_identity.dart`) at display time, so a voucher the
/// wallet proves later is renamed without reading the chain again. The chain's
/// own bank metadata is kept only for what an identity cannot know: the
/// decimals and a name of a token nothing lists.
@immutable
class HeldToken {
  const HeldToken({
    required this.denom,
    required this.amount,
    this.metadataDecimals,
    this.metadataName,
  });

  /// The exact bank denom, never case-folded.
  final String denom;

  /// Base units, a non-negative integer string.
  final String amount;
  final int? metadataDecimals;
  final String? metadataName;

  HeldToken withMetadata(int? decimals, String? name) => HeldToken(
        denom: denom,
        amount: amount,
        metadataDecimals: decimals,
        metadataName: name,
      );
}

/// A read that produced no answer, with the reason.
class ChainReadException implements Exception {
  const ChainReadException(this.failure);
  final ChainReadFailure failure;
  @override
  String toString() => failure.message;
}

/// A balance that was actually read.
///
/// There is deliberately no `empty` instance and no failure case on this type:
/// a [ChainBalance] exists only when the bank endpoint answered, so its
/// available amount and [tokens] are facts about the account. A read that
/// failed is a [BalanceUnavailable], never a ChainBalance full of zeros.
///
/// Staking and distribution are separate endpoints, and some chains do not
/// serve them (Noble has no distribution module). A leg whose route the node
/// does not serve (404, 405, 501) is a real zero: there is nothing to stake
/// there. A leg that failed for any other reason leaves [stakingKnown] or
/// [rewardsKnown] false, and screens show "—" for it instead of the '0' the
/// field carries for older callers.
@immutable
class ChainBalance {
  const ChainBalance({
    required this.chainId,
    required this.available,
    required this.staked,
    required this.rewards,
    this.otherDenoms = const [],
    this.tokens = const [],
    this.stakingKnown = true,
    this.rewardsKnown = true,
  });

  final String chainId;

  /// All amounts are base units (uatom, usaf, …) of the chain's staking coin.
  final String available;
  final String staked;
  final String rewards;

  /// Denominations the account holds that are not the chain entry's
  /// coinMinimalDenom. Present so a screen can say "no ATOM here, but three
  /// other denominations" when [available] is a genuine zero that most likely
  /// means the chain entry names the wrong denom, instead of implying the
  /// account is empty.
  final List<String> otherDenoms;

  /// Every non-zero bank balance: native, IBC, factory and anything else.
  final List<HeldToken> tokens;

  /// False when the delegations endpoint failed: [staked] is not a fact.
  final bool stakingKnown;

  /// False when the rewards endpoint failed: [rewards] is not a fact.
  final bool rewardsKnown;

  ChainBalance withTokens(List<HeldToken> next) => ChainBalance(
        chainId: chainId,
        available: available,
        staked: staked,
        rewards: rewards,
        otherDenoms: otherDenoms,
        tokens: next,
        stakingKnown: stakingKnown,
        rewardsKnown: rewardsKnown,
      );
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

  /// A bank page this large keeps a factory-heavy account to a few requests.
  static const int bankPageLimit = 200;

  /// Past this many pages the account is not read whole, and a denom absent
  /// from what was read cannot be ruled out.
  static const int bankMaxPages = 10;

  /// HTTP answers meaning "this node does not serve the route": a module the
  /// chain does not run (Noble has no distribution), or a proxy that hides it.
  static const Set<int> _routeAbsent = {404, 405, 501};

  static bool _absentRoute(ChainReadFailure? failure) =>
      failure != null &&
      failure.kind == ChainReadFailureKind.badStatus &&
      _routeAbsent.contains(failure.statusCode);

  /// Every bank coin the address holds, following pagination.
  ///
  /// Returns the rows and whether the walk ended on the last page. A failed
  /// page fails the read: a partial list must not be reported as the account.
  Future<({List<Object?> rows, bool complete, ChainReadFailure? failure})> _bankRows(
    String rest,
    String address,
  ) async {
    final rows = <Object?>[];
    String? key;
    for (var page = 0; page < bankMaxPages; page++) {
      final params = <String, String>{'pagination.limit': '$bankPageLimit'};
      if (key != null) params['pagination.key'] = key;
      final query = params.entries
          .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      final read = await _readJson('$rest/cosmos/bank/v1beta1/balances/$address?$query');
      final failure = read.failure;
      if (failure != null) return (rows: rows, complete: false, failure: failure);
      final balances = read.json?['balances'];
      if (balances is! List) {
        return (
          rows: rows,
          complete: false,
          failure: const ChainReadFailure(
            ChainReadFailureKind.malformedBody,
            detail: 'balances is not a list',
          ),
        );
      }
      rows.addAll(balances);
      final pagination = read.json?['pagination'];
      final next = pagination is Map ? (pagination['next_key'] ?? pagination['nextKey']) : null;
      if (next is! String || next.isEmpty) {
        return (rows: rows, complete: true, failure: null);
      }
      key = next;
    }
    return (rows: rows, complete: false, failure: null);
  }

  /// Spendable (every denom), bonded and claimable for one address.
  ///
  /// The bank leg has to answer: it is the account. Staking and rewards are
  /// read beside it; a leg the node does not serve counts as zero, and a leg
  /// that failed otherwise is marked unknown on the result rather than failing
  /// every token the bank read did return (see [ChainBalance.stakingKnown]).
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

    final bankFuture = _bankRows(rest, address);
    final legs = await Future.wait([
      _readJson('$rest/cosmos/staking/v1beta1/delegations/$address'),
      _readJson('$rest/cosmos/distribution/v1beta1/delegators/$address/rewards'),
    ]);
    final bank = await bankFuture;
    final bankFailure = bank.failure;
    if (bankFailure != null) return BalanceUnavailable(bankFailure);

    var available = BigInt.zero;
    var matchedDenom = false;
    final otherDenoms = <String>[];
    final held = <String, BigInt>{};
    for (final row in bank.rows) {
      if (row is! Map) return _malformed('balances row is not an object');
      final rowDenom = row['denom'];
      if (rowDenom is! String || rowDenom.isEmpty) continue;
      final amount = _amountOf(row['amount']);
      if (amount == null) return _malformed('balance amount is not a number');
      if (amount > BigInt.zero) held[rowDenom] = (held[rowDenom] ?? BigInt.zero) + amount;
      if (rowDenom != denom) {
        otherDenoms.add(rowDenom);
        continue;
      }
      matchedDenom = true;
      available += amount;
    }
    if (!matchedDenom && !bank.complete) {
      // Nothing for this denom in the pages read, and there were more.
      return const BalanceUnavailable(
        ChainReadFailure(ChainReadFailureKind.incompletePage),
      );
    }

    var staked = BigInt.zero;
    var stakingKnown = true;
    final stakingFailure = legs[0].failure;
    if (stakingFailure != null) {
      stakingKnown = _absentRoute(stakingFailure);
    } else {
      final delegations = legs[0].json?['delegation_responses'];
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
    }

    var rewards = BigInt.zero;
    var rewardsKnown = true;
    final rewardsFailure = legs[1].failure;
    if (rewardsFailure != null) {
      rewardsKnown = _absentRoute(rewardsFailure);
    } else {
      final totals = legs[1].json?['total'];
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
    }

    return BalanceLoaded(
      ChainBalance(
        chainId: chain.chainId,
        available: available.toString(),
        staked: staked.toString(),
        rewards: rewards.toString(),
        otherDenoms: List.unmodifiable(otherDenoms),
        tokens: List.unmodifiable([
          for (final MapEntry(:key, :value) in held.entries)
            HeldToken(denom: key, amount: value.toString()),
        ]),
        stakingKnown: stakingKnown,
        rewardsKnown: rewardsKnown,
      ),
    );
  }

  /// What a chain's bank metadata says on purpose about [denom]: decimals and
  /// a name, never a ticker. Null when the node has none or could not be
  /// asked. ibc-go's generated voucher records name nothing and say exponent
  /// 0, so they yield nothing either.
  Future<({int? decimals, String? name})?> bankMetadata(ChainEntry chain, String denom) async {
    final rest = _restOf(chain);
    if (rest == null || !enabled) return null;
    final urls = [
      if (denom.contains('/'))
        '$rest/cosmos/bank/v1beta1/denoms_metadata_by_query_string?denom=${Uri.encodeQueryComponent(denom)}',
      '$rest/cosmos/bank/v1beta1/denoms_metadata/${Uri.encodeComponent(denom)}',
    ];
    for (final url in urls) {
      final read = await _readJson(url);
      final failure = read.failure;
      if (failure != null) {
        if (failure.kind == ChainReadFailureKind.badStatus &&
            const {400, 404, 405, 501}.contains(failure.statusCode)) {
          continue;
        }
        return null;
      }
      return metadataFacts(read.json, denom);
    }
    return null;
  }

  /// The decimals and name a metadata record states, or null when the record
  /// is another denom's (a proxy that mixed up its answers).
  static ({int? decimals, String? name})? metadataFacts(Object? body, String denom) {
    final meta = body is Map ? body['metadata'] : null;
    if (meta is! Map) return (decimals: null, name: null);
    final base = '${meta['base'] ?? ''}'.trim();
    if (base.isNotEmpty && base != denom) return null;
    final display = '${meta['display'] ?? ''}'.trim().toLowerCase();
    final name = '${meta['name'] ?? ''}'.trim();
    final description = '${meta['description'] ?? ''}'.trim();
    final generated = RegExp('^IBC token from ', caseSensitive: false).hasMatch(description) ||
        RegExp(r'\bIBC token$', caseSensitive: false).hasMatch(name);
    int? exponentOf(Object? value) {
      final parsed = value is num ? value.toInt() : int.tryParse('${value ?? ''}');
      return parsed != null && parsed > 0 && parsed <= 30 ? parsed : null;
    }

    int? decimals;
    final units = meta['denom_units'];
    if (units is List && display.isNotEmpty) {
      for (final unit in units) {
        if (unit is! Map) continue;
        final aliases = unit['aliases'] is List ? unit['aliases'] as List : const [];
        final names = [unit['denom'], ...aliases].map((alias) => '${alias ?? ''}'.trim().toLowerCase());
        if (!names.contains(display)) continue;
        decimals = exponentOf(unit['exponent']);
        break;
      }
    }
    final clean = name.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return (
      decimals: decimals ?? exponentOf(meta['decimals']),
      name: generated || clean.isEmpty
          ? null
          : (clean.runes.length > 64 ? '${String.fromCharCodes(clean.runes.take(63))}…' : clean),
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

  /// Which spelling of the tx search each chain answered: SDK 0.50 `query`,
  /// older `events`. Remembered so a chain is asked the one it reads.
  static final Map<String, String> _searchStyles = {};

  Future<({List<Object?>? rows, ChainReadFailure? failure})> _searchTxs(
    String rest,
    String chainId,
    String condition,
    int limit,
  ) async {
    final known = _searchStyles[chainId];
    final styles = known == 'events' ? const ['events', 'query'] : const ['query', 'events'];
    ChainReadFailure? last;
    for (final style in styles) {
      final read = await _readJson(
        '$rest/cosmos/tx/v1beta1/txs?$style=${Uri.encodeQueryComponent(condition)}'
        '&order_by=ORDER_BY_DESC&limit=$limit',
      );
      final failure = read.failure;
      if (failure != null) {
        last = failure;
        continue;
      }
      final rows = read.json?['tx_responses'];
      _searchStyles[chainId] = style;
      return (rows: rows is List ? rows : const <Object?>[], failure: null);
    }
    return (rows: null, failure: last);
  }

  /// Recent transactions touching an address, newest first. Uses the LCD tx
  /// search, so it only covers what the node still has indexed.
  ///
  /// Throws [ChainReadException] when neither search could be read, so a
  /// screen can tell a chain it could not reach from a chain with no history.
  Future<List<ActivityItem>> activity(
    ChainEntry chain,
    String address, {
    int limit = 15,
    Map<String, String> feeRecipients = const {},
  }) async {
    final rest = _restOf(chain);
    if (rest == null || !enabled) return const [];
    final size = limit.clamp(1, 100);
    final reads = await Future.wait([
      _searchTxs(rest, chain.chainId, "message.sender='$address'", size),
      _searchTxs(rest, chain.chainId, "transfer.recipient='$address'", size),
    ]);
    if (reads.every((read) => read.rows == null)) {
      throw ChainReadException(
        reads.first.failure ?? const ChainReadFailure(ChainReadFailureKind.unreachable),
      );
    }
    final seen = <String>{};
    final items = <ActivityItem>[];
    for (final read in reads) {
      for (final row in read.rows ?? const <Object?>[]) {
        if (row is! Map) continue;
        final tx = row.map((key, value) => MapEntry('$key', value));
        final hash = '${tx['txhash'] ?? ''}';
        if (hash.isEmpty || !seen.add(hash)) continue;
        final item = activityFromTxResponse(
          tx,
          chain.chainId,
          address,
          feeRecipients: feeRecipients,
        );
        if (item != null) items.add(item);
      }
    }
    items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return items.take(size).toList();
  }

  /// One transaction, read for its detail. Null when the node does not have
  /// it (not indexed yet, or pruned); throws [ChainReadException] when the
  /// node could not be asked.
  Future<TxDetailInfo?> txDetail(
    ChainEntry chain,
    String hash,
    String address, {
    Map<String, String> feeRecipients = const {},
  }) async {
    final rest = _restOf(chain);
    if (rest == null) {
      throw const ChainReadException(ChainReadFailure(ChainReadFailureKind.noEndpoint));
    }
    final read = await _readJson('$rest/cosmos/tx/v1beta1/txs/${Uri.encodeComponent(hash)}');
    final failure = read.failure;
    if (failure != null) {
      if (failure.kind == ChainReadFailureKind.badStatus &&
          (failure.statusCode == 404 || failure.statusCode == 400)) {
        return null;
      }
      throw ChainReadException(failure);
    }
    return parseTxDetail(read.json, chain.chainId, address, feeRecipients: feeRecipients);
  }

  /// IBC channel discovery, validation and state parsing used to live here.
  /// It now lives in `lib/services/interchain/channels.dart`, the Dart mirror
  /// of `@zunialab/interchain`'s `channels.ts`, because three clients had three
  /// copies of it and they disagreed: this one tested a channel state for OPEN
  /// before TRYOPEN, so `STATE_TRYOPEN` — a channel still mid-handshake —
  /// reported as ready to receive funds.
  void close() => _http.close(force: true);
}

