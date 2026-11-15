/// Optional spot prices.
///
/// Mirrors `zunia-extension/lib/prices.ts`: a chain is priced from CoinGecko
/// through its catalog `coinGeckoId`; a chain with none is priced from the one
/// on-chain pool `assets/data/prices.json` names for it (SAF in Osmosis pool
/// 3600, against USDC), read from Osmosis itself, and that price carries its
/// source so every surface can say where it comes from. No exchange is asked
/// for anything: the price is the pool's spot price, the 24 h change compares
/// it with the pool's TWAP over the hour a day ago, and USDC is converted to
/// the user's currency with CoinGecko's USDC price.
///
/// One difference, for 300 enabled chains: the extension asks CoinGecko's
/// per-coin route one coin at a time (its batch route answers a browser
/// extension with a CloudFront 403). An app is not refused, so the batch
/// route is asked first, a hundred ids per request, and the per-coin route is
/// only the fallback when the batch route refuses. The numbers are the same
/// either way: price and 24 h change in the requested currency.
///
/// Nothing here is a balance. A price that could not be read is absent, never
/// zero, and the last good answer is kept and marked stale rather than lost
/// to one rate-limited refresh.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:zunia_mobile/chains/chain_catalog.dart';

/// Currencies the wallet prices in. The first is the fallback.
const List<String> supportedCurrencies = ['usd', 'eur', 'gbp', 'jpy', 'chf'];

String normaliseCurrency(String value) {
  final lower = value.trim().toLowerCase();
  return supportedCurrencies.contains(lower) ? lower : 'usd';
}

/// The on-chain pool a chain is priced from when it has no CoinGecko id.
@immutable
class PoolPriceSource {
  const PoolPriceSource({
    required this.chainId,
    required this.poolId,
    required this.baseDenom,
    required this.quoteDenom,
    required this.quoteGeckoId,
    required this.name,
    required this.pair,
    required this.url,
  });

  factory PoolPriceSource.fromJson(Map<String, dynamic> json) => PoolPriceSource(
        chainId: json['chainId'] as String? ?? '',
        poolId: json['poolId'] as String? ?? '',
        baseDenom: json['baseDenom'] as String? ?? '',
        quoteDenom: json['quoteDenom'] as String? ?? '',
        quoteGeckoId: json['quoteGeckoId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        pair: json['pair'] as String? ?? '',
        url: json['url'] as String? ?? '',
      );

  /// The chain the pool lives on (osmosis-1); its catalog LCD answers.
  final String chainId;
  final String poolId;

  /// The priced coin and what it is counted in, as the pool holds them.
  final String baseDenom;
  final String quoteDenom;

  /// CoinGecko id of the quote asset, to convert into the user's currency.
  final String quoteGeckoId;

  /// Shown beside the price: "via Osmosis".
  final String name;
  final String pair;

  /// The pool's public page, linked from the price.
  final String url;
}

/// Where a price came from when it is one on-chain pool, not an aggregate.
@immutable
class PriceSource {
  const PriceSource({required this.name, required this.pair, required this.url});

  final String name;
  final String pair;
  final String url;
}

@immutable
class SpotPrice {
  const SpotPrice({required this.price, required this.change24h, this.source});

  /// One whole coin in the requested currency.
  final double price;

  /// 24 h change as a percentage, e.g. `-1.24`.
  final double change24h;
  final PriceSource? source;
}

/// Prices keyed by chain id: each chain's own staking coin.
typedef PriceMap = Map<String, SpotPrice>;

/// What a price read produced.
@immutable
class PriceSnapshot {
  const PriceSnapshot({
    required this.currency,
    required this.prices,
    this.fetchedAt,
    this.stale = false,
    this.problem,
  });

  static const empty = PriceSnapshot(currency: 'usd', prices: {});

  final String currency;
  final PriceMap prices;

  /// When the oldest price in [prices] was read.
  final DateTime? fetchedAt;

  /// The last refresh failed and these are older answers.
  final bool stale;

  /// Why some price is missing (rate limit, offline). Never a number.
  final String? problem;
}

/// One HTTP GET returning decoded JSON, or throwing [PriceHttpException].
typedef PriceHttp = Future<Object?> Function(Uri uri);

class PriceHttpException implements Exception {
  const PriceHttpException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

/// What one chain is priced from.
@immutable
class PriceTarget {
  const PriceTarget({required this.chainId, this.coinGeckoId, this.pool});

