/// Tokens the swap lists offer as delivered on Osmosis.
///
/// Port of zunia-extension 0.1.5 `lib/osmosis-assets.ts`. The list is the
/// bundled token table's Osmosis rows, each hash-verified, verified by Osmosis
/// and not flagged unstable, kept while the SQS router that prices the swap
/// still lists them (`/tokens/metadata`, `preview: false`). SQS is a freshness
/// filter and a decimals cross-check only: its rows carry no origin, so it
/// names nothing. Being listed says a token exists on Osmosis, not that a
/// route reaches it; the quote is still the binding check.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/swap/swap_tokens.dart';

/// One row SQS lists (`preview: false`), as it describes it.
@immutable
class OsmosisListing {
  const OsmosisListing({
    required this.denom,
    required this.symbol,
    required this.name,
    required this.decimals,
    required this.coinGeckoId,
  });

  final String denom;

  /// SQS's symbol (`USDC.noble`): an alias users have seen, never the ticker.
  final String symbol;
  final String name;

  /// SQS's exponent, compared with the identity's.
  final int decimals;
  final String? coinGeckoId;

  Map<String, Object?> toJson() => {
    'denom': denom,
    'symbol': symbol,
    'name': name,
    'decimals': decimals,
    'coinGeckoId': coinGeckoId,
  };
}

/// A listed row the bundled table proves.
@immutable
class OsmosisAsset {
  const OsmosisAsset(this.listing, this.row);

  final OsmosisListing listing;

  /// The table's row for the denom; delivery to the issuer reads its
  /// `originDenom`, the hash-verified exact spelling one hop back.
  final SwapTokenTableRow row;

  String get denom => listing.denom;
  int get decimals => listing.decimals;
}

const Duration _cacheTtl = Duration(hours: 6);
const String _cacheKey = 'zunia.swap.osmosisAssets';

/// Bumped when the cached record changes shape; another version is ignored.
const int osmosisAssetsCacheVersion = 1;

final RegExp _cosmosDenom = RegExp(r'^[a-zA-Z][a-zA-Z0-9/:._-]{2,127}$');

/// One SQS row, or null when it does not parse. The cache is read back
/// through this too, so every field survives a round trip.
OsmosisListing? _toListing(Object? denom, Object? raw) {
  if (denom is! String || !_cosmosDenom.hasMatch(denom)) return null;
  if (raw is! Map) return null;
  final symbol = raw['symbol'] is String
      ? (raw['symbol'] as String).trim()
      : '';
  final decimals = raw['decimals'];
  if (symbol.isEmpty || decimals is! int || decimals < 0 || decimals > 30) {
    return null;
  }
  final rawName = raw['name'];
  final name = rawName is String && rawName.trim().isNotEmpty
      ? rawName.trim()
      : symbol;
  final rawId = raw['coinGeckoId'] ?? raw['coingeckoId'];
  final id = rawId is String ? rawId.trim() : '';
  return OsmosisListing(
    denom: denom,
    symbol: symbol.length > 24 ? symbol.substring(0, 24) : symbol,
    name: name.length > 48 ? name.substring(0, 48) : name,
    decimals: decimals,
    coinGeckoId: RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(id) && id.length <= 64
        ? id
        : null,
  );
}

/// Parse SQS `/tokens/metadata`: an object keyed by denom. Unlisted rows
/// (`preview` not false) and rows that do not parse are skipped. Sorted by
/// symbol.
List<OsmosisListing> parseOsmosisTokenMetadata(Object? body) {
  if (body is! Map) return const [];
  final out = <OsmosisListing>[];
  for (final entry in body.entries) {
    final raw = entry.value;
    if (raw is! Map || raw['preview'] != false) continue;
    final listing = _toListing(entry.key, raw);
    if (listing != null) out.add(listing);
  }
  out.sort((a, b) {
    final bySymbol = a.symbol.compareTo(b.symbol);
    return bySymbol != 0 ? bySymbol : a.denom.compareTo(b.denom);
  });
  return out;
}

/// The listed rows the bundled table proves on Osmosis and Osmosis neither
/// leaves unverified nor flags unstable, in the listing's order.
List<OsmosisAsset> osmosisSwapAssets(
  List<OsmosisListing> listed,
  SwapTokenBook book,
) {
  final rows = <String, SwapTokenTableRow>{
    for (final row in book.rowsOn(kOsmosisChainId))
      if (row.verified && row.stable) row.denom: row,
  };
  final out = <OsmosisAsset>[];
  final seen = <String>{};
  for (final listing in listed) {
    final row = rows[listing.denom];
    if (row == null || !seen.add(listing.denom)) continue;
    out.add(OsmosisAsset(listing, row));
  }
  return out;
}

Future<List<OsmosisListing>?> _readCache(DateTime now) async {
  try {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(_cacheKey);
    if (raw == null) return null;
    final record = jsonDecode(raw);
    if (record is! Map || record['version'] != osmosisAssetsCacheVersion) {
      return null;
    }
    final at = record['fetchedAt'];
    final assets = record['assets'];
    if (at is! int || assets is! List) return null;
    final age = now.millisecondsSinceEpoch - at;
    if (age < 0 || age > _cacheTtl.inMilliseconds) return null;
    return [
      for (final row in assets)
        if (row is Map) ?_toListing(row['denom'], row),
    ];
  } on Object {
    return null;
  }
}

Future<void> _writeCache(List<OsmosisListing> listed, DateTime now) async {
  try {
    final store = await SharedPreferences.getInstance();
    await store.setString(
      _cacheKey,
      jsonEncode({
        'version': osmosisAssetsCacheVersion,
        'fetchedAt': now.millisecondsSinceEpoch,
        'assets': [for (final l in listed) l.toJson()],
      }),
    );
  } on Object {
    // The list still answers from this read.
  }
}

/// The Osmosis side of the To list, filtered by the SQS listing from the
/// cache while it is under six hours old, else read from [router].
///
/// Throws the router client's [InterchainError] when there is no cached copy
/// to fall back on.
Future<List<OsmosisAsset>> listOsmosisAssets({
  required LcdClient router,
  required SwapTokenBook book,
  DateTime? now,
}) async {
  final at = now ?? DateTime.now();
  final cached = await _readCache(at);
  if (cached != null && cached.isNotEmpty) {
    return osmosisSwapAssets(cached, book);
  }
  final body = await router.getJson(
    '/tokens/metadata',
    const LcdRequestOptions(
      timeout: Duration(seconds: 15),
      cacheTtl: Duration.zero,
    ),
  );
  final listed = parseOsmosisTokenMetadata(body);
  if (listed.isNotEmpty) await _writeCache(listed, at);
  return osmosisSwapAssets(listed, book);
}
