import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/prices/fiat.dart';
import 'package:zunia_mobile/prices/price_service.dart';

/// Prices as extension 0.1.5 reads them (lib/__tests__/prices.test.ts): SAF
/// from Coinstore's SAF/USDT hourly candles, converted through CoinGecko's
/// Tether price, and everything else from CoinGecko.
Map<String, Object?> klines([List<double>? closes]) {
  final values = closes ?? [for (var i = 0; i < 24; i++) i == 23 ? 0.00028 : 0.0003];
  return {
    'code': 0,
    'data': {
      'channel': '1938@kline@hour_1',
      'item': [
        for (var i = 0; i < values.length; i++)
          {
            'startTime': 1791230400 + i * 3600,
            'open': '${i == 0 ? 0.000309 : 0.0003}',
            'close': '${values[i]}',
            'high': '0.00031',
            'low': '0.000261',
          },
      ],
    },
  };
}

const saf = ExchangePriceSource(
  exchange: 'coinstore',
  name: 'Coinstore',
  market: 'SAFUSDT',
  pair: 'SAF/USDT',
  url: 'https://www.coinstore.com/spot/SAFUSDT',
);

const targets = [
  PriceTarget(chainId: 'safrochain-1', exchange: saf),
  PriceTarget(chainId: 'osmosis-1', coinGeckoId: 'osmosis'),
];

