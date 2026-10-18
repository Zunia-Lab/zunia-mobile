/// Token identity: the one place a bank denom becomes a name.
///
/// Dart port of `zunia-extension/lib/token-identity.ts` (0.1.5), rule for
/// rule, so a balance reads the same ticker on the phone and in the
/// extension. Two facts drive the design:
///
/// 1. An `ibc/HASH` denom names a path, not a token. The same `uusdc` base is
///    Noble USDC over Osmosis channel-750 and Axelar USDC over channel-208, so
///    the issuer comes from the trace, never from "the first catalog chain that
///    lists the base denom". The bundled table and a channel walk the wallet
///    hash-checked are the only two sources.
/// 2. The ticker names the origin and never the location. `USDC.n` is Noble's
///    USDC on Noble, Osmosis and Injective alike; where it sits is a separate
///    field ([TokenIdentity.heldOnChainId]).
///
/// Display only. Nothing here may feed a signed message: message denoms come
/// from the bank or from the table's hash-verified `originDenom`, never from a
/// ticker and never from the catalog's lowercased erc20 spellings.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/tokens/token_registry.dart';

export 'package:zunia_mobile/tokens/token_registry.dart'
    show tokenFamilyOf, denomKey, isIbcDenom;

/* -------------------------------------------------------------------------- *
 * Public types
 * -------------------------------------------------------------------------- */

/// How a denom is minted on the chain that holds it. `native` is the chain's
/// staking or fee coin only; any other plain bank denom is `other`.
enum TokenKind { native, ibc, factory, erc20, peggy, cw20, other }

/// How the origin was established. See the extension's module for the full
/// rules; `unknown` is never guessed.
enum TokenProvenance { native, catalog, table, channelWalk, unknown }

/// Where a token text is shown, see [tokenText].
enum TokenTextVariant { pill, row, sentence, a11y }

/// What a token is and where it is. Display only: nothing here is ever signed.
@immutable
class TokenIdentity {
  const TokenIdentity({
    required this.key,
    required this.heldOnChainId,
    required this.heldOnChainName,
    required this.denom,
    required this.kind,
    required this.originChainId,
    required this.originChainName,
    required this.originDenom,
    required this.path,
    required this.hopChainIds,
    required this.bridge,
    required this.sourceNetwork,
    required this.family,
    required this.ticker,
    required this.name,
    required this.decimals,
    required this.decimalsKnown,
    required this.logoUrl,
    required this.coinGeckoId,
    required this.variantGroup,
    required this.alloyed,
    required this.osmosisDenom,
    required this.aliases,
    required this.provenance,
    required this.proven,
    required this.listed,
    required this.testnet,
  });

  /// `heldOnChainId:denom`.
  final String key;
  final String heldOnChainId;
  final String heldOnChainName;

  /// The exact bank denom, never case-folded.
  final String denom;
  final TokenKind kind;

  /// The issuer chain, or null when it cannot be proven.
  final String? originChainId;
  final String? originChainName;

  /// The exact denom on the origin chain, hash-verified.
  final String? originDenom;

  /// IBC trace path on the holding chain, `''` when none.
  final String path;

  /// Chain reached after each hop of [path]; null where unknown.
  final List<String?> hopChainIds;
  final String? bridge;
  final String? sourceNetwork;

  /// The asset without its issuer decorations: `USDC` for USDC.n and USDC.axl.
  final String family;

  /// `USDC.inj`, `ATOM`, `allUSDC`; `IBC·498A` when the origin is unknown.
  final String ticker;

  /// `Injective USDC`, `Alloyed USDC`, `Unknown token`.
  final String name;

  /// Display exponent; 0 when unknown, in which case amounts are base units.
  final int decimals;
  final bool decimalsKnown;

  /// A token logo. Never a chain logo for a token that is not that chain's coin.
  final String? logoUrl;
  final String? coinGeckoId;
  final String? variantGroup;
  final bool alloyed;

  /// This asset's denom on osmosis-1.
  final String? osmosisDenom;
  final List<String> aliases;
  final TokenProvenance provenance;

  /// Origin and name both come from the registry, the table or a verified
  /// channel walk. The only reason a seal or a "verified" line may be shown.
  final bool proven;

  /// Something names the token. False for a voucher nothing traces and for a
  /// denom nobody lists, which anyone can mint.
  final bool listed;

  /// Held on a testnet or a chain the user added.
  final bool testnet;

  TokenIdentity copyWith({
    String? key,
    String? denom,
    int? decimals,
    bool? decimalsKnown,
    bool? proven,
  }) =>
      TokenIdentity(
        key: key ?? this.key,
        heldOnChainId: heldOnChainId,
        heldOnChainName: heldOnChainName,
        denom: denom ?? this.denom,
        kind: kind,
        originChainId: originChainId,
        originChainName: originChainName,
        originDenom: originDenom,
        path: path,
        hopChainIds: hopChainIds,
        bridge: bridge,
        sourceNetwork: sourceNetwork,
        family: family,
        ticker: ticker,
        name: name,
        decimals: decimals ?? this.decimals,
        decimalsKnown: decimalsKnown ?? this.decimalsKnown,
        logoUrl: logoUrl,
        coinGeckoId: coinGeckoId,
        variantGroup: variantGroup,
        alloyed: alloyed,
        osmosisDenom: osmosisDenom,
        aliases: aliases,
        provenance: provenance,
        proven: proven ?? this.proven,
        listed: listed,
        testnet: testnet,
      );
}

/// What [tickerFor] needs to name an asset.
@immutable
class TickerInput {
  const TickerInput({
    required this.family,
    required this.originChainId,
    this.bridge,
    this.sourceNetwork,
    this.alloyed = false,
  });

  final String family;
  final String? originChainId;
  final String? bridge;
  final String? sourceNetwork;
  final bool alloyed;
}

/* -------------------------------------------------------------------------- *
 * Catalog access
 * -------------------------------------------------------------------------- */

Map<String, ChainEntry>? _bundledIndex;
List<ChainEntry>? _bundledRows;

/// The bundled rows, indexed once: `ChainCatalog.find` walks the whole list,
/// and naming one chain's tokens asks for a chain dozens of times.
List<ChainEntry> _bundled() {
  if (!ChainCatalog.isLoaded) return const [];
  return _bundledRows ??= ChainCatalog.instance.registryOnly;
}

ChainEntry? _entry(String chainId) {
  if (!ChainCatalog.isLoaded) return null;
  for (final entry in ChainCatalog.instance.customOnly) {
    if (entry.chainId == chainId) return entry;
  }
  final index = _bundledIndex ??= {for (final entry in _bundled()) entry.chainId: entry};
  return index[chainId];
}

List<ChainEntry> _custom() =>
    ChainCatalog.isLoaded ? ChainCatalog.instance.customOnly : const [];

TokenRegistry? get _table => TokenRegistry.instance;

final RegExp _caseFoldDenom = RegExp(r'^(?:erc20:|peggy)', caseSensitive: false);

/// `erc20:0xA00C…` and `peggy0xA00C…` match the registry's lowercase spelling.
bool denomsMatch(String left, String right) {
  if (left == right) return true;
  if (_caseFoldDenom.hasMatch(left) && _caseFoldDenom.hasMatch(right)) {
    return left.toLowerCase() == right.toLowerCase();
  }
  return false;
}

/// Native row plus every extra currency.
List<ChainCurrency> currenciesOf(ChainEntry entry) {
  if (entry.currencies.isNotEmpty) return entry.currencies;
  return [
    ChainCurrency(
      coinDenom: entry.coinDenom,
      coinMinimalDenom: entry.coinMinimalDenom,
      coinDecimals: entry.coinDecimals,
      coinGeckoId: entry.coinGeckoId,
    ),
  ];
}

