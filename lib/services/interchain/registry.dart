/// Chain lookup and the channel-route cache.
///
/// Dart mirror of the parts of `registry.ts` this client uses. The chain data
/// itself comes from the app's bundled catalog, so [CatalogChainRegistry] is an
/// adapter rather than a second copy of the registry.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';

import 'types.dart';

/// [ChainRegistry] over the app's [ChainCatalog].
///
/// `features` is passed straight through, including when it is null: the
/// catalog generator drops the registry's `features` array today, and turning
/// that absence into an empty list would tell the engine "this chain declares
/// no CosmWasm", which is a claim nobody has checked. Null means "unknown", the
/// engine degrades to a warning rather than ruling a chain out, and the NFT
/// surface asks the chain instead (see `nftChainSupportProvider`). The day the
/// generator carries the array, every consumer here starts using it with no
/// further change.
class CatalogChainRegistry implements ChainRegistry {
  const CatalogChainRegistry(this._catalog);

  final ChainCatalog _catalog;

  static ChainInfo fromEntry(ChainEntry entry) => ChainInfo(
        chainId: entry.chainId,
        chainName: entry.chainName,
        bech32Prefix: entry.bech32Prefix,
        coinMinimalDenom: entry.coinMinimalDenom,
        network: entry.network,
        rest: entry.rest,
        features: entry.features,
      );

  @override
  ChainInfo? get(String chainId) {
    final entry = _catalog.find(chainId);
    return entry == null ? null : fromEntry(entry);
  }

  @override
  List<ChainInfo> list() => _catalog.all.map(fromEntry).toList();
}

/// Where a channel id came from, which is how much we trust it.
enum ChannelRouteSource {
  /// Confirmed against the chain's own LCD.
  discovered,

  /// The user typed it. Ranked first as an explicit instruction, and warned
  /// about, because nobody checked it.
  manual,

  /// A compiled-in hint. Correct when it was written; channels do get closed.
  seed,
}

/// One directed channel pair between two chains.
///
/// Directed: [channelId] lives on [sourceChainId] and [counterpartyChannelId]
/// on [destChainId], so the reverse direction is a separate record.
@immutable
class ChannelRoute {
  const ChannelRoute({
    required this.sourceChainId,
    required this.destChainId,
    required this.channelId,
    required this.counterpartyChannelId,
    required this.verifiedAt,
    required this.source,
  });

  factory ChannelRoute.fromJson(Map<String, Object?> json) => ChannelRoute(
        sourceChainId: json['sourceChainId'] as String? ?? '',
        destChainId: json['destChainId'] as String? ?? '',
        channelId: json['channelId'] as String? ?? '',
        counterpartyChannelId: json['counterpartyChannelId'] as String? ?? '',
        verifiedAt: (json['verifiedAt'] as num?)?.toInt() ?? 0,
        source: ChannelRouteSource.values.firstWhere(
          (s) => s.name == json['source'],
          orElse: () => ChannelRouteSource.seed,
        ),
      );

  final String sourceChainId;
  final String destChainId;
  final String channelId;

  /// Channel on the destination chain; `''` when the pair is not known yet.
  final String counterpartyChannelId;

  /// Milliseconds since epoch of the last successful on-chain check. `0` means
  /// never verified, which is what every seed entry carries.
  final int verifiedAt;

  final ChannelRouteSource source;

  Map<String, Object?> toJson() => {
        'sourceChainId': sourceChainId,
        'destChainId': destChainId,
        'channelId': channelId,
        'counterpartyChannelId': counterpartyChannelId,
        'verifiedAt': verifiedAt,
        'source': source.name,
      };
}

/// How long a verification is trusted before it is re-checked.
const Duration kRouteMaxAge = Duration(hours: 24);

/// Compiled-in channel hints.
///
/// Two entries on purpose. A bundled table of channel ids goes stale silently
/// and a stale channel id is the one mistake in this flow a user cannot undo,
/// so the wallet discovers channels on chain and only falls back to these.
const List<ChannelRoute> seedChannelRoutes = [
  // The canonical Cosmos Hub / Osmosis transfer pair, and the one channel
  // number the clients already show as the placeholder in their inputs.
  ChannelRoute(
    sourceChainId: 'cosmoshub-4',
    destChainId: 'osmosis-1',
    channelId: 'channel-141',
    counterpartyChannelId: 'channel-0',
    verifiedAt: 0,
    source: ChannelRouteSource.seed,
  ),
  ChannelRoute(
    sourceChainId: 'osmosis-1',
    destChainId: 'cosmoshub-4',
    channelId: 'channel-0',
    counterpartyChannelId: 'channel-141',
    verifiedAt: 0,
    source: ChannelRouteSource.seed,
  ),
];

