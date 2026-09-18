/// The whole swap pipeline, offline: discovery, denom arithmetic, memo, quote.
///
/// This is the test that would have caught a client stitching the engine
/// together wrongly — the memo is asserted byte for byte against the shape
/// INTERCHAIN-SPEC.md documents, and the ICS20 receiver against the ibc-hooks
/// rule that the packet must be addressed to the contract.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/interchain/denom.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

/// A 12-word test mnemonic. Not a wallet anyone funds.
const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';

const _xcs = 'osmo1xcscontract';

/// Source chain -> Osmosis over channel-3 / channel-99, Osmosis -> dest over
/// channel-42 / channel-7. Only these four ids exist in this world.
class _FakeLcd implements LcdClient {
  _FakeLcd(this.chainId, this.calls);

  @override
  final String chainId;
  final List<String> calls;

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    calls.add('$chainId$path');

    if (path == '/ibc/core/channel/v1/channels') {
      return {
        'channels': [
          if (chainId == 'source-1')
            _channel('channel-3', 'connection-0', 'channel-99'),
          if (chainId == 'osmosis-1') ...[
            _channel('channel-99', 'connection-5', 'channel-3'),
            _channel('channel-42', 'connection-6', 'channel-7'),
          ],
        ],
        'pagination': {'next_key': null},
      };
    }
    if (path.startsWith('/ibc/core/connection/v1/connections/')) {
      return {
        'connection': {'client_id': '07-${path.split('/').last}'},
      };
    }
    if (path.startsWith('/ibc/core/client/v1/client_states/')) {
      const targets = {
        '07-connection-0': 'osmosis-1',
        '07-connection-5': 'source-1',
        '07-connection-6': 'dest-1',
      };
      return {
        'client_state': {'chain_id': targets[path.split('/').last]},
      };
    }
    if (path.startsWith('/cosmwasm/wasm/v1/contract/')) {
      return {
        'contract_info': {'code_id': '1'},
      };
    }
    // Every module probe answers "no such route", which the engine reads as
    // unconfirmed rather than as unsupported.
    throw InterchainError(
      InterchainErrorCode.lcdUnreachable,
      'no route',
      chainId: chainId,
      httpStatus: 404,
    );
  }

  static Map<String, Object?> _channel(
    String id,
    String connection,
    String counterparty,
  ) =>
      {
        'channel_id': id,
        'port_id': 'transfer',
        'state': 'STATE_OPEN',
        'connection_hops': [connection],
        'counterparty': {'channel_id': counterparty, 'port_id': 'transfer'},
      };
}

/// The SQS router, answering the one quote this test asks for.
class _FakeRouter implements LcdClient {
  _FakeRouter(this.seen);

  final Map<String, Object?> seen;

  @override
  String get chainId => 'osmosis-1';

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    seen.addAll(options?.query ?? const {});
    return {
      'amount_in': {'denom': 'ibc/IN', 'amount': '1000000'},
      'amount_out': '2200000',
      'route': [
        {
          'pools': [
            {'id': 1400, 'type': 2, 'token_out_denom': 'ibc/OUT'},
          ],
          'in_amount': '1000000',
          'out_amount': '2200000',
        },
      ],
      'effective_fee': '0.002',
      'price_impact': '-0.0004',
      'in_base_out_quote_spot_price': '2.2',
    };
  }
}

/// An endpoint that answers nothing at all.
class _DeadLcd implements LcdClient {
  _DeadLcd(this.chainId);

  @override
  final String chainId;

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    throw InterchainError(
      InterchainErrorCode.lcdUnreachable,
      'endpoint down',
      chainId: chainId,
    );
  }
}

class _Registry implements ChainRegistry {
  const _Registry();

  static const _chains = {
    'source-1': ChainInfo(
      chainId: 'source-1',
      chainName: 'Source',
      bech32Prefix: 'src',
      coinMinimalDenom: 'usrc',
      rest: 'http://127.0.0.1:1',
    ),
    'osmosis-1': ChainInfo(
      chainId: 'osmosis-1',
      chainName: 'Osmosis',
      bech32Prefix: 'osmo',
      coinMinimalDenom: 'uosmo',
      rest: 'http://127.0.0.1:1',
      features: ['cosmwasm'],
    ),
    'dest-1': ChainInfo(
      chainId: 'dest-1',
      chainName: 'Dest',
      bech32Prefix: 'dst',
      coinMinimalDenom: 'udst',
      rest: 'http://127.0.0.1:1',
    ),
  };

