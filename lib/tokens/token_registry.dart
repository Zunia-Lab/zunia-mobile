/// The bundled token table and the registry's canonical IBC channels.
///
/// Both come from extension 0.1.5 through `scripts/sync-extension-data.mjs`
/// (`assets/data/token-registry.json`, `assets/data/ibc-channels.json`), so
/// the phone and the extension name the same tokens and trust the same
/// channels. Every `ibc/` row was kept upstream only because
/// `sha256(path/base)` equals its hash; nothing here re-derives or edits a row.
///
/// Decoded once per process. [TokenRegistry.instance] is null until [load]
/// (or [loadFromStrings] in tests) has run, and every reader degrades to the
/// catalog alone rather than throwing while it is.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// The venue chain the table's Osmosis rows describe.
const String osmosisChainId = 'osmosis-1';

/// Bridge tags a ticker can carry (`USDC.axl`). Any other text is not a bridge.
const Set<String> tokenBridges = {
  'axl', 'grv', 'wh', 'peggy', 'eureka', 'pica', 'rt', 'carbon', 'int3', 'thor',
};

/// Networks a bridge carried a token from, when it is not Ethereum.
const Set<String> sourceNetworks = {
  'polygon', 'avax', 'arb', 'op', 'base', 'sol', 'bsc', 'tron',
};

const Map<String, String> sourceNetworkNames = {
  'polygon': 'Polygon',
  'avax': 'Avalanche',
  'arb': 'Arbitrum',
  'op': 'Optimism',
  'base': 'Base',
  'sol': 'Solana',
  'bsc': 'BNB Chain',
  'tron': 'Tron',
};

/// One decoded row of the generated table.
@immutable
class TokenTableRow {
  const TokenTableRow({
    required this.heldOnChainId,
    required this.denom,
    required this.originChainId,
    required this.originDenom,
    required this.path,
    required this.baseDenom,
    required this.channelId,
    required this.counterpartyChainId,
    required this.counterpartyChannelId,
    required this.family,
    required this.bridge,
    required this.sourceNetwork,
    required this.alloyed,
    required this.verified,
    required this.stable,
    required this.decimals,
    required this.logoUrl,
    required this.coinGeckoId,
    required this.variantGroup,
    required this.aliases,
  });

  final String heldOnChainId;

  /// Bank denom on the holding chain (`ibc/` hashes uppercase).
  final String denom;

  /// The issuer as the source lists it. On a multi-hop Osmosis row that is the
  /// chain one hop back, which may only have relayed the token; the identity
  /// names the further issuer when the table holds the relay's row.
  final String originChainId;

  /// The issuer's exact, hash-verified denom. Never rebuilt from the catalog,
  /// whose erc20 spellings are lowercase.
  final String originDenom;

  /// Trace path on the holding chain, `''` for a local denom.
  final String path;

  /// The trace's base denom; equals [originDenom] for one hop.
  final String baseDenom;

  /// First hop's channel on the holding chain; null for a light-client hop.
  final String? channelId;

  /// Chain at the other end of [channelId]; null when there is no channel hop.
  final String? counterpartyChainId;
  final String? counterpartyChannelId;
  final String family;
  final String? bridge;
  final String? sourceNetwork;
  final bool alloyed;

  /// Osmosis lists the row as verified (every hub-chain row counts as verified).
  final bool verified;

  /// Not flagged unstable or disabled by Osmosis.
  final bool stable;
  final int decimals;
  final String? logoUrl;
  final String? coinGeckoId;
  final String? variantGroup;
  final List<String> aliases;
}

/// One canonical transfer channel, as cosmos/chain-registry `_IBC` names it.
@immutable
class IbcChannelRow {
  const IbcChannelRow({
    required this.sourceChainId,
    required this.channelId,
    required this.destChainId,
    required this.counterpartyChannelId,
  });

  final String sourceChainId;
  final String channelId;
  final String destChainId;
  final String counterpartyChannelId;
}

