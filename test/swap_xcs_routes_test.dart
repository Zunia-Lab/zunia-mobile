/// The crosschain-swaps contract's route table (`lib/swap/xcs_routes.dart`)
/// and the live route check (`lib/services/interchain/xcs_route.dart`), read
/// from the Osmosis LCD's real answers of 2026-10-05 (the extension's fixture)
/// served by a scripted client: no network.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/services/interchain/xcs_route.dart';
import 'package:zunia_mobile/swap/swap_path.dart';
import 'package:zunia_mobile/swap/swap_tokens.dart';
import 'package:zunia_mobile/swap/xcs_routes.dart';

import 'support/swap_fixtures.dart';

const usdcAxl =
    'ibc/D189335C6E4A68B513C10AB227BF1C1D38C746766278BA3EEB4FB14124F1D858';
const usdcInj =
    'ibc/794C7D7F3B857713878A3A1927251FA6AC1EEE520424C1F6FAFE9BA26D476138';
const usdcN =
    'ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4';
const atom =
    'ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2';
const statom =
    'ibc/C140AFD542AE77BD7DCC83F13FDD8C5E5BB8C4929785E6EC2F4C636F98F17901';

/// A `routing_table` key as cw-storage-plus writes it, in the LCD's hex.
String routeKey(
  String input,
  String output, [
  String namespace = 'routing_table',
]) {
  List<int> length(String text) {
    final n = utf8.encode(text).length;
    return [n >> 8, n & 0xff];
  }

  final bytes = [
    ...length(namespace),
    ...utf8.encode(namespace),
    ...length(input),
    ...utf8.encode(input),
    ...utf8.encode(output),
  ];
  return bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

String routeValue(List<Map<String, Object>> hops) =>
    base64.encode(utf8.encode(jsonEncode(hops)));

void main() {
  late Map<String, Object?> live;
  late String xcs;
  late String router;
  late List<Object?> models;
  late SwapTokenBook book;

  setUpAll(() async {
    live =
        jsonDecode(
              await File(
                'test/fixtures/swap/xcs-route-table.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    xcs = live['xcsContract'] as String;
    router = live['swapContract'] as String;
    models = [
      for (final page in live['pages'] as List)
        ...((page as Map)['body'] as Map)['models'] as List,
    ];
    book = (await loadTestSwapData()).book;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetXcsRoutesMemory();
  });

  /// The Osmosis LCD as it answered on 2026-10-05, serving each state page by
  /// its key.
  ScriptedLcd liveLcd() => ScriptedLcd('osmosis-1', (path, query) {
    if (path == '/cosmwasm/wasm/v1/contract/$xcs/raw/Y29uZmln') {
      return live['config'];
    }
    if (path == '/cosmwasm/wasm/v1/contract/$router/state') {
      final key = query['pagination.key'];
      for (final page in live['pages'] as List) {
        if ((page as Map)['key'] == key) return page['body'];
      }
    }
    throw InterchainError(
      InterchainErrorCode.lcdUnreachable,
      'no answer for $path',
    );
  });

  group('parseRouterState', () {
    test(
      'reads the 39 routing_table entries out of the router\'s 41 models',
      () {
        expect(models, hasLength(41));
        final routes = parseRouterState(models);
        expect(routes, hasLength(39));
        expect(
          routes,
          contains(
            const XcsRoute(input: 'uosmo', output: usdcAxl, poolIds: ['678']),
          ),
        );
        expect(
          routes,
          contains(
            const XcsRoute(input: atom, output: statom, poolIds: ['803']),
          ),
        );
        final denoms = {
          for (final r in routes) ...[r.input, r.output],
        };
        expect(denoms, hasLength(20));
        // The only USDC the contract trades is Axelar's, against OSMO.
        expect(
          routes.where((r) => r.input == usdcAxl || r.output == usdcAxl),
          hasLength(2),
        );
        expect(denoms.contains(usdcInj), isFalse);
        expect(denoms.contains(usdcN), isFalse);
      },
    );

    test(
      'skips items, other maps, bad keys and values that are not a route to the output',
      () {
        final item = utf8
            .encode('contract_info')
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        final skipped = <Object?>[
          {
            'key': item,
            'value': base64.encode(
              utf8.encode('{"contract":"crates.io:swaprouter"}'),
            ),
          },
          {
            'key': routeKey('uosmo', atom, 'routing_tablx'),
            'value': routeValue([
              {'pool_id': '1', 'token_out_denom': atom},
            ]),
          },
          {
            'key': '${routeKey('uosmo', atom)}0',
            'value': routeValue([
              {'pool_id': '1', 'token_out_denom': atom},
            ]),
          },
          {
            'key': routeKey('uosmo', atom),
            'value': routeValue([
              {'pool_id': '1', 'token_out_denom': usdcAxl},
            ]),
          },
          {'key': routeKey('uosmo', usdcAxl), 'value': 'not base64 json'},
          {
            'key': routeKey('uosmo', 'ibc/x y'),
            'value': routeValue([
              {'pool_id': '1', 'token_out_denom': 'ibc/x y'},
            ]),
          },
          {
            'key': routeKey('uosmo', statom),
            'value': routeValue([
              {'pool_id': '0', 'token_out_denom': statom},
            ]),
          },
          {
            'key': routeKey('uosmo', 'uion'),
            'value': routeValue([
              {'pool_id': 2, 'token_out_denom': 'uion'},
            ]),
          },
          {
            'key': routeKey('uosmo', 'uion'),
            'value': routeValue([
              {'pool_id': 3, 'token_out_denom': 'uion'},
            ]),
          },
          null,
          'routing_table',
        ];
        expect(parseRouterState(skipped), [
          const XcsRoute(input: 'uosmo', output: 'uion', poolIds: ['2']),
        ]);
      },
    );
  });

  group('readRoutingTable', () {
    test(
      "reads the contract's config, then every page of its router's state",
      () async {
        final lcd = liveLcd();
        final read = await readRoutingTable(
          lcd,
          xcs,
          now: DateTime.fromMillisecondsSinceEpoch(1000),
        );
        expect(read.xcsContract, xcs);
        expect(read.swapContract, router);
        expect(read.routes, parseRouterState(models));
        final pages = live['pages'] as List;
        expect(lcd.calls, [
          '/cosmwasm/wasm/v1/contract/$xcs/raw/Y29uZmln',
          '/cosmwasm/wasm/v1/contract/$router/state?pagination.limit=100',
          '/cosmwasm/wasm/v1/contract/$router/state?pagination.limit=100&pagination.key=${(pages[1] as Map)['key']}',
          '/cosmwasm/wasm/v1/contract/$router/state?pagination.limit=100&pagination.key=${(pages[2] as Map)['key']}',
        ]);
      },
    );

    test(
      'refuses an address that is not one, a config without a router and a state without routes',
      () async {
        expect(
          () => readRoutingTable(liveLcd(), 'not-a-contract'),
          throwsA(
            isA<InterchainError>().having(
              (e) => e.code,
              'code',
              InterchainErrorCode.invalidRequest,
            ),
          ),
        );
        final noRouter = ScriptedLcd(
          'osmosis-1',
          (path, _) => {'data': base64.encode(utf8.encode('{"governor":"x"}'))},
        );
        expect(
          () => readRoutingTable(noRouter, xcs),
          throwsA(
            isA<InterchainError>().having(
              (e) => e.code,
              'code',
              InterchainErrorCode.malformedResponse,
            ),
          ),
        );
        final empty = ScriptedLcd('osmosis-1', (path, _) {
          if (path.contains('/raw/')) return live['config'];
          return {
            'models': <Object>[],
            'pagination': {'next_key': null},
          };
        });
        expect(
          () => readRoutingTable(empty, xcs),
          throwsA(
            isA<InterchainError>().having(
              (e) => e.message,
              'message',
              contains('no routing_table'),
            ),
          ),
        );
      },
    );

    test(
      'a gateway that repeats a page fails the read instead of looping',
      () async {
        final looping = ScriptedLcd('osmosis-1', (path, _) {
          if (path.contains('/raw/')) return live['config'];
          return {
            'models': <Object>[],
            'pagination': {'next_key': 'AAA='},
          };
        });
        expect(
          () => readRoutingTable(looping, xcs),
          throwsA(
            isA<InterchainError>().having(
              (e) => e.message,
              'message',
              contains('repeats the page'),
            ),
          ),
        );
      },
    );
  });

  group('the cache', () {
    test(
      'serves a fresh table from memory and from storage, and reads again after an hour',
      () async {
        final at = DateTime(2026, 10, 18, 12);
        final lcd = liveLcd();
        final first = await loadXcsRoutes(xcs, lcd: lcd, now: at);
        expect(first?.routes, hasLength(39));
        final reads = lcd.calls.length;

        // From memory.
        expect(
          await loadXcsRoutes(
            xcs,
            lcd: lcd,
            now: at.add(const Duration(minutes: 30)),
          ),
          same(first),
        );
        // From storage, as on the next launch.
        resetXcsRoutesMemory();
        final stored = await loadXcsRoutes(
          xcs,
          lcd: lcd,
          now: at.add(const Duration(minutes: 59)),
        );
        expect(stored?.routes, first?.routes);
        expect(lcd.calls.length, reads);
        // Past the hour: read live again.
        await loadXcsRoutes(
          xcs,
          lcd: lcd,
          now: at.add(const Duration(minutes: 61)),
        );
        expect(lcd.calls.length, greaterThan(reads));
      },
    );

    test('a record of another version, contract or shape is not trusted', () {
      final at = DateTime(2026, 10, 18);
      final table = XcsRouteTable(
        xcsContract: xcs,
        swapContract: router,
        routes: const [
          XcsRoute(input: 'uosmo', output: atom, poolIds: ['1']),
        ],
        readAt: at,
      );
      final record = recordOf(table);
      expect(tableFromRecord(record, xcs, at)?.routes, table.routes);
      expect(tableFromRecord({...record, 'version': 2}, xcs, at), isNull);
      expect(tableFromRecord(record, bech('osmo', 9, 32), at), isNull);
      expect(
        tableFromRecord(record, xcs, at.add(const Duration(hours: 2))),
        isNull,
      );
      expect(
        tableFromRecord(record, xcs, at.subtract(const Duration(minutes: 1))),
        isNull,
      );
      expect(
        tableFromRecord(
          {
            ...record,
            'routes': [
              ['uosmo', atom, '0'],
            ],
          },
          xcs,
          at,
        ),
        isNull,
      );
    });

    test('an unreadable table gates nothing: every pair is unknown', () async {
      final down = ScriptedLcd(
        'osmosis-1',
        (path, _) => throw notFound('osmosis-1', path),
      );
      expect(await loadXcsRoutes(xcs, lcd: down), isNull);
      expect(executable(null, 'uosmo', atom), Executable.unknown);
    });
  });

  group('answers and gates', () {
    late XcsRouteTable table;
    setUp(() {
      table = XcsRouteTable(
        xcsContract: xcs,
        swapContract: router,
        routes: parseRouterState(models),
        readAt: DateTime(2026),
      );
    });

    GateSide side(String chainId, String denom, {bool testnet = false}) =>
        GateSide(
          key: '$chainId:$denom',
          chainId: chainId,
          denom: denom,
          identity: book.identityOf(chainId, denom),
          testnet: testnet,
        );

    test(
      'answers yes for a pair in the table, no for one that is not, ignoring ibc hash case',
      () {
        expect(executable(table, 'uosmo', usdcAxl), Executable.yes);
        expect(
          executable(
            table,
            'uosmo',
            usdcAxl.toLowerCase().replaceFirst('ibc/', 'ibc/'),
          ),
          Executable.yes,
        );
        expect(executable(table, 'uosmo', usdcInj), Executable.no);
        expect(executable(table, null, usdcInj), Executable.unknown);
      },
    );

    test('names each side by its Osmosis denom, from its identity', () {
      // ATOM on the Hub is its Osmosis voucher; OSMO on Osmosis is itself.
      expect(
        executableBetween(
          table,
          side('cosmoshub-4', 'uatom'),
          side('osmosis-1', 'uosmo'),
          book,
        ),
        Executable.yes,
      );
      // USDC on Injective is a pair the contract does not hold.
      expect(
        executableBetween(
          table,
          side('osmosis-1', 'uosmo'),
          side(
            'injective-1',
            'erc20:0xa00C59fF5a080D2b954d0c75e46E22a0c371235a',
          ),
          book,
        ),
        Executable.no,
      );
    });

    test(
      'gives the reasons the picker shows, in order of what the user can act on',
      () {
        final from = side('osmosis-1', 'uosmo');
        expect(
          gateOption(
            from,
            side('osmosis-1', 'uosmo'),
            table,
            book,
          ).disabledReason,
          selfReason,
        );
        expect(
          gateOption(
            side('cosmoshub-4', 'uatom'),
            side('osmosis-1', atom),
            table,
            book,
          ).disabledReason,
          sameTokenReason,
        );
        expect(
          gateOption(
            side('osmosis-1', 'uosmo', testnet: true),
            side('cosmoshub-4', 'uatom'),
            table,
            book,
          ).disabledReason,
          testnetReason,
        );
        // SAF is not traded on Osmosis: the pools cannot reach it.
        expect(
          gateOption(
            from,
            side('safrochain-1', 'usaf'),
            table,
            book,
          ).disabledReason,
          notTradedReason('SAF'),
        );
        // A pair the contract lacks is not refused: the pools swap it.
        expect(
          gateOption(
            from,
            side('osmosis-1', usdcInj),
            table,
            book,
          ).disabledReason,
          isNull,
        );
        expect(
          gateOption(
            null,
            side('osmosis-1', usdcInj),
            table,
            book,
          ).disabledReason,
          isNull,
        );
      },
    );

    test('words a missing route the way the extension does', () {
      expect(
        noRouteReason('OSMO', 'USDC.inj'),
        "Zunia's Osmosis swap contract has no route from OSMO to USDC.inj yet.",
      );
      expect(
        notTradedReason('SAF'),
        'SAF is not traded on Osmosis, so Zunia cannot swap it.',
      );
    });
  });

  group('readXcsExecutableRoute', () {
    ScriptedLcd routeLcd(Object? Function(String path) route) =>
        ScriptedLcd('osmosis-1', (path, _) {
          if (path == xcsConfigPath(xcs)) return live['config'];
          return route(path);
        });

    test('prices only the pools the router will execute', () async {
      final lcd = routeLcd((path) {
        expect(path, xcsRouteQueryPath(router, 'uosmo', atom));
        return {
          'data': {
            'pool_route': [
              {'pool_id': '1', 'token_out_denom': atom},
            ],
          },
        };
      });
      final read = await readXcsExecutableRoute(lcd, xcs, 'uosmo', atom);
      expect(read, isA<XcsRouteReady>());
      expect((read as XcsRouteReady).route.single.poolId, '1');
      expect(read.swapContract, router);
    });

    test(
      'says missing when the router has no entry, and unreadable when the check fails',
      () async {
        final missing = routeLcd(
          (path) => throw InterchainError(
            InterchainErrorCode.lcdUnreachable,
            'answered HTTP 500',
            httpStatus: 500,
          ),
        );
        expect(
          await readXcsExecutableRoute(missing, xcs, 'uosmo', usdcInj),
          isA<XcsRouteMissing>(),
        );
        final wrongEnd = routeLcd(
          (path) => {
            'data': {
              'pool_route': [
                {'pool_id': '1', 'token_out_denom': atom},
              ],
            },
          },
        );
        expect(
          await readXcsExecutableRoute(wrongEnd, xcs, 'uosmo', usdcInj),
          isA<XcsRouteMissing>(),
        );
        final down = routeLcd(
          (path) => throw InterchainError(
            InterchainErrorCode.lcdUnreachable,
            'timeout',
          ),
        );
        expect(
          await readXcsExecutableRoute(down, xcs, 'uosmo', atom),
          isA<XcsRouteUnreadable>(),
        );
        expect(
          await readXcsExecutableRoute(down, 'nope', 'uosmo', atom),
          isA<XcsRouteUnreadable>(),
        );
      },
    );

    test('keeps reads-off its own error', () async {
      final off = ScriptedLcd(
        'osmosis-1',
        (path, _) =>
            throw InterchainError(InterchainErrorCode.readsDisabled, 'off'),
      );
      expect(
        () => readXcsExecutableRoute(off, xcs, 'uosmo', atom),
        throwsA(
          isA<InterchainError>().having(
            (e) => e.code,
            'code',
            InterchainErrorCode.readsDisabled,
          ),
        ),
      );
    });
  });
}
