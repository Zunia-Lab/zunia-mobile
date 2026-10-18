/// Which pairs Zunia's Osmosis swap contract can execute, read from the
/// contract's own route table.
///
/// Port of zunia-extension 0.1.5 `lib/xcs-routes.ts`. The crosschain-swaps
/// contract takes no route in its memo: it asks its swaprouter
/// `get_route(input, output)` and refuses the packet when the router has no
/// entry. SQS prices far more pairs than that table holds. Those pairs are
/// swapped in Osmosis's own pools instead (`pool_swap.dart`), so the table's
/// answer picks the path for a pair (`swap_path.dart`) rather than whether it
/// can be swapped at all.
///
/// The table is read once and cached for an hour, in memory and in
/// SharedPreferences: the contract's raw `config` names the router
/// (`swap_contract`), and the router's paginated contract state holds the
/// `routing_table` map. The answer is advisory: the live route check
/// (`readXcsExecutableRoute`) still decides what the contract path may sign.
/// When the table cannot be read every answer is `unknown`, and `unknown`
/// never disables a row.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/services/interchain/xcs_route.dart';
import 'package:zunia_mobile/swap/swap_path.dart';
import 'package:zunia_mobile/swap/swap_tokens.dart';

/// One entry of the swaprouter's `routing_table`.
@immutable
class XcsRoute {
  const XcsRoute({
    required this.input,
    required this.output,
    required this.poolIds,
  });

  /// Denom the contract receives on Osmosis.
  final String input;

  /// Denom it pays out on Osmosis.
  final String output;

  /// Pools in the order the router swaps through them.
  final List<String> poolIds;

  @override
  bool operator ==(Object other) =>
      other is XcsRoute &&
      other.input == input &&
      other.output == output &&
      listEquals(other.poolIds, poolIds);

  @override
  int get hashCode => Object.hash(input, output, Object.hashAll(poolIds));

  @override
  String toString() => 'XcsRoute($input -> $output via ${poolIds.join('>')})';
}

/// The route table of one crosschain-swaps deployment.
class XcsRouteTable {
  XcsRouteTable({
    required this.xcsContract,
    required this.swapContract,
    required this.routes,
    required this.readAt,
  });

  final String xcsContract;

  /// Its swaprouter, from the contract's raw `config`.
  final String swapContract;
  final List<XcsRoute> routes;

  /// When the read finished.
  final DateTime readAt;

  late final Set<String> _pairs = {
    for (final route in routes) _pairKey(route.input, route.output),
  };

  bool hasPair(String input, String output) =>
      _pairs.contains(_pairKey(input, output));
}

/// Bumped when the cached record changes shape; a record of another version
/// is ignored.
const int xcsRoutesCacheVersion = 1;

/// The router's owner can add routes at any time; the live check covers the
/// gap, so an hour only costs UX.
const Duration xcsRoutesTtl = Duration(hours: 1);

const String _routingTable = 'routing_table';
const int _pageLimit = 100;

/// A table this long would be 20,000 routes: not the contract this was
/// written for, so the read fails instead of trusting a partial table.
const int _maxPages = 200;

final RegExp _cosmosDenom = RegExp(r'^[a-zA-Z][a-zA-Z0-9/:._-]{1,127}$');
const String _cacheKey = 'zunia.swap.xcsRoutes';

/* -------------------------------------------------------------------------- *
 * Reasons, in the words the picker shows
 * -------------------------------------------------------------------------- */

/// A pair the route table does not hold.
String noRouteReason(String fromTicker, String toTicker) =>
    "Zunia's Osmosis swap contract has no route from $fromTicker to $toTicker yet.";

/// A side Osmosis has no denom for: neither the contract nor the pools can
/// trade it.
String notTradedReason(String ticker) =>
    '$ticker is not traded on Osmosis, so Zunia cannot swap it.';

/// The To row is the From row itself.
const String selfReason = 'This is the token you are selling.';

/// The same asset somewhere else.
const String sameTokenReason =
    'Same token as the one you sell. Use Send to move it.';

/// Either side on a test network.
const String testnetReason =
    'Zunia swaps on Osmosis mainnet, so it cannot swap testnet tokens.';

/* -------------------------------------------------------------------------- *
 * Parsing the router's state
 * -------------------------------------------------------------------------- */

/// `ibc/` hashes compare without case; every other denom exactly.
String _venueDenomKey(String denom) => denom.startsWith('ibc/')
    ? 'ibc/${denom.substring(4).toUpperCase()}'
    : denom;

String _pairKey(String input, String output) =>
    // NUL cannot occur in a denom, so two pairs never share a key.
    '${_venueDenomKey(input)}\u0000${_venueDenomKey(output)}';