  final String chainId;
  final String? coinGeckoId;
  final PoolPriceSource? pool;
}

const String _coinEndpoint = 'https://api.coingecko.com/api/v3/coins/';
const String _simpleEndpoint = 'https://api.coingecko.com/api/v3/simple/price';

/// A few at a time: the free per-coin route rejects a burst with 429.
const int _perCoinConcurrency = 4;
const int _batchSize = 100;

/// How long a price counts as current.
const Duration priceCacheTtl = Duration(seconds: 120);
const Duration _requestTimeout = Duration(seconds: 8);

/// The pool's price and 24 h change, in its quote asset: the spot price
/// (`/osmosis/poolmanager/v2/pools/{id}/prices`) against the arithmetic TWAP
/// over the hour that ended a day ago. Null for a spot price it cannot read;
/// without a TWAP the change stays 0 rather than an invented one.
({double price, double change24h})? parsePoolQuote(Object? spot, Object? twap) {
  final price = spot is Map ? _number(spot['spot_price']) : null;
  if (price == null || !(price > 0)) return null;
  final before = twap is Map ? _number(twap['arithmetic_twap']) : null;
  final change = before != null && before > 0 ? (price - before) / before * 100 : 0.0;
  return (price: price, change24h: change);
}

double? _number(Object? value) {
  if (value is num) return value.isFinite ? value.toDouble() : null;
  if (value is String) {
    final parsed = double.tryParse(value);
    return parsed != null && parsed.isFinite ? parsed : null;
  }
  return null;
}

/// One CoinGecko per-coin body: `market_data.current_price[currency]` and the
/// 24 h change in that currency (or the USD change when it has none).
({double price, double change24h})? parseCoinQuote(Object? body, String currency) {
  if (body is! Map) return null;
  final market = body['market_data'];
  if (market is! Map) return null;
  final current = market['current_price'];
  final price = current is Map ? _number(current[currency]) : null;
  if (price == null) return null;
  final inCurrency = market['price_change_percentage_24h_in_currency'];
  final change = (inCurrency is Map ? _number(inCurrency[currency]) : null) ??
      _number(market['price_change_percentage_24h']) ??
      0;
  return (price: price, change24h: change);
}

/// CoinGecko's batch body: `{id: {usd: 1.7, usd_24h_change: -0.27}}`.
Map<String, ({double price, double change24h})> parseSimplePrices(
  Object? body,
  String currency,
) {
  final out = <String, ({double price, double change24h})>{};
  if (body is! Map) return out;
  for (final MapEntry(:key, :value) in body.entries) {
    if (key is! String || value is! Map) continue;
    final price = _number(value[currency]);
    if (price == null) continue;
    out[key] = (price: price, change24h: _number(value['${currency}_24h_change']) ?? 0);
  }
  return out;
}

class PriceService {
  PriceService({
    PriceHttp? http,
    DateTime Function()? now,
    String? Function(String chainId)? restOf,
  })  : _http = http ?? _defaultHttp,
        _now = now ?? DateTime.now,
        _restOf = restOf ?? _catalogRest;

  final PriceHttp _http;
  final DateTime Function() _now;

  /// The LCD that answers for a pool's chain.
  final String? Function(String chainId) _restOf;

  static String? _catalogRest(String chainId) =>
      ChainCatalog.isLoaded ? ChainCatalog.instance.find(chainId)?.rest : null;

  /// Per currency: chain id → (price, when it was read).
  final Map<String, Map<String, (SpotPrice, DateTime)>> _cache = {};

  /// Only one refresh at a time; overlapping callers share it.
  Future<PriceSnapshot>? _inFlight;
  String? _inFlightKey;

  /// Prices for [targets] in [currency]. Answers from the cache when every
  /// target is fresh; otherwise asks for the stale and missing ones only.
  Future<PriceSnapshot> prices(
    List<PriceTarget> targets,
    String currency, {
    bool force = false,
  }) {
    final key = '$currency|$force|${targets.map((t) => t.chainId).join(',')}';
    final running = _inFlight;
    if (running != null && _inFlightKey == key) return running;
    final run = _prices(targets, normaliseCurrency(currency), force: force);
    _inFlight = run;
    _inFlightKey = key;
    return run.whenComplete(() {
      if (identical(_inFlight, run)) {
        _inFlight = null;
        _inFlightKey = null;
      }
    });
  }

