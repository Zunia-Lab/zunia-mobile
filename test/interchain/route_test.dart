/// Ported from `zunia-sdk/packages/interchain/src/route.test.ts`.
///
/// Same chain and channel fixtures, so a plan built here and a plan built by
/// the TypeScript planner can be diffed by eye. The planner never touches the
/// network: the only injected dependency that may await is the denom resolver.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

const atomOnOsmosis =
    'ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2';

const osmosisXcs =
    'osmo1uwk8xc6q0s6t5qcpr6rht3sczu6du83xq8pwxjua0hfj5hzcnh3sqxwvxs';

/// Safrochain's prefix has an underscore. Nothing in the planner may split,
/// lowercase or otherwise touch an address, and the tests below check that the
/// recipient survives verbatim into the memo.
const safroAddress = 'addr_safro1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq';

ChainInfo _chain(
  String chainId,
  String name,
  String prefix,
  String denom, {
  String network = 'mainnet',
  List<String>? features,
  String? rest,
}) =>
    ChainInfo(
      chainId: chainId,
      chainName: name,
      bech32Prefix: prefix,
      coinMinimalDenom: denom,
      network: network,
      rest: rest ?? 'https://rest.$chainId.example',
      features: features,
    );

final _chains = <ChainInfo>[
  _chain('safrochain-1', 'Safrochain', 'addr_safro', 'usafro',
      features: ['cosmwasm']),
  _chain('cosmoshub-4', 'Cosmos Hub', 'cosmos', 'uatom'),
  _chain('osmosis-1', 'Osmosis', 'osmo', 'uosmo', features: ['cosmwasm']),
  _chain('juno-1', 'Juno', 'juno', 'ujuno', features: ['cosmwasm']),
  _chain('stargaze-1', 'Stargaze', 'stars', 'ustars'),
  _chain('safro-testnet-1', 'Safrochain Testnet', 'addr_safro', 'usafro',
      network: 'testnet'),
];

class _Registry implements ChainRegistry {
  @override
  ChainInfo? get(String chainId) {
    for (final chain in _chains) {
      if (chain.chainId == chainId) return chain;
    }
    return null;
  }

  @override
  List<ChainInfo> list() => _chains;
}

/// Hub/Osmosis and Osmosis/Juno use the real channel ids so the computed denoms
/// match the published hashes; the Safrochain edges are invented.
final _links = <ChannelLink>[
  const ChannelLink(
    sourceChainId: 'cosmoshub-4',
    destChainId: 'osmosis-1',
    channelId: 'channel-141',
    counterpartyChannelId: 'channel-0',
    source: ChannelLinkSource.verified,
    state: IbcChannelState.open,
  ),
  const ChannelLink(
    sourceChainId: 'osmosis-1',
    destChainId: 'juno-1',
    channelId: 'channel-42',
    counterpartyChannelId: 'channel-0',
    source: ChannelLinkSource.verified,
    state: IbcChannelState.open,
  ),
  const ChannelLink(
    sourceChainId: 'cosmoshub-4',
    destChainId: 'juno-1',
    channelId: 'channel-207',
    counterpartyChannelId: 'channel-1',
    source: ChannelLinkSource.verified,
    state: IbcChannelState.open,
  ),
  const ChannelLink(
    sourceChainId: 'juno-1',
    destChainId: 'stargaze-1',
    channelId: 'channel-5',
    counterpartyChannelId: 'channel-7',
  ),
  const ChannelLink(
    sourceChainId: 'safrochain-1',
    destChainId: 'osmosis-1',
    channelId: 'channel-0',
    counterpartyChannelId: 'channel-9999',
    source: ChannelLinkSource.verified,
    state: IbcChannelState.open,
  ),
  const ChannelLink(
    sourceChainId: 'safro-testnet-1',
    destChainId: 'osmosis-1',
    channelId: 'channel-3',
    counterpartyChannelId: 'channel-8888',
  ),
];

final _directory = createChannelDirectory(_links);

const _capabilities = <String, ChainCapabilities>{
  'osmosis-1': ChainCapabilities(pfm: true, ibcHooks: true, cosmwasm: true),
  'cosmoshub-4': ChainCapabilities(pfm: true, ibcHooks: false, cosmwasm: false),
  'juno-1': ChainCapabilities(pfm: false, ibcHooks: false, cosmwasm: true),
};

