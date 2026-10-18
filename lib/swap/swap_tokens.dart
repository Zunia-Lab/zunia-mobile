/// What a token is, for Swap: the one adapter between a bank denom and the
/// name, exponent, logo and Osmosis denom the swap screens and messages use.
///
/// INTEGRATION NOTE: the portfolio workstream ports the extension's full
/// token identity (`lib/token-identity.ts`). Until it lands on this branch,
/// this file reads the same bundled, hash-verified table
/// (`assets/data/token-registry.json`, `ibc-channels.json`) with a reduced
/// version of the extension's rules. Everything Swap reads goes through
/// [SwapTokenBook.identityOf] and [SwapTokenIdentity], so switching to the
/// shared identity means re-implementing those two and nothing else.
///
/// Display and naming only, with two exceptions that are proofs, not guesses:
/// [SwapTokenIdentity.osmosisDenom] (the table's hash-verified voucher, or the
/// held denom on Osmosis) and [SwapTokenTableRow.originDenom] (the exact denom
/// one hop back). Signed denoms come from the bank or from those two, never
/// from a ticker or from the catalog's lowercased erc20 spellings.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:zunia_mobile/chains/chain_catalog.dart';

/// The venue chain the table's Osmosis rows describe.
const String kOsmosisChainId = 'osmosis-1';

/// One decoded row of the generated table (the extension's `TokenTableRow`).
@immutable
class SwapTokenTableRow {
  const SwapTokenTableRow({
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
    required this.aliases,
  });

  final String heldOnChainId;

  /// Bank denom on the holding chain (`ibc/` hashes uppercase).
  final String denom;
  final String originChainId;

  /// The issuer's exact, hash-verified denom. When
  /// `counterpartyChainId == originChainId` it is the denom one hop back, so
  /// unwinding over [channelId] delivers exactly it on the issuer.
  final String originDenom;

  /// Trace path on the holding chain, `''` for a local denom.
  final String path;
  final String baseDenom;

  /// First hop's channel on the holding chain.
  final String? channelId;
  final String? counterpartyChainId;
  final String? counterpartyChannelId;
  final String family;
  final String? bridge;
  final String? sourceNetwork;
  final bool alloyed;

  /// Osmosis lists the row as verified.
  final bool verified;

  /// Not flagged unstable or disabled by Osmosis.
  final bool stable;
  final int decimals;
  final String? logoUrl;
  final String? coinGeckoId;
  final List<String> aliases;
}

/// What a token is and where it is (the extension's `TokenIdentity`, reduced
/// to what Swap reads).
@immutable
class SwapTokenIdentity {
  const SwapTokenIdentity({
    required this.chainId,
    required this.chainName,
    required this.denom,
    required this.ticker,
    required this.family,
    required this.name,
    required this.decimals,
    required this.decimalsKnown,
    required this.logoUrl,
    required this.originChainId,
    required this.originChainName,
    required this.originDenom,
    required this.osmosisDenom,
    required this.proven,
    required this.known,
    required this.testnet,
    required this.coinGeckoId,
    required this.aliases,
  });

  /// `${chainId}:${denom}`, the key of every swap row.
  String get key => '$chainId:$denom';

  /// Where the balance lives, or where a destination is delivered.
  final String chainId;
  final String chainName;

  /// The exact bank denom, never case-folded.
  final String denom;

  /// `USDC.inj`, `ATOM`, `allUSDC`; `IBC·498A` when nothing names it.
  final String ticker;

  /// The asset without its issuer decorations: `USDC` for USDC.n.
  final String family;

  /// `Noble USDC`, or the ticker when nothing better is known.
  final String name;

  /// Display exponent; 0 when unknown, and amounts then read in base units.
  final int decimals;
  final bool decimalsKnown;
  final String? logoUrl;
  final String? originChainId;
  final String? originChainName;
  final String? originDenom;

  /// This asset's denom on osmosis-1: the held denom there, else the table's
  /// canonical voucher. Null when Osmosis does not hold it.
  final String? osmosisDenom;

  /// Origin and name both come from the catalog or the hash-verified table.
  final bool proven;

  /// Something names the token (false for a voucher nothing traces).
  final bool known;

  /// Held on a testnet or a chain the user added.
  final bool testnet;
  final String? coinGeckoId;

  /// Other names users have seen (`USDC.noble`, `axlUSDC`), for search.
  final List<String> aliases;

