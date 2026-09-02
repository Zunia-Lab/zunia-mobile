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

const _timeout = Duration(seconds: 9);

@immutable
class ChainBalance {
  const ChainBalance({
    required this.chainId,
    required this.available,
    required this.staked,
    required this.rewards,
  });

  final String chainId;

  /// All amounts are base units (uatom, usaf, …).
  final String available;
  final String staked;
  final String rewards;

  static const empty = ChainBalance(
    chainId: '',
    available: '0',
    staked: '0',
    rewards: '0',
  );
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
  ChainClient({required this.enabled});

  /// Mirrors the `liveReads` preference.
  final bool enabled;

  final HttpClient _http = HttpClient()..connectionTimeout = _timeout;

  static String? _restOf(ChainEntry chain) {
    final rest = chain.rest;
    if (rest == null || rest.isEmpty) return null;
    return rest.endsWith('/') ? rest.substring(0, rest.length - 1) : rest;
  }

  Future<Map<String, dynamic>?> _getJson(String url) async {
    if (!enabled) return null;
    try {
      final request = await _http.getUrl(Uri.parse(url)).timeout(_timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
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

  /// Spendable, bonded and claimable in one round trip set.
  Future<ChainBalance> balance(ChainEntry chain, String address) async {
    final rest = _restOf(chain);
    if (rest == null) {
      return ChainBalance(
        chainId: chain.chainId,
        available: '0',
        staked: '0',
        rewards: '0',
      );
    }
    final denom = chain.coinMinimalDenom;

    final results = await Future.wait([
      _getJson('$rest/cosmos/bank/v1beta1/balances/$address'),
      _getJson('$rest/cosmos/staking/v1beta1/delegations/$address'),
      _getJson('$rest/cosmos/distribution/v1beta1/delegators/$address/rewards'),
    ]);

    final available = _sumDenom(results[0]?['balances'], denom);

    var staked = BigInt.zero;
    final delegations = results[1]?['delegation_responses'];
    if (delegations is List) {
      for (final row in delegations) {
        final balance = (row as Map)['balance'];
        if (balance is Map && balance['denom'] == denom) {
          staked += BigInt.tryParse(
                (balance['amount'] as String? ?? '0').split('.').first,
              ) ??
              BigInt.zero;
        }
      }
    }

    final rewards = _sumDenom(results[2]?['total'], denom);

    return ChainBalance(
      chainId: chain.chainId,
      available: available,
      staked: staked.toString(),
      rewards: rewards,
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

  static String normalizeChannelId(String raw) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) return '';
    if (RegExp(r'^channel-\d+$').hasMatch(value)) return value;
    if (RegExp(r'^\d+$').hasMatch(value)) return 'channel-$value';
    return value;
  }

  static IbcChannelState _mapState(Object? raw) {
    final s = (raw ?? '').toString().toUpperCase();
    if (s.contains('OPEN')) return IbcChannelState.open;
    if (s.contains('CLOSED')) return IbcChannelState.closed;
    if (s.contains('INIT')) return IbcChannelState.init;
    if (s.contains('TRY')) return IbcChannelState.tryOpen;
    return IbcChannelState.unknown;
  }

  Future<String?> _connectionChainId(
    String rest,
    String connectionId,
    Map<String, String?> cache,
  ) async {
    if (cache.containsKey(connectionId)) return cache[connectionId];
    final conn = await _getJson(
      '$rest/ibc/core/connection/v1/connections/${Uri.encodeComponent(connectionId)}',
    );
    final clientId = (conn?['connection'] as Map?)?['client_id'] as String? ??
        conn?['client_id'] as String?;
    if (clientId == null) {
      cache[connectionId] = null;
      return null;
    }
    final state = await _getJson(
      '$rest/ibc/core/client/v1/client_states/${Uri.encodeComponent(clientId)}',
    );
    final nested = state?['client_state'] is Map
        ? state!['client_state'] as Map
        : state;
    final chainId = nested?['chain_id'] as String?;
    cache[connectionId] = chainId;
    return chainId;
  }

  /// Open transfer channels on [source] that connect to [destChainId].
  Future<List<IbcChannelOption>> findIbcChannels(
    ChainEntry source,
    String destChainId,
  ) async {
    if (!enabled || destChainId.isEmpty || source.chainId == destChainId) {
      return const [];
    }
    final rest = _restOf(source);
    if (rest == null) return const [];

    final raw = <Map>[];
    String? key;
    for (var page = 0; page < 3; page++) {
      final params = StringBuffer('pagination.limit=100');
      if (key != null) {
        params.write('&pagination.key=${Uri.encodeComponent(key)}');
      }
      final body = await _getJson('$rest/ibc/core/channel/v1/channels?$params');
      final rows = body?['channels'];
      if (rows is List) {
        for (final row in rows) {
          if (row is! Map) continue;
          if ((row['port_id'] as String? ?? 'transfer') != 'transfer') continue;
          raw.add(row);
        }
      }
      final next = (body?['pagination'] as Map?)?['next_key'] as String?;
      if (next == null || next.isEmpty) break;
      key = next;
    }

    final cache = <String, String?>{};
    final matches = <IbcChannelOption>[];
    for (final row in raw) {
      final channelId = row['channel_id'] as String?;
      if (channelId == null) continue;
      final state = _mapState(row['state']);
      if (state != IbcChannelState.open) continue;
      final hops = row['connection_hops'];
      final connectionId =
          hops is List && hops.isNotEmpty ? hops.first as String? : null;
      if (connectionId == null) continue;
      final counterpartyChainId =
          await _connectionChainId(rest, connectionId, cache);
      if (counterpartyChainId != destChainId) continue;
      final counterparty = row['counterparty'] as Map?;
      matches.add(
        IbcChannelOption(
          channelId: channelId,
          portId: row['port_id'] as String? ?? 'transfer',
          counterpartyChannelId: counterparty?['channel_id'] as String? ?? '',
          counterpartyChainId: counterpartyChainId,
          connectionId: connectionId,
          state: state,
        ),
      );
    }
    matches.sort((a, b) => a.channelId.compareTo(b.channelId));
    return matches;
  }

  Future<IbcChannelCheck> validateIbcChannel(
    ChainEntry source,
    String channelRaw, {
    String? destChainId,
  }) async {
    final channelId = normalizeChannelId(channelRaw);
    const portId = 'transfer';
    if (channelId.isEmpty) {
      return const IbcChannelCheck(
        ok: false,
        state: IbcChannelState.unknown,
        channelId: '',
        message: 'Enter a channel id (e.g. channel-141)',
      );
    }
    if (!enabled) {
      return IbcChannelCheck(
        ok: false,
        state: IbcChannelState.unknown,
        channelId: channelId,
        message: 'Turn on live reads to check channels',
      );
    }
    final rest = _restOf(source);
    if (rest == null) {
      return IbcChannelCheck(
        ok: false,
        state: IbcChannelState.unknown,
        channelId: channelId,
        message: 'No REST endpoint for this chain',
      );
    }
    final body = await _getJson(
      '$rest/ibc/core/channel/v1/channels/${Uri.encodeComponent(channelId)}/ports/$portId',
    );
    final row = body?['channel'] as Map?;
    if (row == null) {
      return IbcChannelCheck(
        ok: false,
        state: IbcChannelState.unknown,
        channelId: channelId,
        message: 'Channel not found on this chain',
      );
    }
    final state = _mapState(row['state']);
    final hops = row['connection_hops'];
    final connectionId =
        hops is List && hops.isNotEmpty ? hops.first as String? : null;
    String? counterpartyChainId;
    if (connectionId != null) {
      counterpartyChainId =
          await _connectionChainId(rest, connectionId, {});
    }
    final counterparty = row['counterparty'] as Map?;
    if (state != IbcChannelState.open) {
      return IbcChannelCheck(
        ok: false,
        state: state,
        channelId: channelId,
        counterpartyChannelId: counterparty?['channel_id'] as String?,
        counterpartyChainId: counterpartyChainId,
        message: 'Channel is ${state.name}, not open',
      );
    }
    if (destChainId != null &&
        counterpartyChainId != null &&
        counterpartyChainId != destChainId) {
      return IbcChannelCheck(
        ok: false,
        state: state,
        channelId: channelId,
        counterpartyChannelId: counterparty?['channel_id'] as String?,
        counterpartyChainId: counterpartyChainId,
        message: 'Open, but connects to $counterpartyChainId',
      );
    }
    return IbcChannelCheck(
      ok: true,
      state: state,
      channelId: channelId,
      counterpartyChannelId: counterparty?['channel_id'] as String?,
      counterpartyChainId: counterpartyChainId,
      message: counterpartyChainId == null
          ? 'Open and ready'
          : 'Open · $counterpartyChainId',
    );
  }

  void close() => _http.close(force: true);
}

enum IbcChannelState { open, closed, init, tryOpen, unknown }

@immutable
class IbcChannelOption {
  const IbcChannelOption({
    required this.channelId,
    required this.portId,
    required this.counterpartyChannelId,
    required this.counterpartyChainId,
    required this.connectionId,
    required this.state,
  });

  final String channelId;
  final String portId;
  final String counterpartyChannelId;
  final String? counterpartyChainId;
  final String connectionId;
  final IbcChannelState state;
}

@immutable
class IbcChannelCheck {
  const IbcChannelCheck({
    required this.ok,
    required this.state,
    required this.channelId,
    required this.message,
    this.counterpartyChannelId,
    this.counterpartyChainId,
  });

  final bool ok;
  final IbcChannelState state;
  final String channelId;
  final String message;
  final String? counterpartyChannelId;
  final String? counterpartyChainId;
}
