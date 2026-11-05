/// Staking reads: the validator set, one address's positions and unbondings,
/// the chain's staking parameters and, where it can be worked out honestly,
/// an estimated APR.
///
/// The shapes follow zunia-extension/lib/chain-queries.ts (fetchValidators,
/// fetchDelegations, fetchUnbonding) so both products show the same numbers.
/// Every amount is base units in a string or a [BigInt]; doubles appear only
/// for rates and shares (commission, voting power, APR).
library;

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/chain_reader.dart';

enum ValidatorBondState { active, inactive, jailed }

/// Bonded and not jailed is active; unbonded or unbonding is inactive.
ValidatorBondState validatorBondState({required bool jailed, String? status}) {
  if (jailed) return ValidatorBondState.jailed;
  final s = (status ?? '').trim().toUpperCase().replaceFirst('BOND_STATUS_', '');
  if (s == 'UNBONDED' || s == 'UNBONDING' || s == '1' || s == '3') {
    return ValidatorBondState.inactive;
  }
  return ValidatorBondState.active;
}

/// An http(s) website from `description.website`, or null when the field is
/// empty or names another scheme.
Uri? validatorWebsite(String? raw) {
  final value = (raw ?? '').trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri;
}

@immutable
class StakingValidator {
  const StakingValidator({
    required this.chainId,
    required this.operatorAddress,
    required this.moniker,
    required this.identity,
    required this.commission,
    required this.maxCommission,
    required this.votingPower,
    required this.tokens,
    required this.minSelfDelegation,
    required this.website,
    required this.details,
    required this.jailed,
    required this.status,
  });

  final String chainId;
  final String operatorAddress;
  final String moniker;

  /// Keybase id from `description.identity`, empty when none was set.
  final String identity;

  /// 0-1.
  final double commission;

  /// The most the validator can ever raise its commission to, 0-1.
  final double maxCommission;

  /// Share of bonded stake, 0-1. Zero for a validator outside the bonded set.
  final double votingPower;

  /// Bonded tokens, base units.
  final BigInt tokens;
  final BigInt minSelfDelegation;
  final String website;
  final String details;
  final bool jailed;
  final String status;

  ValidatorBondState get bondState =>
      validatorBondState(jailed: jailed, status: status);

  Uri? get websiteUri => validatorWebsite(website);

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return moniker.toLowerCase().contains(q) ||
        operatorAddress.toLowerCase().contains(q) ||
        identity.toLowerCase() == q;
  }
}

/// One delegation of the active address, with its pending rewards.
@immutable
class StakingPosition {
  const StakingPosition({
    required this.chainId,
    required this.validatorAddress,
    required this.moniker,
    required this.identity,
    required this.amount,
    required this.rewards,
    required this.jailed,
    required this.status,
  });

  final String chainId;
  final String validatorAddress;
  final String moniker;
  final String identity;

  /// Staked, base units of the staking denom.
  final BigInt amount;

  /// Claimable, base units of the staking denom. Null when the rewards read
  /// failed: unknown, which is not zero.
  final BigInt? rewards;
  final bool jailed;
  final String status;

  ValidatorBondState get bondState =>
      validatorBondState(jailed: jailed, status: status);
}

@immutable
class UnbondingEntry {
  const UnbondingEntry({
    required this.chainId,
    required this.validatorAddress,
    required this.moniker,
    required this.amount,
    required this.completionTime,
    required this.completionTimeRaw,
    required this.creationHeight,
  });

  final String chainId;
  final String validatorAddress;
  final String moniker;
  final BigInt amount;

  /// When the tokens are liquid again. Null when the chain sent something
  /// that does not parse.
  final DateTime? completionTime;

  /// As the chain sent it; part of the notification id.
  final String completionTimeRaw;
  final String creationHeight;
}

@immutable
class StakingParams {
  const StakingParams({
    required this.unbondingTime,
    required this.bondDenom,
    required this.maxValidators,
  });

  /// Null when the chain's value does not parse.
  final Duration? unbondingTime;
  final String bondDenom;
  final int? maxValidators;
}

/// An APR worked out from chain parameters, with the inputs that produced it
/// so the screen can show its working.
@immutable
class AprEstimate {
  const AprEstimate({
    required this.apr,
    required this.inflation,
    required this.communityTax,
    required this.bondedRatio,
  });