  Future<PriceSnapshot> _prices(
    List<PriceTarget> targets,
    String currency, {
    required bool force,
  }) async {
    final cache = _cache.putIfAbsent(currency, () => {});
    final now = _now();
    final due = [
      for (final target in targets)
        if (force ||
            cache[target.chainId] == null ||
            now.difference(cache[target.chainId]!.$2) >= priceCacheTtl)
          target,
    ];
    String? problem;
    if (due.isNotEmpty) {
      try {
        final fresh = await _fetch(due, currency);
        final at = _now();
        for (final MapEntry(:key, :value) in fresh.prices.entries) {
          cache[key] = (value, at);
        }
        problem = fresh.problem;
      } on Object catch (error) {
        problem = 'Prices could not be read: $error';
      }
    }
    final prices = <String, SpotPrice>{};
    DateTime? oldest;
    var stale = false;
    for (final target in targets) {
      final hit = cache[target.chainId];
      if (hit == null) continue;
      prices[target.chainId] = hit.$1;
      if (oldest == null || hit.$2.isBefore(oldest)) oldest = hit.$2;
      if (_now().difference(hit.$2) >= priceCacheTtl) stale = true;
    }
    return PriceSnapshot(
      currency: currency,
      prices: prices,
      fetchedAt: oldest,
      stale: stale,
      problem: problem,
    );
  }

  Future<({PriceMap prices, String? problem})> _fetch(
    List<PriceTarget> targets,
    String currency,
  ) async {
    final geckoByChain = <String, String>{};
    final poolByChain = <String, PoolPriceSource>{};
    for (final target in targets) {
      final id = target.coinGeckoId;
      if (id != null && id.isNotEmpty) {
        geckoByChain[target.chainId] = id;
      } else if (target.pool != null) {
        poolByChain[target.chainId] = target.pool!;
      }
    }
    // The pools' quote assets too (USDC), to convert into the user's currency.
    final ids = <String>{
      ...geckoByChain.values,
      for (final pool in poolByChain.values)
        if (pool.quoteGeckoId.isNotEmpty) pool.quoteGeckoId,
    }.toList()
      ..sort();
    String? problem;
    final quotes = <String, ({double price, double change24h})>{};
    if (ids.isNotEmpty) {
      final read = await _coinGecko(ids, currency);
      quotes.addAll(read.quotes);
      problem = read.problem;
    }
    final pools = await _pool(
      poolByChain.entries.toList(),
      _perCoinConcurrency,
      (entry) async => (chainId: entry.key, source: entry.value, quote: await _poolQuote(entry.value)),
    );

    final prices = <String, SpotPrice>{};
    for (final MapEntry(key: chainId, value: id) in geckoByChain.entries) {
      final quote = quotes[id];
      if (quote == null) continue;
      prices[chainId] = SpotPrice(price: quote.price, change24h: quote.change24h);
    }
    for (final pool in pools) {
      final quote = pool.quote;
      // The quote asset in the user's currency; without its quote only USD
      // can assume par.
      final unit = quotes[pool.source.quoteGeckoId]?.price ?? (currency == 'usd' ? 1.0 : null);
      if (quote == null || unit == null) continue;
      prices[pool.chainId] = SpotPrice(
        price: quote.price * unit,
        change24h: quote.change24h,
        source: PriceSource(name: pool.source.name, pair: pool.source.pair, url: pool.source.url),
      );
    }
    if (poolByChain.isNotEmpty && pools.any((p) => p.quote == null)) {
      problem ??= 'A pool price could not be read.';
    }
    return (prices: prices, problem: problem);
  }

  /// The batch route first; the per-coin route for what it refused.
  Future<({Map<String, ({double price, double change24h})> quotes, String? problem})> _coinGecko(
    List<String> ids,
    String currency,
  ) async {
    final quotes = <String, ({double price, double change24h})>{};
    String? problem;
    var batchRefused = false;
    for (var start = 0; start < ids.length; start += _batchSize) {
      final chunk = ids.sublist(start, start + _batchSize > ids.length ? ids.length : start + _batchSize);
      final uri = Uri.parse(_simpleEndpoint).replace(queryParameters: {
        'ids': chunk.join(','),
        'vs_currencies': currency,
        'include_24hr_change': 'true',
      });
      try {
        quotes.addAll(parseSimplePrices(await _http(uri), currency));
      } on PriceHttpException catch (error) {
        if (error.status == 429) {
          problem = 'The price feed is rate limiting this device. Prices refresh in a minute.';
          return (quotes: quotes, problem: problem);
        }
        batchRefused = true;
      } on Object {
        batchRefused = true;
      }
    }
    if (!batchRefused) return (quotes: quotes, problem: problem);
    final missing = [for (final id in ids) if (!quotes.containsKey(id)) id];
    final perCoin = await _pool(missing, _perCoinConcurrency, (id) async {
      final uri = Uri.parse('$_coinEndpoint${Uri.encodeComponent(id)}').replace(queryParameters: {
        'localization': 'false',
        'tickers': 'false',
        'market_data': 'true',
        'community_data': 'false',
        'developer_data': 'false',
        'sparkline': 'false',
      });
      try {
        return (id: id, quote: parseCoinQuote(await _http(uri), currency));
      } on Object {
        return (id: id, quote: null);
      }
    });
    for (final row in perCoin) {
      final quote = row.quote;
      if (quote != null) quotes[row.id] = quote;
    }
    if (perCoin.any((row) => row.quote == null)) {
      problem = 'Some prices could not be read.';
    }
    return (quotes: quotes, problem: problem);
  }

