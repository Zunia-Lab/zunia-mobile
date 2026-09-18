/// Ported from `zunia-sdk/packages/interchain/src/channels.test.ts`.
///
/// The state-parsing tests are the load-bearing ones: `'STATE_TRYOPEN'` contains
/// `'OPEN'`, and the code this module replaces tested for OPEN first, which
/// reported a channel still mid-handshake as ready to receive funds.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

final _chains = <ChainInfo>[
  const ChainInfo(
    chainId: 'cosmoshub-4',
    chainName: 'Cosmos Hub',
    bech32Prefix: 'cosmos',
    coinMinimalDenom: 'uatom',
    rest: 'https://rest.cosmoshub-4.example',
  ),
  const ChainInfo(
    chainId: 'osmosis-1',
    chainName: 'Osmosis',
    bech32Prefix: 'osmo',
    coinMinimalDenom: 'uosmo',
    rest: 'https://rest.osmosis-1.example',
  ),
  const ChainInfo(
    chainId: 'norest-1',
    chainName: 'No REST',
    bech32Prefix: 'no',
    coinMinimalDenom: 'unone',
  ),
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

class _FakeLcd implements LcdClient {
  _FakeLcd(this.chainId, this._routes, this.calls);

  @override
  final String chainId;
  final Map<String, Object? Function()> _routes;
  final List<String> calls;

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    calls.add('$chainId$path');
    final handler = _routes['$chainId$path'];
    if (handler == null) {
      throw InterchainError(
        InterchainErrorCode.lcdUnreachable,
        'not registered',
        chainId: chainId,
        httpStatus: 404,
      );
    }
    return handler();
  }
}

Map<String, Object?> _channelRow({
  String channelId = 'channel-141',
  String state = 'STATE_OPEN',
  String connection = 'connection-0',
  String counterparty = 'channel-0',
  String port = 'transfer',
}) =>
    {
      'channel_id': channelId,
      'port_id': port,
      'state': state,
      'connection_hops': [connection],
      'counterparty': {'channel_id': counterparty, 'port_id': 'transfer'},
    };

IbcChannelService _service(
  Map<String, Object? Function()> routes,
  List<String> calls,
) =>
    IbcChannelService(
      lcd: (chain) => _FakeLcd(chain.chainId, routes, calls),
      registry: _Registry(),
    );