RoutePlannerDeps _deps({
  Future<ResolvedDenom> Function(ChainInfo, String)? resolveDenom,
  List<SwapVenue> venues = const [
    SwapVenue(chainId: 'osmosis-1', contractAddress: osmosisXcs),
  ],
}) =>
    RoutePlannerDeps(
      registry: _Registry(),
      channels: _directory,
      capabilities: (chainId) => _capabilities[chainId],
      venues: venues,
      resolveDenom: resolveDenom,
    );

RouteRequest _request({
  String sourceChainId = 'safrochain-1',
  String destChainId = 'osmosis-1',
  String inputDenom = 'usafro',
  String amount = '1000000',
  String sender = safroAddress,
  String recipient = 'osmo1recipient',
  String? outputDenom,
  double? slippagePercent,
  int? maxHops,
  bool allowSwap = false,
  bool allowPfm = true,
  String? recoveryAddress,
}) =>
    RouteRequest(
      sourceChainId: sourceChainId,
      destChainId: destChainId,
      inputDenom: inputDenom,
      amount: amount,
      sender: sender,
      recipient: recipient,
      outputDenom: outputDenom,
      slippagePercent: slippagePercent,
      maxHops: maxHops,
      allowSwap: allowSwap,
      allowPfm: allowPfm,
      recoveryAddress: recoveryAddress,
    );

Map<String, Object?> _memoOf(RoutePlanCandidate candidate) =>
    jsonDecode(candidate.plan.memo) as Map<String, Object?>;

Map<String, Object?> _objectAt(Object? value, String key) =>
    (value! as Map<String, Object?>)[key]! as Map<String, Object?>;

final _atomOnOsmosisTrace = ResolvedDenom(
  denom: atomOnOsmosis,
  baseDenom: 'uatom',
  path: 'transfer/channel-0',
  hops: const [DenomHop(port: 'transfer', channelId: 'channel-0')],
  originChainId: 'cosmoshub-4',
  isNative: false,
  ibcHash: atomOnOsmosis.substring(4),
);