  /// Before validator commission, 0-1 (0.18 is 18%).
  final double apr;
  final double inflation;
  final double communityTax;
  final double bondedRatio;

  /// What one validator's delegators earn, after its commission.
  double afterCommission(double commission) => apr * (1 - commission);
}

/// The nominal staking APR of a chain running the standard x/mint module:
/// `inflation × (1 − community tax) ÷ bonded ratio`.
///
/// Returns null, so the screen shows no number at all, whenever that formula
/// would not describe what stakers are paid: no inflation reported (a custom
/// mint module, or none), zero inflation (rewards come from somewhere the
/// formula cannot see), a mint denom that is not the bond denom, or inputs out
/// of range. It is an estimate either way: it leaves out fees and assumes the
/// chain keeps its configured block rate, and the screen says so.
AprEstimate? estimateApr({
  required double? inflation,
  required double? communityTax,
  required BigInt? bondedTokens,
  required BigInt? totalSupply,
  String? mintDenom,
  String? bondDenom,
}) {
  if (inflation == null || communityTax == null) return null;
  if (bondedTokens == null || totalSupply == null) return null;
  if (mintDenom != null && bondDenom != null && mintDenom != bondDenom) {
    return null;
  }
  if (inflation <= 0 || inflation > 1) return null;
  if (communityTax < 0 || communityTax >= 1) return null;
  if (bondedTokens <= BigInt.zero || totalSupply <= BigInt.zero) return null;
  if (bondedTokens > totalSupply) return null;
  // Ratio in parts per billion, so two 30-digit integers never pass through a
  // double before they are divided.
  final ppb = (bondedTokens * BigInt.from(1000000000)) ~/ totalSupply;
  final ratio = ppb.toInt() / 1e9;
  if (ratio <= 0) return null;
  final apr = inflation * (1 - communityTax) / ratio;
  // A bonded ratio of a few percent makes the formula explode into numbers no
  // chain pays; past 1000% it is describing a broken input, not a yield.
  if (!apr.isFinite || apr <= 0 || apr > 10) return null;
  return AprEstimate(
    apr: apr,
    inflation: inflation,
    communityTax: communityTax,
    bondedRatio: ratio,
  );
}

/// `"1814400s"` (protobuf JSON Duration) to a Duration.
Duration? parseProtoDuration(Object? raw) {
  final text = asString(raw).trim();
  final match = RegExp(r'^(\d+)(?:\.(\d{1,9}))?s$').firstMatch(text);
  if (match == null) return null;
  final seconds = int.parse(match.group(1)!);
  final fraction = (match.group(2) ?? '').padRight(9, '0');
  return Duration(
    seconds: seconds,
    microseconds: int.parse(fraction) ~/ 1000,
  );
}

/// "21 days", "3 days 12 hours", "36 hours".
String describeDuration(Duration d) {
  final days = d.inDays;
  final hours = d.inHours - days * 24;
  if (days >= 2) {
    return hours == 0 ? '$days days' : '$days days $hours hours';
  }
  if (d.inHours >= 1) return '${d.inHours} hours';
  return '${d.inMinutes} minutes';
}

class StakingClient {
  StakingClient(this._reader);

  final ChainReader _reader;

  /// Bonded validators, strongest first. Pages through a large set (the Hub
  /// bonds 180, which a single 150-row page used to cut short, also skewing
  /// every voting-power share).
  Future<List<StakingValidator>> validators(ChainEntry chain) async {
    final rows = <Map<String, dynamic>>[];
    String? key;
    for (var page = 0; page < 4; page++) {
      final body = await _reader.get(
        chain,
        '/cosmos/staking/v1beta1/validators',
        query: {
          'status': 'BOND_STATUS_BONDED',
          'pagination.limit': 300,
          'pagination.key': key,
        },
      );
      final list = body['validators'];
      if (list is! List) {
        throw ChainReadError(
          ChainReadErrorKind.malformed,
          '${chain.chainId}: validators is not a list',
        );
      }
      rows.addAll(list.map(asMap));
      final next = asString(asMap(body['pagination'])['next_key']);
      if (next.isEmpty) break;
      key = next;
    }

    var total = BigInt.zero;
    for (final row in rows) {
      total += asBaseUnits(row['tokens']) ?? BigInt.zero;
    }
    final out = [
      for (final row in rows) _validatorFrom(chain.chainId, row, total),
    ]..sort((a, b) => b.tokens.compareTo(a.tokens));
    return out;
  }

