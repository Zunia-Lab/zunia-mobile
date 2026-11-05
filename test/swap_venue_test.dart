/// The crosschain-swaps contract is checked before it is trusted.
///
/// This address is the one field in the whole flow where a wrong value loses
/// funds silently: a memo naming a contract that does not exist, or that
/// exists and is not the swap router, sends the packet somewhere nothing will
/// send it back from. The release names candidates
/// (`assets/data/interchain.json` `xcsContractCandidates`); each is confirmed
/// against the chain before the contract path is enabled, and the first one
/// the chain knows is used.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/config/interchain_config.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/swap/swap_config.dart';
import 'package:zunia_mobile/swap/swap_data.dart';

import 'support/swap_fixtures.dart';

class _Registry implements ChainRegistry {
  const _Registry({this.rest = 'https://lcd.osmosis.test'});

  final String? rest;

  @override
  ChainInfo? get(String chainId) => chainId == 'osmosis-1'
      ? ChainInfo(
          chainId: chainId,
          chainName: 'Osmosis',
          bech32Prefix: 'osmo',
          coinMinimalDenom: 'uosmo',
          rest: rest,
        )
      : null;

  @override
  List<ChainInfo> list() => [?get('osmosis-1')];
}

void main() {
  late SwapData shipped;
  final second = bech('osmo', 4, 32);

  setUpAll(() async => shipped = await loadTestSwapData());

  SwapData withCandidates(List<String> candidates) {
    final c = shipped.config;
    return SwapData(
      config: SwapConfig(
        venueChainId: c.venueChainId,
        xcsContractCandidates: candidates,
        routerEndpoints: c.routerEndpoints,
        defaultSlippagePercent: c.defaultSlippagePercent,
        slippagePresets: c.slippagePresets,
        highSlippagePercent: c.highSlippagePercent,
        maxSlippagePercent: c.maxSlippagePercent,
        packetTimeoutMinutes: c.packetTimeoutMinutes,
        maxRouteHops: c.maxRouteHops,
        quoteTtl: c.quoteTtl,
        explorerTxUrls: c.explorerTxUrls,
      ),
      fees: shipped.fees,
      book: shipped.book,
      catalog: shipped.catalog,
    );
  }

  ({ProviderContainer container, ScriptedLcd lcd}) harness({
    required LcdAnswer answer,
    String? rest = 'https://lcd.osmosis.test',
    SwapData? data,
  }) {
    final lcd = ScriptedLcd('osmosis-1', answer);
    final container = ProviderContainer(
      overrides: [
        swapDataProvider.overrideWith((_) async => data ?? shipped),
        interchainRegistryProvider.overrideWithValue(_Registry(rest: rest)),
        lcdFactoryProvider.overrideWithValue((_) => lcd),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, lcd: lcd);
  }

  test(
    'the release names the contract Osmosis governance lists, and nothing is compiled in',
    () {
      expect(shipped.config.xcsContractCandidates, [
        'osmo1uwk8xc6q0s6t5qcpr6rht3sczu6du83xq8pwxjua0hfj5hzcnh3sqxwvxs',
      ]);
      // A build may add its own candidate, checked like any other.
      expect(kOsmosisXcsContract.trim(), kOsmosisXcsContract);
    },
  );

  test(
    'contract info from the chain turns the contract path on, with its label',
    () async {
      final h = harness(
        answer: (path, _) {
          expect(
            path,
            '/cosmwasm/wasm/v1/contract/${shipped.config.xcsContractCandidates.first}',
          );
          return {
            'contract_info': {'code_id': '37', 'label': 'CrossChainSwaps v1.2'},
          };
        },
      );
      final status = await h.container.read(swapVenueStatusProvider.future);
      expect(status.ready, isTrue);
      expect(
        status.contractAddress,
        shipped.config.xcsContractCandidates.first,
      );
      expect(status.label, 'CrossChainSwaps v1.2');
      expect(status.venue?.chainId, 'osmosis-1');
    },
  );

  test(
    'an address the chain does not know is skipped, and the next candidate is checked',
    () async {
      final first = shipped.config.xcsContractCandidates.first;
      final h = harness(
        data: withCandidates([first, second]),
        answer: (path, _) {
          if (path.endsWith(first)) throw notFound('osmosis-1', path);
          return {
            'contract_info': {'code_id': '37'},
          };
        },
      );
      final status = await h.container.read(swapVenueStatusProvider.future);
      expect(status.ready, isTrue);
      expect(status.contractAddress, second);
    },
  );

  test(
    'no candidate on chain keeps the contract path off, and says so',
    () async {
      final h = harness(answer: (path, _) => throw notFound('osmosis-1', path));
      final status = await h.container.read(swapVenueStatusProvider.future);
      expect(status.ready, isFalse);
      expect(status.venue, isNull);
      expect(
        status.reason,
        contains(
          'No crosschain-swaps contract this release names exists on Osmosis',
        ),
      );
    },
  );

  test(
    'a 200 without contract info is not proof, so the contract path stays off',
    () async {
      final h = harness(answer: (path, _) => {'unexpected': true});
      final status = await h.container.read(swapVenueStatusProvider.future);
      expect(status.ready, isFalse);
    },
  );

  test('an endpoint that cannot answer fails closed', () async {
    final h = harness(
      answer: (path, _) =>
          throw InterchainError(InterchainErrorCode.lcdUnreachable, 'timeout'),
    );
    final status = await h.container.read(swapVenueStatusProvider.future);
    expect(status.ready, isFalse);
    expect(status.reason, contains('Could not reach Osmosis'));
  });

  test(
    'live reads off: nothing is checked, and the reason says how to turn them on',
    () async {
      final h = harness(
        answer: (path, _) =>
            throw InterchainError(InterchainErrorCode.readsDisabled, 'off'),
      );
      final status = await h.container.read(swapVenueStatusProvider.future);
      expect(status.ready, isFalse);
      expect(status.reason, contains('Live reads are off'));
    },
  );

  test('a chain with no REST endpoint cannot be checked', () async {
    final h = harness(
      rest: null,
      answer: (path, _) => fail('nothing should be read'),
    );
    final status = await h.container.read(swapVenueStatusProvider.future);
    expect(status.ready, isFalse);
    expect(status.reason, contains('no REST endpoint'));
    expect(h.lcd.calls, isEmpty);
  });

  test(
    'a release with no candidates keeps cross-chain swaps off, pools untouched',
    () async {
      final h = harness(
        data: withCandidates(const []),
        answer: (path, _) => fail('nothing should be read'),
      );
      final status = await h.container.read(swapVenueStatusProvider.future);
      if (kOsmosisXcsContract.isNotEmpty) return;
      expect(status.ready, isFalse);
      expect(
        status.reason,
        contains('Swaps of tokens already on Osmosis still work'),
      );
    },
  );
}