void main() {
  group('createChannelDirectory', () {
    test('derives the reverse of a link that names its counterparty', () {
      final directory = createChannelDirectory([
        const ChannelLink(
          sourceChainId: 'a',
          destChainId: 'b',
          channelId: 'channel-1',
          counterpartyChannelId: 'channel-2',
        ),
      ]);
      final reverse = directory.from('b').single;
      expect(reverse.channelId, 'channel-2');
      expect(reverse.destChainId, 'a');
      expect(reverse.derived, isTrue);
    });

    test('leaves a link without a counterparty one-way', () {
      final directory = createChannelDirectory([
        const ChannelLink(
            sourceChainId: 'a', destChainId: 'b', channelId: 'channel-1'),
      ]);
      expect(directory.from('b'), isEmpty);
    });

    test('drops rows with missing ids', () {
      final directory = createChannelDirectory([
        const ChannelLink(
            sourceChainId: '', destChainId: 'b', channelId: 'channel-1'),
        const ChannelLink(
            sourceChainId: 'a', destChainId: 'b', channelId: ''),
      ]);
      expect(directory.from('a'), isEmpty);
    });
  });

  group('findRoutePaths', () {
    test('returns shortest paths first', () {
      final paths = findRoutePaths('cosmoshub-4', 'juno-1', _directory);
      expect(paths.first.links.length, 1);
      expect(paths.first.links.first.channelId, 'channel-207');
    });

    test('never revisits a chain', () {
      for (final path in findRoutePaths('cosmoshub-4', 'stargaze-1', _directory)) {
        expect(path.chainIds.toSet().length, path.chainIds.length);
      }
    });

    test('respects the hop budget and clamps a silly one to the cap', () {
      expect(findRoutePaths('cosmoshub-4', 'stargaze-1', _directory, maxHops: 1),
          isEmpty);
      expect(
        findRoutePaths('cosmoshub-4', 'stargaze-1', _directory, maxHops: 99)
            .every((p) => p.links.length <= kMaxHopsCap),
        isTrue,
      );
    });

    test('skips closed channels', () {
      final directory = createChannelDirectory([
        const ChannelLink(
          sourceChainId: 'a',
          destChainId: 'b',
          channelId: 'channel-1',
          state: IbcChannelState.closed,
        ),
      ]);
      expect(findRoutePaths('a', 'b', directory), isEmpty);
    });

    test('returns nothing for a same-chain or empty request', () {
      expect(findRoutePaths('a', 'a', _directory), isEmpty);
      expect(findRoutePaths('', 'b', _directory), isEmpty);
    });
  });

  group('same chain', () {
    test('same denom is a bank send with no hops', () async {
      final result = await planRoute(
        _request(destChainId: 'safrochain-1', recipient: safroAddress),
        _deps(),
      );
      final best = result.best!;
      expect(best.strategy, RouteStrategy.bankSend);
      expect(best.plan.hops, isEmpty);
      expect(best.plan.memo, '');
      expect(best.requiresQuote, isFalse);
    });

    test('a different denom needs allowSwap', () async {
      final result = await planRoute(
        _request(
            destChainId: 'safrochain-1',
            recipient: safroAddress,
            outputDenom: 'uother'),
        _deps(),
      );
      expect(result.candidates, isEmpty);
      expect(result.warnings.any((w) => w.contains('Swaps are turned off')),
          isTrue);
    });
  });

  group('cross chain, same asset', () {
    test('a direct channel is a plain transfer with no memo', () async {
      final result = await planRoute(_request(), _deps());
      final best = result.best!;
      expect(best.strategy, RouteStrategy.ibcTransfer);
      expect(best.plan.memo, '');
      expect(best.plan.hops.single.channelId, 'channel-0');
      expect(best.plan.hops.single.kind, RouteHopKind.transfer);
      // A direct hop is addressed to the real recipient.
      expect(best.receiver, 'osmo1recipient');
      expect(best.plan.requiresPfm, isFalse);
    });

    test('the destination denom is the real ibc hash of the wrapped path',
        () async {
      final result = await planRoute(
        _request(
            sourceChainId: 'cosmoshub-4',
            inputDenom: 'uatom',
            sender: 'cosmos1sender'),
        _deps(),
      );
      expect(result.best!.plan.outputDenom, atomOnOsmosis);
    });

    test('a two-hop route nests one forward with the real recipient',
        () async {
      final result = await planRoute(
        _request(
          sourceChainId: 'cosmoshub-4',
          destChainId: 'stargaze-1',
          inputDenom: 'uatom',
          sender: 'cosmos1sender',
          recipient: 'stars1recipient',
          maxHops: 2,
        ),
        _deps(),
      );
      final best = result.best!;
      expect(best.strategy, RouteStrategy.ibcForward);
      final forward = _objectAt(_memoOf(best), 'forward');
      expect(forward['receiver'], 'stars1recipient');
      expect(forward['channel'], 'channel-5');
      expect(forward.containsKey('next'), isFalse);
      expect(best.plan.hops.map((h) => h.kind).toList(),
          [RouteHopKind.transfer, RouteHopKind.forward]);
    });

    test('the first packet is addressed to the intermediate chain', () async {
      final result = await planRoute(
        _request(
          sourceChainId: 'cosmoshub-4',
          destChainId: 'stargaze-1',
          inputDenom: 'uatom',
          sender: 'cosmos1sender',
          recipient: 'stars1recipient',
          maxHops: 2,
        ),
        _deps(),
        const PlanRouteOptions(
          intermediateReceivers: {'juno-1': 'juno1intermediate'},
        ),
      );
      expect(result.best!.receiver, 'juno1intermediate');
    });

    test('without an intermediate receiver the placeholder is used and warned',
        () async {
      final result = await planRoute(
        _request(
          sourceChainId: 'cosmoshub-4',
          destChainId: 'stargaze-1',
          inputDenom: 'uatom',
          sender: 'cosmos1sender',
          recipient: 'stars1recipient',
          maxHops: 2,
        ),
        _deps(),
      );
      final best = result.best!;
      expect(best.receiver, 'pfm');
      expect(
        best.plan.warnings.any((w) => w.contains('must replace it before')),
        isTrue,
      );
    });

    test('allowPfm false rules out everything but a direct channel', () async {
      final result = await planRoute(
        _request(
          sourceChainId: 'cosmoshub-4',
          destChainId: 'stargaze-1',
          inputDenom: 'uatom',
          sender: 'cosmos1sender',
          recipient: 'stars1recipient',
          allowPfm: false,
        ),
        _deps(),
      );
      expect(result.candidates, isEmpty);
      expect(
        result.warnings.any((w) => w.contains('Packet forwarding is turned off')),
        isTrue,
      );
    });

    test('a chain that does not run PFM is a warning, not a refusal', () async {
      final result = await planRoute(
        _request(
          sourceChainId: 'cosmoshub-4',
          destChainId: 'stargaze-1',
          inputDenom: 'uatom',
          sender: 'cosmos1sender',
          recipient: 'stars1recipient',
          maxHops: 2,
        ),
        _deps(),
      );
      expect(result.best, isNotNull);
      expect(
        result.best!.plan.warnings.any(
            (w) => w.contains('does not run packet-forward-middleware')),
        isTrue,
      );
    });

    test('an unverified channel is flagged', () async {
      final result = await planRoute(
        _request(
          sourceChainId: 'juno-1',
          destChainId: 'stargaze-1',
          inputDenom: 'ujuno',
          sender: 'juno1sender',
          recipient: 'stars1recipient',
        ),
        _deps(),
      );
      final best = result.best!;
      expect(best.unverifiedChannelCount, 1);
      expect(
        best.plan.warnings.any((w) => w.contains('not been verified as open')),
        isTrue,
      );
    });

    test('mixing mainnet and testnet is called out', () async {
      final result = await planRoute(
        _request(sourceChainId: 'safro-testnet-1', sender: safroAddress),
        _deps(),
      );
      expect(
        result.best!.plan.warnings
            .any((w) => w.contains('mainnet and testnet')),
        isTrue,
      );
    });

    test('a Safrochain recipient keeps its underscore prefix verbatim',
        () async {
      final result = await planRoute(
        _request(
          sourceChainId: 'cosmoshub-4',
          destChainId: 'stargaze-1',
          inputDenom: 'uatom',
          sender: 'cosmos1sender',
          recipient: safroAddress,
          maxHops: 2,
        ),
        _deps(),
      );
      expect(result.best!.plan.memo, contains(safroAddress));
    });
  });

  group('wrapped denoms', () {
    test('a wrapped token unwinds along the channel it arrived on', () async {
      final result = await planRoute(
        _request(
          sourceChainId: 'osmosis-1',
          destChainId: 'cosmoshub-4',
          inputDenom: atomOnOsmosis,
          sender: 'osmo1sender',
          recipient: 'cosmos1recipient',
        ),
        _deps(resolveDenom: (chain, denom) async => _atomOnOsmosisTrace),
      );
      final best = result.best!;
      expect(best.unwindsDenom, isTrue);
      expect(best.plan.hops.single.channelId, 'channel-0');
      // Unwinding returns the base denom, not a second wrapper.
      expect(best.plan.outputDenom, 'uatom');
    });

    test('a resolver that throws leaves a warning and still plans', () async {
      final result = await planRoute(
        _request(
          sourceChainId: 'osmosis-1',
          destChainId: 'cosmoshub-4',
          inputDenom: atomOnOsmosis,
          sender: 'osmo1sender',
          recipient: 'cosmos1recipient',
        ),
        _deps(
          resolveDenom: (chain, denom) async =>
              throw StateError('trace endpoint down'),
        ),
      );
      expect(
        result.warnings.any((w) => w.contains('Could not read the denom trace')),
        isTrue,
      );
      expect(result.best, isNotNull);
    });

    test('without a resolver a wrapped denom stays opaque', () async {
      final result = await planRoute(
        _request(
          sourceChainId: 'osmosis-1',
          destChainId: 'cosmoshub-4',
          inputDenom: atomOnOsmosis,
          sender: 'osmo1sender',
          recipient: 'cosmos1recipient',
        ),
        _deps(),
      );
      expect(
        result.warnings.any((w) => w.contains('No denom resolver')),
        isTrue,
      );
    });
  });

  group('cross-chain swap', () {
    test('builds a wasm memo with exactly contract and msg', () async {
      final result = await planRoute(
        _request(
          outputDenom: 'uosmo',
          allowSwap: true,
          slippagePercent: 20,
          recoveryAddress: 'osmo1recovery',
        ),
        _deps(),
        const PlanRouteOptions(twapWindowSeconds: 10),
      );
      final best = result.best!;
      expect(best.strategy, RouteStrategy.ibcSwap);
      expect(best.plan.requiresIbcHooks, isTrue);
      expect(best.plan.requiresPfm, isFalse);
      expect(best.requiresQuote, isTrue);
      expect(best.quote, isNull);

      final memo = _memoOf(best);
      expect(memo.keys.toList(), ['wasm']);
      final wasm = _objectAt(memo, 'wasm');
      // The middleware rejects the packet unless this object holds exactly
      // these two keys.
      expect(wasm.keys.toList()..sort(), ['contract', 'msg']);
      expect(wasm['contract'], osmosisXcs);

      final swap = _objectAt(_objectAt(wasm, 'msg'), 'osmosis_swap');
      expect(swap['output_denom'], 'uosmo');
      expect(swap['receiver'], 'osmo1recipient');
      expect(swap['next_memo'], isNull);
      expect(swap['on_failed_delivery'],
          {'local_recovery_addr': 'osmo1recovery'});
      expect(swap['slippage'], {
        'twap': {'slippage_percentage': '20', 'window_seconds': 10},
      });

      // ibc-hooks requires the ICS20 receiver to be "" or the contract address.
      expect(best.receiver, osmosisXcs);
    });

    test('omits window_seconds when the host chose no window', () async {
      final result = await planRoute(
        _request(
          outputDenom: 'uosmo',
          allowSwap: true,
          slippagePercent: 1,
          recoveryAddress: 'osmo1recovery',
        ),
        _deps(),
      );
      final swap = _objectAt(
          _objectAt(_objectAt(_memoOf(result.best!), 'wasm'), 'msg'),
          'osmosis_swap');
      expect(swap['slippage'], {
        'twap': {'slippage_percentage': '1'},
      });
    });

    test('no recovery address means do_nothing, and the user is told',
        () async {
      final result = await planRoute(
        _request(outputDenom: 'uosmo', allowSwap: true),
        _deps(),
      );
      final swap = _objectAt(
          _objectAt(_objectAt(_memoOf(result.best!), 'wasm'), 'msg'),
          'osmosis_swap');
      expect(swap['on_failed_delivery'], 'do_nothing');
      expect(result.warnings.any((w) => w.contains('cannot be reclaimed')),
          isTrue);
    });

    test('a quoted minimum switches the slippage form', () async {
      final result = await planRoute(
        _request(outputDenom: 'uosmo', allowSwap: true),
        _deps(),
        const PlanRouteOptions(minOutputAmount: '990000'),
      );
      final swap = _objectAt(
          _objectAt(_objectAt(_memoOf(result.best!), 'wasm'), 'msg'),
          'osmosis_swap');
      expect(swap['slippage'], {'min_output_amount': '990000'});
    });

    test('a swap with a hop after it addresses the recipient directly',
        () async {
      final result = await planRoute(
        _request(
          destChainId: 'juno-1',
          outputDenom: 'uosmo',
          allowSwap: true,
          recipient: 'juno1recipient',
          maxHops: 3,
        ),
        _deps(),
      );
      final best = result.best!;
      final swap = _objectAt(
          _objectAt(_objectAt(_memoOf(best), 'wasm'), 'msg'), 'osmosis_swap');
      // One outbound hop: the contract sends straight to the recipient.
      expect(swap['receiver'], 'juno1recipient');
      expect(swap['next_memo'], isNull);
      expect(best.plan.hops.map((h) => h.kind).toList(),
          [RouteHopKind.transfer, RouteHopKind.swap, RouteHopKind.forward]);
      expect(best.plan.hops[1].channelId, '');
      expect(best.plan.hops[1].counterpartyChainId, 'osmosis-1');
    });

    test('two hops after the swap put a forward in next_memo', () async {
      final result = await planRoute(
        _request(
          destChainId: 'stargaze-1',
          outputDenom: 'uosmo',
          allowSwap: true,
          recipient: 'stars1recipient',
          maxHops: 3,
        ),
        _deps(),
        const PlanRouteOptions(
          intermediateReceivers: {'juno-1': 'juno1intermediate'},
        ),
      );
      final best = result.best!;
      final swap = _objectAt(
          _objectAt(_objectAt(_memoOf(best), 'wasm'), 'msg'), 'osmosis_swap');
      expect(swap['receiver'], 'juno1intermediate');
      final forward = _objectAt(swap['next_memo'], 'forward');
      expect(forward['channel'], 'channel-5');
      expect(forward['receiver'], 'stars1recipient');
      expect(best.plan.requiresPfm, isTrue);
    });

    test('a hop before the swap wraps the wasm memo in a forward to the '
        'contract', () async {
      final result = await planRoute(
        _request(
          sourceChainId: 'cosmoshub-4',
          destChainId: 'osmosis-1',
          inputDenom: 'uatom',
          outputDenom: 'uosmo',
          allowSwap: true,
          sender: 'cosmos1sender',
          maxHops: 3,
        ),
        _deps(),
        const PlanRouteOptions(
          intermediateReceivers: {'juno-1': 'juno1intermediate'},
        ),
      );
      final viaJuno = result.candidates
          .where((c) => c.links.first.channelId == 'channel-207')
          .toList();
      expect(viaJuno, isNotEmpty,
          reason: 'the route through Juno should be offered');
      final forward = _objectAt(_memoOf(viaJuno.first), 'forward');
      // The forward that lands on Osmosis must address the contract, and the
      // wasm memo rides in `next` so ibc-hooks sees it on arrival.
      expect(forward['receiver'], osmosisXcs);
      final wasm = _objectAt(_objectAt(forward, 'next'), 'wasm');
      expect(wasm.keys.toList()..sort(), ['contract', 'msg']);
      expect(viaJuno.first.receiver, 'juno1intermediate');
      expect(viaJuno.first.plan.requiresPfm, isTrue);
      expect(viaJuno.first.plan.requiresIbcHooks, isTrue);
    });

    test('no venue means no swap route, and the reason is stated', () async {
      final result = await planRoute(
        _request(outputDenom: 'uosmo', allowSwap: true),
        _deps(venues: const []),
      );
      expect(result.candidates, isEmpty);
      expect(result.warnings, contains('No swap venue is configured'));
    });
  });

  group('manual overrides', () {
    test('an override replaces the channel the search picked', () async {
      final result = await planRoute(
        _request(),
        _deps(),
        const PlanRouteOptions(
          overrides: [RouteHopOverride(hopIndex: 0, channelId: 'channel-777')],
        ),
      );
      final best = result.best!;
      expect(best.plan.hops.single.channelId, 'channel-777');
      expect(
        best.plan.warnings.any((w) => w.contains('entered by hand')),
        isTrue,
      );
    });

    test('an override alone builds a route the directory has never seen',
        () async {
      final result = await planRoute(
        _request(destChainId: 'juno-1', recipient: 'juno1recipient'),
        RoutePlannerDeps(
          registry: _Registry(),
          // An empty graph: discovery found nothing at all.
          channels: createChannelDirectory(const []),
          capabilities: (chainId) => _capabilities[chainId],
        ),
        const PlanRouteOptions(
          overrides: [
            RouteHopOverride(
              fromChainId: 'safrochain-1',
              toChainId: 'juno-1',
              channelId: 'channel-12',
            ),
          ],
        ),
      );
      final best = result.best!;
      expect(best.plan.hops.single.channelId, 'channel-12');
      expect(best.links.single.source, ChannelLinkSource.manual);
      expect(
        best.plan.warnings.any((w) => w.contains('has not been checked')),
        isTrue,
      );
    });
  });

  test('bestRoutePlan carries the warnings when nothing works', () async {
    await expectLater(
      bestRoutePlan(
        _request(destChainId: 'stargaze-1', recipient: 'stars1r', allowPfm: false),
        _deps(),
      ),
      throwsA(isA<InterchainError>()
          .having((e) => e.code, 'code', InterchainErrorCode.noRoute)
          .having((e) => e.message, 'message', contains('No route from'))),
    );
  });
}