  /// One validator, bonded or not. For a position on a validator that has
  /// left the bonded set, which the set read above does not return.
  Future<StakingValidator> validator(
    ChainEntry chain,
    String operatorAddress,
  ) async {
    final body = await _reader.get(
      chain,
      '/cosmos/staking/v1beta1/validators/$operatorAddress',
    );
    return _validatorFrom(chain.chainId, asMap(body['validator']), null);
  }

  StakingValidator _validatorFrom(
    String chainId,
    Map<String, dynamic> row,
    BigInt? bondedTotal,
  ) {
    final description = asMap(row['description']);
    final rates = asMap(asMap(row['commission'])['commission_rates']);
    final tokens = asBaseUnits(row['tokens']) ?? BigInt.zero;
    final operator = asString(row['operator_address']);
    final moniker = asString(description['moniker']).trim();
    double share = 0;
    if (bondedTotal != null && bondedTotal > BigInt.zero) {
      share = ((tokens * BigInt.from(1000000)) ~/ bondedTotal).toInt() / 1e6;
    }
    return StakingValidator(
      chainId: chainId,
      operatorAddress: operator,
      moniker: moniker.isEmpty ? operator : moniker,
      identity: asString(description['identity']).trim(),
      commission: asDecimal(rates['rate']) ?? 0,
      maxCommission: asDecimal(rates['max_rate']) ?? 0,
      votingPower: share,
      tokens: tokens,
      minSelfDelegation: asBaseUnits(row['min_self_delegation']) ?? BigInt.zero,
      website: asString(description['website']).trim(),
      details: asString(description['details']).trim(),
      jailed: row['jailed'] == true,
      status: asString(row['status']),
    );
  }

  /// Active delegations of [address], each with its pending rewards in the
  /// staking denom. [known] names validators already loaded, so a position
  /// only costs a validator read when its validator is outside that list.
  Future<List<StakingPosition>> positions(
    ChainEntry chain,
    String address, {
    Map<String, StakingValidator> known = const {},
  }) async {
    final denom = chain.coinMinimalDenom;
    final delegationsFuture = _reader.get(
      chain,
      '/cosmos/staking/v1beta1/delegations/$address',
      query: {'pagination.limit': 200},
    );
    final rewardsFuture = _reader
        .get(chain, '/cosmos/distribution/v1beta1/delegators/$address/rewards')
        .then<Map<String, dynamic>?>((v) => v, onError: (Object _) => null);
    final body = await delegationsFuture;
    final rewardsBody = await rewardsFuture;

    final rows = body['delegation_responses'];
    if (rows != null && rows is! List) {
      throw ChainReadError(
        ChainReadErrorKind.malformed,
        '${chain.chainId}: delegation_responses is not a list',
      );
    }

    // Unknown when the rewards read failed, which is not the same as zero.
    Map<String, BigInt>? rewardByValidator;
    if (rewardsBody != null) {
      rewardByValidator = {};
      for (final row in asList(rewardsBody['rewards'])) {
        final map = asMap(row);
        final validator = asString(map['validator_address']);
        if (validator.isEmpty) continue;
        rewardByValidator[validator] = sumDenom(map['reward'], denom);
      }
    }

    final out = <StakingPosition>[];
    final parsed = asList(rows);
    final missing = <String>{};
    for (final row in parsed) {
      final validator =
          asString(asMap(asMap(row)['delegation'])['validator_address']);
      if (validator.isNotEmpty && !known.containsKey(validator)) {
        missing.add(validator);
      }
    }
    final looked = <String, StakingValidator>{...known};
    await Future.wait(
      missing.map((operator) async {
        try {
          looked[operator] = await validator(chain, operator);
        } on ChainReadError {
          // The address stands in for the name.
        }
      }),
    );

    for (final row in parsed) {
      final map = asMap(row);
      final validator =
          asString(asMap(map['delegation'])['validator_address']);
      final balance = asMap(map['balance']);
      final amount = balance['denom'] == denom
          ? (asBaseUnits(balance['amount']) ?? BigInt.zero)
          : BigInt.zero;
      final meta = looked[validator];
      out.add(
        StakingPosition(
          chainId: chain.chainId,
          validatorAddress: validator,
          moniker: meta?.moniker ?? validator,
          identity: meta?.identity ?? '',
          amount: amount,
          rewards: rewardByValidator == null
              ? null
              : (rewardByValidator[validator] ?? BigInt.zero),
          jailed: meta?.jailed ?? false,
          status: meta?.status ?? '',
        ),
      );
    }
    out.sort((a, b) => b.amount.compareTo(a.amount));
    return out;
  }

