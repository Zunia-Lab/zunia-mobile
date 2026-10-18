/// The swap tests' offline world: real bundled data and the contract's real
/// route table, with every chain endpoint and the SQS router scripted. Hub
/// channel-141 ↔ Osmosis channel-0, Osmosis channel-122 ↔ Injective
/// channel-8; the router buys 0.5 out per 1 in along whatever it is asked.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/services/interchain/xcs_route.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/swap/osmosis_assets.dart';
import 'package:zunia_mobile/swap/swap_assets.dart';
import 'package:zunia_mobile/swap/swap_data.dart';
import 'package:zunia_mobile/swap/xcs_routes.dart';

import 'swap_fixtures.dart';

const atomOnOsmosis =
    'ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2';
const usdcInj =
    'ibc/794C7D7F3B857713878A3A1927251FA6AC1EEE520424C1F6FAFE9BA26D476138';
const usdcInjOrigin = 'erc20:0xa00C59fF5a080D2b954d0c75e46E22a0c371235a';

final hubMe = bech('cosmos', 1);
final osmoMe = bech('osmo', 1);
final injMe = bech('inj', 2);

late SwapData data;
late Map<String, Object?> live;
late String xcs;
late String router;
late XcsRouteTable table;
late List<OsmosisAsset> osmosis;

ChainEntry chain(String id) => ChainCatalog.instance.find(id)!;

/// Channels in this world: Hub channel-141 ↔ Osmosis channel-0, Osmosis
/// channel-122 ↔ Injective channel-8.
Object? chainAnswer(String chainId, String path, Map<String, Object?> query) {
  const channels = {
    'cosmoshub-4': [('channel-141', 'connection-hub', 'channel-0')],
    'osmosis-1': [
      ('channel-0', 'connection-osmo-hub', 'channel-141'),
      ('channel-122', 'connection-osmo-inj', 'channel-8'),
    ],
    'injective-1': [('channel-8', 'connection-inj', 'channel-122')],
  };
  const targets = {
    '07-connection-hub': 'osmosis-1',
    '07-connection-osmo-hub': 'cosmoshub-4',
    '07-connection-osmo-inj': 'injective-1',
    '07-connection-inj': 'osmosis-1',
  };
  Map<String, Object?> row((String, String, String) c) => {
    'channel_id': c.$1,
    'port_id': 'transfer',
    'state': 'STATE_OPEN',
    'ordering': 'ORDER_UNORDERED',
    'connection_hops': [c.$2],
    'counterparty': {'channel_id': c.$3, 'port_id': 'transfer'},
  };
  final rows = channels[chainId] ?? const [];
  if (path == '/ibc/core/channel/v1/channels') {
    return {
      'channels': [for (final c in rows) row(c)],
      'pagination': {'next_key': null},
    };
  }
  final single = RegExp(
    r'^/ibc/core/channel/v1/channels/([^/]+)/ports/transfer$',
  ).firstMatch(path);
  if (single != null) {
    for (final c in rows) {
      if (c.$1 == single.group(1)) return {'channel': row(c)};
    }
    throw notFound(chainId, path);
  }
  if (path.startsWith('/ibc/core/connection/v1/connections/')) {
    return {
      'connection': {
        'client_id': '07-${path.split('/').last}',
        'state': 'STATE_OPEN',
      },
    };
  }
  if (path.startsWith('/ibc/core/client/v1/client_states/')) {
    return {
      'client_state': {'chain_id': targets[path.split('/').last]},
    };
  }
  if (chainId == 'osmosis-1') {
    if (path == xcsConfigPath(xcs)) return live['config'];
    final route = RegExp(r'/smart/(.+)$').firstMatch(path);
    if (route != null) {
      final padded = route
          .group(1)!
          .padRight((route.group(1)!.length + 3) ~/ 4 * 4, '=');
      final query = jsonDecode(utf8.decode(base64Url.decode(padded))) as Map;
      final ask = query['get_route'] as Map;
      for (final r in table.routes) {
        if (r.input == ask['input_denom'] && r.output == ask['output_denom']) {
          return {
            'data': {
              'pool_route': [
                for (final id in r.poolIds)
                  {'pool_id': id, 'token_out_denom': r.output},
              ],
            },
          };
        }
      }
      throw InterchainError(
        InterchainErrorCode.lcdUnreachable,
        'answered HTTP 500',
        httpStatus: 500,
      );
    }
  }
  throw notFound(chainId, path);
}

/// The SQS router: 1 in buys 0.5 out along whatever route is asked.
Object? routerAnswer(String path, Map<String, Object?> query) {
  final tokenIn = '${query['tokenIn']}';
  final amount = BigInt.parse(RegExp(r'^\d+').firstMatch(tokenIn)!.group(0)!);
  final out = amount ~/ BigInt.two;
  if (path == '/router/custom-direct-quote') {
    final pools = '${query['poolID']}'.split(',');
    final outs = '${query['tokenOutDenom']}'.split(',');
    return {
      'amount_in': {
        'denom': tokenIn.substring('$amount'.length),
        'amount': '$amount',
      },
      'amount_out': '$out',
      'route': [
        {
          'pools': [
            for (var i = 0; i < pools.length; i++)
              {'id': int.parse(pools[i]), 'token_out_denom': outs[i]},
          ],
          'in_amount': '$amount',
          'out_amount': '$out',
        },
      ],
      'effective_fee': '0.002',
      'price_impact': '-0.0004',
      'in_base_out_quote_spot_price': '0.5',
    };
  }
  if (path == '/router/quote') {
    final first = amount * BigInt.from(6) ~/ BigInt.from(10);
    return {
      'amount_in': {
        'denom': tokenIn.substring('$amount'.length),
        'amount': '$amount',
      },
      'amount_out': '$out',
      'route': [
        {
          'pools': [
            {'id': 3498, 'token_out_denom': query['tokenOutDenom']},
          ],
          'in_amount': '$first',
          'out_amount': '${first ~/ BigInt.two}',
        },
        {
          'pools': [
            {'id': 3586, 'token_out_denom': query['tokenOutDenom']},
          ],
          'in_amount': '${amount - first}',
          'out_amount': '${out - first ~/ BigInt.two}',
        },
      ],
      'effective_fee': '0.008',
      'price_impact': '-0.0038',
      'in_base_out_quote_spot_price': '0.5',
    };
  }
  throw notFound('osmosis-1', path);
}