/// The decoded table and its lookups. Built once; never mutated.
class TokenRegistry {
  TokenRegistry._({
    required this.rows,
    required this.byKey,
    required this.byChain,
    required this.osmosisByOrigin,
    required this.issuerRows,
    required this.issuerDenoms,
    required this.issuerSpellings,
    required this.channels,
    required this.chains,
    required this.catalogLogos,
    required this.channelRows,
  });

  static TokenRegistry? _instance;

  /// The loaded registry, or null before [load].
  static TokenRegistry? get instance => _instance;

  static bool get isLoaded => _instance != null;

  /// Reads both assets from the bundle. Safe to call twice.
  static Future<TokenRegistry> load() async {
    final existing = _instance;
    if (existing != null) return existing;
    final tokens = await rootBundle.loadString('assets/data/token-registry.json');
    final channels = await rootBundle.loadString('assets/data/ibc-channels.json');
    return loadFromStrings(tokens, channels);
  }

  /// Decodes the two documents and installs the result as [instance].
  static TokenRegistry loadFromStrings(String tokensJson, String channelsJson) {
    final registry = _decode(
      jsonDecode(tokensJson) as Map<String, dynamic>,
      jsonDecode(channelsJson) as Map<String, dynamic>,
    );
    _instance = registry;
    return registry;
  }

  /// Drops the loaded registry. Tests only.
  @visibleForTesting
  static void reset() => _instance = null;

  final List<TokenTableRow> rows;

  /// `chainId:denomKey` → row.
  final Map<String, TokenTableRow> byKey;
  final Map<String, List<TokenTableRow>> byChain;

  /// `originChainId:originDenom` → the canonical Osmosis voucher.
  final Map<String, TokenTableRow> osmosisByOrigin;

  /// `originChainId:denomKey(originDenom)` → the best voucher row whose first
  /// hop lands on its issuer: the proof the issuer holds that exact denom.
  final Map<String, TokenTableRow> issuerRows;

  /// Issuer chain → the denoms [issuerRows] proves there.
  final Map<String, List<String>> issuerDenoms;

  /// `originChainId:folded erc20/peggy denom` → its one proven spelling.
  final Map<String, String> issuerSpellings;

  /// `chainId:channelId` → the chain at the other end, from first hops.
  final Map<String, String> channels;

  /// Chain id → (display name, bech32 prefix) for every chain a row names.
  final Map<String, (String, String)> chains;

  /// Chain id → (denom, erc20 and peggy lowercased) → logo URL.
  final Map<String, Map<String, String>> catalogLogos;

  /// The registry's canonical transfer channels, every direction listed.
  final List<IbcChannelRow> channelRows;

  Map<String, List<String>>? _canonicalIndex;
  Map<String, String>? _canonicalEnds;
  Set<String>? _canonicalHops;

  TokenTableRow? row(String chainId, String denom) =>
      byKey['$chainId:${denomKey(denom)}'];

  List<TokenTableRow> rowsOn(String? heldOnChainId) => heldOnChainId == null
      ? rows
      : (byChain[heldOnChainId] ?? const <TokenTableRow>[]);

  /// The canonical channel ids leaving [sourceChainId] for [destChainId].
  /// Almost always one; empty when the registry names none.
  List<String> canonicalChannelIds(String sourceChainId, String destChainId) {
    final index = _canonicalIndex ??= () {
      final out = <String, List<String>>{};
      for (final route in channelRows) {
        final ids = out.putIfAbsent(
          '${route.sourceChainId}\u0000${route.destChainId}',
          () => <String>[],
        );
        if (!ids.contains(route.channelId)) ids.add(route.channelId);
      }
      return out;
    }();
    return index['$sourceChainId\u0000$destChainId'] ?? const [];
  }

  /// The channel id at the other end of [channelId] on [chainId], from the
  /// canonical table. A channel's counterparty is fixed when it opens.
  String? canonicalCounterpartyChannel(String chainId, String channelId) {
    final ends = _canonicalEnds ??= {
      for (final row in channelRows)
        '${row.sourceChainId}|${row.channelId}': row.counterpartyChannelId,
    };
    return ends['$chainId|$channelId'];
  }