/// A persistable cache of discovered channel pairs.
///
/// Deliberately not a router: it answers "which channel did we last see between
/// these two chains?", and the caller re-verifies on chain before building a
/// transfer.
class RouteRegistry {
  RouteRegistry([Iterable<ChannelRoute> initial = const []]) {
    putMany(initial);
  }

  factory RouteRegistry.fromSnapshot(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return RouteRegistry();
      if (decoded['version'] != 1) return RouteRegistry();
      final rows = decoded['routes'];
      if (rows is! List) return RouteRegistry();
      return RouteRegistry(rows
          .whereType<Map<String, Object?>>()
          .map(ChannelRoute.fromJson)
          .where((r) => r.sourceChainId.isNotEmpty && r.channelId.isNotEmpty));
    } on FormatException {
      // A corrupt snapshot is dropped rather than repaired: half a channel
      // table is worse than none, because the half we keep looks authoritative.
      return RouteRegistry();
    }
  }

  final Map<String, ChannelRoute> _routes = {};

  static String _key(ChannelRoute route) =>
      '${route.sourceChainId}|${route.destChainId}|${route.channelId}';

  int get size => _routes.length;

  /// Store a route, keeping the stronger source and the newer verification.
  ChannelRoute put(ChannelRoute route) {
    final key = _key(route);
    final existing = _routes[key];
    final merged = existing == null
        ? route
        : ChannelRoute(
            sourceChainId: route.sourceChainId,
            destChainId: route.destChainId,
            channelId: route.channelId,
            counterpartyChannelId: route.counterpartyChannelId.isNotEmpty
                ? route.counterpartyChannelId
                : existing.counterpartyChannelId,
            verifiedAt: route.verifiedAt > existing.verifiedAt
                ? route.verifiedAt
                : existing.verifiedAt,
            source: _strongerSource(route.source, existing.source),
          );
    _routes[key] = merged;
    return merged;
  }

  int putMany(Iterable<ChannelRoute> routes) {
    var stored = 0;
    for (final route in routes) {
      if (route.sourceChainId.isEmpty ||
          route.destChainId.isEmpty ||
          route.channelId.isEmpty ||
          route.sourceChainId == route.destChainId) {
        continue;
      }
      put(route);
      stored += 1;
    }
    return stored;
  }

  static ChannelRouteSource _strongerSource(
    ChannelRouteSource a,
    ChannelRouteSource b,
  ) {
    int rank(ChannelRouteSource s) => switch (s) {
          ChannelRouteSource.manual => 0,
          ChannelRouteSource.discovered => 1,
          ChannelRouteSource.seed => 2,
        };
    return rank(a) <= rank(b) ? a : b;
  }

  /// Every known route, or those matching a direction.
  List<ChannelRoute> list({String? sourceChainId, String? destChainId}) {
    final rows = _routes.values.where((route) {
      if (sourceChainId != null && route.sourceChainId != sourceChainId) {
        return false;
      }
      if (destChainId != null && route.destChainId != destChainId) return false;
      return true;
    }).toList();
    rows.sort((a, b) {
      final bySource =
          _strongerSource(a.source, b.source) == a.source ? -1 : 1;
      if (a.source != b.source) return bySource;
      return b.verifiedAt.compareTo(a.verifiedAt);
    });
    return rows;
  }

  /// The best known route for a direction, or null.
  ChannelRoute? get(String sourceChainId, String destChainId) {
    final rows = list(sourceChainId: sourceChainId, destChainId: destChainId);
    return rows.isEmpty ? null : rows.first;
  }

  /// Whether a route's verification is recent enough to skip a re-check.
  bool isFresh(ChannelRoute route, {DateTime? now}) {
    if (route.verifiedAt == 0) return false;
    final at = DateTime.fromMillisecondsSinceEpoch(route.verifiedAt);
    return (now ?? DateTime.now()).difference(at) < kRouteMaxAge;
  }

  String toSnapshot() => jsonEncode({
        'version': 1,
        'routes': _routes.values.map((r) => r.toJson()).toList(),
      });
}