  Future<({double price, double change24h})?> _poolQuote(PoolPriceSource source) async {
    final rest = _restOf(source.chainId)?.trim().replaceAll(RegExp(r'/+$'), '');
    if (rest == null || rest.isEmpty || source.poolId.isEmpty) return null;
    String stamp(DateTime at) => '${at.toUtc().toIso8601String().split('.').first}Z';
    final now = _now();
    try {
      final spot = await _http(
        Uri.parse('$rest/osmosis/poolmanager/v2/pools/${source.poolId}/prices').replace(
          queryParameters: {
            'base_asset_denom': source.baseDenom,
            'quote_asset_denom': source.quoteDenom,
          },
        ),
      );
      Object? twap;
      try {
        twap = await _http(
          Uri.parse('$rest/osmosis/twap/v1beta1/ArithmeticTwap').replace(
            queryParameters: {
              'pool_id': source.poolId,
              'base_asset': source.baseDenom,
              'quote_asset': source.quoteDenom,
              'start_time': stamp(now.subtract(const Duration(hours: 25))),
              'end_time': stamp(now.subtract(const Duration(hours: 24))),
            },
          ),
        );
      } on Object {
        twap = null;
      }
      return parsePoolQuote(spot, twap);
    } on Object {
      return null;
    }
  }

  static Future<List<R>> _pool<T, R>(List<T> items, int limit, Future<R> Function(T) fn) async {
    final out = List<R?>.filled(items.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < items.length) {
        final index = next++;
        out[index] = await fn(items[index]);
      }
    }

    await Future.wait([for (var i = 0; i < limit && i < items.length; i++) worker()]);
    return out.cast<R>();
  }

  static Future<Object?> _defaultHttp(Uri uri) async {
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final request = await client.getUrl(uri).timeout(_requestTimeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_requestTimeout);
      final text = await response.transform(utf8.decoder).join().timeout(_requestTimeout);
      if (response.statusCode != 200) {
        throw PriceHttpException('HTTP ${response.statusCode}', status: response.statusCode);
      }
      try {
        return jsonDecode(text);
      } on FormatException {
        throw const PriceHttpException('The price feed answered with something that is not JSON');
      }
    } on TimeoutException {
      throw const PriceHttpException('The price feed did not answer in time');
    } on SocketException catch (error) {
      throw PriceHttpException('The price feed could not be reached (${error.message})');
    } finally {
      client.close(force: true);
    }
  }
}

/* -------------------------------------------------------------------------- *
 * Bundled pool sources
 * -------------------------------------------------------------------------- */

Map<String, PoolPriceSource>? _poolSources;

/// `assets/data/prices.json`, decoded once.
Future<Map<String, PoolPriceSource>> loadPoolSources() async {
  final cached = _poolSources;
  if (cached != null) return cached;
  try {
    final raw = await rootBundle.loadString('assets/data/prices.json');
    return _poolSources = decodePoolSources(raw);
  } on Object {
    return _poolSources = const {};
  }
}

/// The sources already loaded, or empty before [loadPoolSources].
Map<String, PoolPriceSource> get poolSources => _poolSources ?? const {};

Map<String, PoolPriceSource> decodePoolSources(String raw) {
  final json = jsonDecode(raw);
  final sources = json is Map ? json['poolSources'] : null;
  if (sources is! Map) return const {};
  return {
    for (final MapEntry(:key, :value) in sources.entries)
      if (key is String && value is Map<String, dynamic>) key: PoolPriceSource.fromJson(value),
  };
}

@visibleForTesting
void debugSetPoolSources(Map<String, PoolPriceSource> sources) => _poolSources = sources;
