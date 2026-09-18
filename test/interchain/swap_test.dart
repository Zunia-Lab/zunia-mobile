/// Ported from `zunia-sdk/packages/interchain/src/swap.test.ts`.
///
/// The slippage arithmetic is done in BigInt and rounds down, because the result
/// becomes a floor the chain enforces: rounding up would put the floor above
/// what the quote promised.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/memo.dart';
import 'package:zunia_mobile/services/interchain/swap.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

class _FakeLcd implements LcdClient {
  _FakeLcd(this.chainId, this._routes, {this.calls});

  @override
  final String chainId;
  final Map<String, Object? Function(Map<String, Object?>? query)> _routes;
  final List<String>? calls;

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    calls?.add(path);
    final handler = _routes[path];
    if (handler == null) {
      throw InterchainError(
        InterchainErrorCode.lcdUnreachable,
        'not registered: $path',
        chainId: chainId,
        httpStatus: 404,
      );
    }
    return handler(options?.query);
  }
}

/// The SQS shape verified in swap.ts's header comment.
Map<String, Object?> _routerQuoteBody({
  String outAmount = '22518',
  List<Object?>? route,
  String? effectiveFee = '0.008000000000000000',
  String? priceImpact = '-0.000060651677841116',
}) =>
    {
      'amount_in': {'denom': 'uosmo', 'amount': '1000000'},
      'amount_out': outAmount,
      'route': route ??
          [
            {
              'pools': [
                {
                  'id': 1400,
                  'type': 2,
                  'spread_factor': '0.0',
                  'token_out_denom': 'uatom',
                  'taker_fee': '0.008',
                },
              ],
              'in_amount': '1000000',
              'out_amount': outAmount,
            },
          ],
      'effective_fee': effectiveFee,
      'price_impact': priceImpact,
      'in_base_out_quote_spot_price': '0.022700973626332612',
    };