void main() {
  group('Coinstore candles', () {
    test('read the last price and the 24h change from the hourly bars', () {
      final quote = parseCoinstoreKlines(klines())!;
      expect(quote.price, 0.00028);
      expect(quote.change24h, closeTo(((0.00028 - 0.000309) / 0.000309) * 100, 1e-6));
      // Out-of-order bars are sorted by time; only the last 24 count.
      final shuffled = klines();
      ((shuffled['data']! as Map)['item']! as List).setAll(0, (((shuffled['data']! as Map)['item']! as List).reversed.toList()));
      expect(parseCoinstoreKlines(shuffled)!.price, quote.price);
      expect(parseCoinstoreKlines(shuffled)!.change24h, quote.change24h);
      for (final bad in <Object?>[
        null,
        <String, Object?>{},
        {'data': {'item': <Object?>[]}},
        {
          'data': {
            'item': [
              {'startTime': 1, 'open': '0', 'close': '1'},
            ],
          },
        },
      ]) {
        expect(parseCoinstoreKlines(bad), isNull);
      }
    });

    test('keep only the last 24 bars of a longer window', () {
      final long = klines([for (var i = 0; i < 30; i++) 0.0004]);
      final quote = parseCoinstoreKlines(long)!;
      // The oldest kept bar opens at 0.0003 (bar 6), not bar 0's 0.000309.
      expect(quote.change24h, closeTo(((0.0004 - 0.0003) / 0.0003) * 100, 1e-6));
    });
  });

  group('PriceService', () {
    late Map<String, Object?> routes;
    late List<Uri> calls;
    late DateTime clock;
    late PriceService service;

    setUp(() {
      calls = [];
      clock = DateTime(2026, 10, 18, 12);
      routes = {
        'https://api.coingecko.com/api/v3/simple/price': {
          'tether': {'usd': 1.0002, 'usd_24h_change': 0.01, 'eur': 0.92, 'eur_24h_change': 0.2},
          'osmosis': {'usd': 0.2, 'usd_24h_change': 2, 'eur': 0.18, 'eur_24h_change': 2.5},
        },
        'https://api.coinstore.com/api/v1/market/kline/SAFUSDT': klines(),
      };
      service = PriceService(
        now: () => clock,
        http: (uri) async {
          calls.add(uri);
          final key = '${uri.scheme}://${uri.host}${uri.path}';
          final body = routes[key];
          if (body is PriceHttpException) throw body;
          if (body == null) throw const PriceHttpException('HTTP 404', status: 404);
          return body;
        },
      );
    });

    test('prices SAF in USD through Tether, and says where the price comes from', () async {
      final snapshot = await service.prices(targets, 'USD');
      final safPrice = snapshot.prices['safrochain-1']!;
      expect(safPrice.price, closeTo(0.00028 * 1.0002, 1e-12));
      expect(safPrice.change24h, lessThan(0));
      expect(safPrice.source!.name, 'Coinstore');
      expect(safPrice.source!.pair, 'SAF/USDT');
      expect(safPrice.source!.url, 'https://www.coinstore.com/spot/SAFUSDT');
      final osmo = snapshot.prices['osmosis-1']!;
      expect(osmo.price, 0.2);
      expect(osmo.change24h, 2);
      expect(osmo.source, isNull);
      final kline = calls.firstWhere((uri) => uri.path.contains('/kline/SAFUSDT'));
      expect(kline.queryParameters, {'period': '60min', 'size': '24'});
      // One batch request carries every CoinGecko id, Tether included.
      final batch = calls.where((uri) => uri.path.endsWith('/simple/price')).single;
      expect(batch.queryParameters['ids'], 'osmosis,tether');
      expect(batch.queryParameters['vs_currencies'], 'usd');
    });

    test("converts to the user's currency through Tether", () async {
      final snapshot = await service.prices(targets, 'eur');
      expect(snapshot.prices['safrochain-1']!.price, closeTo(0.00028 * 0.92, 1e-12));
      expect(snapshot.prices['osmosis-1']!.price, 0.18);
    });

    test('leaves SAF unpriced when USDT cannot be converted, except at USD par', () async {
      routes['https://api.coingecko.com/api/v3/simple/price'] = {
        'osmosis': {'usd': 0.2, 'eur': 0.18},
      };
      final eur = await service.prices(targets, 'EUR', force: true);
      expect(eur.prices['safrochain-1'], isNull);
      final usd = await service.prices(targets, 'USD', force: true);
      expect(usd.prices['safrochain-1']!.price, 0.00028);
    });

    test('leaves SAF unpriced when Coinstore does not answer', () async {
      routes.remove('https://api.coinstore.com/api/v1/market/kline/SAFUSDT');
      final snapshot = await service.prices(targets, 'USD');
      expect(snapshot.prices['safrochain-1'], isNull);
      expect(snapshot.prices['osmosis-1']!.price, 0.2);
      expect(snapshot.problem, isNotNull);
    });

    test('answers from the cache for two minutes, then reads again', () async {
      await service.prices(targets, 'USD');
      final first = calls.length;
      clock = clock.add(const Duration(seconds: 119));
      await service.prices(targets, 'USD');
      expect(calls.length, first);
      clock = clock.add(const Duration(seconds: 2));
      await service.prices(targets, 'USD');
      expect(calls.length, greaterThan(first));
    });

    test('keeps the last good price, marked stale, when a refresh is rate limited', () async {
      await service.prices(targets, 'USD');
      clock = clock.add(const Duration(minutes: 5));
      routes['https://api.coingecko.com/api/v3/simple/price'] =
          const PriceHttpException('HTTP 429', status: 429);
      routes.remove('https://api.coinstore.com/api/v1/market/kline/SAFUSDT');
      final snapshot = await service.prices(targets, 'USD');
      // Never a zero: the old price stays, and the snapshot says it is old.
      expect(snapshot.prices['osmosis-1']!.price, 0.2);
      expect(snapshot.stale, isTrue);
      expect(snapshot.problem, contains('rate limiting'));
    });

    test('falls back to the per-coin route when the batch route refuses', () async {
      routes['https://api.coingecko.com/api/v3/simple/price'] = const PriceHttpException('HTTP 403', status: 403);
      routes['https://api.coingecko.com/api/v3/coins/osmosis'] = {
        'market_data': {
          'current_price': {'usd': 0.21},
          'price_change_percentage_24h': 1.5,
        },
      };
      routes['https://api.coingecko.com/api/v3/coins/tether'] = {
        'market_data': {
          'current_price': {'usd': 1.0},
          'price_change_percentage_24h_in_currency': {'usd': 0.0},
        },
      };
      final snapshot = await service.prices(targets, 'USD');
      expect(snapshot.prices['osmosis-1']!.price, 0.21);
      expect(snapshot.prices['osmosis-1']!.change24h, 1.5);
      expect(snapshot.prices['safrochain-1']!.price, closeTo(0.00028, 1e-12));
    });

    test('a coin with neither a CoinGecko id nor an exchange market stays unpriced', () async {
      final snapshot = await service.prices(const [PriceTarget(chainId: 'nowhere-1')], 'USD');
      expect(snapshot.prices, isEmpty);
    });
  });

  group('currencies', () {
    test('normalise to the five the wallet prices in', () {
      expect(normaliseCurrency('USD'), 'usd');
      expect(normaliseCurrency('chf'), 'chf');
      expect(normaliseCurrency('JPY'), 'jpy');
      expect(normaliseCurrency('XYZ'), 'usd');
    });

    test('read the bundled exchange sources', () {
      final sources = decodeExchangeSources(File('assets/data/prices.json').readAsStringSync());
      expect(sources['safrochain-1']!.pair, 'SAF/USDT');
      expect(sources['safrochain-1']!.market, 'SAFUSDT');
    });
  });

  group('fiat text', () {
    test('keeps the digits a small price needs', () {
      expect(formatFiatPrice(0.00028, 'usd'), r'$0.00028');
      expect(formatFiatPrice(0.000280056, 'usd'), r'$0.0002801');
      expect(formatFiatPrice(0.1234567, 'eur'), '€0.1235');
      expect(formatFiatPrice(0, 'usd'), formatFiatPrice(-1, 'usd'));
      expect(formatFiatPrice(1.7, 'gbp'), '£1.70');
    });

    test('groups the headline and cuts instead of rounding up', () {
      expect(formatFiatFull(12408.2, 'usd'), r'$12,408.20');
      expect(formatFiatFull(0.999, 'usd'), r'$0.99');
      expect(formatFiatFull(1234567, 'eur'), '€1.23M');
      expect(formatFiatFull(1500, 'jpy'), '¥1,500');
      expect(formatFiatFull(12.5, 'chf'), 'CHF 12.50');
    });

    test('compacts list values', () {
      expect(formatFiatCompact(20345, 'usd'), r'$20.34k');
      expect(formatFiatCompact(12.5, 'usd'), r'$12.50');
      expect(formatChange(1.234), '+1.2%');
      expect(formatChange(-0.46, digits: 2), '-0.46%');
    });
  });
}