/// The currency [denom] is on [chainId] itself, or null. Naming only.
({ChainEntry entry, ChainCurrency currency})? findCurrencyOn(String chainId, String denom) {
  final entry = _entry(chainId);
  if (entry == null || denom.isEmpty) return null;
  for (final row in currenciesOf(entry)) {
    if (denomsMatch(row.coinMinimalDenom, denom)) return (entry: entry, currency: row);
  }
  if (denom == entry.coinMinimalDenom) {
    return (
      entry: entry,
      currency: ChainCurrency(
        coinDenom: entry.coinDenom,
        coinMinimalDenom: entry.coinMinimalDenom,
        coinDecimals: entry.coinDecimals,
        coinGeckoId: entry.coinGeckoId,
      ),
    );
  }
  if (denom == entry.feeMinimalDenom) {
    return (
      entry: entry,
      currency: ChainCurrency(
        coinDenom: entry.feeDenom,
        coinMinimalDenom: entry.feeMinimalDenom,
        coinDecimals: entry.feeDecimals,
      ),
    );
  }
  return null;
}

/// Base units that Ethereum, Bitcoin and Solana assets unwind to; never a
/// unique Cosmos issuer.
const Set<String> _foreignBaseUnits = {
  'wei', 'gwei', 'sat', 'sats', 'satoshi', 'lamport', 'lamports',
};

/// The one mainnet registry chain that issues [baseDenom], or null when none
/// does or several do. Custom chains and testnets never count.
({ChainEntry entry, ChainCurrency currency})? uniqueIssuerOf(String baseDenom) {
  final needle = baseDenom.trim();
  if (needle.isEmpty || _foreignBaseUnits.contains(needle.toLowerCase())) return null;
  final custom = {for (final entry in _custom()) entry.chainId};
  ({ChainEntry entry, ChainCurrency currency})? first;
  final chains = <String>{};
  for (final entry in _bundled()) {
    if (entry.network != 'mainnet' || custom.contains(entry.chainId)) continue;
    for (final row in currenciesOf(entry)) {
      if (!denomsMatch(row.coinMinimalDenom, needle)) continue;
      first ??= (entry: entry, currency: row);
      chains.add(entry.chainId);
    }
  }
  return chains.length == 1 ? first : null;
}

/* -------------------------------------------------------------------------- *
 * The ticker rule
 * -------------------------------------------------------------------------- */

/// Families with several issuers of equal standing: always tagged, never bare.
const Set<String> _multiIssuer = {'USDC', 'USDT', 'DAI', 'ETH', 'WBTC', 'BTC'};

/// Issuer tags the ecosystem already uses; any other falls back to the prefix.
const Map<String, String> _issuerTag = {
  'noble-1': 'n',
  'injective-1': 'inj',
  'kava_2222-10': 'kava',
  'osmosis-1': 'osmo',
};

/// Keplr-style network prefixes on Axelar tickers (`PolygonUSDC.axl`).
const Map<String, String> _networkPrefix = {
  'Polygon': 'polygon',
  'Avalanche': 'avax',
  'Arbitrum': 'arb',
  'Optimism': 'op',
  'Base': 'base',
  'Binance': 'bsc',
};

final RegExp _thorPool = RegExp(r'^(eth|avax|base|bsc|tron|gaia|btc|bch|doge|ltc|xrp|sol)-');
const Map<String, String> _thorNetwork = {
  'avax': 'avax',
  'base': 'base',
  'bsc': 'bsc',
  'tron': 'tron',
  'sol': 'sol',
};

/// Ethereum contracts behind Peggy and Gravity denoms the catalog does not list.
const Map<String, (String, int)> _ethereumTokens = {
  '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48': ('USDC', 6),
  '0xdac17f958d2ee523a2206206994597c13d831ec7': ('USDT', 6),
  '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2': ('ETH', 18),
  '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599': ('WBTC', 8),
  '0x6b175474e89094c44da98b954eedeac495271d0f': ('DAI', 18),
};

/// The asset a symbol names, without issuer decorations.
String familyOf(String symbol) => tokenFamilyOf(symbol);

Map<String, String>? _homeIssuers;

final RegExp _gasVoucher = RegExp(r'^(ibc|l2)/');

/// The one mainnet chain whose staking coin is [family]. Built from the
/// bundled catalog only, so a custom chain can never become a home issuer.
String? _homeIssuerOf(String family) {
  final issuers = _homeIssuers ??= () {
    final byFamily = <String, List<ChainEntry>>{};
    for (final entry in _bundled()) {
      if (entry.network != 'mainnet' || _gasVoucher.hasMatch(entry.coinMinimalDenom)) continue;
      byFamily.putIfAbsent(familyOf(entry.coinDenom), () => <ChainEntry>[]).add(entry);
    }
    final out = <String, String>{};
    for (final MapEntry(:key, :value) in byFamily.entries) {
      final listed = value.length > 1
          ? value.where((entry) => entry.inCosmosRegistry).toList()
          : value;
      if (listed.length == 1) out[key] = listed.first.chainId;
    }
    return out;
  }();
  return issuers[family];
}

/// A chain the user typed in. Its catalog row says `testnet` whatever it is,
/// so only the user's own list can tell it from a registry testnet.
bool isUserAddedChain(String chainId) =>
    _custom().any((entry) => entry.chainId == chainId);

/// A testnet or a chain the user added: never an issuer, never renames anyone.
bool _isNeverIssuer(String chainId) {
  if (isUserAddedChain(chainId)) return true;
  return _entry(chainId)?.network == 'testnet';
}

String _chainNameOf(String chainId) =>
    _entry(chainId)?.chainName ?? _table?.chains[chainId]?.$1 ?? chainId;

String _prefixOfChain(String chainId) =>
    _entry(chainId)?.bech32Prefix ?? _table?.chains[chainId]?.$2 ?? '';

String _issuerTagOf(String chainId) {
  final tag = _issuerTag[chainId];
  if (tag != null) return tag;
  final prefix = _prefixOfChain(chainId);
  return prefix.isEmpty ? chainId : prefix;
}

/// The ticker for an asset, from its origin and never its location:
/// 1. an Osmosis alloy is `all` + family (`allUSDC`);
/// 2. a bridged asset takes the bridge tag, plus the source network for a
///    multi-issuer family when it is not Ethereum (`USDC.axl.polygon`);
/// 3. a multi-issuer family minted on a chain takes the issuer tag (`USDC.n`);
/// 4. any other family is bare on its home issuer (`ATOM` on the Hub) and
///    tagged elsewhere (`ATOM.thor`);
/// 5. a testnet or custom origin is never tagged.
String tickerFor(TickerInput input) {
  final family = input.family;
  if (input.alloyed) return 'all$family';
  final origin = input.originChainId;
  if (origin != null && _isNeverIssuer(origin)) return family;
  final bridge = input.bridge;
  if (bridge != null) {
    final network = input.sourceNetwork != null && _multiIssuer.contains(family)
        ? '.${input.sourceNetwork}'
        : '';
    return '$family.$bridge$network';
  }
  if (origin == null) return family;
  if (_multiIssuer.contains(family)) return '$family.${_issuerTagOf(origin)}';
  final home = _homeIssuerOf(family);
  return home == null || home == origin ? family : '$family.${_issuerTagOf(origin)}';
}

typedef _Traits = ({String family, String? bridge, String? sourceNetwork, bool alloyed});

final RegExp _networkWord = RegExp(r'^(Polygon|Avalanche|Arbitrum|Optimism|Base|Binance)(?=[A-Z])');
final RegExp _peggyContract = RegExp(r'^peggy0x', caseSensitive: false);
final RegExp _gravityContract = RegExp(r'^gravity0x', caseSensitive: false);