  /// The registry's far end of a canonical channel, keyed by direction.
  String? canonicalFarEnd(String sourceChainId, String destChainId, String channelId) {
    for (final row in channelRows) {
      if (row.sourceChainId == sourceChainId &&
          row.destChainId == destChainId &&
          row.channelId == channelId) {
        return row.counterpartyChannelId.isEmpty ? null : row.counterpartyChannelId;
      }
    }
    return null;
  }

  /// Whether the registry names [channelId] on [chainId] as the canonical
  /// channel to [counterparty].
  bool isCanonicalHop(String chainId, String channelId, String counterparty) {
    final hops = _canonicalHops ??= {
      for (final row in channelRows)
        '${row.sourceChainId}|${row.channelId}|${row.destChainId}',
    };
    return hops.contains('$chainId|$channelId|$counterparty');
  }
}

/* -------------------------------------------------------------------------- *
 * IBC arithmetic shared with the identity module
 * -------------------------------------------------------------------------- */

bool isIbcDenom(String denom) => denom.startsWith('ibc/');

/// Table and cache key: `ibc/` hashes uppercase, every other denom exact.
String denomKey(String denom) =>
    isIbcDenom(denom) ? 'ibc/${denom.substring(4).toUpperCase()}' : denom;

final RegExp _foldable = RegExp(r'^(erc20:|peggy)', caseSensitive: false);

/// erc20 and peggy denoms lowercased, for spelling lookups only.
String foldDenom(String denom) =>
    _foldable.hasMatch(denom) ? denom.toLowerCase() : denom;

final RegExp _firstChannel = RegExp(r'^[^/]+/(channel-\d+)(?:/|$)');

String? firstChannelOf(String path) => _firstChannel.firstMatch(path)?.group(1);

/* -------------------------------------------------------------------------- *
 * Decoding
 * -------------------------------------------------------------------------- */

final RegExp _compressedPath = RegExp(r'^\d+(/\d+)*$');

/// `122/52` → `transfer/channel-122/transfer/channel-52`; a full path stays.
String _expandPath(String value) {
  if (!_compressedPath.hasMatch(value)) return value;
  return value.split('/').map((channel) => 'transfer/channel-$channel').join('/');
}

String? _expandLogo(String? value, List<String> prefixes) {
  if (value == null || value.isEmpty) return null;
  final first = value.codeUnitAt(0);
  if (first >= 0x30 && first <= 0x39) {
    final index = first - 0x30;
    if (index < prefixes.length) return '${prefixes[index]}${value.substring(1)}';
  }
  return value;
}

/// Lower is better when several Osmosis vouchers carry one origin asset.
int _osmosisRank(TokenTableRow row) {
  final hops = row.path.split('/').length ~/ 2;
  return (row.verified ? 0 : 4) + (row.stable ? 0 : 2) + (hops > 1 ? 1 : 0);
}