  /// The picker's second line: where it is from and where it is.
  String get subtitle {
    if (!known) return 'Unverified token · on $chainName';
    final origin = originChainId;
    if (origin == null || origin == chainId) return 'Native on $chainName';
    return '${originChainName ?? origin} $family · on $chainName';
  }

  /// The identity with a different exponent: SQS vetoed the table's.
  SwapTokenIdentity withDecimals(int? value) => SwapTokenIdentity(
    chainId: chainId,
    chainName: chainName,
    denom: denom,
    ticker: ticker,
    family: family,
    name: name,
    decimals: value ?? 0,
    decimalsKnown: value != null,
    logoUrl: logoUrl,
    originChainId: originChainId,
    originChainName: originChainName,
    originDenom: originDenom,
    osmosisDenom: osmosisDenom,
    proven: proven,
    known: known,
    testnet: testnet,
    coinGeckoId: coinGeckoId,
    aliases: aliases,
  );
}

/// A canonical transfer channel from the chain registry.
@immutable
class CanonicalChannel {
  const CanonicalChannel({
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

/* -------------------------------------------------------------------------- *
 * Ticker rule (the extension's `tickerFor`, reduced)
 * -------------------------------------------------------------------------- */

const Set<String> _multiIssuer = {'USDC', 'USDT', 'DAI', 'ETH', 'WBTC', 'BTC'};

const Map<String, String> _issuerTag = {
  'noble-1': 'n',
  'injective-1': 'inj',
  'kava_2222-10': 'kava',
  'osmosis-1': 'osmo',
};

const Set<String> _decorations = {
  'n', 'inj', 'axl', 'grv', 'wh', 'peggy', 'pica', 'eureka', 'kava', 'osmo', //
  'noble', 'atom', 'eth', 'sol', 'avax', 'matic', 'polygon', 'arb', 'op',
  'base', 'bsc', 'tron', 'rt', 'int3', 'carbon', 'terra', 'e', 'gravity',
  'wormhole', 'axelar', 'cosmos',
};

const Set<String> _bridges = {
  'axl',
  'grv',
  'wh',
  'peggy',
  'eureka',
  'pica',
  'rt',
  'carbon',
  'int3',
  'thor',
};

const Set<String> _networks = {
  'polygon',
  'avax',
  'arb',
  'op',
  'base',
  'sol',
  'bsc',
  'tron',
};

/// The asset a symbol names, without issuer decorations: `axlUSDC`,
/// `PolygonUSDC.axl` and `USDC.n` are all `USDC`.
String tokenFamilyOf(String symbol) {
  var text = symbol.trim();
  text = text.replaceFirst(RegExp(r'^axl(?=[A-Z])'), '');
  text = text.replaceFirst(
    RegExp(r'^(Polygon|Avalanche|Arbitrum|Optimism|Base|Binance)(?=[A-Z])'),
    '',
  );
  text = text.replaceFirst(
    RegExp(
      r'^(solana|avalanche|polygon|arbitrum|optimism|base|ethereum|binance|bsc)\.(?=[A-Za-z])',
    ),
    '',
  );
  final parts = text.split('.');
  while (parts.length > 1 && _decorations.contains(parts.last.toLowerCase())) {
    parts.removeLast();
  }
  text = parts.join('.');
  if (RegExp(r'^usdt$', caseSensitive: false).hasMatch(text)) return 'USDT';
  if (RegExp(r'^usdc$', caseSensitive: false).hasMatch(text)) return 'USDC';
  if (RegExp(r'^w?eth$', caseSensitive: false).hasMatch(text)) return 'ETH';
  if (RegExp(r'^wbtc$', caseSensitive: false).hasMatch(text)) return 'WBTC';
  return text.isEmpty ? symbol : text;
}

/* -------------------------------------------------------------------------- *
 * The book
 * -------------------------------------------------------------------------- */

/// The bundled token table and canonical channels, indexed for Swap.
class SwapTokenBook {
  SwapTokenBook._({
    required this.rows,
    required Map<String, SwapTokenTableRow> byKey,
    required Map<String, SwapTokenTableRow> osmosisByOrigin,
    required Map<String, SwapTokenTableRow> issuerRows,
    required Map<String, (String, String)> chains,
    required Map<String, Map<String, String>> catalogLogos,
    required List<CanonicalChannel> channels,
    required List<ChainEntry> catalog,
    required Set<String> customChainIds,
  }) : _byKey = byKey,
       _osmosisByOrigin = osmosisByOrigin,
       _issuerRows = issuerRows,
       _chains = chains,
       _catalogLogos = catalogLogos,
       _channels = channels,
       _catalog = {for (final entry in catalog) entry.chainId: entry},
       _customChainIds = customChainIds {
    _homeIssuers = _buildHomeIssuers(catalog);
  }

  final List<SwapTokenTableRow> rows;
  final Map<String, SwapTokenTableRow> _byKey;
  final Map<String, SwapTokenTableRow> _osmosisByOrigin;
  final Map<String, SwapTokenTableRow> _issuerRows;
  final Map<String, (String, String)> _chains;
  final Map<String, Map<String, String>> _catalogLogos;
  final List<CanonicalChannel> _channels;
  final Map<String, ChainEntry> _catalog;
  final Set<String> _customChainIds;
  late final Map<String, String> _homeIssuers;
  final Map<String, SwapTokenIdentity> _identities = {};

  /// Read both bundled files. [catalog] is the bundled chain list (custom
  /// chains are passed separately: they are never an issuer).
  static Future<SwapTokenBook> load(
    AssetBundle bundle, {
    required List<ChainEntry> catalog,
    List<ChainEntry> custom = const [],
  }) async {
    final tokens = jsonDecode(
      await bundle.loadString('assets/data/token-registry.json'),
    );
    final channels = jsonDecode(
      await bundle.loadString('assets/data/ibc-channels.json'),
    );
    if (tokens is! Map<String, Object?> || channels is! Map<String, Object?>) {
      throw const FormatException('assets/data: token table is not an object');
    }
    return SwapTokenBook.decode(
      tokens,
      channels,
      catalog: catalog,
      custom: custom,
    );
  }

  /// Decode the documents [load] reads.
  factory SwapTokenBook.decode(
    Map<String, Object?> tokens,
    Map<String, Object?> channelsDoc, {
    required List<ChainEntry> catalog,
    List<ChainEntry> custom = const [],
  }) {
    List<Object?> list(Object? value) => value is List ? value : const [];
    final prefixes = [for (final p in list(tokens['logoPrefixes'])) '$p'];
    final logos = [for (final l in list(tokens['logos'])) '$l'];
    final chainRows = [
      for (final row in list(tokens['chains']))
        if (row is List && row.length >= 3)
          ['${row[0]}', '${row[1]}', '${row[2]}'],
    ];
    String chainAt(int index) =>
        index >= 0 && index < chainRows.length ? chainRows[index][0] : '';
    String? logoOf(String? value) {
      if (value == null || value.isEmpty) return null;
      final first = value.codeUnitAt(0);
      if (first >= 0x30 && first <= 0x39) {
        final index = first - 0x30;
        if (index < prefixes.length) {
          return '${prefixes[index]}${value.substring(1)}';
        }
      }
      return value;
    }

    String expandPath(String value) {
      if (!RegExp(r'^\d+(/\d+)*$').hasMatch(value)) return value;
      return value.split('/').map((c) => 'transfer/channel-$c').join('/');
    }

    final rows = <SwapTokenTableRow>[];
    for (final raw in list(tokens['rows'])) {
      if (raw is! List || raw.length < 17) continue;
      int number(int i) => raw[i] is int ? raw[i] as int : -1;
      String text(int i) => raw[i] is String ? raw[i] as String : '';
      final denom = text(1);
      final path = expandPath(text(4));
      final channelId = RegExp(
        r'^[^/]+/(channel-\d+)(?:/|$)',
      ).firstMatch(path)?.group(1);
      final originChainId = chainAt(number(2));
      final flags = number(11);
      final bridge = text(9);
      final network = text(10);
      rows.add(
        SwapTokenTableRow(
          heldOnChainId: chainAt(number(0)),
          denom: denom,
          originChainId: originChainId,
          originDenom: text(3).isEmpty ? denom : text(3),
          path: path,
          baseDenom: text(5).isEmpty
              ? (text(3).isEmpty ? denom : text(3))
              : text(5),
          channelId: channelId,
          counterpartyChainId: number(6) >= 0
              ? chainAt(number(6))
              : channelId != null
              ? originChainId
              : null,
          counterpartyChannelId: number(7) >= 0 ? 'channel-${number(7)}' : null,
          family: tokenFamilyOf(text(8)),
          bridge: _bridges.contains(bridge) ? bridge : null,
          sourceNetwork: _networks.contains(network) ? network : null,
          alloyed: flags >= 0 && (flags & 1) != 0,
          verified: flags >= 0 && (flags & 2) != 0,
          stable: flags >= 0 && (flags & 4) != 0,
          decimals: number(12),
          logoUrl: number(13) >= 0 && number(13) < logos.length
              ? logoOf(logos[number(13)])
              : null,
          coinGeckoId: text(14).isEmpty ? null : text(14),
          aliases: text(16).isEmpty ? const [] : text(16).split('|'),
        ),
      );
    }

    int osmosisRank(SwapTokenTableRow row) {
      final hops = row.path.split('/').length ~/ 2;
      return (row.verified ? 0 : 4) + (row.stable ? 0 : 2) + (hops > 1 ? 1 : 0);
    }

    final byKey = <String, SwapTokenTableRow>{};
    final osmosisByOrigin = <String, SwapTokenTableRow>{};
    final issuerRows = <String, SwapTokenTableRow>{};
    for (final row in rows) {
      byKey['${row.heldOnChainId}:${_denomKey(row.denom)}'] = row;
      if (row.heldOnChainId == kOsmosisChainId && row.path.isNotEmpty) {
        final key = '${row.originChainId}:${row.originDenom}';
        final best = osmosisByOrigin[key];
        if (best == null || osmosisRank(row) < osmosisRank(best)) {
          osmosisByOrigin[key] = row;
        }
      }
      if (row.channelId != null &&
          row.counterpartyChainId == row.originChainId &&
          row.originChainId != row.heldOnChainId) {
        final key = '${row.originChainId}:${_denomKey(row.originDenom)}';
        final best = issuerRows[key];
        int rank(SwapTokenTableRow r) =>
            (r.heldOnChainId == kOsmosisChainId ? 0 : 8) + osmosisRank(r);
        if (best == null || rank(row) < rank(best)) issuerRows[key] = row;
      }
    }

    final catalogLogos = <String, Map<String, String>>{};
    for (final raw in list(tokens['catalogLogos'])) {
      if (raw is! List || raw.length < 3) continue;
      final chainId = '${raw[0]}';
      final dir = '${raw[1]}';
      final entries = <String, String>{};
      for (final entry in list(raw[2])) {
        if (entry is! List || entry.isEmpty) continue;
        final denom = '${entry[0]}';
        final url = entry.length == 2 && entry[1] is int
            ? (entry[1] as int) < logos.length
                  ? logoOf(logos[entry[1] as int])
                  : null
            : prefixes.length > 1
            ? '${prefixes[1]}$dir/${denom.replaceAll(':', '/')}.png'
            : null;
        if (url != null) entries[_foldDenom(denom)] = url;
      }
      catalogLogos[chainId] = entries;
    }

    final channels = <CanonicalChannel>[
      for (final raw in list(channelsDoc['rows']))
        if (raw is List && raw.length >= 4)
          CanonicalChannel(
            sourceChainId: '${raw[0]}',
            channelId: '${raw[1]}',
            destChainId: '${raw[2]}',
            counterpartyChannelId: '${raw[3]}',
          ),
    ];

    return SwapTokenBook._(
      rows: List.unmodifiable(rows),
      byKey: byKey,
      osmosisByOrigin: osmosisByOrigin,
      issuerRows: issuerRows,
      chains: {for (final c in chainRows) c[0]: (c[1], c[2])},
      catalogLogos: catalogLogos,
      channels: channels,
      catalog: [...catalog, ...custom],
      customChainIds: {for (final c in custom) c.chainId},
    );
  }

  /* ------------------------------------------------------------------------ */

  /// The table's rows held on [chainId].
  Iterable<SwapTokenTableRow> rowsOn(String chainId) =>
      rows.where((row) => row.heldOnChainId == chainId);

  SwapTokenTableRow? rowOf(String chainId, String denom) =>
      _byKey['$chainId:${_denomKey(denom)}'];

  /// The asset's denom on osmosis-1: the origin denom when Osmosis is the
  /// issuer, else the canonical voucher the table lists (verified and stable
  /// first). Exact match only.
  String? osmosisDenomOf(String originChainId, String originDenom) {
    if (originChainId.isEmpty || originDenom.isEmpty) return null;
    if (originChainId == kOsmosisChainId) return originDenom;
    return _osmosisByOrigin['$originChainId:$originDenom']?.denom;
  }

  /// The registry's canonical channel on [sourceChainId] to [destChainId].
  CanonicalChannel? canonicalChannel(String sourceChainId, String destChainId) {
    for (final row in _channels) {
      if (row.sourceChainId == sourceChainId &&
          row.destChainId == destChainId) {
        return row;
      }
    }
    return null;
  }

  /// Whether the registry names [channelId] on [sourceChainId] as the
  /// canonical channel to [destChainId].
  bool isCanonicalChannel(
    String sourceChainId,
    String destChainId,
    String channelId,
  ) => _channels.any(
    (row) =>
        row.sourceChainId == sourceChainId &&
        row.destChainId == destChainId &&
        row.channelId == channelId,
  );

  String chainNameOf(String chainId) =>
      _catalog[chainId]?.chainName ?? _chains[chainId]?.$1 ?? chainId;

  String _prefixOf(String chainId) =>
      _catalog[chainId]?.bech32Prefix ?? _chains[chainId]?.$2 ?? '';

  bool _neverIssuer(String chainId) =>
      _customChainIds.contains(chainId) ||
      (_catalog[chainId]?.isTestnet ?? false);

  bool isTestnetChain(String chainId) => _neverIssuer(chainId);

  static Map<String, String> _buildHomeIssuers(List<ChainEntry> catalog) {
    final byFamily = <String, List<ChainEntry>>{};
    for (final entry in catalog) {
      if (entry.network != 'mainnet') continue;
      if (RegExp(r'^(ibc|l2)/').hasMatch(entry.coinMinimalDenom)) continue;
      byFamily.putIfAbsent(tokenFamilyOf(entry.coinDenom), () => []).add(entry);
    }
    final out = <String, String>{};
    for (final MapEntry(:key, :value) in byFamily.entries) {
      final listed = value.length > 1
          ? value.where((e) => e.inCosmosRegistry).toList()
          : value;
      if (listed.length == 1) out[key] = listed.first.chainId;
    }
    return out;
  }

  /// The ticker rule: an alloy is `all` + family, a bridged asset takes the
  /// bridge tag, a multi-issuer family takes the issuer tag (`USDC.n`), any
  /// other family is bare on its home issuer and tagged elsewhere.
  String _tickerFor({
    required String family,
    required String? originChainId,
    String? bridge,
    String? sourceNetwork,
    bool alloyed = false,
  }) {
    if (alloyed) return 'all$family';
    if (originChainId != null && _neverIssuer(originChainId)) return family;
    if (bridge != null) {
      final network = sourceNetwork != null && _multiIssuer.contains(family)
          ? '.$sourceNetwork'
          : '';
      return '$family.$bridge$network';
    }
    if (originChainId == null) return family;
    String tag() {
      final prefix = _prefixOf(originChainId);
      return _issuerTag[originChainId] ??
          (prefix.isEmpty ? originChainId : prefix);
    }

    if (_multiIssuer.contains(family)) return '$family.${tag()}';
    final home = _homeIssuers[family];
    return home == null || home == originChainId ? family : '$family.${tag()}';
  }

  /// What the denom is, on the chain that holds it. Never throws; a denom
  /// nothing names reads as unknown, with its decimals unknown.
  SwapTokenIdentity identityOf(String chainId, String denom) {
    final key = '$chainId:$denom';
    return _identities[key] ??= _resolve(chainId, denom);
  }

  SwapTokenIdentity _resolve(String chainId, String denom) {
    final chainName = chainNameOf(chainId);
    final testnet = _neverIssuer(chainId);
    final entry = _catalog[chainId];

    SwapTokenIdentity build({
      required String family,
      required String ticker,
      required int? decimals,
      required String? logoUrl,
      required String originChainId,
      required String originDenom,
      required bool proven,
      String? coinGeckoId,
      List<String> aliases = const [],
    }) {
      final originName = chainNameOf(originChainId);
      final osmosis = chainId == kOsmosisChainId
          ? denom
          : osmosisDenomOf(originChainId, originDenom);
      return SwapTokenIdentity(
        chainId: chainId,
        chainName: chainName,
        denom: denom,
        ticker: ticker,
        family: family,
        name: originChainId == chainId ? ticker : '$originName $family',
        decimals: decimals ?? 0,
        decimalsKnown: decimals != null,
        logoUrl: logoUrl,
        originChainId: originChainId,
        originChainName: originName,
        originDenom: originDenom,
        osmosisDenom: osmosis,
        proven: proven && !testnet,
        known: true,
        testnet: testnet,
        coinGeckoId: coinGeckoId,
        aliases: aliases,
      );
    }

    int? agreed(int? a, int? b) =>
        a == null || b == null || a == b ? (a ?? b) : null;

    // 1. A catalog currency (the chain's own coin included) on its own chain.
    if (entry != null && !denom.startsWith('ibc/')) {
      ChainCurrency? currency;
      for (final c in entry.currencies) {
        if (c.coinMinimalDenom == denom) currency = c;
      }
      final native =
          denom == entry.coinMinimalDenom || denom == entry.feeMinimalDenom;
      if (currency != null || native) {
        final symbol =
            currency?.coinDenom ??
            (denom == entry.coinMinimalDenom
                ? entry.coinDenom
                : entry.feeDenom);
        final decimals =
            currency?.coinDecimals ??
            (denom == entry.coinMinimalDenom
                ? entry.coinDecimals
                : entry.feeDecimals);
        final row =
            rowOf(chainId, denom) ??
            _issuerRows['$chainId:${_denomKey(denom)}'];
        final family =
            row != null && row.originChainId == chainId && row.path.isEmpty
            ? row.family
            : tokenFamilyOf(symbol);
        final ticker = testnet
            ? symbol
            : _tickerFor(
                family: family,
                originChainId: chainId,
                bridge: row?.originChainId == chainId ? row?.bridge : null,
              );
        return build(
          family: family,
          ticker: ticker,
          decimals: agreed(decimals, row?.decimals),
          logoUrl:
              _catalogLogos[chainId]?[_foldDenom(denom)] ??
              row?.logoUrl ??
              (native ? entry.iconUrl : null),
          originChainId: chainId,
          originDenom: denom,
          proven: entry.inCosmosRegistry || !_customChainIds.contains(chainId),
          coinGeckoId:
              currency?.coinGeckoId ??
              row?.coinGeckoId ??
              (native ? entry.coinGeckoId : null),
          aliases: row?.aliases ?? const [],
        );
      }
    }

    // 2. A row the table holds for this exact denom here.
    final row = rowOf(chainId, denom);
    if (row != null) {
      return build(
        family: row.family,
        ticker: _tickerFor(
          family: row.family,
          originChainId: row.originChainId,
          bridge: row.bridge,
          sourceNetwork: row.sourceNetwork,
          alloyed: row.alloyed,
        ),
        decimals: row.decimals,
        logoUrl: row.logoUrl,
        originChainId: row.originChainId,
        originDenom: row.originDenom,
        proven: true,
        coinGeckoId: row.coinGeckoId,
        aliases: row.aliases,
      );
    }

    // 3. A denom on its issuer that a voucher row proves (local denoms only:
    //    an `ibc/` denom here would need its own trace checked).
    final issued = denom.startsWith('ibc/')
        ? null
        : _issuerRows['$chainId:${_denomKey(denom)}'];
    if (issued != null) {
      return build(
        family: issued.family,
        ticker: _tickerFor(
          family: issued.family,
          originChainId: chainId,
          bridge: issued.bridge,
          sourceNetwork: issued.sourceNetwork,
        ),
        decimals: issued.decimals,
        logoUrl: issued.logoUrl,
        originChainId: chainId,
        originDenom: denom,
        proven: true,
        coinGeckoId: issued.coinGeckoId,
        aliases: issued.aliases,
      );
    }

    // 4. Nothing names it.
    final ticker = denom.startsWith('ibc/')
        ? 'IBC·${denom.length >= 8 ? denom.substring(4, 8).toUpperCase() : denom}'
        : denom.startsWith('factory/')
        ? denom.split('/').last
        : denom;
    return SwapTokenIdentity(
      chainId: chainId,
      chainName: chainName,
      denom: denom,
      ticker: ticker,
      family: ticker,
      name: 'Unknown token',
      decimals: 0,
      decimalsKnown: false,
      logoUrl: null,
      originChainId: denom.startsWith('ibc/') ? null : chainId,
      originChainName: denom.startsWith('ibc/') ? null : chainName,
      originDenom: denom.startsWith('ibc/') ? null : denom,
      osmosisDenom: chainId == kOsmosisChainId ? denom : null,
      proven: false,
      known: false,
      testnet: testnet,
      coinGeckoId: null,
      aliases: const [],
    );
  }
}

/// Table and cache key: `ibc/` hashes uppercase, every other denom exact.
String _denomKey(String denom) => denom.startsWith('ibc/')
    ? 'ibc/${denom.substring(4).toUpperCase()}'
    : denom;

String _foldDenom(String denom) =>
    RegExp(r'^(erc20:|peggy)', caseSensitive: false).hasMatch(denom)
    ? denom.toLowerCase()
    : denom;