_Traits _catalogTraits(ChainEntry entry, ChainCurrency currency, [String? held]) {
  final denom = held ?? currency.coinMinimalDenom;
  final row = _tableRow(entry.chainId, denom);
  if (row != null && row.originChainId == entry.chainId && row.path.isEmpty) {
    return (
      family: row.family,
      bridge: row.bridge,
      sourceNetwork: row.sourceNetwork,
      alloyed: row.alloyed,
    );
  }
  final issued =
      _issuerRowOf(entry.chainId, denom) ?? _issuerRowOf(entry.chainId, denom, folded: true);
  if (issued != null) {
    return (
      family: issued.family,
      bridge: issued.bridge,
      sourceNetwork: issued.sourceNetwork,
      alloyed: false,
    );
  }
  final symbol = currency.coinDenom;
  final prefix = _networkWord.firstMatch(symbol)?.group(1);
  String? sourceNetwork = prefix == null ? null : _networkPrefix[prefix];
  String? bridge;
  if (_peggyContract.hasMatch(denom)) {
    bridge = 'peggy';
  } else if (_gravityContract.hasMatch(denom)) {
    bridge = 'grv';
  } else if (entry.chainId == 'thorchain-1' && _thorPool.hasMatch(denom)) {
    bridge = 'thor';
    sourceNetwork = _thorNetwork[denom.split('-').first];
  } else if (entry.chainId == 'axelar-dojo-1' && denom != entry.coinMinimalDenom) {
    bridge = 'axl';
  } else if (entry.chainId == 'wormchain' && denom.startsWith('factory/')) {
    // Every token-factory denom on the Wormhole Gateway is the token bridge's.
    bridge = 'wh';
  } else {
    final tags = symbol.split('.').skip(1).map((tag) => tag.toLowerCase()).toList();
    for (final tag in tags.reversed) {
      if (tokenBridges.contains(tag)) {
        bridge = tag;
        break;
      }
    }
  }
  return (family: familyOf(symbol), bridge: bridge, sourceNetwork: sourceNetwork, alloyed: false);
}

/// The ticker of a catalog currency on its own chain. A held denom goes
/// through [identityOf] instead.
String catalogTicker(ChainEntry entry, ChainCurrency currency) {
  if (_isNeverIssuer(entry.chainId)) return currency.coinDenom;
  final denom = currency.coinMinimalDenom;
  if (_gasVoucher.hasMatch(denom)) {
    // Gas paid in someone else's coin: the listing chain did not issue it.
    final proven = isIbcDenom(denom) ? identityOf(entry.chainId, denom) : null;
    if (proven != null && proven.provenance != TokenProvenance.unknown) return proven.ticker;
    final family = familyOf(currency.coinDenom);
    final home = _homeIssuerOf(family);
    return home != null
        ? tickerFor(TickerInput(family: family, originChainId: home))
        : currency.coinDenom;
  }
  final traits = _catalogTraits(entry, currency);
  return tickerFor(TickerInput(
    family: traits.family,
    originChainId: entry.chainId,
    bridge: traits.bridge,
    sourceNetwork: traits.sourceNetwork,
    alloyed: traits.alloyed,
  ));
}

String _tickerOfCurrency(ChainEntry entry, String symbol, String? minimalDenom) {
  final row = _entry(entry.chainId);
  if (row == null) return symbol;
  ChainCurrency? currency =
      minimalDenom == null ? null : findCurrencyOn(row.chainId, minimalDenom)?.currency;
  if (currency == null) {
    for (final candidate in currenciesOf(row)) {
      if (candidate.coinDenom == symbol) {
        currency = candidate;
        break;
      }
    }
  }
  currency ??= ChainCurrency(
    coinDenom: symbol,
    coinMinimalDenom: minimalDenom ?? row.coinMinimalDenom,
    coinDecimals: row.coinDecimals,
  );
  return catalogTicker(row, currency);
}

/// The chain's staking coin as every screen names it (`USDC.n` on Noble).
String chainTicker(ChainEntry entry) =>
    _tickerOfCurrency(entry, entry.coinDenom, entry.coinMinimalDenom);

/// The fee coin's ticker, with the same rule as [chainTicker].
String feeTicker(ChainEntry entry) {
  if (entry.feeDenom.isEmpty || entry.feeDenom == entry.coinDenom) return chainTicker(entry);
  return _tickerOfCurrency(
    entry,
    entry.feeDenom,
    entry.feeMinimalDenom.isEmpty ? null : entry.feeMinimalDenom,
  );
}

/* -------------------------------------------------------------------------- *
 * IBC arithmetic
 * -------------------------------------------------------------------------- */

final RegExp _trimSlashes = RegExp(r'^/+|/+$');

/// `ibc/` + uppercase sha256 of `path/baseDenom` (ibc-go's DenomTrace.Hash).
String ibcDenomFor(String path, String baseDenom) {
  final trimmed = path.replaceAll(_trimSlashes, '');
  final full = trimmed.isEmpty ? baseDenom : '$trimmed/$baseDenom';
  return 'ibc/${sha256.convert(utf8.encode(full)).toString().toUpperCase()}';
}

/// True when `path/baseDenom` hashes to [denom].
bool traceMatches(String denom, String path, String baseDenom) {
  if (!isIbcDenom(denom) || baseDenom.isEmpty) return false;
  return ibcDenomFor(path, baseDenom) == denomKey(denom);
}

/* -------------------------------------------------------------------------- *
 * Table lookups
 * -------------------------------------------------------------------------- */

TokenTableRow? _tableRow(String chainId, String denom) => _table?.row(chainId, denom);

String? _catalogLogo(String chainId, String denom) =>
    _table?.catalogLogos[chainId]?[foldDenom(denom)];

/// Rows of the table, all of them or those held on one chain.
List<TokenTableRow> tokenTableRows([String? heldOnChainId]) =>
    _table?.rowsOn(heldOnChainId) ?? const [];

/// The chain at the other end of [channelId] on [chainId], from the table's
/// first hops and proven walks; null when unknown.
String? channelCounterpartyOf(String chainId, String channelId) {
  final known = _table?.channels['$chainId:$channelId'];
  if (known != null) return known;
  for (final MapEntry(:key, :value) in _facts.entries) {
    if (!key.startsWith('$chainId:') || firstChannelOf(value.p) != channelId) continue;
    final next = value.h != null && value.h!.isNotEmpty ? value.h!.first : null;
    if (next != null) return next;
  }
  return null;
}

/// The asset's denom on osmosis-1: the origin denom when Osmosis issues it,
/// else the canonical voucher the table lists. Exact match only.
String? osmosisDenomOf(String originChainId, String originDenom) {
  if (originChainId.isEmpty || originDenom.isEmpty) return null;
  if (originChainId == osmosisChainId) return originDenom;
  return _table?.osmosisByOrigin['$originChainId:$originDenom']?.denom;
}

TokenTableRow? _issuerRowOf(String chainId, String denom, {bool folded = false}) {
  final table = _table;
  if (table == null) return null;
  if (!folded) return table.issuerRows['$chainId:${denomKey(denom)}'];
  final exact = table.issuerSpellings['$chainId:${foldDenom(denom)}'];
  return exact == null ? null : table.issuerRows['$chainId:${denomKey(exact)}'];
}

/* -------------------------------------------------------------------------- *
 * The facts cache: proven traces the table does not list
 * -------------------------------------------------------------------------- */

/// One proven trace. Facts, never labels, so a rule change needs no wipe.
@immutable
class TraceFact {
  const TraceFact({required this.o, required this.b, required this.p, this.h, required this.at});

  /// Origin chain id.
  final String o;

  /// Base denom on the origin.
  final String b;

  /// Trace path on the holding chain.
  final String p;

  /// Chain after each hop.
  final List<String?>? h;

  /// When it was learned (ms), for trimming.
  final int at;

  Map<String, Object?> toJson() => {'o': o, 'b': b, 'p': p, if (h != null) 'h': h, 'at': at};
}

const int _factsVersion = 1;
const int _factsMax = 500;
const String _factsKey = 'zunia.tokens.identityFacts';

/// A voucher that could not be traced is not asked about again for this long.
const Duration _missTtl = Duration(minutes: 30);

/// Point lookups per call; the rest wait for the next balance read.
const int _maxLookups = 32;

final Map<String, TraceFact> _facts = {};
final Map<String, int> _misses = {};
int _generation = 0;

/// Bumped whenever a new fact is learned; screens that memoize rows watch it.
final ValueNotifier<int> tokenFactsGeneration = ValueNotifier<int>(0);

String _factKey(String chainId, String denom) => '$chainId:${denomKey(denom)}';

