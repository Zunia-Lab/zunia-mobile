/// Ported from `zunia-sdk/packages/interchain/src/denom.test.ts`.
///
/// The hash vectors are the same ones: ATOM on Osmosis is a denom anyone can
/// check against a block explorer, so a port that computes it differently is
/// caught here rather than by a user holding a token nothing can name.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/services/interchain/denom.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

/// The canonical ATOM-on-Osmosis voucher.
const atomOnOsmosis =
    'ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2';

/// The same ATOM after a second hop, Osmosis -> Juno over Juno's channel-42.
final atomViaOsmosisOnJuno =
    ibcDenomHash('transfer/channel-42/transfer/channel-0', 'uatom');

ChainInfo _chain(String id, String name, String prefix, String denom) =>
    ChainInfo(
      chainId: id,
      chainName: name,
      bech32Prefix: prefix,
      coinMinimalDenom: denom,
      rest: 'https://lcd.$id.test',
    );

final _chains = [
  _chain('cosmoshub-4', 'Cosmos Hub', 'cosmos', 'uatom'),
  _chain('osmosis-1', 'Osmosis', 'osmo', 'uosmo'),
  _chain('juno-1', 'Juno', 'juno', 'ujuno'),
  _chain('safrochain-1', 'Safrochain', 'addr_safro', 'usaf'),
];

class _FakeRegistry implements ChainRegistry {
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

/// An [LcdClient] backed by a route table, so no socket is ever opened.
class _FakeLcd implements LcdClient {
  _FakeLcd(this.chainId, this.routes, this.calls);

  @override
  final String chainId;
  final Map<String, Object? Function()> routes;
  final List<String> calls;

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    calls.add('$chainId$path');
    final handler = routes['$chainId$path'];
    if (handler == null) {
      throw InterchainError(
        InterchainErrorCode.lcdUnreachable,
        'no route for $chainId$path',
        chainId: chainId,
        httpStatus: 404,
      );
    }
    return handler();
  }
}

Map<String, Object?> _wrapped(String path, String base) => {
      'denom_trace': {'path': path, 'base_denom': base},
    };

({DenomContext ctx, List<String> calls}) _harness({
  Map<String, Object? Function()> routes = const {},
  ChannelCounterpartyLookup? counterparty,
}) {
  final calls = <String>[];
  final registry = _FakeRegistry();
  return (
    ctx: DenomContext(
      lcd: (chain) => _FakeLcd(chain.chainId, routes, calls),
      registry: registry,
      counterparty: counterparty,
    ),
    calls: calls,
  );
}

String _traceKey(String chainId, String denom) =>
    '$chainId/ibc/apps/transfer/v1/denom_traces/${denom.substring(4)}';

Map<String, Object? Function()> _defaultRoutes() => {
      _traceKey('osmosis-1', atomOnOsmosis): () =>
          _wrapped('transfer/channel-0', 'uatom'),
      _traceKey('juno-1', atomViaOsmosisOnJuno): () =>
          _wrapped('transfer/channel-42/transfer/channel-0', 'uatom'),
    };

/// juno-1/channel-42 -> osmosis-1 -> (channel-0) -> cosmoshub-4.
Future<String?> _counterparty(
    String chainId, String port, String channelId) async {
  if (chainId == 'juno-1' && channelId == 'channel-42') return 'osmosis-1';
  if (chainId == 'osmosis-1' && channelId == 'channel-0') return 'cosmoshub-4';
  return null;
}

