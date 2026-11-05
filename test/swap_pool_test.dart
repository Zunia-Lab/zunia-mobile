/// Swaps in Osmosis's own pools (`lib/swap/pool_swap.dart`) and which pairs
/// take which path (`lib/swap/swap_path.dart`): a port of zunia-extension
/// 0.1.5 `lib/__tests__/pool-swap.test.ts`. The numbers are the Osmosis
/// router's real answer for 10 OSMO to USDC.inj on 2026-10-06: split 60/40
/// across pools 3498 and 3586.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/services/interchain/swap.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/swap/pool_swap.dart';
import 'package:zunia_mobile/swap/swap_path.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

import 'support/swap_fixtures.dart';

const usdcInj =
    'ibc/794C7D7F3B857713878A3A1927251FA6AC1EEE520424C1F6FAFE9BA26D476138';
const usdcN =
    'ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4';

final osmoMe = bech('osmo', 7);
final injMe = bech('inj', 7);

OsmosisSwapQuote quoteOf(
  List<({List<(String, String)> pools, String inAmount, String outAmount})>
  splits, [
  String outputDenom = usdcInj,
]) {
  final out = splits.fold<BigInt>(
    BigInt.zero,
    (sum, s) => sum + BigInt.parse(s.outAmount),
  );
  final input = splits.fold<BigInt>(
    BigInt.zero,
    (sum, s) => sum + BigInt.parse(s.inAmount),
  );
  return OsmosisSwapQuote(
    inputDenom: 'uosmo',
    inputAmount: '$input',
    outputDenom: outputDenom,
    outputAmount: '$out',
    priceImpact: 0.39,
    poolFee: 0.8,
    minReceived: '0',
    slippagePercent: 1,
    route: const [],
    source: OsmosisQuoteSource.router,
    splits: [
      for (final split in splits)
        OsmosisRouteSplit(
          pools: [
            for (final (id, denom) in split.pools)
              OsmosisPoolLeg(poolId: id, tokenOutDenom: denom),
          ],
          inAmount: split.inAmount,
          outAmount: split.outAmount,
        ),
    ],
    spotPrice: null,
    effectiveFeeFraction: '0.008',
    warnings: const [],
    fetchedAt: DateTime(2026, 10, 6),
  );
}

final split = quoteOf([
  (pools: [('3498', usdcInj)], inAmount: '6000000', outAmount: '212554'),
  (pools: [('3586', usdcInj)], inAmount: '4000000', outAmount: '142080'),
]);
const splitRoutes = [
  PoolRoute([PoolHop('3498', usdcInj)], '6000000'),
  PoolRoute([PoolHop('3586', usdcInj)], '4000000'),
];
const twoHops = [
  PoolRoute([PoolHop('3497', usdcN), PoolHop('1464', 'uosmo')], '1000000'),
];

/// The router's real answer for 10 OSMO → USDC.inj, scaled to the amount.
ScriptedLcd splitRouter() => ScriptedLcd('osmosis-1', (path, query) {
  if (path != '/router/quote') throw notFound('osmosis-1', path);
  final tokenIn = '${query['tokenIn']}';
  final amount = BigInt.parse(RegExp(r'^\d+').firstMatch(tokenIn)!.group(0)!);
  if (query['tokenOutDenom'] != usdcInj) {
    throw InterchainError(
      InterchainErrorCode.lcdUnreachable,
      'no routes',
      httpStatus: 400,
    );
  }
  final first = amount * BigInt.from(6) ~/ BigInt.from(10);
  final second = amount - first;
  final outFirst = first * BigInt.from(212554) ~/ BigInt.from(6000000);
  final outSecond = second * BigInt.from(142080) ~/ BigInt.from(4000000);
  return {
    'amount_in': {'denom': 'uosmo', 'amount': '$amount'},
    'amount_out': '${outFirst + outSecond}',
    'route': [
      {
        'pools': [
          {
            'id': 3498,
            'type': 2,
            'token_out_denom': usdcInj,
            'spread_factor': '0.002',
            'taker_fee': '0.008',
          },
        ],
        'in_amount': '$first',
        'out_amount': '$outFirst',
      },
      {
        'pools': [
          {
            'id': 3586,
            'type': 0,
            'token_out_denom': usdcInj,
            'spread_factor': '0.003',
            'taker_fee': '0.008',
          },
        ],
        'in_amount': '$second',
        'out_amount': '$outSecond',
      },
    ],
    'effective_fee': '0.008',
    'price_impact': '-0.003872499987184370',
    'in_base_out_quote_spot_price': '0.035888372884826882',
  };
});