Uint8List? _hexBytes(Object? hex) {
  if (hex is! String ||
      hex.length < 4 ||
      hex.length.isOdd ||
      !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
    return null;
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String? _utf8(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// The pair a `routing_table` key names. cw-storage-plus writes a composite
/// key as: the namespace's length (u16, big-endian), the namespace, the first
/// element's length (u16), the first element, then the last element with no
/// length. Items stored under a bare name do not have a length that fits, and
/// are skipped like anything else that is not this map.
({String input, String output})? _routeKeyOf(Object? hex) {
  final key = _hexBytes(hex);
  if (key == null) return null;
  final namespaceLength = (key[0] << 8) | key[1];
  final namespaceEnd = 2 + namespaceLength;
  if (namespaceEnd + 2 > key.length) return null;
  if (_utf8(key.sublist(2, namespaceEnd)) != _routingTable) return null;
  final inputLength = (key[namespaceEnd] << 8) | key[namespaceEnd + 1];
  final inputEnd = namespaceEnd + 2 + inputLength;
  if (inputLength == 0 || inputEnd >= key.length) return null;
  final input = _utf8(key.sublist(namespaceEnd + 2, inputEnd));
  final output = _utf8(key.sublist(inputEnd));
  if (input == null || output == null) return null;
  if (!_cosmosDenom.hasMatch(input) || !_cosmosDenom.hasMatch(output)) {
    return null;
  }
  return (input: input, output: output);
}

/// The pools of a stored route, or null when the value is not a route that
/// ends in [output]: `get_route` would hand the engine the same value, the
/// engine would refuse it, and the pair could not be signed anyway.
List<String>? _poolIdsOf(Object? value, String output) {
  if (value is! String || value.isEmpty) return null;
  Object? hops;
  try {
    hops = jsonDecode(utf8.decode(base64.decode(value)));
  } on FormatException {
    return null;
  }
  if (hops is! List || hops.isEmpty) return null;
  final pools = <String>[];
  Object? last;
  for (final hop in hops) {
    if (hop is! Map) return null;
    final raw = hop['pool_id'];
    final id = raw is int ? '$raw' : raw;
    if (id is! String || !RegExp(r'^[1-9]\d*$').hasMatch(id)) return null;
    pools.add(id);
    last = hop['token_out_denom'];
  }
  return last == output ? pools : null;
}

/// Every route in a swaprouter's raw contract state (`models` from
/// `/cosmwasm/wasm/v1/contract/{router}/state`, all pages together). Models
/// that are not `routing_table` entries, or do not parse, are skipped.
List<XcsRoute> parseRouterState(List<Object?> models) {
  final out = <XcsRoute>[];
  final seen = <String>{};
  for (final model in models) {
    if (model is! Map) continue;
    final pair = _routeKeyOf(model['key']);
    if (pair == null) continue;
    final poolIds = _poolIdsOf(model['value'], pair.output);
    final key = _pairKey(pair.input, pair.output);
    if (poolIds == null || seen.contains(key)) continue;
    seen.add(key);
    out.add(XcsRoute(input: pair.input, output: pair.output, poolIds: poolIds));
  }
  return out;
}

/* -------------------------------------------------------------------------- *
 * Reading the table
 * -------------------------------------------------------------------------- */

InterchainError _malformed(String chainId, String message) => InterchainError(
  InterchainErrorCode.malformedResponse,
  '$chainId: $message',
  chainId: chainId,
);

/// Read a crosschain-swaps deployment's route table from chain: the
/// contract's raw `config` for its `swap_contract`, then that router's
/// contract state, page by page, then the `routing_table` keys.
///
/// Throws [InterchainError]: `invalidRequest` for an address that is not one,
/// `malformedResponse` when the config names no router or the state holds no
/// route (a table this cannot read is not an empty table), and the LCD
/// client's own codes.
Future<XcsRouteTable> readRoutingTable(
  LcdClient lcd,
  String xcsContract, {
  DateTime? now,
}) async {
  final contract = xcsContract.trim();
  if (!looksLikeContractAddress(contract)) {
    throw InterchainError(
      InterchainErrorCode.invalidRequest,
      '${contract.isEmpty ? '(empty)' : contract} is not a contract address',
      chainId: lcd.chainId,
    );
  }
  // Read fresh: the table is cached here for an hour, and a page from the
  // client's own cache would make the read look newer than it is.
  const fresh = LcdRequestOptions(
    timeout: Duration(seconds: 10),
    cacheTtl: Duration.zero,
  );
  final router = parseXcsSwapContract(
    contractQueryData(
      await lcd.getJson(xcsConfigPath(contract), fresh),
      lcd.chainId,
    ),
  );
  if (router == null) {
    throw _malformed(
      lcd.chainId,
      '$contract has no swap_contract in its config',
    );
  }

  final statePath =
      '/cosmwasm/wasm/v1/contract/${Uri.encodeComponent(router)}/state';
  final models = <Object?>[];
  final asked = <String>{};
  String? next;
  for (var page = 0; ; page++) {
    if (page >= _maxPages) {
      throw _malformed(
        lcd.chainId,
        '$router state did not end within $_maxPages pages',
      );
    }
    final body = await lcd.getJson(
      statePath,
      LcdRequestOptions(
        timeout: fresh.timeout,
        cacheTtl: Duration.zero,
        query: {'pagination.limit': _pageLimit, 'pagination.key': ?next},
      ),
    );
    final rows = body is Map ? body['models'] : null;
    if (rows is! List) {
      throw _malformed(lcd.chainId, '$router state has no models');
    }
    models.addAll(rows);
    final pagination = body is Map ? body['pagination'] : null;
    final key = pagination is Map ? pagination['next_key'] : null;
    if (key is! String || key.isEmpty) break;
    // A gateway that drops the query string answers every page with the first
    // one and the same next key. Asking again would only repeat it.
    if (!asked.add(key)) {
      throw _malformed(
        lcd.chainId,
        '$router state repeats the page after $key',
      );
    }
    next = key;
  }

  final routes = parseRouterState(models);
  if (routes.isEmpty) {
    throw _malformed(lcd.chainId, '$router state holds no routing_table entry');
  }
  return XcsRouteTable(
    xcsContract: contract,
    swapContract: router,
    routes: routes,
    readAt: now ?? DateTime.now(),
  );
}

/* -------------------------------------------------------------------------- *
 * The cache
 * -------------------------------------------------------------------------- */

/// A stored record for [xcsContract], when it is this version, fresh and
/// well formed. Storage is checked like any other input.
@visibleForTesting
XcsRouteTable? tableFromRecord(Object? raw, String xcsContract, DateTime now) {
  if (raw is! Map || raw['version'] != xcsRoutesCacheVersion) return null;
  final readAt = raw['readAt'];
  final router = raw['swapContract'];
  final routes = raw['routes'];
  if (raw['xcsContract'] != xcsContract ||
      router is! String ||
      !looksLikeContractAddress(router)) {
    return null;
  }
  if (readAt is! int) return null;
  final age = now.millisecondsSinceEpoch - readAt;
  if (age < 0 || age > xcsRoutesTtl.inMilliseconds) return null;
  if (routes is! List || routes.isEmpty) return null;
  final out = <XcsRoute>[];
  for (final row in routes) {
    if (row is! List || row.length < 3 || row.any((part) => part is! String)) {
      return null;
    }
    final parts = row.cast<String>();
    final input = parts[0];
    final output = parts[1];
    final poolIds = parts.sublist(2);
    if (!_cosmosDenom.hasMatch(input) || !_cosmosDenom.hasMatch(output)) {
      return null;
    }
    if (!poolIds.every((id) => RegExp(r'^[1-9]\d*$').hasMatch(id))) return null;
    out.add(XcsRoute(input: input, output: output, poolIds: poolIds));
  }
  return XcsRouteTable(
    xcsContract: xcsContract,
    swapContract: router,
    routes: out,
    readAt: DateTime.fromMillisecondsSinceEpoch(readAt),
  );
}

@visibleForTesting
Map<String, Object?> recordOf(XcsRouteTable table) => {
  'version': xcsRoutesCacheVersion,
  'xcsContract': table.xcsContract,
  'swapContract': table.swapContract,
  'readAt': table.readAt.millisecondsSinceEpoch,
  'routes': [
    for (final route in table.routes)
      [route.input, route.output, ...route.poolIds],
  ],
};

XcsRouteTable? _memory;

/// Forget the in-memory table (the stored copy stays). For tests and a
/// manual refresh.
void resetXcsRoutesMemory() => _memory = null;

bool _fresh(XcsRouteTable table, String contract, DateTime now) {
  final age = now.difference(table.readAt);
  return table.xcsContract == contract &&
      !age.isNegative &&
      age <= xcsRoutesTtl;
}

/// The route table of [xcsContract] (the verified venue's address), from
/// memory or the stored copy while it is under an hour old, else read live.
///
/// Resolves null when the table cannot be read for any reason (reads off, an
/// unreachable LCD, a router this cannot parse): every pair is then `unknown`
/// and nothing is gated.
Future<XcsRouteTable?> loadXcsRoutes(
  String xcsContract, {
  required LcdClient lcd,
  bool force = false,
  DateTime? now,
}) async {
  final contract = xcsContract.trim();
  final at = now ?? DateTime.now();
  if (!force) {
    final memory = _memory;
    if (memory != null && _fresh(memory, contract, at)) return memory;
    try {
      final store = await SharedPreferences.getInstance();
      final raw = store.getString(_cacheKey);
      final stored = raw == null
          ? null
          : tableFromRecord(jsonDecode(raw), contract, at);
      if (stored != null) return _memory = stored;
    } on Object {
      // A damaged record is no record.
    }
  }
  try {
    final table = await readRoutingTable(lcd, contract, now: at);
    _memory = table;
    try {
      final store = await SharedPreferences.getInstance();
      await store.setString(_cacheKey, jsonEncode(recordOf(table)));
    } on Object {
      // The table still answers from memory.
    }
    return table;
  } on Object {
    return null;
  }
}

/* -------------------------------------------------------------------------- *
 * Answers
 * -------------------------------------------------------------------------- */

/// Whether the contract can swap [vin] into [vout], both named as Osmosis
/// denoms. `unknown` without a table or without a name for either side.
Executable executable(XcsRouteTable? table, String? vin, String? vout) {
  if (table == null || vin == null || vout == null) return Executable.unknown;
  return table.hasPair(vin, vout) ? Executable.yes : Executable.no;
}

/// What gating needs from a swap row.
@immutable
class GateSide {
  const GateSide({
    required this.key,
    required this.chainId,
    required this.denom,
    required this.identity,
    required this.testnet,
  });

  final String key;
  final String chainId;
  final String denom;
  final SwapTokenIdentity identity;
  final bool testnet;
}

/// The verdict on one To row for the current From.
@immutable
class Gate {
  const Gate(this.executable, this.disabledReason);

  /// What the route table says about the pair, and nothing else.
  final Executable executable;

  /// Why the row cannot be picked; null when it can.
  final String? disabledReason;
}

/// The side's denom on Osmosis: the held denom there, else the identity's
/// canonical voucher.
String? osmosisDenomFor(
  GateSide side, {
  String venueChainId = kOsmosisChainId,
}) => side.chainId == venueChainId ? side.denom : side.identity.osmosisDenom;

/// The assets the table trades, as `origin chain + origin denom`, or null when
/// any of its denoms has no proven identity.
Set<String>? _assetsOf(XcsRouteTable table, SwapTokenBook book) {
  final assets = <String>{};
  for (final route in table.routes) {
    for (final denom in [route.input, route.output]) {
      final identity = book.identityOf(kOsmosisChainId, denom);
      if (!identity.known ||
          identity.originChainId == null ||
          identity.originDenom == null) {
        return null;
      }
      assets.add('${identity.originChainId}\u0000${identity.originDenom}');
    }
  }
  return assets;
}

/// [executable] for two swap rows, from their identities. A side with no
/// Osmosis denom answers `no` only when it provably is none of the table's
/// assets, else `unknown`.
Executable executableBetween(
  XcsRouteTable? table,
  GateSide from,
  GateSide to,
  SwapTokenBook book,
) {
  if (table == null) return Executable.unknown;
  Object? venueSide(GateSide side) {
    final denom = osmosisDenomFor(side);
    if (denom != null) return denom;
    final identity = side.identity;
    if (!identity.known ||
        identity.originChainId == null ||
        identity.originDenom == null) {
      return Executable.unknown;
    }
    final assets = _assetsOf(table, book);
    if (assets == null ||
        assets.contains(
          '${identity.originChainId}\u0000${identity.originDenom}',
        )) {
      return Executable.unknown;
    }
    return Executable.no;
  }

  final vin = venueSide(from);
  final vout = venueSide(to);
  if (vin == Executable.unknown || vout == Executable.unknown) {
    return Executable.unknown;
  }
  if (vin == Executable.no || vout == Executable.no) return Executable.no;
  return executable(table, vin as String, vout as String);
}

/// The verdict on [option] as the To side of a swap from [from], in order of
/// what the user can act on: a testnet side, the From row itself, the same
/// asset elsewhere, a side Osmosis does not trade. A pair the contract's table
/// does not hold is not refused for that: Osmosis's own pools swap it.
Gate gateOption(
  GateSide? from,
  GateSide option,
  XcsRouteTable? table,
  SwapTokenBook book,
) {
  if (from == null) return const Gate(Executable.unknown, null);
  final answer = executableBetween(table, from, option, book);
  Gate gate(String? reason) => Gate(answer, reason);
  if (from.testnet || option.testnet) return gate(testnetReason);
  if (option.key == from.key) return gate(selfReason);
  final vin = osmosisDenomFor(from);
  final vout = osmosisDenomFor(option);
  if (vin != null &&
      vout != null &&
      _venueDenomKey(vin) == _venueDenomKey(vout)) {
    return gate(sameTokenReason);
  }
  final path = swapPathFor(
    from.chainId,
    option.chainId,
    answer,
    venueChainId: kOsmosisChainId,
  );
  if (path != SwapPath.contract && (vin == null || vout == null)) {
    return gate(notTradedReason((vin != null ? option : from).identity.ticker));
  }
  return gate(null);
}