TokenRegistry _decode(Map<String, dynamic> tokens, Map<String, dynamic> channelsDoc) {
  // familyOf lives in the identity module, which imports this one; the table
  // keeps the issuer symbol as listed and the identity module reads the family
  // from it through [tokenFamilyOf].
  final prefixes = [
    for (final value in tokens['logoPrefixes'] as List<dynamic>) value as String,
  ];
  final chainRows = [
    for (final value in tokens['chains'] as List<dynamic>)
      [for (final part in value as List<dynamic>) part as String],
  ];
  final logos = [for (final value in tokens['logos'] as List<dynamic>) value as String];
  final groups = [for (final value in tokens['groups'] as List<dynamic>) value as String];

  String chainAt(int index) =>
      index >= 0 && index < chainRows.length ? chainRows[index][0] : '';

  final rows = <TokenTableRow>[];
  for (final raw in tokens['rows'] as List<dynamic>) {
    final t = raw as List<dynamic>;
    final heldOnChainId = chainAt(t[0] as int);
    final denom = t[1] as String;
    final originChainId = chainAt(t[2] as int);
    final originDenom = (t[3] as String).isEmpty ? denom : t[3] as String;
    final path = _expandPath(t[4] as String);
    final channelId = firstChannelOf(path);
    final flags = t[11] as int;
    final alloyed = (flags & 1) != 0;
    final aliasText = t[16] as String;
    final bridge = t[9] as String;
    final network = t[10] as String;
    final logoIndex = t[13] as int;
    final groupIndex = t[15] as int;
    final counterpartyIndex = t[6] as int;
    final counterpartyChannel = t[7] as int;
    final coinGeckoId = t[14] as String;
    rows.add(TokenTableRow(
      heldOnChainId: heldOnChainId,
      denom: denom,
      originChainId: originChainId,
      originDenom: originDenom,
      path: path,
      baseDenom: (t[5] as String).isEmpty ? originDenom : t[5] as String,
      channelId: channelId,
      // -1 means "the origin" only behind a channel: a light-client hop (the
      // Hub's Eureka `transfer/08-wasm-1369`) leads off Cosmos, to no chain id.
      counterpartyChainId: counterpartyIndex >= 0
          ? chainAt(counterpartyIndex)
          : channelId != null
              ? originChainId
              : null,
      counterpartyChannelId:
          counterpartyChannel >= 0 ? 'channel-$counterpartyChannel' : null,
      family: tokenFamilyOf(t[8] as String),
      bridge: tokenBridges.contains(bridge) ? bridge : null,
      sourceNetwork: sourceNetworks.contains(network) ? network : null,
      alloyed: alloyed,
      verified: (flags & 2) != 0,
      stable: (flags & 4) != 0,
      decimals: t[12] as int,
      logoUrl: logoIndex >= 0 && logoIndex < logos.length
          ? _expandLogo(logos[logoIndex], prefixes)
          : null,
      coinGeckoId: coinGeckoId.isEmpty ? null : coinGeckoId,
      variantGroup: groupIndex >= 0 && groupIndex < groups.length
          ? groups[groupIndex]
          : alloyed
              ? denom
              : null,
      aliases: aliasText.isEmpty ? const [] : aliasText.split('|'),
    ));
  }

  final byKey = <String, TokenTableRow>{};
  final byChain = <String, List<TokenTableRow>>{};
  final osmosisByOrigin = <String, TokenTableRow>{};
  final issuerRows = <String, TokenTableRow>{};
  final channels = <String, String>{};
  for (final row in rows) {
    byKey['${row.heldOnChainId}:${denomKey(row.denom)}'] = row;
    byChain.putIfAbsent(row.heldOnChainId, () => <TokenTableRow>[]).add(row);
    final channelId = row.channelId;
    final counterparty = row.counterpartyChainId;
    if (channelId != null && counterparty != null) {
      channels.putIfAbsent('${row.heldOnChainId}:$channelId', () => counterparty);
    }
    if (row.heldOnChainId == osmosisChainId && row.path.isNotEmpty) {
      final key = '${row.originChainId}:${row.originDenom}';
      final best = osmosisByOrigin[key];
      if (best == null || _osmosisRank(row) < _osmosisRank(best)) {
        osmosisByOrigin[key] = row;
      }
    }
    if (channelId != null &&
        counterparty == row.originChainId &&
        row.originChainId != row.heldOnChainId) {
      // Osmosis rows first: its listing carries the verified flags and logos.
      final key = '${row.originChainId}:${denomKey(row.originDenom)}';
      final best = issuerRows[key];
      int rank(TokenTableRow candidate) =>
          (candidate.heldOnChainId == osmosisChainId ? 0 : 8) + _osmosisRank(candidate);
      if (best == null || rank(row) < rank(best)) issuerRows[key] = row;
    }
  }

  final issuerDenoms = <String, List<String>>{};
  final issuerSpellings = <String, String>{};
  for (final row in issuerRows.values) {
    issuerDenoms.putIfAbsent(row.originChainId, () => <String>[]).add(row.originDenom);
    final folded = foldDenom(row.originDenom);
    if (folded != row.originDenom) {
      issuerSpellings['${row.originChainId}:$folded'] = row.originDenom;
    }
  }

  final chains = <String, (String, String)>{
    for (final row in chainRows) row[0]: (row[1], row[2]),
  };

  final catalogLogos = <String, Map<String, String>>{};
  for (final raw in tokens['catalogLogos'] as List<dynamic>) {
    final entry = raw as List<dynamic>;
    final chainId = entry[0] as String;
    final dir = entry[1] as String;
    final logosOnChain = <String, String>{};
    for (final item in entry[2] as List<dynamic>) {
      final parts = item as List<dynamic>;
      final denom = parts[0] as String;
      final String? url = parts.length == 2
          ? _expandLogo(
              (parts[1] as int) < logos.length ? logos[parts[1] as int] : null,
              prefixes,
            )
          : '${prefixes.length > 1 ? prefixes[1] : ''}$dir/${denom.replaceAll(':', '/')}.png';
      if (url != null) logosOnChain[foldDenom(denom)] = url;
    }
    catalogLogos[chainId] = logosOnChain;
  }

  final channelRows = <IbcChannelRow>[
    for (final raw in channelsDoc['rows'] as List<dynamic>)
      () {
        final parts = raw as List<dynamic>;
        return IbcChannelRow(
          sourceChainId: parts[0] as String,
          channelId: parts[1] as String,
          destChainId: parts[2] as String,
          counterpartyChannelId: parts[3] as String,
        );
      }(),
  ];

  return TokenRegistry._(
    rows: List.unmodifiable(rows),
    byKey: byKey,
    byChain: byChain,
    osmosisByOrigin: osmosisByOrigin,
    issuerRows: issuerRows,
    issuerDenoms: issuerDenoms,
    issuerSpellings: issuerSpellings,
    channels: channels,
    chains: chains,
    catalogLogos: catalogLogos,
    channelRows: List.unmodifiable(channelRows),
  );
}