void main() {
  group('which way a pair swaps', () {
    SwapPath path(String from, String to, Executable answer) =>
        swapPathFor(from, to, answer, venueChainId: 'osmosis-1');

    test(
      'swaps funds on Osmosis in its pools, unless the contract can deliver the whole output elsewhere',
      () {
        expect(path('osmosis-1', 'osmosis-1', Executable.no), SwapPath.pool);
        expect(path('osmosis-1', 'osmosis-1', Executable.yes), SwapPath.pool);
        expect(
          path('osmosis-1', 'injective-1', Executable.yes),
          SwapPath.contract,
        );
        expect(
          path('osmosis-1', 'injective-1', Executable.no),
          SwapPath.poolDeliver,
        );
        expect(
          path('osmosis-1', 'injective-1', Executable.unknown),
          SwapPath.poolDeliver,
        );
      },
    );

    test(
      'sends funds elsewhere through the contract, and moves them to Osmosis first when it has no route',
      () {
        expect(
          path('injective-1', 'osmosis-1', Executable.yes),
          SwapPath.contract,
        );
        expect(
          path('injective-1', 'osmosis-1', Executable.unknown),
          SwapPath.contract,
        );
        expect(
          path('injective-1', 'osmosis-1', Executable.no),
          SwapPath.moveFirst,
        );
        expect(isPoolPath(SwapPath.pool), isTrue);
        expect(isPoolPath(SwapPath.poolDeliver), isTrue);
        expect(isPoolPath(SwapPath.moveFirst), isFalse);
        expect(isPoolPath(null), isFalse);
      },
    );
  });

  group("the router's order", () {
    test('takes every split for exactly the amount sold', () {
      expect(poolRoutesOf(split, '10000000'), splitRoutes);
      final single = quoteOf([
        (pools: [('3586', usdcInj)], inAmount: '9950000', outAmount: '350000'),
      ]);
      expect(poolRoutesOf(single, '9950000'), const [
        PoolRoute([PoolHop('3586', usdcInj)], '9950000'),
      ]);
    });

    test(
      'refuses an order that would sell another amount, or that the chain would refuse',
      () {
        expect(poolRoutesOf(split, '9999999'), isNull);
        expect(
          poolRoutesOf(
            quoteOf([
              (pools: [('1', usdcN)], inAmount: '5', outAmount: '1'),
            ]),
            '5',
          ),
          isNull,
        );
        expect(
          poolRoutesOf(
            quoteOf([
              (pools: [('3586', usdcInj)], inAmount: '5', outAmount: '1'),
              (pools: [('3586', usdcInj)], inAmount: '5', outAmount: '1'),
            ]),
            '10',
          ),
          isNull,
        );
        expect(
          poolRoutesOf(
            quoteOf([
              (pools: [('0', usdcInj)], inAmount: '5', outAmount: '1'),
            ]),
            '5',
          ),
          isNull,
        );
        expect(
          poolRoutesOf(
            quoteOf([
              (pools: [('1', usdcInj)], inAmount: '5', outAmount: '1'),
              (pools: [('2', usdcInj)], inAmount: '0', outAmount: '0'),
            ]),
            '5',
          ),
          isNull,
        );
        expect(
          poolRoutesOf(
            quoteOf([(pools: const [], inAmount: '5', outAmount: '1')]),
            '5',
          ),
          isNull,
        );
        final long = quoteOf([
          (
            pools: [
              for (var i = 0; i <= maxPoolHops; i++) ('${i + 1}', usdcInj),
            ],
            inAmount: '5',
            outAmount: '1',
          ),
        ]);
        expect(poolRoutesOf(long, '5'), isNull);
        final wide = quoteOf([
          for (var i = 0; i <= maxPoolSplits; i++)
            (pools: [('${i + 1}', usdcInj)], inAmount: '1', outAmount: '1'),
        ]);
        expect(poolRoutesOf(wide, '${maxPoolSplits + 1}'), isNull);
      },
    );

    test(
      'floors the output at the slippage, rounding down, and never at nothing',
      () {
        expect(poolMinOut('354634', 1), '351087');
        expect(poolMinOut('354634', 0.5), '352860');
        expect(poolMinOut('1', 1), isNull);
        expect(poolMinOut('0', 1), isNull);
      },
    );

    test('says the route in words', () {
      expect(
        poolRouteText(splitRoutes),
        '2 routes: pool 3498 (60%) and pool 3586 (40%)',
      );
      expect(poolRouteText(twoHops), 'pools 3497 → 1464');
      expect(
        poolRouteText(const [
          PoolRoute([PoolHop('3586', usdcInj)], '1'),
        ]),
        'pool 3586',
      );
    });
  });

  group('the poolmanager message', () {
    test(
      'is MsgSwapExactAmountIn for one route, with the whole input as token_in',
      () {
        final msg = buildPoolSwapMsg(
          sender: osmoMe,
          denom: 'uosmo',
          routes: twoHops,
          minOut: '28000000',
        );
        expect(msg.typeUrl, poolSwapTypeUrl);
        expect(msg.value, {
          'sender': osmoMe,
          'routes': [
            {'pool_id': '3497', 'token_out_denom': usdcN},
            {'pool_id': '1464', 'token_out_denom': 'uosmo'},
          ],
          'token_in': {'denom': 'uosmo', 'amount': '1000000'},
          'token_out_min_amount': '28000000',
        });
      },
    );

    test(
      'is MsgSplitRouteSwapExactAmountIn for a split order, each route with its share',
      () {
        final msg = buildPoolSwapMsg(
          sender: osmoMe,
          denom: 'uosmo',
          routes: splitRoutes,
          minOut: '351087',
        );
        expect(msg.typeUrl, poolSplitSwapTypeUrl);
        expect(msg.value, {
          'sender': osmoMe,
          'routes': [
            {
              'pools': [
                {'pool_id': '3498', 'token_out_denom': usdcInj},
              ],
              'token_in_amount': '6000000',
            },
            {
              'pools': [
                {'pool_id': '3586', 'token_out_denom': usdcInj},
              ],
              'token_in_amount': '4000000',
            },
          ],
          'token_in_denom': 'uosmo',
          'token_out_min_amount': '351087',
        });
        // snake_case keys, amounts as strings: the shape zunia-core's json.rs reads.
        expect(
          jsonEncode(msg.toJson()),
          contains('"token_out_min_amount":"351087"'),
        );
      },
    );

    test(
      'refuses to build a swap with no floor, a bad denom, or routes that are not an order',
      () {
        expect(
          () => buildPoolSwapMsg(
            sender: osmoMe,
            denom: 'uosmo',
            routes: splitRoutes,
            minOut: '0',
          ),
          throwsArgumentError,
        );
        expect(
          () => buildPoolSwapMsg(
            sender: osmoMe,
            denom: 'u',
            routes: splitRoutes,
            minOut: '1',
          ),
          throwsArgumentError,
        );
        expect(
          () => buildPoolSwapMsg(
            sender: osmoMe,
            denom: 'uosmo',
            routes: const [],
            minOut: '1',
          ),
          throwsArgumentError,
        );
      },
    );

    test('reads back exactly what it built', () {
      final single = readPoolSwapMsg(
        buildPoolSwapMsg(
          sender: osmoMe,
          denom: 'uosmo',
          routes: twoHops,
          minOut: '28000000',
        ),
      )!;
      expect(single.split, isFalse);
      expect(single.sender, osmoMe);
      expect(single.sold, const PoolCoin('uosmo', '1000000'));
      expect(single.outputDenom, 'uosmo');
      expect(single.minOut, '28000000');
      expect(single.routes, twoHops);
      final read = readPoolSwapMsg(
        buildPoolSwapMsg(
          sender: osmoMe,
          denom: 'uosmo',
          routes: splitRoutes,
          minOut: '351087',
        ),
      )!;
      expect(read.split, isTrue);
      expect(read.sold, const PoolCoin('uosmo', '10000000'));
      expect(read.outputDenom, usdcInj);
      expect(sameRoutes(read.routes, splitRoutes), isTrue);
      expect(sameRoutes(read.routes, twoHops), isFalse);
    });

    test('refuses to read a message with anything it would not show', () {
      final value = buildPoolSwapMsg(
        sender: osmoMe,
        denom: 'uosmo',
        routes: splitRoutes,
        minOut: '351087',
      ).value;
      final variants = <Map<String, dynamic>>[
        {...value, 'extra': 'x'},
        {...value, 'token_out_min_amount': '0'},
        {...value, 'token_out_min_amount': '007'},
        {...value, 'token_out_min_amount': 351087},
        {...value, 'token_in_denom': ''},
        {...value, 'routes': []},
        {
          ...value,
          'routes': [
            {
              'pools': [
                {'pool_id': '3498', 'token_out_denom': usdcInj, 'extra': 1},
              ],
              'token_in_amount': '1',
            },
          ],
        },
        {
          ...value,
          'routes': [
            {
              'pools': [
                {'pool_id': 3498, 'token_out_denom': usdcInj},
              ],
              'token_in_amount': '1',
            },
          ],
        },
        {
          ...value,
          'routes': [
            {
              'pools': [
                {'pool_id': '3498', 'token_out_denom': usdcInj},
              ],
              'token_in_amount': '1',
            },
            {
              'pools': [
                {'pool_id': '3586', 'token_out_denom': usdcN},
              ],
              'token_in_amount': '1',
            },
          ],
        },
      ];
      for (final variant in variants) {
        expect(
          readPoolSwapMsg(TxMsg(poolSplitSwapTypeUrl, variant)),
          isNull,
          reason: jsonEncode(variant),
        );
      }
      expect(
        readPoolSwapMsg(
          TxMsg('/osmosis.gamm.v1beta1.MsgSwapExactAmountIn', value),
        ),
        isNull,
      );
      expect(readPoolSwapMsg(TxMsg(poolSwapTypeUrl, value)), isNull);
      expect(readPoolSwapMsg(null), isNull);
    });
  });

  group('the transfer that sends the output on', () {
    TxMsg transfer({
      String memo = '',
      String amount = '351087',
      Map<String, dynamic>? extra,
    }) => TxMsg(transferTypeUrl, {
      ...TxMsg.transfer(
        sourcePort: 'transfer',
        sourceChannel: 'channel-122',
        token: TxCoin(usdcInj, amount),
        sender: osmoMe,
        receiver: injMe,
        timeoutTimestampNanos: '1800000000000000000',
        memo: memo,
      ).value,
      ...?extra,
    });

    test('is read whole: port, channel, coin, parties, memo and timeout', () {
      final read = readDeliveryTransfer(transfer())!;
      expect(read.sourceChannel, 'channel-122');
      expect(read.token, const PoolCoin(usdcInj, '351087'));
      expect(read.sender, osmoMe);
      expect(read.receiver, injMe);
      expect(read.memo, '');
      expect(read.timeoutTimestamp, '1800000000000000000');
    });

    test(
      'refuses a field it does not know, a height that is not two counters, or a zero amount',
      () {
        expect(readDeliveryTransfer(transfer(extra: {'relayer': 'x'})), isNull);
        expect(
          readDeliveryTransfer(
            transfer(
              extra: {
                'timeout_height': {'revision_number': '1', 'other': '2'},
              },
            ),
          ),
          isNull,
        );
        expect(readDeliveryTransfer(transfer(amount: '0')), isNull);
        expect(
          readDeliveryTransfer(TxMsg(poolSwapTypeUrl, transfer().value)),
          isNull,
        );
      },
    );
  });

  group('pricing in the pools', () {
    final venue = ScriptedLcd(
      'osmosis-1',
      (path, _) => throw notFound('osmosis-1', path),
    );

    test(
      "prices along the router's split and works out the order and the floor",
      () async {
        final priced = await quotePoolSwap(
          venueInputDenom: 'uosmo',
          venueOutputDenom: usdcInj,
          amountBaseUnits: '10000000',
          slippagePercent: 1,
          venueLcd: venue,
          router: splitRouter(),
        );
        expect(priced.error, isNull);
        expect(priced.quote?.outputAmount, '354634');
        expect(priced.routes, splitRoutes);
        expect(priced.minOut, '351087');
        expect(priced.ready, isTrue);
      },
    );

    test(
      'says when Osmosis has no pool route, and refuses to price a token against itself',
      () async {
        final none = await quotePoolSwap(
          venueInputDenom: 'uosmo',
          venueOutputDenom: usdcN,
          amountBaseUnits: '10000000',
          slippagePercent: 1,
          venueLcd: venue,
          router: splitRouter(),
        );
        expect(none.quote, isNull);
        expect(none.code, PoolQuoteBlockedCode.noPoolRoute);
        final same = await quotePoolSwap(
          venueInputDenom: usdcInj,
          venueOutputDenom: usdcInj,
          amountBaseUnits: '1',
          slippagePercent: 1,
          venueLcd: venue,
          router: splitRouter(),
        );
        expect(same.code, PoolQuoteBlockedCode.sameToken);
      },
    );

    test('refuses a floor that rounds to nothing', () async {
      final dust = await quotePoolSwap(
        venueInputDenom: 'uosmo',
        venueOutputDenom: usdcInj,
        amountBaseUnits: '20',
        slippagePercent: 1,
        venueLcd: venue,
        router: splitRouter(),
      );
      expect(dust.code, PoolQuoteBlockedCode.noFloor);
      expect(dust.minOut, isNull);
    });
  });
}