  @override
  ChainInfo? get(String chainId) => _chains[chainId];

  @override
  List<ChainInfo> list() => _chains.values.toList();
}

ChainEntry _entry(String id, String denom, String prefix) => ChainEntry(
      chainId: id,
      chainName: id,
      bech32Prefix: prefix,
      coinType: 118,
      network: 'mainnet',
      coinDenom: denom,
      coinMinimalDenom: 'u${denom.toLowerCase()}',
      coinDecimals: 6,
      feeDenom: denom,
      feeMinimalDenom: 'u${denom.toLowerCase()}',
      feeDecimals: 6,
      rest: 'http://127.0.0.1:1',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final from = ChainAccount(
    chain: _entry('source-1', 'SRC', 'src'),
    address: 'src1sender',
  );
  final to = ChainAccount(
    chain: _entry('dest-1', 'DST', 'dst'),
    address: 'dst1recipient',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // The controller derives the recovery address on the venue chain through
    // the catalog, so the real one is loaded here.
    await ChainCatalog.load();
  });

  ({ProviderContainer container, List<String> calls, Map<String, Object?> query})
      harness() {
    final calls = <String>[];
    final query = <String, Object?>{};
    final container = ProviderContainer(
      overrides: [
        interchainRegistryProvider.overrideWithValue(const _Registry()),
        lcdFactoryProvider.overrideWithValue(
          (chain) => _FakeLcd(chain.chainId, calls),
        ),
        swapRouterClientProvider.overrideWithValue(_FakeRouter(query)),
        swapVenueStatusProvider.overrideWith(
          (_) async => const SwapVenueStatus.ready(
            chainId: 'osmosis-1',
            contractAddress: _xcs,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, calls: calls, query: query);
  }

  test('plans, prices and composes one signable transfer', () async {
    final h = harness();
    final controller = h.container.read(swapControllerProvider.notifier);

    await controller.plan(
      from: from,
      to: to,
      amountBaseUnits: '1000000',
      phrase: _phrase,
    );
    final state = h.container.read(swapControllerProvider);

    expect(state.planError, isNull, reason: state.planError ?? '');
    expect(state.quoteError, isNull, reason: state.quoteError ?? '');
    expect(state.blockedReason, isNull, reason: state.blockedReason ?? '');
    expect(state.ready, isTrue);

    final candidate = state.candidate!;
    // One signature, on the source chain, over one hop.
    expect(candidate.plan.hops.first.chainId, 'source-1');
    expect(candidate.plan.hops.first.channelId, 'channel-3');
    // ibc-hooks only runs when the ICS20 receiver is "" or the contract.
    expect(candidate.receiver, _xcs);
    expect(candidate.plan.requiresIbcHooks, isTrue);
    expect(candidate.plan.requiresPfm, isFalse);

    final memo = jsonDecode(candidate.plan.memo) as Map<String, Object?>;
    final wasm = memo['wasm']! as Map<String, Object?>;
    expect(memo.keys.toList(), ['wasm']);
    expect(wasm.keys.toList()..sort(), ['contract', 'msg']);
    expect(wasm['contract'], _xcs);

    final swap = (wasm['msg']! as Map<String, Object?>)['osmosis_swap']!
        as Map<String, Object?>;
    // The output denom is the destination token as *Osmosis* names it: the
    // hash of Osmosis's own receiving channel, not the name dest-1 uses.
    expect(swap['output_denom'], ibcDenomHash('transfer/channel-42', 'udst'));
    expect(swap['receiver'], 'dst1recipient');
    // Recovery is set, so stranded output can be claimed.
    final recovery = swap['on_failed_delivery']! as Map<String, Object?>;
    expect(recovery['local_recovery_addr'], startsWith('osmo1'));
    expect(swap['next_memo'], isNull);
    // The window is omitted, so the contract's own default applies.
    expect(swap['slippage'], {
      'twap': {'slippage_percentage': '1'},
    });

    // The venue was asked to price the denom as it holds it.
    expect(h.query['tokenIn'],
        '1000000${ibcDenomHash('transfer/channel-99', 'usrc')}');
    expect(h.query['tokenOutDenom'], ibcDenomHash('transfer/channel-42', 'udst'));

    // The quote is the venue's, and the floor is derived from it.
    expect(state.quote!.outputAmount, '2200000');
    expect(state.quote!.minReceived, '2178000');
    expect(state.quote!.poolFee, closeTo(0.2, 0.0001));
    expect(state.quote!.priceImpact, closeTo(0.04, 0.0001));

    // The memo the user approves is read back from the memo itself.
    expect(state.memoInspection!.summary, contains('swaps to'));
    expect(state.memoInspection!.summary, contains('Recovery address'));
  });

  test('a locked wallet is planned and priced but never offered for signing',
      () async {
    final h = harness();
    await h.container.read(swapControllerProvider.notifier).plan(
          from: from,
          to: to,
          amountBaseUnits: '1000000',
        );
    final state = h.container.read(swapControllerProvider);

    // The route and the price are still shown — the user learns something.
    expect(state.candidate, isNotNull);
    // But an unrecoverable swap is not signable.
    expect(state.ready, isFalse);
    expect(state.blockedReason, contains('recover the swap output'));
  });

  test('the same chain twice is refused with a reason', () async {
    final h = harness();
    await h.container.read(swapControllerProvider.notifier).plan(
          from: from,
          to: from,
          amountBaseUnits: '1000000',
          phrase: _phrase,
        );
    final state = h.container.read(swapControllerProvider);
    expect(state.candidate, isNull);
    expect(state.blockedReason, contains('two different networks'));
  });

  test('no amount means no quote, and the reason says so', () async {
    final h = harness();
    await h.container.read(swapControllerProvider.notifier).plan(
          from: from,
          to: to,
          amountBaseUnits: '',
          phrase: _phrase,
        );
    final state = h.container.read(swapControllerProvider);
    expect(state.quote, isNull);
    expect(state.blockedReason, 'Enter an amount to swap.');
  });

  test('an unconfigured contract stops the flow before any chain read',
      () async {
    final calls = <String>[];
    final container = ProviderContainer(
      overrides: [
        interchainRegistryProvider.overrideWithValue(const _Registry()),
        lcdFactoryProvider.overrideWithValue(
          (chain) => _FakeLcd(chain.chainId, calls),
        ),
        swapVenueStatusProvider.overrideWith(
          (_) async => const SwapVenueStatus.unavailable('no address in build'),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(swapControllerProvider.notifier).plan(
          from: from,
          to: to,
          amountBaseUnits: '1000000',
          phrase: _phrase,
        );
    final state = container.read(swapControllerProvider);
    expect(state.blockedReason, 'no address in build');
    expect(state.candidate, isNull);
    // Nothing was discovered, quoted or read: the feature is off, not degraded.
    expect(calls, isEmpty);
  });

  test('typed channels alone build a route when discovery finds nothing',
      () async {
    // Every read fails: a chain whose endpoint cannot list its channels, which
    // is the case this whole override mechanism exists for.
    final container = ProviderContainer(
      overrides: [
        interchainRegistryProvider.overrideWithValue(const _Registry()),
        lcdFactoryProvider.overrideWithValue((chain) => _DeadLcd(chain.chainId)),
        swapRouterClientProvider.overrideWithValue(_FakeRouter({})),
        swapVenueStatusProvider.overrideWith(
          (_) async => const SwapVenueStatus.ready(
            chainId: 'osmosis-1',
            contractAddress: _xcs,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(swapControllerProvider.notifier);
    controller
      ..setOverride(0, 'channel-3',
          fromChainId: 'source-1', toChainId: 'osmosis-1')
      ..setOverride(1, 'channel-42',
          fromChainId: 'osmosis-1', toChainId: 'dest-1');
    await controller.plan(
      from: from,
      to: to,
      amountBaseUnits: '1000000',
      phrase: _phrase,
    );
    final state = container.read(swapControllerProvider);

    expect(state.candidate, isNotNull, reason: state.blockedReason ?? '');
    expect(state.candidate!.plan.hops.first.channelId, 'channel-3');
    expect(state.candidate!.receiver, _xcs);
    // The user is told these channels are their own word, not the chain's.
    expect(
      state.warnings.any((w) => w.contains('entered by hand')),
      isTrue,
    );
  });

  test('a manual channel overrides what discovery found', () async {
    final h = harness();
    final controller = h.container.read(swapControllerProvider.notifier);
    controller.setOverride(0, '777');
    await controller.plan(
      from: from,
      to: to,
      amountBaseUnits: '1000000',
      phrase: _phrase,
    );
    final state = h.container.read(swapControllerProvider);
    expect(state.candidate!.plan.hops.first.channelId, 'channel-777');
    expect(
      state.warnings.any((w) => w.contains('entered by hand')),
      isTrue,
    );
  });
}
