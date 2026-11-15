import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/prices/fiat.dart';
import 'package:zunia_mobile/prices/price_service.dart';

/// Prices as the extension reads them (lib/__tests__/prices.test.ts): SAF from
/// its Osmosis pool (3600, against USDC), read on chain and converted through
/// CoinGecko's USDC price, and everything else from CoinGecko.
const osmosisLcd = 'https://lcd-osmosis.keplr.app';
const spotPath = '$osmosisLcd/osmosis/poolmanager/v2/pools/3600/prices';
const twapPath = '$osmosisLcd/osmosis/twap/v1beta1/ArithmeticTwap';

const saf = PoolPriceSource(
  chainId: 'osmosis-1',
  poolId: '3600',
  baseDenom: 'ibc/DBAA4846F611A7603EFCE6F9F46F4F561D48B1F492A576022F000614A17089CE',
  quoteDenom: 'factory/osmo147h5x9pcj7lm0cttlaefx6sqq5vdfnmwfcqxkmjd7exqm9gc7grqhr75m0/alloyed/allUSDC',
  quoteGeckoId: 'usd-coin',
  name: 'Osmosis',
  pair: 'SAF/USDC',
  url: 'https://app.osmosis.zone/pool/3600',
);

const targets = [
  PriceTarget(chainId: 'safrochain-1', pool: saf),
  PriceTarget(chainId: 'osmosis-1', coinGeckoId: 'osmosis'),
];

void main() {
  group('the Osmosis pool', () {
    test('reads the spot price, and the change against the TWAP a day ago', () {
      final quote = parsePoolQuote({'spot_price': '0.0002'}, {'arithmetic_twap': '0.00025'})!;
      expect(quote.price, 0.0002);
      expect(quote.change24h, closeTo(-20, 1e-9));
      // No TWAP: the price stands and no change is invented.
      final alone = parsePoolQuote({'spot_price': '0.0002'}, null)!;
      expect(alone.change24h, 0);
      for (final bad in [null, <String, Object?>{}, {'spot_price': '0'}, {'spot_price': 'x'}]) {
        expect(parsePoolQuote(bad, null), isNull);
      }
    });
  });

  group('PriceService', () {
    late Map<String, Object?> routes;
    late List<Uri> calls;
    late DateTime clock;
    late PriceService service;

    setUp(() {
      calls = [];
      clock = DateTime.utc(2026, 11, 15, 12);
      routes = {
        'https://api.coingecko.com/api/v3/simple/price': {
          'usd-coin': {'usd': 0.9998, 'usd_24h_change': 0.01, 'eur': 0.92, 'eur_24h_change': 0.2},
          'osmosis': {'usd': 0.2, 'usd_24h_change': 2, 'eur': 0.18, 'eur_24h_change': 2.5},
        },
        spotPath: {'spot_price': '0.000202749040940238000000000000000000'},
        twapPath: {'arithmetic_twap': '0.000284792120779832'},
      };
      service = PriceService(
        now: () => clock,
        restOf: (chainId) => chainId == 'osmosis-1' ? osmosisLcd : null,
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

    test('prices SAF in USD through USDC, and says where the price comes from', () async {
      final snapshot = await service.prices(targets, 'USD');
      final safPrice = snapshot.prices['safrochain-1']!;
      expect(safPrice.price, closeTo(0.000202749040940238 * 0.9998, 1e-15));
      expect(safPrice.change24h, closeTo((0.000202749040940238 / 0.000284792120779832 - 1) * 100, 1e-9));
      expect(safPrice.source!.name, 'Osmosis');
      expect(safPrice.source!.pair, 'SAF/USDC');
      expect(safPrice.source!.url, 'https://app.osmosis.zone/pool/3600');
      final osmo = snapshot.prices['osmosis-1']!;
      expect(osmo.price, 0.2);
      expect(osmo.change24h, 2);
      expect(osmo.source, isNull);
      final spot = calls.firstWhere((uri) => uri.path.endsWith('/pools/3600/prices'));
      expect(spot.queryParameters['base_asset_denom'], saf.baseDenom);
      expect(spot.queryParameters['quote_asset_denom'], saf.quoteDenom);
      final twap = calls.firstWhere((uri) => uri.path.endsWith('/ArithmeticTwap'));
      expect(twap.queryParameters['start_time'], '2026-11-14T11:00:00Z');
      expect(twap.queryParameters['end_time'], '2026-11-14T12:00:00Z');
      // No exchange is asked for anything.
      expect(calls.any((uri) => uri.host.contains('coinstore')), isFalse);
      // One batch request carries every CoinGecko id, USDC included.
      final batch = calls.where((uri) => uri.path.endsWith('/simple/price')).single;
      expect(batch.queryParameters['ids'], 'osmosis,usd-coin');
      expect(batch.queryParameters['vs_currencies'], 'usd');
    });

    test("converts to the user's currency through USDC", () async {
      final snapshot = await service.prices(targets, 'eur');
      expect(snapshot.prices['safrochain-1']!.price, closeTo(0.000202749040940238 * 0.92, 1e-15));
      expect(snapshot.prices['osmosis-1']!.price, 0.18);
    });

    test('leaves SAF unpriced when USDC cannot be converted, except at USD par', () async {
      routes['https://api.coingecko.com/api/v3/simple/price'] = {
        'osmosis': {'usd': 0.2, 'eur': 0.18},
      };
      final eur = await service.prices(targets, 'EUR', force: true);
      expect(eur.prices['safrochain-1'], isNull);
      final usd = await service.prices(targets, 'USD', force: true);
      expect(usd.prices['safrochain-1']!.price, closeTo(0.000202749040940238, 1e-15));
    });

    test('leaves SAF unpriced when the pool does not answer', () async {
      routes.remove(spotPath);
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
      routes.remove(spotPath);
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
      routes['https://api.coingecko.com/api/v3/coins/usd-coin'] = {
        'market_data': {
          'current_price': {'usd': 1.0},
          'price_change_percentage_24h_in_currency': {'usd': 0.0},
        },
      };
      final snapshot = await service.prices(targets, 'USD');
      expect(snapshot.prices['osmosis-1']!.price, 0.21);
      expect(snapshot.prices['osmosis-1']!.change24h, 1.5);
      expect(snapshot.prices['safrochain-1']!.price, closeTo(0.000202749040940238, 1e-15));
    });

    test('a coin with neither a CoinGecko id nor a pool stays unpriced', () async {
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

    test('read the bundled pool sources: SAF on Osmosis, no exchange', () {
      final raw = File('assets/data/prices.json').readAsStringSync();
      final sources = decodePoolSources(raw);
      expect(sources['safrochain-1']!.pair, 'SAF/USDC');
      expect(sources['safrochain-1']!.poolId, '3600');
      expect(sources['safrochain-1']!.chainId, 'osmosis-1');
      expect(raw.toLowerCase(), isNot(contains('coinstore')));
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