/// Stored facts, keeping only those whose trace still hashes to their denom.
Map<String, TraceFact> parseTraceFacts(Object? raw) {
  final out = <String, TraceFact>{};
  if (raw is! Map || raw['version'] != _factsVersion || raw['facts'] is! Map) return out;
  for (final MapEntry(:key, :value) in (raw['facts'] as Map).entries) {
    if (key is! String || value is! Map) continue;
    final split = key.indexOf(':ibc/');
    final o = value['o'];
    final b = value['b'];
    final p = value['p'];
    if (split < 0 || o is! String || b is! String || p is! String) continue;
    if (o.isEmpty || b.isEmpty) continue;
    if (!traceMatches(key.substring(split + 1), p, b)) continue;
    final h = value['h'];
    out[key] = TraceFact(
      o: o,
      b: b,
      p: p,
      h: h is List ? [for (final hop in h) hop is String ? hop : null] : null,
      at: value['at'] is num ? (value['at'] as num).toInt() : 0,
    );
  }
  return out;
}

void _adoptFacts(Map<String, TraceFact> incoming) {
  var changed = false;
  for (final MapEntry(:key, :value) in incoming.entries) {
    final current = _facts[key];
    if (current != null && current.at >= value.at) continue;
    _facts[key] = value;
    changed = true;
  }
  if (changed) _bump();
}

void _bump() {
  _generation += 1;
  tokenFactsGeneration.value = _generation;
}

/// Load the stored facts. Never throws.
Future<void> hydrateTokenIdentities() async {
  try {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(_factsKey);
    if (raw == null) return;
    _adoptFacts(parseTraceFacts(jsonDecode(raw)));
  } on Object {
    // Without storage, the table and the catalog still answer.
  }
}

Future<void> _persistFacts() async {
  try {
    final kept = _facts.entries.toList()..sort((a, b) => b.value.at.compareTo(a.value.at));
    final store = await SharedPreferences.getInstance();
    await store.setString(
      _factsKey,
      jsonEncode({
        'version': _factsVersion,
        'facts': {for (final entry in kept.take(_factsMax)) entry.key: entry.value.toJson()},
      }),
    );
  } on Object {
    // The facts still answer in memory until the app closes.
  }
}

/// A hash-checked trace for one voucher, as the engine's resolver walks it.
typedef TraceLookupResult = ({
  String baseDenom,
  String path,
  String? originChainId,
  List<String?>? hopChainIds,
});

/// Resolves one voucher on one chain; null when it could not be traced.
typedef TraceLookup = Future<TraceLookupResult?> Function(String chainId, String denom);