/* -------------------------------------------------------------------------- *
 * Families
 * -------------------------------------------------------------------------- */

/// Ticker suffixes that decorate a family rather than name it (`USDC.e.matic.axl`).
const Set<String> _decorations = {
  'n', 'inj', 'axl', 'grv', 'wh', 'peggy', 'pica', 'eureka', 'kava', 'osmo', 'noble', 'atom',
  'eth', 'sol', 'avax', 'matic', 'polygon', 'arb', 'op', 'base', 'bsc', 'tron', 'rt', 'int3',
  'carbon', 'terra', 'e', 'gravity', 'wormhole', 'axelar', 'cosmos',
};

final RegExp _axlPrefix = RegExp(r'^axl(?=[A-Z])');
final RegExp _networkWordPrefix =
    RegExp(r'^(Polygon|Avalanche|Arbitrum|Optimism|Base|Binance)(?=[A-Z])');
final RegExp _networkDotPrefix = RegExp(
  r'^(solana|avalanche|polygon|arbitrum|optimism|base|ethereum|binance|bsc)\.(?=[A-Za-z])',
);

/// The asset a symbol names, without issuer decorations: `axlUSDC`,
/// `PolygonUSDC.axl`, `solana.USDC.wh`, `USDC.e.matic.axl` and `USDC.n` are
/// all `USDC`. Wrapped ETH goes to its root (`WETH` → `ETH`), and Tether's
/// `USDt` is `USDT`.
String tokenFamilyOf(String symbol) {
  var text = symbol.trim();
  text = text.replaceFirst(_axlPrefix, '');
  text = text.replaceFirst(_networkWordPrefix, '');
  text = text.replaceFirst(_networkDotPrefix, '');
  final parts = text.split('.');
  while (parts.length > 1 && _decorations.contains(parts.last.toLowerCase())) {
    parts.removeLast();
  }
  text = parts.join('.');
  final lower = text.toLowerCase();
  if (lower == 'usdt') return 'USDT';
  if (lower == 'usdc') return 'USDC';
  if (lower == 'eth' || lower == 'weth') return 'ETH';
  if (lower == 'wbtc') return 'WBTC';
  return text.isEmpty ? symbol : text;
}