/// The clock the swap state reads; a test that moves time sets it, and
/// [resetWorldClock] puts the real one back.
DateTime Function() worldClock = DateTime.now;
void resetWorldClock() => worldClock = DateTime.now;

List<Override> swapOverrides({
  Map<String, List<HeldToken>>? holdings,
  XcsRouteTable? routes,
  bool tableGiven = true,
  SwapVenueStatus? venue,
  List<String> enabled = const ['cosmoshub-4', 'osmosis-1'],
  SwapData? swapData,
}) {
  final addresses = {
    'cosmoshub-4': hubMe,
    'osmosis-1': osmoMe,
    'injective-1': injMe,
  };
  return [
    swapDataProvider.overrideWith((_) async => swapData ?? data),
    chainAccountsProvider.overrideWithValue([
      for (final id in enabled)
        ChainAccount(chain: chain(id), address: addresses[id]!),
    ]),
    swapHoldingsProvider.overrideWith(
      (_) async =>
          holdings ??
          {
            'cosmoshub-4': const [HeldToken('uatom', '10000000')],
            'osmosis-1': const [HeldToken('uosmo', '50000000')],
          },
    ),
    osmosisSwapAssetsProvider.overrideWith(
      (_) async => OsmosisAssetsRead(osmosis),
    ),
    xcsRouteTableProvider.overrideWith(
      (_) async => tableGiven ? (routes ?? table) : null,
    ),
    swapVenueStatusProvider.overrideWith(
      (_) async =>
          venue ??
          SwapVenueStatus.ready(
            chainId: 'osmosis-1',
            contractAddress: xcs,
            label: 'CrossChainSwaps v1.2',
          ),
    ),
    swapAddressResolverProvider.overrideWithValue((id) => addresses[id]),
    lcdFactoryProvider.overrideWithValue(
      (c) => ScriptedLcd(c.chainId, (p, q) => chainAnswer(c.chainId, p, q)),
    ),
    swapRouterProvider.overrideWithValue(
      ScriptedLcd('osmosis-1', routerAnswer),
    ),
    swapSettingsProvider.overrideWith(
      (_) => SwapSettingsController(restore: false),
    ),
    swapControllerProvider.overrideWith(
      (ref) => SwapController(ref, restoreIntent: false),
    ),
    swapClockProvider.overrideWithValue(() => worldClock()),
  ];
}

ProviderContainer world({
  Map<String, List<HeldToken>>? holdings,
  XcsRouteTable? routes,
  bool tableGiven = true,
  SwapVenueStatus? venue,
  List<String> enabled = const ['cosmoshub-4', 'osmosis-1'],
  SwapData? swapData,
}) {
  final container = ProviderContainer(
    overrides: swapOverrides(
      holdings: holdings,
      routes: routes,
      tableGiven: tableGiven,
      venue: venue,
      enabled: enabled,
      swapData: swapData,
    ),
  );
  addTearDown(container.dispose);
  return container;
}

/// Let every provider settle, then return the view.
Future<SwapView> settle(ProviderContainer c) async {
  // Preferences restore from storage on creation; let that finish before the
  // container can be disposed under it.
  c.read(preferencesProvider);
  await pumpEventQueue();
  await c.read(swapDataProvider.future);
  await c.read(swapHoldingsProvider.future);
  await c.read(osmosisSwapAssetsProvider.future);
  await c.read(swapVenueStatusProvider.future);
  await c.read(xcsRouteTableProvider.future);
  return c.read(swapViewProvider);
}

/// Pick, type, plan: what the form does when the user does.
Future<SwapView> plan(
  ProviderContainer c, {
  required String from,
  required String to,
  required String amount,
}) async {
  await settle(c);
  final controller = c.read(swapControllerProvider.notifier);
  controller
    ..pickFrom(from)
    ..pickTo(to);
  final picked = c.read(swapViewProvider);
  controller.setAmount(amount, picked.from!);
  final view = c.read(swapViewProvider);
  await controller.plan(view);
  return c.read(swapViewProvider);
}

/// Load the bundled data and the fixtures once per test file.
Future<void> loadSwapWorld() async {
  data = await loadTestSwapData();
  live =
      jsonDecode(
            await File(
              'test/fixtures/swap/xcs-route-table.json',
            ).readAsString(),
          )
          as Map<String, Object?>;
  xcs = live['xcsContract'] as String;
  router = live['swapContract'] as String;
  final models = [
    for (final p in live['pages'] as List)
      ...(((p as Map)['body'] as Map)['models'] as List),
  ];
  table = XcsRouteTable(
    xcsContract: xcs,
    swapContract: router,
    routes: parseRouterState(models),
    readAt: DateTime.now(),
  );
  final listed = parseOsmosisTokenMetadata(
    jsonDecode(
      await File('test/fixtures/swap/sqs-tokens-metadata.json').readAsString(),
    ),
  );
  osmosis = osmosisSwapAssets(listed, data.book);
}