/// Identify a chain's held denoms, once per balance read. Denoms the table or
/// the catalog already name cost nothing; each remaining `ibc/` voucher gets
/// one point lookup whose trace must hash to the denom, at most 32 per call. A
/// voucher that could not be traced is not looked up again for 30 minutes.
Future<Map<String, TokenIdentity>> identifyHeld(
  String chainId,
  List<String> denoms, {
  required TraceLookup lookup,
  int concurrency = 4,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final wanted = <String>[];
  for (final denom in denoms.toSet()) {
    if (!isIbcDenom(denom) || identityOf(chainId, denom).provenance != TokenProvenance.unknown) {
      continue;
    }
    final missed = _misses[_factKey(chainId, denom)];
    if (missed != null && now - missed <= _missTtl.inMilliseconds) continue;
    wanted.add(denom);
    if (wanted.length >= _maxLookups) break;
  }
  if (wanted.isNotEmpty) {
    final found = <String, TraceLookupResult?>{};
    var next = 0;
    Future<void> worker() async {
      while (next < wanted.length) {
        final denom = wanted[next++];
        try {
          found[denom] = await lookup(chainId, denom);
        } on Object {
          found[denom] = null;
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < wanted.length; i++) worker(),
    ]);
    var learned = 0;
    for (final denom in wanted) {
      final hit = found[denom];
      final origin = hit?.originChainId;
      if (hit == null || origin == null || !traceMatches(denom, hit.path, hit.baseDenom)) {
        _misses[_factKey(chainId, denom)] = now;
        continue;
      }
      _facts[_factKey(chainId, denom)] = TraceFact(
        o: origin,
        b: hit.baseDenom,
        p: hit.path,
        h: hit.hopChainIds,
        at: now,
      );
      learned += 1;
    }
    if (learned > 0) {
      _bump();
      await _persistFacts();
    }
  }
  return {for (final denom in denoms) denom: identityOf(chainId, denom)};
}

/// Forget learned facts and memos. Tests only.
@visibleForTesting
void resetTokenIdentityState() {
  _facts.clear();
  _misses.clear();
  _memo.clear();
  _guards.clear();
  _homeIssuers = null;
  _knownNames = null;
  _bundledIndex = null;
  _bundledRows = null;
  _bump();
}

/// Install a fact directly. Tests only.
@visibleForTesting
void debugAddTraceFact(String chainId, String denom, TraceFact fact) {
  _facts[_factKey(chainId, denom)] = fact;
  _bump();
}

/* -------------------------------------------------------------------------- *
 * Resolution
 * -------------------------------------------------------------------------- */

/// An identity before the ticker, the name and the guard are applied.
class _Draft {
  _Draft({
    required this.heldOnChainId,
    required this.denom,
    required this.kind,
    required this.originChainId,
    required this.originDenom,
    required this.path,
    required this.hopChainIds,
    required this.symbol,
    required this.family,
    required this.bridge,
    required this.sourceNetwork,
    required this.alloyed,
    required this.decimals,
    required this.logoUrl,
    required this.coinGeckoId,
    required this.variantGroup,
    required this.aliases,
    required this.provenance,
    required this.named,
    required this.rank,
    this.walkCanonical,
  });

  final String heldOnChainId;
  final String denom;
  final TokenKind kind;
  final String? originChainId;
  final String? originDenom;
  final String path;
  final List<String?> hopChainIds;

  /// The registry symbol, or a readable stand-in when [named] is false.
  final String symbol;
  final String family;
  final String? bridge;
  final String? sourceNetwork;
  final bool alloyed;
  final int? decimals;
  final String? logoUrl;
  final String? coinGeckoId;
  final String? variantGroup;
  final List<String> aliases;
  final TokenProvenance provenance;

  /// The symbol comes from the catalog, the table or a known contract.
  final bool named;

  /// Rank in the collision guard: lower keeps the bare ticker.
  final int rank;

  /// For a channel walk: every hop crossed a registry-canonical channel.
  final bool? walkCanonical;

  _Draft copyWith({
    String? originChainId,
    String? originDenom,
    String? symbol,
    String? family,
    String? bridge,
    int? decimals,
    TokenProvenance? provenance,
    bool? named,
    int? rank,
  }) =>
      _Draft(
        heldOnChainId: heldOnChainId,
        denom: denom,
        kind: kind,
        originChainId: originChainId ?? this.originChainId,
        originDenom: originDenom ?? this.originDenom,
        path: path,
        hopChainIds: hopChainIds,
        symbol: symbol ?? this.symbol,
        family: family ?? this.family,
        bridge: bridge ?? this.bridge,
        sourceNetwork: sourceNetwork,
        alloyed: alloyed,
        decimals: decimals ?? this.decimals,
        logoUrl: logoUrl,
        coinGeckoId: coinGeckoId,
        variantGroup: variantGroup,
        aliases: aliases,
        provenance: provenance ?? this.provenance,
        named: named ?? this.named,
        rank: rank ?? this.rank,
        walkCanonical: walkCanonical,
      );
}

final RegExp _erc20Kind = RegExp(r'^erc20[:/]', caseSensitive: false);
final RegExp _peggyKind = RegExp(r'^peggy0x', caseSensitive: false);
final RegExp _cw20Kind = RegExp(r'^cw20:', caseSensitive: false);

TokenKind _kindOf(String chainId, String denom) {
  if (isIbcDenom(denom)) return TokenKind.ibc;
  if (denom.startsWith('factory/')) return TokenKind.factory;
  if (_erc20Kind.hasMatch(denom)) return TokenKind.erc20;
  if (_peggyKind.hasMatch(denom)) return TokenKind.peggy;
  if (_cw20Kind.hasMatch(denom)) return TokenKind.cw20;
  final entry = _entry(chainId);
  if (entry != null && (denom == entry.coinMinimalDenom || denom == entry.feeMinimalDenom)) {
    return TokenKind.native;
  }
  return TokenKind.other;
}

_Draft _unknownDraft(String chainId, String denom) => _Draft(
      heldOnChainId: chainId,
      denom: denom,
      kind: _kindOf(chainId, denom),
      originChainId: null,
      originDenom: null,
      path: '',
      hopChainIds: const [],
      symbol: '',
      family: '',
      bridge: null,
      sourceNetwork: null,
      alloyed: false,
      decimals: null,
      logoUrl: null,
      coinGeckoId: null,
      variantGroup: null,
      aliases: const [],
      provenance: TokenProvenance.unknown,
      named: false,
      rank: 9,
    );

/// When the catalog and the table disagree about one asset's decimals neither
/// is trusted: the amount stays in base units.
int? _agreedDecimals(int? first, int? second) {
  if (first == null || second == null) return first;
  return first == second ? first : null;
}

List<String?> _hopsOf(TokenTableRow row) {
  if (row.path.isEmpty) return const [];
  final count = row.path.split('/').length ~/ 2;
  return [row.counterpartyChainId, ...List<String?>.filled(count - 1, null)];
}

/// The row of the voucher a relay holds, when [row] reached its listed origin
/// through that relay rather than from the issuer.
TokenTableRow? _relayedRowOf(TokenTableRow row) {
  if (row.path.isEmpty || row.originChainId == row.heldOnChainId) return null;
  final inner = _tableRow(row.originChainId, row.originDenom);
  if (inner == null || inner.channelId == null || inner.originChainId == inner.heldOnChainId) {
    return null;
  }
  final rest = row.path.split('/').skip(2).join('/');
  return inner.path == rest && inner.baseDenom == row.baseDenom ? inner : null;
}

_Draft _draftFromRow(TokenTableRow row) {
  // The identity names the issuer; the row keeps the hop delivery unwinds to.
  final relayed = _relayedRowOf(row);
  final originChainId = relayed?.originChainId ?? row.originChainId;
  final originDenom = relayed?.originDenom ?? row.originDenom;
  return _Draft(
    heldOnChainId: row.heldOnChainId,
    denom: row.denom,
    kind: _kindOf(row.heldOnChainId, row.denom),
    originChainId: originChainId,
    originDenom: originDenom,
    path: row.path,
    hopChainIds: relayed != null ? [row.counterpartyChainId, ..._hopsOf(relayed)] : _hopsOf(row),
    symbol: row.family,
    family: row.family,
    bridge: row.bridge,
    sourceNetwork: row.sourceNetwork,
    alloyed: row.alloyed,
    decimals: _agreedDecimals(
      _agreedDecimals(row.decimals, relayed?.decimals),
      findCurrencyOn(originChainId, originDenom)?.currency.coinDecimals,
    ),
    logoUrl: row.logoUrl,
    coinGeckoId: row.coinGeckoId,
    variantGroup: row.variantGroup,
    aliases: row.aliases,
    provenance: row.path.isNotEmpty ? TokenProvenance.table : TokenProvenance.native,
    named: true,
    rank: row.verified && row.stable ? 1 : row.verified ? 2 : 3,
  );
}

_Draft _draftFromCatalog(String chainId, String denom, ChainEntry entry, ChainCurrency currency) {
  final row = _tableRow(chainId, denom) ?? _issuerRowOf(chainId, denom);
  final traits = _catalogTraits(entry, currency, denom);
  final native = denom == entry.coinMinimalDenom || denom == entry.feeMinimalDenom;
  return _Draft(
    heldOnChainId: chainId,
    denom: denom,
    kind: _kindOf(chainId, denom),
    originChainId: chainId,
    originDenom: denom,
    path: '',
    hopChainIds: const [],
    symbol: currency.coinDenom,
    family: traits.family,
    bridge: traits.bridge,
    sourceNetwork: traits.sourceNetwork,
    alloyed: traits.alloyed,
    decimals: _agreedDecimals(currency.coinDecimals, row?.decimals),
    // A chain's own staking or fee coin wears the chain's mark when nothing
    // names a coin logo: there the chain logo is the token logo.
    logoUrl: (row?.heldOnChainId == chainId ? row?.logoUrl : null) ??
        _catalogLogo(chainId, denom) ??
        row?.logoUrl ??
        (native ? entry.iconUrl : null),
    coinGeckoId: currency.coinGeckoId ?? row?.coinGeckoId ?? (native ? entry.coinGeckoId : null),
    variantGroup: row?.variantGroup,
    aliases: row?.aliases ?? const [],
    provenance: native ? TokenProvenance.native : TokenProvenance.catalog,
    named: true,
    rank: 0,
  );
}

final RegExp _lightClientHop = RegExp(r'^([^/]+/\d{2}-[a-z][a-z0-9]*-\d+)/(.+)$');

/// The issuer's side of [_issuerRowOf]: the voucher's trace minus its first hop.
({String path, String base}) _issuerTrace(TokenTableRow row) {
  final path = row.path.split('/').skip(2).join('/');
  // A light-client hop stays inside the base on the voucher's row; split it
  // back out so the path reads as one.
  final hop = path.isNotEmpty ? null : _lightClientHop.firstMatch(row.baseDenom);
  return hop != null
      ? (path: hop.group(1) ?? '', base: hop.group(2) ?? '')
      : (path: path, base: row.baseDenom);
}

_Draft? _draftFromIssuerRow(String chainId, String denom, TokenTableRow row) {
  var path = '';
  if (isIbcDenom(denom)) {
    final trace = _issuerTrace(row);
    if (!traceMatches(denom, trace.path, trace.base)) return null;
    path = trace.path;
  }
  return _Draft(
    heldOnChainId: chainId,
    denom: denom,
    kind: _kindOf(chainId, denom),
    originChainId: chainId,
    originDenom: denom,
    path: path,
    hopChainIds: path.isEmpty
        ? const []
        : List<String?>.filled(path.split('/').length ~/ 2, null),
    symbol: row.family,
    family: row.family,
    bridge: row.bridge,
    sourceNetwork: row.sourceNetwork,
    alloyed: row.alloyed,
    decimals: _agreedDecimals(row.decimals, findCurrencyOn(chainId, denom)?.currency.coinDecimals),
    logoUrl: row.logoUrl,
    coinGeckoId: row.coinGeckoId,
    variantGroup: row.variantGroup,
    aliases: row.aliases,
    provenance: TokenProvenance.table,
    named: true,
    rank: row.verified && row.stable ? 1 : row.verified ? 2 : 3,
  );
}

/// Ethereum bridges whose module mints `<prefix>0x<contract>` denoms, and the
/// one mainnet chain each runs on.
const Map<String, (String, String)> _contractBridges = {
  'peggy': ('injective-1', 'peggy'),
  'gravity': ('gravity-bridge-3', 'grv'),
};

final RegExp _bridgedContract = RegExp(r'^(peggy|gravity)(0x[0-9a-fA-F]{40})$');

/// A local denom no registry lists. Its origin is the holding chain; its name
/// is not known unless it embeds a known Ethereum contract on the right chain.
_Draft _draftFromLocal(String chainId, String denom) {
  final base = _unknownDraft(chainId, denom);
  if (_entry(chainId) == null) return base;
  final bridged = _bridgedContract.firstMatch(denom);
  final minter = bridged == null ? null : _contractBridges[bridged.group(1)];
  final known = bridged != null && minter?.$1 == chainId
      ? _ethereumTokens[(bridged.group(2) ?? '').toLowerCase()]
      : null;
  if (minter != null && known != null) {
    return base.copyWith(
      originChainId: chainId,
      originDenom: denom,
      symbol: known.$1,
      family: known.$1,
      bridge: minter.$2,
      decimals: known.$2,
      provenance: TokenProvenance.native,
      named: true,
      rank: 0,
    );
  }
  final symbol = denom.startsWith('factory/') ? denom.split('/').last : '';
  return base.copyWith(
    originChainId: chainId,
    originDenom: denom,
    symbol: symbol,
    provenance: TokenProvenance.native,
    rank: 5,
  );
}

/// Whether a walked trace crossed only registry-canonical transfer channels.
bool _walkedCanonically(String holdingChainId, TraceFact fact) {
  final table = _table;
  if (table == null) return false;
  final segments = fact.p.split('/');
  if (segments.isEmpty || segments.length.isOdd) return false;
  var chain = holdingChainId;
  for (var hop = 0; hop < segments.length ~/ 2; hop++) {
    final port = segments[hop * 2];
    final channel = segments[hop * 2 + 1];
    final next = fact.h != null && hop < fact.h!.length ? fact.h![hop] : null;
    if (port != 'transfer' || channel.isEmpty || next == null) return false;
    if (!table.isCanonicalHop(chain, channel, next)) return false;
    chain = next;
  }
  return true;
}

_Draft _draftFromFact(String chainId, String denom, TraceFact fact) {
  final inner = _localDraftOf(fact.o, fact.b);
  final canonical = _table?.osmosisByOrigin['${fact.o}:${fact.b}'];
  final listed = inner.named ? null : findCurrencyOn(chainId, denom)?.currency;
  final unnamedSymbol = fact.b.startsWith('factory/') ? fact.b.split('/').last : '';
  final named = inner.named || listed != null;
  return _Draft(
    heldOnChainId: chainId,
    denom: denom,
    kind: TokenKind.ibc,
    originChainId: fact.o,
    originDenom: fact.b,
    path: fact.p,
    hopChainIds: fact.h ?? const [],
    symbol: inner.named ? inner.symbol : (listed?.coinDenom ?? unnamedSymbol),
    family: inner.named
        ? inner.family
        : listed != null
            ? familyOf(listed.coinDenom)
            : inner.family,
    bridge: inner.bridge,
    sourceNetwork: inner.sourceNetwork,
    alloyed: inner.alloyed,
    decimals: inner.named ? inner.decimals : listed?.coinDecimals,
    logoUrl: inner.logoUrl,
    coinGeckoId: inner.coinGeckoId ?? listed?.coinGeckoId ?? canonical?.coinGeckoId,
    variantGroup: inner.variantGroup ?? canonical?.variantGroup,
    aliases: [...inner.aliases, ...?canonical?.aliases],
    provenance: TokenProvenance.channelWalk,
    named: named,
    // An unnamed walk never outranks a named token in the collision guard.
    rank: named ? 4 : 6,
    walkCanonical: _walkedCanonically(chainId, fact),
  );
}

/// A denom as its own chain sees it: the catalog, a table row held there, the
/// voucher row that proves it on its issuer, else an unlisted local denom. An
/// erc20 or peggy spelling that differs only in case from the proven one is a
/// different, empty bank denom and stays unknown.
_Draft _localDraftOf(String chainId, String denom) {
  final exact = _table?.issuerSpellings['$chainId:${foldDenom(denom)}'];
  if (exact != null && exact != denom) return _unknownDraft(chainId, denom);
  final hit = findCurrencyOn(chainId, denom) ?? _cw20Listing(chainId, denom);
  if (hit != null) return _draftFromCatalog(chainId, denom, hit.entry, hit.currency);
  final row = _tableRow(chainId, denom);
  if (row != null) return _draftFromRow(row);
  final issued = _issuerRowOf(chainId, denom);
  final fromIssuer = issued == null ? null : _draftFromIssuerRow(chainId, denom, issued);
  if (fromIssuer != null) return fromIssuer;
  return _draftFromLocal(chainId, denom);
}

/// The catalog row of a `cw20:<contract>` denom when the catalog lists the
/// contract bare: one token under two spellings.
({ChainEntry entry, ChainCurrency currency})? _cw20Listing(String chainId, String denom) =>
    denom.startsWith('cw20:') ? findCurrencyOn(chainId, denom.substring(5)) : null;

/// A packet denom: the sender's trace, not a bank denom here.
final RegExp _packetPath = RegExp(r'^[^/]+/(?:channel-\d+|\d{2}-[a-z][a-z0-9]*-\d+)/');

_Draft _draftOf(String chainId, String denom) {
  if (chainId.isEmpty || denom.isEmpty) return _unknownDraft(chainId, denom);
  if (isIbcDenom(denom)) {
    final row = _tableRow(chainId, denom);
    if (row != null) return _draftFromRow(row);
    final issued = _issuerRowOf(chainId, denom);
    final fromIssuer = issued == null ? null : _draftFromIssuerRow(chainId, denom, issued);
    if (fromIssuer != null) return fromIssuer;
    final fact = _facts[_factKey(chainId, denom)];
    if (fact != null) return _draftFromFact(chainId, denom, fact);
    return _unknownDraft(chainId, denom);
  }
  if (_packetPath.hasMatch(denom)) return _unknownDraft(chainId, denom);
  return _localDraftOf(chainId, denom);
}

/* -------------------------------------------------------------------------- *
 * Tickers, the collision guard and the final identity
 * -------------------------------------------------------------------------- */

String _unknownTicker(String denom) =>
    isIbcDenom(denom) ? 'IBC·${denom.substring(4, denom.length < 8 ? denom.length : 8).toUpperCase()}' : shortDenom(denom);

/// Four characters that tell two denoms apart.
String _hashTag(String denom) {
  final hex = isIbcDenom(denom)
      ? denom.substring(4)
      : sha256.convert(utf8.encode(denom)).toString();
  final tag = hex.length >= 4 ? hex.substring(0, 4) : hex;
  return tag.isEmpty ? '0000' : tag.toUpperCase();
}

Set<String>? _knownNames;

/// Every name the registries give an asset, uppercased. Bundled data only.
Set<String> _knownNameSet() {
  final cached = _knownNames;
  if (cached != null) return cached;
  final names = <String>{'IBC', ..._multiIssuer};
  void add(String symbol) {
    if (symbol.isEmpty) return;
    names.add(symbol.toUpperCase());
    names.add(familyOf(symbol).toUpperCase());
  }

  for (final row in tokenTableRows()) {
    add(row.family);
    row.aliases.forEach(add);
  }
  for (final entry in _bundled()) {
    add(entry.coinDenom);
    for (final currency in currenciesOf(entry)) {
      add(currency.coinDenom);
    }
  }
  return _knownNames = names;
}

final RegExp _allPrefix = RegExp(r'^all(?=[A-Z])');

/// The ticker of a token no registry names, from its own free text. When that
/// text claims a name the registries give a real asset, it carries a hash of
/// its denom (`USDC.n·3F2A`). `·` cannot occur in a denom.
String _unnamedTicker(_Draft draft) {
  final symbol = draft.symbol;
  if (symbol.isEmpty) return _unknownTicker(draft.denom);
  final known = _knownNameSet();
  final words = [
    symbol,
    familyOf(symbol),
    symbol.split('.').first,
    symbol.replaceFirst(_allPrefix, ''),
  ];
  final claims = words.any((word) => word.isNotEmpty && known.contains(word.toUpperCase()));
  return claims ? '$symbol·${_hashTag(draft.denom)}' : symbol;
}

bool _ownSymbolOnly(_Draft draft) =>
    draft.originChainId == null || _isNeverIssuer(draft.originChainId!);

String? _tickerOriginOf(_Draft draft) {
  if (draft.originDenom?.startsWith('l2/') ?? false) return _homeIssuerOf(draft.family);
  return draft.originChainId;
}

String _baseTicker(_Draft draft) {
  if (draft.provenance == TokenProvenance.unknown) return _unknownTicker(draft.denom);
  if (!draft.named) return _unnamedTicker(draft);
  if (_ownSymbolOnly(draft)) return draft.symbol;
  return tickerFor(TickerInput(
    family: draft.family,
    originChainId: _tickerOriginOf(draft),
    bridge: draft.bridge,
    sourceNetwork: draft.sourceNetwork,
    alloyed: draft.alloyed,
  ));
}

final Map<String, Map<String, String>> _guards = {};

int _compareStrings(String a, String b) => a.compareTo(b) < 0 ? -1 : 1;

/// Tickers on one holding chain after the collision guard. When several share
/// a ticker, the best ranked keeps it; the others take their issuer tag when
/// that separates them, else a 4-character hash of their denom.
Map<String, String> _guardFor(String chainId) {
  final cached = _guards[chainId];
  if (cached != null) return cached;
  final drafts = <String, _Draft>{};
  for (final row in tokenTableRows(chainId)) {
    drafts[denomKey(row.denom)] = _draftOf(chainId, row.denom);
  }
  final entry = _entry(chainId);
  if (entry != null) {
    for (final currency in currenciesOf(entry)) {
      if (isIbcDenom(currency.coinMinimalDenom)) continue;
      final key = denomKey(currency.coinMinimalDenom);
      drafts.putIfAbsent(key, () => _draftOf(chainId, currency.coinMinimalDenom));
    }
  }
  for (final denom in _table?.issuerDenoms[chainId] ?? const <String>[]) {
    final key = denomKey(denom);
    if (drafts.containsKey(key) || _cw20Listing(chainId, denom) != null) continue;
    drafts[key] = _draftOf(chainId, denom);
  }
  for (final MapEntry(:key, :value) in _facts.entries) {
    if (!key.startsWith('$chainId:')) continue;
    final denom = key.substring(chainId.length + 1);
    drafts.putIfAbsent(denom, () => _draftFromFact(chainId, denom, value));
  }
  final groups = <String, List<_Draft>>{};
  for (final draft in drafts.values) {
    if (draft.provenance == TokenProvenance.unknown) continue;
    groups.putIfAbsent(_baseTicker(draft), () => <_Draft>[]).add(draft);
  }
  final taken = groups.keys.toSet();
  final out = <String, String>{};
  final sorted = groups.entries.toList()..sort((a, b) => _compareStrings(a.key, b.key));
  for (final MapEntry(key: ticker, value: members) in sorted) {
    if (members.length < 2) continue;
    members.sort((a, b) {
      final byRank = a.rank - b.rank;
      if (byRank != 0) return byRank;
      return _compareStrings(denomKey(a.denom), denomKey(b.denom));
    });
    final keeper = members.first;
    for (final draft in members.skip(1)) {
      var next = ticker;
      final tag = draft.named && draft.originChainId != null ? _issuerTagOf(draft.originChainId!) : '';
      if (tag.isNotEmpty &&
          draft.originChainId != keeper.originChainId &&
          !ticker.endsWith('.$tag')) {
        final candidate = '$ticker.$tag';
        if (!taken.contains(candidate)) next = candidate;
      }
      if (next == ticker) {
        next = '$ticker·${_hashTag(draft.denom)}';
        for (var extra = 1; taken.contains(next); extra += 1) {
          next = '$next$extra';
        }
      }
      taken.add(next);
      out[denomKey(draft.denom)] = next;
    }
  }
  _guards[chainId] = out;
  return out;
}

List<String> _legacyAliases(_Draft draft) {
  if (draft.provenance == TokenProvenance.unknown || draft.alloyed) return const [];
  final out = <String>[];
  if (draft.family == 'ETH') out.add('WETH');
  if (draft.bridge == 'axl') {
    out.add('axl${draft.family}');
    if (draft.family == 'ETH') out.add('axlWETH');
  }
  if (draft.family == 'USDC' && draft.originChainId == 'noble-1') {
    out.addAll(const ['USDCnb', 'USDC.noble']);
  }
  if (draft.family == 'USDC' && draft.bridge == 'wh') out.add('USDCet');
  if (draft.family == 'USDT' && draft.originChainId == 'kava_2222-10') out.add('USDTkv');
  return out;
}

String _nameOf(_Draft draft, String? originName, String heldName) {
  if (draft.provenance == TokenProvenance.unknown) return 'Unknown token';
  // The origin is known but nothing names the token: never echo its own free
  // text as a name.
  if (!draft.named) return 'Unlisted ${originName ?? heldName} token';
  if (draft.alloyed) return 'Alloyed ${draft.family}';
  if (_ownSymbolOnly(draft)) return '${originName ?? heldName} ${draft.symbol}'.trim();
  final network = draft.sourceNetwork == null
      ? ''
      : ' from ${sourceNetworkNames[draft.sourceNetwork] ?? draft.sourceNetwork}';
  return '${originName ?? heldName} ${draft.family}$network';
}

TokenIdentity _finalize(_Draft draft) {
  final testnet = _isNeverIssuer(draft.heldOnChainId);
  final heldName = _chainNameOf(draft.heldOnChainId);
  final originName = draft.originChainId == null ? null : _chainNameOf(draft.originChainId!);
  final guarded = draft.provenance == TokenProvenance.unknown
      ? null
      : _guardFor(draft.heldOnChainId)[denomKey(draft.denom)];
  final ticker = guarded ?? _baseTicker(draft);
  final userAdded = isUserAddedChain(draft.heldOnChainId) ||
      (draft.originChainId != null && isUserAddedChain(draft.originChainId!));
  // No channel joins a testnet to a mainnet issuer: such a walk is forged.
  final crossesNetworks =
      testnet && draft.originChainId != null && !_isNeverIssuer(draft.originChainId!);
  final aliasSet = <String>{};
  for (final alias in [...draft.aliases, ..._legacyAliases(draft)]) {
    if (alias.isNotEmpty && alias != ticker && alias != draft.family) aliasSet.add(alias);
  }
  final originChainId = draft.originChainId;
  final originDenom = draft.originDenom;
  return TokenIdentity(
    key: '${draft.heldOnChainId}:${draft.denom}',
    heldOnChainId: draft.heldOnChainId,
    heldOnChainName: heldName,
    denom: draft.denom,
    kind: draft.kind,
    originChainId: originChainId,
    originChainName: originName,
    originDenom: originDenom,
    path: draft.path,
    hopChainIds: draft.hopChainIds,
    bridge: draft.bridge,
    sourceNetwork: draft.sourceNetwork,
    family: draft.family.isEmpty ? ticker : draft.family,
    ticker: ticker,
    name: _nameOf(draft, originName, heldName),
    decimals: draft.decimals ?? 0,
    decimalsKnown: draft.decimals != null,
    logoUrl: draft.logoUrl,
    coinGeckoId: draft.coinGeckoId,
    variantGroup: draft.variantGroup,
    alloyed: draft.alloyed,
    osmosisDenom: draft.heldOnChainId == osmosisChainId
        ? draft.denom
        : originChainId != null && originDenom != null
            ? osmosisDenomOf(originChainId, originDenom)
            : null,
    aliases: aliasSet.toList(),
    provenance: draft.provenance,
    // A chain the user typed in is not evidence, so nothing on it is proven.
    proven: draft.provenance != TokenProvenance.unknown &&
        draft.named &&
        !userAdded &&
        !crossesNetworks &&
        (draft.provenance != TokenProvenance.channelWalk || draft.walkCanonical == true),
    listed: draft.named,
    testnet: testnet,
  );
}

final Map<String, TokenIdentity> _memo = {};
int _memoGeneration = -1;
String? _memoCustom;
TokenRegistry? _memoTable;
const int _memoMax = 4000;

/// Drop derived state when the facts, the table or the user's chains change.
void _syncMemo() {
  final custom = '${ChainCatalog.isLoaded}\u0000'
      '${_custom().map((entry) => entry.chainId).join('\u0000')}';
  final table = _table;
  if (_memoGeneration == _generation && _memoCustom == custom && identical(_memoTable, table)) {
    return;
  }
  if (!identical(_memoTable, table) || _bundledRows == null) {
    _homeIssuers = null;
    _knownNames = null;
    _bundledIndex = null;
    _bundledRows = null;
  }
  _memo.clear();
  _guards.clear();
  _memoGeneration = _generation;
  _memoCustom = custom;
  _memoTable = table;
}

/// The identity of [denom] held on [chainId]. Synchronous and never throws: a
/// denom nothing proves comes back with provenance `unknown`, ticker
/// `IBC·498A`, no origin and unknown decimals, never a guessed issuer.
TokenIdentity identityOf(String chainId, String denom) {
  try {
    _syncMemo();
    final key = '$chainId:$denom';
    final cached = _memo[key];
    if (cached != null) return cached;
    final identity = _finalize(_draftOf(chainId, denom));
    if (_memo.length >= _memoMax) _memo.clear();
    _memo[key] = identity;
    return identity;
  } on Object {
    final ticker = _unknownTicker(denom);
    return TokenIdentity(
      key: '$chainId:$denom',
      heldOnChainId: chainId,
      heldOnChainName: chainId,
      denom: denom,
      kind: TokenKind.other,
      originChainId: null,
      originChainName: null,
      originDenom: null,
      path: '',
      hopChainIds: const [],
      bridge: null,
      sourceNetwork: null,
      family: ticker,
      ticker: ticker,
      name: 'Unknown token',
      decimals: 0,
      decimalsKnown: false,
      logoUrl: null,
      coinGeckoId: null,
      variantGroup: null,
      alloyed: false,
      osmosisDenom: null,
      aliases: const [],
      provenance: TokenProvenance.unknown,
      proven: false,
      listed: false,
      testnet: false,
    );
  }
}

/* -------------------------------------------------------------------------- *
 * Text
 * -------------------------------------------------------------------------- */

/// A token minted on the chain that holds it that nothing lists: anyone's
/// `factory/<self>/USDC.n`. It is never called native.
bool isUnlistedLocal(TokenIdentity identity) =>
    identity.provenance != TokenProvenance.unknown &&
    !identity.listed &&
    identity.originChainId == identity.heldOnChainId;

/// The words an unlisted local token gets where a listed one reads "Native".
const String unlistedTokenLabel = 'Unlisted token';

/// The words for one identity, so no screen builds token text itself.
/// - `pill`: `on Osmosis`.
/// - `row`: `Native on Injective`, `Noble USDC · on Osmosis`,
///   `Unlisted token · on Osmosis`, `Unknown origin · on Osmosis · ibc/498A…6BA6E4`.
/// - `sentence`: `USDC.n (Noble USDC) on Osmosis`, `ATOM on Cosmos Hub`.
/// - `a11y`: `USDC from Noble, on Osmosis`, `ATOM, native on Cosmos Hub`.
String tokenText(TokenIdentity identity, TokenTextVariant variant) {
  final held = identity.heldOnChainName;
  final unknown = identity.provenance == TokenProvenance.unknown;
  final home = !unknown && identity.originChainId == identity.heldOnChainId;
  final unlisted = isUnlistedLocal(identity);
  switch (variant) {
    case TokenTextVariant.pill:
      return 'on $held';
    case TokenTextVariant.row:
      if (unknown) return 'Unknown origin · on $held · ${shortDenom(identity.denom)}';
      if (unlisted) return '$unlistedTokenLabel · on $held';
      if (identity.alloyed && home) return '${identity.name} · $held only';
      return home ? 'Native on $held' : '${identity.name} · on $held';
    case TokenTextVariant.sentence:
      if (unknown) return 'unknown token ${shortDenom(identity.denom)} on $held';
      if (unlisted) return '${identity.ticker} (unlisted token) on $held';
      return home
          ? '${identity.ticker} on $held'
          : '${identity.ticker} (${identity.name}) on $held';
    case TokenTextVariant.a11y:
      if (unknown) return 'Unknown token ${shortDenom(identity.denom)}, on $held';
      if (unlisted) return '${identity.ticker}, unlisted token, on $held';
      if (identity.alloyed || !identity.listed) return '${identity.name}, on $held';
      return home
          ? '${identity.ticker}, native on $held'
          : '${identity.family} from ${identity.originChainName ?? 'an unknown chain'}, on $held';
  }
}

/// Everything a search should match: ticker, family, aliases, name, the origin
/// and location chains, the denom and the origin denom.
List<String> tokenKeywords(TokenIdentity identity) {
  final words = <String>[
    identity.ticker,
    identity.family,
    ...identity.aliases,
    identity.name,
    identity.originChainName ?? '',
    identity.originChainId ?? '',
    identity.heldOnChainName,
    identity.heldOnChainId,
    identity.denom,
    identity.originDenom ?? '',
    identity.sourceNetwork == null ? '' : (sourceNetworkNames[identity.sourceNetwork] ?? ''),
  ];
  return {for (final word in words) if (word.isNotEmpty) word}.toList();
}

/// The single label for a token kind.
String tokenKindLabel(TokenKind kind) => switch (kind) {
      TokenKind.native => 'Native',
      TokenKind.ibc => 'IBC',
      TokenKind.factory => 'Factory',
      TokenKind.erc20 => 'ERC-20',
      TokenKind.peggy => 'Peggy',
      TokenKind.cw20 => 'CW20',
      TokenKind.other => 'Asset',
    };

/// The "Issued on" line: `Noble`, `Noble (not verified)`, or `Unknown`.
String issuerText(TokenIdentity identity) {
  if (identity.provenance == TokenProvenance.unknown || identity.originChainId == null) {
    return 'Unknown';
  }
  final name = identity.originChainName ?? identity.originChainId!;
  return identity.proven ? name : '$name (not verified)';
}

/* -------------------------------------------------------------------------- *
 * Short forms
 * -------------------------------------------------------------------------- */

final RegExp _bridgedDenom = RegExp(r'^(erc20:0x|peggy0x|gravity0x)([0-9a-fA-F]{12,})$');

/// The one short form of a denom: `ibc/498A…6BA6E4`, `erc20:0xa00C…235a`, a
/// clipped factory path, else the denom. Display only.
String shortDenom(String denom) {
  if (denom.startsWith('factory/')) {
    final parts = denom.split('/');
    final sub = parts.last;
    final creator = parts.length > 1 ? parts[1] : '';
    final clipped = creator.length > 12
        ? '${creator.substring(0, 6)}…${creator.substring(creator.length - 4)}'
        : creator;
    return clipped.isEmpty ? denom : 'factory/$clipped/$sub';
  }
  if (denom.startsWith('ibc/')) {
    return denom.length <= 20
        ? denom
        : 'ibc/${denom.substring(4, 8)}…${denom.substring(denom.length - 6)}';
  }
  final bridged = _bridgedDenom.firstMatch(denom);
  if (bridged != null) {
    final hex = bridged.group(2)!;
    return '${bridged.group(1)}${hex.substring(0, 4)}…${hex.substring(hex.length - 4)}';
  }
  return denom;
}

/* -------------------------------------------------------------------------- *
 * Held rows
 * -------------------------------------------------------------------------- */

/// Exponents past this are not a token's decimals but a broken record.
const int maxTokenDecimals = 30;

/// The identity a held row is shown with: [identityOf] for its names, and the
/// row's own decimals when nothing names the token but the chain's metadata
/// gave them. A named token keeps its identity's decimals, known or not.
TokenIdentity heldTokenIdentity(
  String chainId,
  String denom, {
  int? metadataDecimals,
}) {
  final identity = identityOf(chainId, denom);
  if (identity.provenance != TokenProvenance.unknown || identity.decimalsKnown) {
    return identity;
  }
  final decimals = metadataDecimals;
  if (decimals == null || decimals < 0 || decimals > maxTokenDecimals) return identity;
  return identity.copyWith(decimals: decimals, decimalsKnown: true);
}

/// Waits for [work] at most [budget]; true when it settled in time.
Future<bool> settleWithin(Future<Object?> work, Duration budget) async {
  var settled = false;
  final done = work.then((_) => settled = true, onError: (Object _) => settled = true);
  await Future.any([done, Future<void>.delayed(budget)]);
  return settled;
}