void main() {
  group('applySlippage', () {
    test('rounds down and never above the quote', () {
      expect(applySlippage('1000000', 1), '990000');
      expect(applySlippage('1000000', 0), '1000000');
      expect(applySlippage('1000000', 100), '0');
      // Rounding down: 3 * 99% = 2.97 -> 2, never 3.
      expect(applySlippage('3', 1), '2');
    });

    test('handles amounts far past a double', () {
      const huge = '340282366920938463463374607431768211455';
      expect(applySlippage(huge, 50),
          '170141183460469231731687303715884105727');
    });

    test('rejects an unusable amount or tolerance', () {
      expect(() => applySlippage('1.5', 1), throwsA(isA<InterchainError>()));
      expect(() => applySlippage('-1', 1), throwsA(isA<InterchainError>()));
      expect(() => applySlippage('100', -1), throwsA(isA<InterchainError>()));
      expect(() => applySlippage('100', 101), throwsA(isA<InterchainError>()));
    });
  });

  group('XCS slippage forms', () {
    test('slippageToTwapParams renders a plain decimal, never exponent form',
        () {
      final twap = slippageToTwapParams(0.5, windowSeconds: 10);
      expect(twap.slippagePercentage, '0.5');
      expect(twap.windowSeconds, 10);
      // The contract parses a Decimal and rejects `5e-7`.
      expect(slippageToTwapParams(0.0000005).slippagePercentage,
          isNot(contains('e')));
    });

    test('omitting the window leaves the contract default in place', () {
      final twap = slippageToTwapParams(1);
      expect(twap.windowSeconds, isNull);
      expect(twap.slippagePercentage, '1');
    });

    test('a percentage outside 0-100 is refused', () {
      expect(() => slippageToTwapParams(101), throwsA(isA<InterchainError>()));
      expect(() => slippageToTwapParams(-1), throwsA(isA<InterchainError>()));
    });

    test('minOutputFromQuote re-parses rather than trusting the quote', () {
      const quote = SwapQuote(
        inputDenom: 'uosmo',
        inputAmount: '1000000',
        outputDenom: 'uatom',
        outputAmount: '22518',
        priceImpact: 0.1,
        poolFee: 0.8,
        minReceived: '22292',
        slippagePercent: 1,
        route: [],
      );
      expect(minOutputFromQuote(quote).minOutputAmount, '22292');
      expect(minOutputFromQuote(quote, slippagePercent: 5).minOutputAmount,
          '21392');
    });
  });

  group('parseRouterQuote', () {
    test('reads the verified SQS shape', () {
      final quote = parseRouterQuote(_routerQuoteBody());
      expect(quote.inDenom, 'uosmo');
      expect(quote.outAmount, '22518');
      expect(quote.splits.single.pools.single.poolId, '1400');
      expect(quote.effectiveFeeFraction, '0.008000000000000000');
      expect(quote.priceImpactFraction, '-0.000060651677841116');
    });

    test('an empty route is reported as no route, not as a zero quote', () {
      expect(
        () => parseRouterQuote(_routerQuoteBody(route: const [])),
        throwsA(isA<InterchainError>()
            .having((e) => e.code, 'code', InterchainErrorCode.noRoute)),
      );
    });

    test('a malformed body is malformed, not empty', () {
      expect(() => parseRouterQuote(<String, Object?>{}),
          throwsA(isA<InterchainError>()));
      expect(() => parseRouterQuote('nope'), throwsA(isA<InterchainError>()));
    });
  });

  group('quoteOsmosisSwap', () {
    test('refuses a chain that is not Osmosis', () async {
      expect(
        () => quoteOsmosisSwap(
          const OsmosisSwapQuoteParams(
            tokenInDenom: 'uatom',
            tokenInAmount: '1000000',
            tokenOutDenom: 'uosmo',
          ),
          _FakeLcd('cosmoshub-4', const {}),
        ),
        throwsA(isA<InterchainError>()
            .having((e) => e.code, 'code', InterchainErrorCode.unsupportedChain)),
      );
    });

    test('refuses a request that cannot mean anything', () async {
      final lcd = _FakeLcd('osmosis-1', const {});
      expect(
        () => quoteOsmosisSwap(
          const OsmosisSwapQuoteParams(
            tokenInDenom: 'uosmo',
            tokenInAmount: '0',
            tokenOutDenom: 'uatom',
          ),
          lcd,
        ),
        throwsA(isA<InterchainError>()),
      );
      expect(
        () => quoteOsmosisSwap(
          const OsmosisSwapQuoteParams(
            tokenInDenom: 'uosmo',
            tokenInAmount: '1',
            tokenOutDenom: 'uosmo',
          ),
          lcd,
        ),
        throwsA(isA<InterchainError>()),
      );
    });

    test('prices through the router and derives the minimum itself', () async {
      final router = _FakeLcd('osmosis-1', {
        '/router/quote': (query) {
          expect(query!['tokenIn'], '1000000uosmo');
          expect(query['tokenOutDenom'], 'uatom');
          return _routerQuoteBody();
        },
      });
      final quote = await quoteOsmosisSwap(
        OsmosisSwapQuoteParams(
          tokenInDenom: 'uosmo',
          tokenInAmount: '1000000',
          tokenOutDenom: 'uatom',
          slippagePercent: 1,
          router: router,
        ),
        _FakeLcd('osmosis-1', const {}),
      );
      expect(quote.source, OsmosisQuoteSource.router);
      expect(quote.outputAmount, '22518');
      expect(quote.minReceived, '22292');
      // SQS signs impact negative when the price moves against the user; ours
      // is a cost, so the sign is flipped rather than made absolute.
      expect(quote.priceImpact, closeTo(0.00606, 0.0001));
      expect(quote.poolFee, closeTo(0.8, 0.0001));
      expect(quote.route.single.poolId, '1400');
    });

    test('a fee the router did not report stays null, never 0', () async {
      final router = _FakeLcd('osmosis-1', {
        '/router/quote': (_) =>
            _routerQuoteBody(effectiveFee: null, priceImpact: null),
      });
      final quote = await quoteOsmosisSwap(
        OsmosisSwapQuoteParams(
          tokenInDenom: 'uosmo',
          tokenInAmount: '1000000',
          tokenOutDenom: 'uatom',
          router: router,
        ),
        _FakeLcd('osmosis-1', const {}),
      );
      expect(quote.poolFee, isNull);
      expect(quote.priceImpact, isNull);
      expect(quote.warnings.any((w) => w.contains('did not report a fee')),
          isTrue);
    });

    test('a forced route asks custom-direct-quote with positional lists',
        () async {
      final calls = <String>[];
      final router = _FakeLcd('osmosis-1', {
        '/router/custom-direct-quote': (query) {
          expect(query!['poolID'], '1400,2');
          expect(query['tokenOutDenom'], 'uion,uatom');
          return _routerQuoteBody();
        },
      }, calls: calls);
      await quoteOsmosisSwap(
        OsmosisSwapQuoteParams(
          tokenInDenom: 'uosmo',
          tokenInAmount: '1000000',
          tokenOutDenom: 'uatom',
          router: router,
          route: const [
            SwapPoolHop(poolId: '1400', tokenOutDenom: 'uion'),
            SwapPoolHop(poolId: '2', tokenOutDenom: 'uatom'),
          ],
        ),
        _FakeLcd('osmosis-1', const {}),
      );
      expect(calls, ['/router/custom-direct-quote']);
    });

    test('a quote below the caller floor is slippage-exceeded, not a quote',
        () async {
      final router = _FakeLcd('osmosis-1', {
        '/router/quote': (_) => _routerQuoteBody(outAmount: '100'),
      });
      expect(
        () => quoteOsmosisSwap(
          OsmosisSwapQuoteParams(
            tokenInDenom: 'uosmo',
            tokenInAmount: '1000000',
            tokenOutDenom: 'uatom',
            router: router,
            minOutputAmount: '20000',
          ),
          _FakeLcd('osmosis-1', const {}),
        ),
        throwsA(isA<InterchainError>().having(
            (e) => e.code, 'code', InterchainErrorCode.slippageExceeded)),
      );
    });

    test('without a router or candidates it says why, and does not guess',
        () async {
      expect(
        () => quoteOsmosisSwap(
          const OsmosisSwapQuoteParams(
            tokenInDenom: 'uosmo',
            tokenInAmount: '1000000',
            tokenOutDenom: 'uatom',
          ),
          _FakeLcd('osmosis-1', const {}),
        ),
        throwsA(isA<InterchainError>()
            .having((e) => e.code, 'code', InterchainErrorCode.noRoute)
            .having((e) => e.message, 'message',
                contains('no pool-by-denom index'))),
      );
    });

    test('the poolmanager path chains single-pool estimates', () async {
      final lcd = _FakeLcd('osmosis-1', {
        '/osmosis/poolmanager/v1beta1/pools/1/total_pool_liquidity': (_) => {
              'liquidity': [
                {'denom': 'uosmo', 'amount': '1'},
                {'denom': 'uatom', 'amount': '1'},
              ],
            },
        '/osmosis/poolmanager/v1beta1/1/estimate/single_pool_swap_exact_amount_in':
            (query) {
          expect(query!['token_in'], '1000000uosmo');
          return {'token_out_amount': '22411'};
        },
        '/osmosis/poolmanager/v1beta1/pools/1': (_) => {
              'pool': {
                'pool_params': {'swap_fee': '0.002000000000000000'},
              },
            },
        '/osmosis/poolmanager/v1beta1/trading_pair_takerfee': (_) =>
            {'taker_fee': '0.008000000000000000'},
        '/osmosis/poolmanager/v2/pools/1/prices': (_) =>
            {'spot_price': '0.022637700000000000'},
      });
      final quote = await quoteOsmosisSwap(
        const OsmosisSwapQuoteParams(
          tokenInDenom: 'uosmo',
          tokenInAmount: '1000000',
          tokenOutDenom: 'uatom',
          candidatePoolIds: ['1'],
        ),
        lcd,
      );
      expect(quote.source, OsmosisQuoteSource.poolmanager);
      expect(quote.outputAmount, '22411');
      expect(quote.minReceived, applySlippage('22411', 1));
      // Both fees compose rather than add: 1 - (1-0.002)(1-0.008) = 0.009984,
      // i.e. 0.9984% — not the 1.0% a naive sum would report.
      expect(quote.poolFee, closeTo(0.9984, 0.0001));
    });
  });

  test('toMemoSlippage crosses between the wire and tagged forms', () {
    final twap = slippageToTwapParams(20, windowSeconds: 10);
    expect(twap, isA<XcsTwapSlippage>());
    const floor = XcsMinOutputSlippage('100');
    expect(floor.minOutputAmount, '100');
    // The memo builder is the only thing that renders either of them.
    expect(
      buildXcsSwapMemo(
        contract: 'osmo1c',
        outputDenom: 'uatom',
        receiver: 'cosmos1r',
        slippage: twap,
        onFailedDelivery: const XcsLocalRecovery('osmo1r'),
      ),
      contains('"twap":{"slippage_percentage":"20","window_seconds":10}'),
    );
  });
}