  /// In-flight unbonding entries, soonest completion first.
  Future<List<UnbondingEntry>> unbonding(
    ChainEntry chain,
    String address, {
    Map<String, StakingValidator> known = const {},
  }) async {
    final body = await _reader.get(
      chain,
      '/cosmos/staking/v1beta1/delegators/$address/unbonding_delegations',
    );
    final out = <UnbondingEntry>[];
    for (final row in asList(body['unbonding_responses'])) {
      final map = asMap(row);
      final validator = asString(map['validator_address']);
      for (final entry in asList(map['entries'])) {
        final e = asMap(entry);
        final raw = asString(e['completion_time']);
        out.add(
          UnbondingEntry(
            chainId: chain.chainId,
            validatorAddress: validator,
            moniker: known[validator]?.moniker ?? validator,
            amount: asBaseUnits(e['balance']) ?? BigInt.zero,
            completionTime: DateTime.tryParse(raw),
            completionTimeRaw: raw,
            creationHeight: asString(e['creation_height']),
          ),
        );
      }
    }
    out.sort((a, b) {
      final at = a.completionTime;
      final bt = b.completionTime;
      if (at == null || bt == null) return at == null ? 1 : -1;
      return at.compareTo(bt);
    });
    return out;
  }

  Future<StakingParams> params(ChainEntry chain) async {
    final body = await _reader.get(chain, '/cosmos/staking/v1beta1/params');
    final params = asMap(body['params']);
    return StakingParams(
      unbondingTime: parseProtoDuration(params['unbonding_time']),
      bondDenom: asString(params['bond_denom']),
      maxValidators: int.tryParse(asString(params['max_validators'])),
    );
  }

  /// Total claimable rewards of [address] in the staking denom, for the
  /// rewards notice. One read per chain.
  Future<BigInt> rewardsTotal(ChainEntry chain, String address) async {
    final body = await _reader.get(
      chain,
      '/cosmos/distribution/v1beta1/delegators/$address/rewards',
    );
    return sumDenom(body['total'], chain.coinMinimalDenom);
  }

  /// See [estimateApr]. Null whenever any input is missing.
  Future<AprEstimate?> apr(ChainEntry chain, {String? bondDenom}) async {
    Future<Map<String, dynamic>?> read(String path, [Map<String, Object?>? q]) =>
        _reader
            .get(chain, path, query: q)
            .then<Map<String, dynamic>?>((v) => v, onError: (Object _) => null);

    final denom = (bondDenom == null || bondDenom.isEmpty)
        ? chain.coinMinimalDenom
        : bondDenom;
    final results = await Future.wait([
      read('/cosmos/mint/v1beta1/inflation'),
      read('/cosmos/mint/v1beta1/params'),
      read('/cosmos/distribution/v1beta1/params'),
      read('/cosmos/staking/v1beta1/pool'),
      read('/cosmos/bank/v1beta1/supply/by_denom', {'denom': denom}),
    ]);
    var supply = asBaseUnits(asMap(results[4]?['amount'])['amount']);
    if (supply == null) {
      // SDK 0.45 has no by_denom route; it takes the denom in the path.
      final legacy = await read('/cosmos/bank/v1beta1/supply/$denom');
      supply = asBaseUnits(asMap(legacy?['amount'])['amount']);
    }
    final mintDenom = asString(asMap(results[1]?['params'])['mint_denom']);
    return estimateApr(
      inflation: asDecimal(results[0]?['inflation']),
      communityTax: asDecimal(asMap(results[2]?['params'])['community_tax']),
      bondedTokens: asBaseUnits(asMap(results[3]?['pool'])['bonded_tokens']),
      totalSupply: supply,
      mintDenom: mintDenom.isEmpty ? null : mintDenom,
      bondDenom: denom,
    );
  }
}