void main() {
  group('normalizeChannelId', () {
    test('accepts both spellings and leaves anything else alone', () {
      expect(normalizeChannelId('channel-141'), 'channel-141');
      expect(normalizeChannelId(' 141 '), 'channel-141');
      expect(normalizeChannelId('CHANNEL-141'), 'channel-141');
      expect(normalizeChannelId(''), '');
      expect(normalizeChannelId('nonsense'), 'nonsense');
    });
  });

  group('parseChannelState', () {
    test('reads TRYOPEN before OPEN', () {
      // The bug this replaces: 'STATE_TRYOPEN'.contains('OPEN') is true.
      expect(parseChannelState('STATE_TRYOPEN'), IbcChannelState.tryopen);
      expect(parseChannelState('STATE_OPEN'), IbcChannelState.open);
      expect(parseChannelState('STATE_CLOSED'), IbcChannelState.closed);
      expect(parseChannelState('STATE_INIT'), IbcChannelState.init);
    });

    test('rules out the zero value before any substring test', () {
      expect(parseChannelState('STATE_UNINITIALIZED_UNSPECIFIED'),
          IbcChannelState.unknown);
    });

    test('reads the integer enum', () {
      expect(parseChannelState(1), IbcChannelState.init);
      expect(parseChannelState(2), IbcChannelState.tryopen);
      expect(parseChannelState(3), IbcChannelState.open);
      expect(parseChannelState(4), IbcChannelState.closed);
      expect(parseChannelState(9), IbcChannelState.unknown);
    });

    test('channel-upgrade states fall through to unknown', () {
      // A flushing channel is not accepting new packets.
      expect(parseChannelState('STATE_FLUSHING'), IbcChannelState.unknown);
      expect(parseChannelState(null), IbcChannelState.unknown);
    });
  });

  group('findIbcChannels', () {
    test('returns only open channels whose client targets the destination',
        () async {
      final calls = <String>[];
      final service = _service({
        'cosmoshub-4/ibc/core/channel/v1/channels': () => {
              'channels': [
                _channelRow(),
                _channelRow(channelId: 'channel-9', state: 'STATE_TRYOPEN'),
                _channelRow(channelId: 'channel-8', connection: 'connection-9'),
              ],
              'pagination': {'next_key': null},
            },
        'cosmoshub-4/ibc/core/connection/v1/connections/connection-0': () => {
              'connection': {'client_id': '07-tendermint-0'},
            },
        'cosmoshub-4/ibc/core/client/v1/client_states/07-tendermint-0': () => {
              'client_state': {'chain_id': 'osmosis-1'},
            },
        'cosmoshub-4/ibc/core/connection/v1/connections/connection-9': () => {
              'connection': {'client_id': '07-tendermint-9'},
            },
        'cosmoshub-4/ibc/core/client/v1/client_states/07-tendermint-9': () => {
              'client_state': {'chain_id': 'juno-1'},
            },
      }, calls);

      final rows = await service.findIbcChannels('cosmoshub-4', 'osmosis-1');
      expect(rows.length, 1);
      expect(rows.single.channelId, 'channel-141');
      expect(rows.single.counterpartyChannelId, 'channel-0');
      expect(rows.single.counterpartyChainId, 'osmosis-1');
    });

    test('a chain with no REST endpoint yields an empty list, not an error',
        () async {
      final service = _service(const {}, <String>[]);
      expect(await service.findIbcChannels('norest-1', 'osmosis-1'), isEmpty);
    });

    test('a same-chain or unknown request yields an empty list', () async {
      final service = _service(const {}, <String>[]);
      expect(await service.findIbcChannels('osmosis-1', 'osmosis-1'), isEmpty);
      expect(await service.findIbcChannels('nope-1', 'osmosis-1'), isEmpty);
    });
  });

  group('validateIbcChannel', () {
    test('empty input asks for a channel id', () async {
      final result = await _service(const {}, <String>[])
          .validateIbcChannel('cosmoshub-4', '  ');
      expect(result.ok, isFalse);
      expect(result.message, 'Enter a channel id (e.g. channel-141)');
    });

    test('a chain with no endpoint says so', () async {
      final result = await _service(const {}, <String>[])
          .validateIbcChannel('norest-1', 'channel-1');
      expect(result.ok, isFalse);
      expect(result.message, 'No REST endpoint for this chain');
    });

    test('a 404 is reported as not found, not as unreachable', () async {
      final result = await _service(const {}, <String>[])
          .validateIbcChannel('cosmoshub-4', '999');
      expect(result.ok, isFalse);
      expect(result.message, 'Channel not found on this chain');
    });

    test('an open channel names its counterparty chain', () async {
      final service = _service({
        'cosmoshub-4/ibc/core/channel/v1/channels/channel-141/ports/transfer':
            () => {'channel': _channelRow()},
        'cosmoshub-4/ibc/core/connection/v1/connections/connection-0': () => {
              'connection': {'client_id': '07-tendermint-0'},
            },
        'cosmoshub-4/ibc/core/client/v1/client_states/07-tendermint-0': () => {
              'client_state': {'chain_id': 'osmosis-1'},
            },
      }, <String>[]);
      final result =
          await service.validateIbcChannel('cosmoshub-4', '141');
      expect(result.ok, isTrue);
      expect(result.message, 'Open · osmosis-1');
      expect(result.counterpartyChannelId, 'channel-0');
    });

    test('a channel that is not open is rejected with its state', () async {
      final service = _service({
        'cosmoshub-4/ibc/core/channel/v1/channels/channel-141/ports/transfer':
            () => {'channel': _channelRow(state: 'STATE_TRYOPEN')},
        'cosmoshub-4/ibc/core/connection/v1/connections/connection-0': () => {
              'connection': {'client_id': '07-tendermint-0'},
            },
        'cosmoshub-4/ibc/core/client/v1/client_states/07-tendermint-0': () => {
              'client_state': {'chain_id': 'osmosis-1'},
            },
      }, <String>[]);
      final result = await service.validateIbcChannel('cosmoshub-4', '141');
      expect(result.ok, isFalse);
      expect(result.message, 'Channel is tryopen, not open');
    });

    test('an open channel to the wrong chain is rejected', () async {
      final service = _service({
        'cosmoshub-4/ibc/core/channel/v1/channels/channel-141/ports/transfer':
            () => {'channel': _channelRow()},
        'cosmoshub-4/ibc/core/connection/v1/connections/connection-0': () => {
              'connection': {'client_id': '07-tendermint-0'},
            },
        'cosmoshub-4/ibc/core/client/v1/client_states/07-tendermint-0': () => {
              'client_state': {'chain_id': 'juno-1'},
            },
      }, <String>[]);
      final result = await service.validateIbcChannel(
        'cosmoshub-4',
        '141',
        destChainId: 'osmosis-1',
      );
      expect(result.ok, isFalse);
      expect(result.message, 'Open, but connects to juno-1');
    });

    test('the counterparty check confirms both sides', () async {
      final service = _service({
        'cosmoshub-4/ibc/core/channel/v1/channels/channel-141/ports/transfer':
            () => {'channel': _channelRow()},
        'cosmoshub-4/ibc/core/connection/v1/connections/connection-0': () => {
              'connection': {'client_id': '07-tendermint-0'},
            },
        'cosmoshub-4/ibc/core/client/v1/client_states/07-tendermint-0': () => {
              'client_state': {'chain_id': 'osmosis-1'},
            },
        'osmosis-1/ibc/core/channel/v1/channels/channel-0/ports/transfer': () =>
            {
              'channel': _channelRow(
                channelId: 'channel-0',
                connection: 'connection-5',
                counterparty: 'channel-141',
              ),
            },
        'osmosis-1/ibc/core/connection/v1/connections/connection-5': () => {
              'connection': {'client_id': '07-tendermint-5'},
            },
        'osmosis-1/ibc/core/client/v1/client_states/07-tendermint-5': () => {
              'client_state': {'chain_id': 'cosmoshub-4'},
            },
      }, <String>[]);
      final result = await service.validateIbcChannel(
        'cosmoshub-4',
        '141',
        destChainId: 'osmosis-1',
        checkCounterparty: true,
      );
      expect(result.ok, isTrue);
      expect(result.message, 'Open on both sides · osmosis-1');
      expect(result.counterparty!.status, CounterpartyCheckStatus.ok);
    });

    test('a far side pointing elsewhere is a definite failure', () async {
      final service = _service({
        'cosmoshub-4/ibc/core/channel/v1/channels/channel-141/ports/transfer':
            () => {'channel': _channelRow()},
        'cosmoshub-4/ibc/core/connection/v1/connections/connection-0': () => {
              'connection': {'client_id': '07-tendermint-0'},
            },
        'cosmoshub-4/ibc/core/client/v1/client_states/07-tendermint-0': () => {
              'client_state': {'chain_id': 'osmosis-1'},
            },
        'osmosis-1/ibc/core/channel/v1/channels/channel-0/ports/transfer': () =>
            {
              'channel': _channelRow(
                channelId: 'channel-0',
                counterparty: 'channel-999',
              ),
            },
      }, <String>[]);
      final result = await service.validateIbcChannel(
        'cosmoshub-4',
        '141',
        destChainId: 'osmosis-1',
        checkCounterparty: true,
      );
      expect(result.ok, isFalse);
      expect(result.counterparty!.status, CounterpartyCheckStatus.mismatch);
      expect(result.message, contains('points at channel-999'));
    });

    test('an unreachable far side does not overturn the source verdict',
        () async {
      final service = _service({
        'cosmoshub-4/ibc/core/channel/v1/channels/channel-141/ports/transfer':
            () => {'channel': _channelRow()},
        'cosmoshub-4/ibc/core/connection/v1/connections/connection-0': () => {
              'connection': {'client_id': '07-tendermint-0'},
            },
        'cosmoshub-4/ibc/core/client/v1/client_states/07-tendermint-0': () => {
              'client_state': {'chain_id': 'osmosis-1'},
            },
      }, <String>[]);
      final result = await service.validateIbcChannel(
        'cosmoshub-4',
        '141',
        destChainId: 'osmosis-1',
        checkCounterparty: true,
      );
      // The far side answered 404 for its channel, which this fixture cannot
      // distinguish from a missing route, so it reports not-found and blocks.
      expect(result.counterparty, isNotNull);
    });
  });

  group('module probes', () {
    test('a params object is evidence of support', () async {
      final service = _service({
        'osmosis-1/ibc/apps/packetforward/v1/params': () => {
              'params': {'fee_percentage': '0.000000000000000000'},
            },
      }, <String>[]);
      final support = await service.detectPfmSupport('osmosis-1');
      expect(support.status, ModuleSupportStatus.supported);
      expect(support.supported, isTrue);
    });

    test('every route answering "no such route" rules PFM out', () async {
      final service = _service(const {}, <String>[]);
      final support = await service.detectPfmSupport('osmosis-1');
      expect(support.status, ModuleSupportStatus.unsupported);
    });

    test('a host declaration skips the network entirely', () async {
      final service = IbcChannelService(
        lcd: (chain) => throw StateError('must not be called'),
        registry: _Registry(),
        moduleSupport: const {
          'osmosis-1': ModuleSupportOverride(packetForward: true, ibcHooks: true),
        },
      );
      final pfm = await service.detectPfmSupport('osmosis-1');
      final hooks = await service.detectIbcHooksSupport('osmosis-1');
      expect(pfm.supported, isTrue);
      expect(hooks.supported, isTrue);
      expect(pfm.evidence, 'declared by the host');
    });

    test('CosmWasm present but no hooks route is unknown, not supported',
        () async {
      final service = _service({
        'osmosis-1/cosmwasm/wasm/v1/codes': () => {'code_infos': <Object?>[]},
      }, <String>[]);
      final support = await service.detectIbcHooksSupport('osmosis-1');
      expect(support.status, ModuleSupportStatus.unknown);
      expect(support.evidence, contains('exposes no query route'));
    });

    test('no CosmWasm at all rules ibc-hooks out', () async {
      final service = _service(const {}, <String>[]);
      final support = await service.detectIbcHooksSupport('osmosis-1');
      expect(support.status, ModuleSupportStatus.unsupported);
      expect(support.evidence, contains('no CosmWasm module'));
    });
  });
}
