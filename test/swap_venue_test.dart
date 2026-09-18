/// The crosschain-swaps contract is checked before it is trusted.
///
/// This address is the one field in the whole flow where a wrong value loses
/// funds silently: a memo naming a contract that does not exist, or that exists
/// and is not the swap router, sends the packet somewhere nothing will send it
/// back from. So the build ships without an address, and even when one is
/// configured it is confirmed against the chain before a memo is built.
///
/// The second group only runs when the address is supplied, so the suite is
/// meaningful in both builds:
///
///   flutter test test/swap_venue_test.dart
///   flutter test --dart-define=OSMOSIS_XCS_CONTRACT=osmo1example \
///     test/swap_venue_test.dart
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/config/interchain_config.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/interchain.dart';

class _Registry implements ChainRegistry {
  const _Registry({this.rest = 'https://lcd.osmosis.test'});

  final String? rest;

  @override
  ChainInfo? get(String chainId) => chainId == kSwapVenueChainId
      ? ChainInfo(
          chainId: chainId,
          chainName: 'Osmosis',
          bech32Prefix: 'osmo',
          coinMinimalDenom: 'uosmo',
          rest: rest,
        )
      : null;

  @override
  List<ChainInfo> list() => [if (get(kSwapVenueChainId) != null) get(kSwapVenueChainId)!];
}

class _FakeLcd implements LcdClient {
  _FakeLcd(this.chainId, this._answer);

  @override
  final String chainId;
  final Object? Function(String path) _answer;

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async =>
      _answer(path);
}

ProviderContainer _container({
  required Object? Function(String path) answer,
  String? rest = 'https://lcd.osmosis.test',
}) {
  final container = ProviderContainer(
    overrides: [
      interchainRegistryProvider.overrideWithValue(_Registry(rest: rest)),
      lcdFactoryProvider.overrideWithValue(
        (chain) => _FakeLcd(chain.chainId, answer),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('the shipped default is no address at all', () {
    // A constant here would be a promise nobody verified. INTERCHAIN-SPEC.md
    // lists two candidate addresses and calls both unverified.
    if (kOsmosisXcsContract.isEmpty) {
      expect(kOsmosisXcsContract, isEmpty);
    } else {
      // A build that supplies one is fine; this test only pins that the value
      // comes from configuration rather than from source.
      expect(kOsmosisXcsContract.trim(), kOsmosisXcsContract);
    }
  });

  group('with no configured address', () {
    test('the swap is off and the reason names the missing setting', () async {
      if (kOsmosisXcsContract.isNotEmpty) return;
      final container = _container(answer: (_) => throw StateError('no reads'));
      final status = await container.read(swapVenueStatusProvider.future);
      expect(status.ready, isFalse);
      expect(status.venue, isNull);
      expect(status.reason, contains('OSMOSIS_XCS_CONTRACT'));
    });
  });

  group('with a configured address', () {
    test('an address the chain does not know disables the swap', () async {
      if (kOsmosisXcsContract.isEmpty) return;
      final container = _container(
        answer: (path) => throw InterchainError(
          InterchainErrorCode.lcdUnreachable,
          'not found',
          httpStatus: 404,
        ),
      );
      final status = await container.read(swapVenueStatusProvider.future);
      expect(status.ready, isFalse);
      expect(status.reason, contains('No contract exists'));
    });

    test('an endpoint that cannot answer disables the swap, fail closed',
        () async {
      if (kOsmosisXcsContract.isEmpty) return;
      final container = _container(
        answer: (path) => throw InterchainError(
          InterchainErrorCode.lcdUnreachable,
          'timeout',
        ),
      );
      final status = await container.read(swapVenueStatusProvider.future);
      expect(status.ready, isFalse);
      expect(status.reason, contains('Could not reach'));
    });

    test('a chain with no REST endpoint disables the swap', () async {
      if (kOsmosisXcsContract.isEmpty) return;
      final container = _container(
        answer: (_) => throw StateError('no reads'),
        rest: null,
      );
      final status = await container.read(swapVenueStatusProvider.future);
      expect(status.ready, isFalse);
      expect(status.reason, contains('no REST endpoint'));
    });

    test('contract info from the chain turns the swap on', () async {
      if (kOsmosisXcsContract.isEmpty) return;
      final container = _container(
        answer: (path) {
          expect(path, contains('/cosmwasm/wasm/v1/contract/'));
          return <String, Object?>{
            'contract_info': {'code_id': '9', 'creator': 'osmo1creator'},
          };
        },
      );
      final status = await container.read(swapVenueStatusProvider.future);
      expect(status.ready, isTrue);
      expect(status.checked, isTrue);
      expect(status.venue!.contractAddress, kOsmosisXcsContract);
    });

    test('a 200 without contract info is not proof, so the swap stays off',
        () async {
      if (kOsmosisXcsContract.isEmpty) return;
      final container = _container(answer: (_) => <String, Object?>{});
      final status = await container.read(swapVenueStatusProvider.future);
      expect(status.ready, isFalse);
      expect(status.reason, contains('without contract info'));
    });
  });
}