void main() {
  group('hashing', () {
    test('reproduces the known ATOM-on-Osmosis denom', () {
      expect(ibcDenomHash('transfer/channel-0', 'uatom'), atomOnOsmosis);
    });

    test('ibcDenomHashHex is uppercase hex with no prefix', () {
      final hex = ibcDenomHashHex('transfer/channel-0', 'uatom');
      expect(hex, matches(r'^[0-9A-F]{64}$'));
      expect('ibc/$hex', atomOnOsmosis);
    });

    test('ignores stray slashes and whitespace in the path', () {
      expect(ibcDenomHash('/transfer/channel-0/', 'uatom'), atomOnOsmosis);
      expect(ibcDenomHash('  transfer/channel-0  ', ' uatom '), atomOnOsmosis);
    });

    test('rejects an empty base denom', () {
      expect(() => ibcDenomHash('transfer/channel-0', '   '),
          throwsA(isA<InterchainError>()));
    });

    test('isIbcDenom / ibcHashFromDenom', () {
      expect(isIbcDenom('uatom'), isFalse);
      expect(isIbcDenom(atomOnOsmosis), isTrue);
      expect(ibcHashFromDenom('uatom'), isNull);
      expect(ibcHashFromDenom('factory/osmo1abc/uusdc'), isNull);
      expect(ibcHashFromDenom(atomOnOsmosis), atomOnOsmosis.substring(4));
    });

    test('rejects an ibc/ denom that is not a 64-char hash', () {
      expect(() => ibcHashFromDenom('ibc/nope'),
          throwsA(isA<InterchainError>()));
    });
  });

  group('trace paths', () {
    test('parseTracePath splits ordered hops', () {
      expect(
        parseTracePath('transfer/channel-0/transfer/channel-42'),
        [
          const DenomHop(port: 'transfer', channelId: 'channel-0'),
          const DenomHop(port: 'transfer', channelId: 'channel-42'),
        ],
      );
      expect(parseTracePath(''), isEmpty);
    });

    test('rejects an odd segment count and an empty segment', () {
      expect(() => parseTracePath('transfer/channel-0/transfer'),
          throwsA(isA<InterchainError>()));
      expect(() => parseTracePath('transfer//channel-0/transfer/channel-1'),
          throwsA(isA<InterchainError>()));
    });

    test('rejects a non-transfer port unless asked not to', () {
      expect(() => parseTracePath('wasm.osmo1abc/channel-0'),
          throwsA(isA<InterchainError>()));
      expect(
        parseTracePath('wasm.osmo1abc/channel-0',
            allowNonTransferPorts: true),
        [const DenomHop(port: 'wasm.osmo1abc', channelId: 'channel-0')],
      );
    });

    test('rejects a channel id that is not channel-<n>', () {
      expect(() => parseTracePath('transfer/chan0'),
          throwsA(isA<InterchainError>()));
    });

    test('joinTracePath inverts parseTracePath', () {
      const path = 'transfer/channel-0/transfer/channel-42';
      expect(joinTracePath(parseTracePath(path)), path);
    });
  });

  group('parseDenomTrace', () {
    test('accepts the documented wrapped shape', () {
      final trace = parseDenomTrace(_wrapped('transfer/channel-0', 'uatom'));
      expect(trace.path, 'transfer/channel-0');
      expect(trace.baseDenom, 'uatom');
    });

    test('accepts a bare object and ignores extra keys', () {
      final trace = parseDenomTrace(<String, Object?>{
        'path': 'transfer/channel-0',
        'base_denom': 'uatom',
        'extra': 1,
      });
      expect(trace.baseDenom, 'uatom');
    });

    test('accepts a native trace with no path', () {
      final trace = parseDenomTrace(<String, Object?>{'base_denom': 'uatom'});
      expect(trace.path, '');
    });

    test('accepts the ibc-go v9 denoms shape', () {
      final trace = parseDenomTrace(<String, Object?>{
        'denom': {
          'base': 'uatom',
          'trace': [
            {'port_id': 'transfer', 'channel_id': 'channel-0'},
          ],
        },
      });
      expect(trace.path, 'transfer/channel-0');
      expect(trace.baseDenom, 'uatom');
    });

    test('rejects malformed bodies', () {
      for (final body in <Object?>[
        null,
        <String, Object?>{},
        <String, Object?>{'denom_trace': <String, Object?>{}},
        <String, Object?>{'path': 'transfer/channel-0'},
      ]) {
        expect(() => parseDenomTrace(body), throwsA(isA<InterchainError>()));
      }
    });
  });

  group('resolveDenom', () {
    test('returns a native denom without touching the network', () async {
      final h = _harness();
      final resolved = await resolveDenom(h.ctx, 'cosmoshub-4', 'uatom');
      expect(h.calls, isEmpty);
      expect(resolved.isNative, isTrue);
      expect(resolved.baseDenom, 'uatom');
      expect(resolved.path, '');
      expect(resolved.hops, isEmpty);
      expect(resolved.ibcHash, isNull);
      expect(resolved.originChainId, 'cosmoshub-4');
      expect(resolved.originProvenance, OriginProvenance.native);
    });

    test('parses a voucher', () async {
      final h = _harness(routes: _defaultRoutes());
      final resolved = await resolveDenom(h.ctx, 'osmosis-1', atomOnOsmosis);
      expect(h.calls, [_traceKey('osmosis-1', atomOnOsmosis)]);
      expect(resolved.isNative, isFalse);
      expect(resolved.baseDenom, 'uatom');
      expect(resolved.path, 'transfer/channel-0');
      expect(resolved.hops,
          [const DenomHop(port: 'transfer', channelId: 'channel-0')]);
      expect(resolved.ibcHash, atomOnOsmosis.substring(4));
      expect(resolved.chainId, 'osmosis-1');
    });

    test('rejects a trace that does not hash back to the denom asked for',
        () async {
      final h = _harness(routes: {
        // The endpoint answers with a different token entirely.
        _traceKey('osmosis-1', atomOnOsmosis): () =>
            _wrapped('transfer/channel-0', 'ujuno'),
      });
      expect(
        () => resolveDenom(h.ctx, 'osmosis-1', atomOnOsmosis),
        throwsA(isA<InterchainError>().having(
            (e) => e.code, 'code', InterchainErrorCode.malformedResponse)),
      );
    });

    test('falls back to the v9 /denoms path on 404', () async {
      final h = _harness(routes: {
        'osmosis-1/ibc/apps/transfer/v1/denoms/${atomOnOsmosis.substring(4)}':
            () => _wrapped('transfer/channel-0', 'uatom'),
      });
      final resolved = await resolveDenom(h.ctx, 'osmosis-1', atomOnOsmosis);
      expect(resolved.baseDenom, 'uatom');
    });

    test('refuses an unknown chain and a malformed denom', () async {
      final h = _harness();
      expect(() => resolveDenom(h.ctx, 'nope-1', 'uatom'),
          throwsA(isA<InterchainError>()));
      expect(() => resolveDenom(h.ctx, 'cosmoshub-4', '  '),
          throwsA(isA<InterchainError>()));
    });

    test('walks the channels to the origin chain when a lookup is wired',
        () async {
      final h = _harness(
          routes: _defaultRoutes(), counterparty: _counterparty);
      final resolved =
          await resolveDenom(h.ctx, 'juno-1', atomViaOsmosisOnJuno);
      expect(resolved.originChainId, 'cosmoshub-4');
      expect(resolved.originProvenance, OriginProvenance.channelWalk);
      expect(resolved.hopChainIds, ['osmosis-1', 'cosmoshub-4']);
    });

    test('leaves the origin unknown without a lookup', () async {
      final h = _harness(routes: _defaultRoutes());
      final resolved = await resolveDenom(h.ctx, 'osmosis-1', atomOnOsmosis);
      expect(resolved.originChainId, isNull);
      expect(resolved.originProvenance, OriginProvenance.unknown);
    });
  });

  group('unwindPath', () {
    test('is empty for a native denom', () async {
      final h = _harness();
      final resolved = await resolveDenom(h.ctx, 'cosmoshub-4', 'uatom');
      expect(unwindPath(resolved), isEmpty);
    });

    test('walks the trace left to right, naming the denom at every step',
        () async {
      final h =
          _harness(routes: _defaultRoutes(), counterparty: _counterparty);
      final resolved =
          await resolveDenom(h.ctx, 'juno-1', atomViaOsmosisOnJuno);
      final steps = unwindPath(resolved);
      expect(steps.length, 2);

      // Hop 0 is the channel on the chain holding the token: sending out of
      // exactly this channel burns the voucher instead of wrapping it again.
      expect(steps[0].channelId, 'channel-42');
      expect(steps[0].fromChainId, 'juno-1');
      expect(steps[0].toChainId, 'osmosis-1');
      expect(steps[0].denom, atomViaOsmosisOnJuno);
      expect(steps[0].nextDenom, atomOnOsmosis);
      expect(steps[0].nextPath, 'transfer/channel-0');
      expect(steps[0].landsOnOrigin, isFalse);

      expect(steps[1].channelId, 'channel-0');
      expect(steps[1].fromChainId, 'osmosis-1');
      expect(steps[1].toChainId, 'cosmoshub-4');
      expect(steps[1].nextDenom, 'uatom');
      expect(steps[1].nextPath, '');
      expect(steps[1].landsOnOrigin, isTrue);
    });

    test('works on a plain ResolvedDenom with no chain ids', () {
      final bare = ResolvedDenom(
        denom: atomOnOsmosis,
        baseDenom: 'uatom',
        path: 'transfer/channel-0',
        hops: const [DenomHop(port: 'transfer', channelId: 'channel-0')],
        originChainId: null,
        isNative: false,
        ibcHash: atomOnOsmosis.substring(4),
      );
      final steps = unwindPath(bare);
      expect(steps.single.fromChainId, isNull);
      expect(steps.single.toChainId, isNull);
      expect(steps.single.nextDenom, 'uatom');
    });
  });

  group('recommendDenom', () {
    test('on the same chain moves nothing', () async {
      final h = _harness();
      final plan =
          await recommendDenom(h.ctx, 'cosmoshub-4', 'cosmoshub-4', 'uatom');
      expect(plan.strategy, DenomStrategy.direct);
      expect(plan.outputDenom, 'uatom');
      expect(plan.unwind, isEmpty);
    });

    test('sends a native denom directly and names the voucher it becomes',
        () async {
      final h = _harness();
      final blind =
          await recommendDenom(h.ctx, 'cosmoshub-4', 'osmosis-1', 'uatom');
      expect(blind.strategy, DenomStrategy.direct);
      expect(blind.firstHop, isNull);
      // Without the receiving channel the arriving denom cannot be named.
      expect(blind.outputDenom, isNull);
      expect(blind.warnings.any((w) => w.contains('receiving channel')), isTrue);

      final named = await recommendDenom(
        h.ctx,
        'cosmoshub-4',
        'osmosis-1',
        'uatom',
        destinationReceiveChannelId: 'channel-0',
      );
      expect(named.outputDenom, atomOnOsmosis);
      expect(named.originChainId, 'cosmoshub-4');
      expect(named.warnings, isEmpty);
    });

    test('unwinds a voucher when the destination is its origin', () async {
      final h =
          _harness(routes: _defaultRoutes(), counterparty: _counterparty);
      final plan = await recommendDenom(
          h.ctx, 'osmosis-1', 'cosmoshub-4', atomOnOsmosis);
      expect(plan.strategy, DenomStrategy.unwind);
      // The user gets uatom back, not a fresh hash.
      expect(plan.outputDenom, 'uatom');
      expect(plan.firstHop,
          const DenomHop(port: 'transfer', channelId: 'channel-0'));
      expect(plan.unwind.length, 1);
      expect(plan.originChainId, 'cosmoshub-4');
      expect(plan.originProvenance, OriginProvenance.channelWalk);
    });

    test('unwinds then forwards when the destination is neither end',
        () async {
      final h =
          _harness(routes: _defaultRoutes(), counterparty: _counterparty);
      final plan = await recommendDenom(
        h.ctx,
        'osmosis-1',
        'juno-1',
        atomOnOsmosis,
        destinationReceiveChannelId: 'channel-9',
      );
      expect(plan.strategy, DenomStrategy.unwindThenForward);
      expect(plan.originChainId, 'cosmoshub-4');
      expect(plan.outputDenom, ibcDenomHash('transfer/channel-9', 'uatom'));
      expect(
        plan.warnings.any((w) => w.contains('double-wrapped')),
        isTrue,
      );
    });

    test('refuses to guess when the origin cannot be determined', () async {
      // No counterparty lookup, and `uatom` is claimed by exactly one chain in
      // this registry, so the registry guess is what saves it; strip that by
      // using a base denom nothing claims.
      final unknownDenom = ibcDenomHash('transfer/channel-7', 'umystery');
      final h = _harness(routes: {
        _traceKey('osmosis-1', unknownDenom): () =>
            _wrapped('transfer/channel-7', 'umystery'),
      });
      final plan =
          await recommendDenom(h.ctx, 'osmosis-1', 'juno-1', unknownDenom);
      expect(plan.strategy, DenomStrategy.unknown);
      expect(plan.outputDenom, isNull);
      expect(plan.originProvenance, OriginProvenance.unknown);
      expect(
        plan.warnings.any((w) => w.contains('mint a denom nothing recognises')),
        isTrue,
      );
    });

    test('falls back to the registry and says the origin was inferred',
        () async {
      final h = _harness(routes: _defaultRoutes());
      final plan = await recommendDenom(
        h.ctx,
        'osmosis-1',
        'juno-1',
        atomOnOsmosis,
        destinationReceiveChannelId: 'channel-9',
      );
      expect(plan.originChainId, 'cosmoshub-4');
      expect(plan.originProvenance, OriginProvenance.registryGuess);
      expect(
        plan.warnings.any((w) => w.contains('inferred from the registry')),
        isTrue,
      );
    });
  });
}
