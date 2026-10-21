/// Custom chains: the validation a typed or site-suggested chain goes
/// through, and the two bugs this module had: saved chains were not in the
/// catalog after a restart, and an add racing the first restore was lost.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/chains/chain_draft.dart';
import 'package:zunia_mobile/state/custom_chains.dart';

CustomChainDraft draft({
  String chainId = 'safro-devnet-2',
  String rpc = 'https://rpc.devnet.example',
  String rest = 'https://api.devnet.example/',
  String prefix = 'addr_safro',
  int coinType = 118,
  String denom = 'usaf',
  int decimals = 6,
  double gasPrice = 0.025,
  String name = 'Safrochain Devnet',
}) =>
    CustomChainDraft(
      chainName: name,
      chainId: chainId,
      rpc: rpc,
      rest: rest,
      bech32Prefix: prefix,
      coinType: coinType,
      coinDenom: 'SAF',
      coinMinimalDenom: denom,
      coinDecimals: decimals,
      gasPrice: gasPrice,
    );

bool notRegistry(String _) => false;

String? problem(CustomChainDraft d, {bool Function(String)? registry}) {
  try {
    validateCustomChainDraft(d, isRegistryChainId: registry ?? notRegistry);
    return null;
  } on ChainDraftError catch (e) {
    return e.message;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await ChainCatalog.load();
  });

  setUp(() {
    ChainCatalog.instance.setCustom(const []);
  });

  group('validation', () {
    test('a good draft normalises its endpoints', () {
      final clean = validateCustomChainDraft(draft(), isRegistryChainId: notRegistry);
      expect(clean.rest, 'https://api.devnet.example');
      final entry = clean.toEntry();
      expect(entry.gasPriceStep, {'low': 0.025, 'average': 0.025, 'high': 0.05});
      expect(entry.feeMinimalDenom, 'usaf');
      expect(entry.isTestnet, isFalse);
    });

    test('names the first bad field', () {
      expect(problem(draft(chainId: '')), 'Chain ID is required');
      expect(problem(draft(chainId: 'bad id!')), contains('Chain ID may use'));
      expect(problem(draft(rpc: 'http://rpc.example')), 'RPC must be an https:// URL');
      expect(problem(draft(rest: 'https://user:pw@api.example')), contains('username'));
      expect(problem(draft(prefix: 'Cosmos')), contains('Prefix'));
      expect(problem(draft(denom: '1bad')), contains('denom'));
      expect(problem(draft(decimals: 19)), contains('Decimals'));
      expect(problem(draft(coinType: -1)), contains('Coin type'));
      expect(problem(draft(gasPrice: -1)), contains('Gas price'));
      expect(problem(draft(name: 'Evil\u202Ename')), contains('hidden'));
    });

    test('a registry chain id is refused, so no endpoint can shadow it', () {
      expect(
        problem(draft(chainId: 'cosmoshub-4'), registry: registryHasChainId),
        'That chain ID is already in the registry',
      );
    });

    test('a site\'s ChainInfo is read and still validated', () {
      final suggested = draftFromSuggestedChain({
        'chainId': 'mychain-1',
        'chainName': 'My Chain',
        'rpc': 'https://rpc.mychain.example',
        'rest': 'https://lcd.mychain.example',
        'bip44': {'coinType': 118},
        'bech32Config': {'bech32PrefixAccAddr': 'my'},
        'currencies': [
          {'coinDenom': 'MY', 'coinMinimalDenom': 'umy', 'coinDecimals': 6},
        ],
        'feeCurrencies': [
          {
            'coinDenom': 'MY',
            'coinMinimalDenom': 'umy',
            'coinDecimals': 6,
            'gasPriceStep': {'low': 0.01, 'average': 0.02, 'high': 0.03},
          },
        ],
        'features': ['testnet'],
      });
      final clean =
          validateCustomChainDraft(suggested, isRegistryChainId: notRegistry);
      expect(clean.bech32Prefix, 'my');
      expect(clean.gasPrice, 0.02);
      expect(clean.testnet, isTrue);
      // A suggestion without a coin type is refused, never defaulted to 118.
      expect(
        problem(draftFromSuggestedChain({'chainId': 'x-1', 'bech32Config': {}})),
        isNotNull,
      );
    });
  });

  group('storage', () {
    test('saved chains are in the catalog after a restart', () async {
      SharedPreferences.setMockInitialValues({
        'zunia.chains.custom': jsonEncode([
          draft().toEntry().toJson(),
          // A row an older build let through for a registry id: dropped.
          {...draft(chainId: 'cosmoshub-4').toEntry().toJson()},
        ]),
      });
      final rows = await hydrateCustomChains();
      expect(rows.map((c) => c.chainId), ['safro-devnet-2']);
      expect(ChainCatalog.instance.find('safro-devnet-2')?.chainName, 'Safrochain Devnet');
      expect(ChainCatalog.instance.find('cosmoshub-4')?.inCosmosRegistry, isTrue);
    });

    test('an add that lands before the restore keeps both chains', () async {
      SharedPreferences.setMockInitialValues({
        'zunia.chains.custom': jsonEncode([draft().toEntry().toJson()]),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Read the notifier and add in the same tick: the restore has not
      // finished. Before the fix the restore then replaced the list.
      final notifier = container.read(customChainsProvider.notifier);
      final added = await notifier.addDraft(draft(chainId: 'other-1'));
      expect(added.chainId, 'other-1');
      await notifier.ready;
      expect(
        container.read(customChainsProvider).map((c) => c.chainId),
        ['safro-devnet-2', 'other-1'],
      );
      final stored = jsonDecode(
        (await SharedPreferences.getInstance()).getString('zunia.chains.custom')!,
      ) as List;
      expect(stored.length, 2);
      expect(ChainCatalog.instance.find('other-1'), isNotNull);
    });

    test('concurrent adds and a remove are applied in order', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(customChainsProvider.notifier);
      await Future.wait([
        notifier.addDraft(draft(chainId: 'a-1')),
        notifier.addDraft(draft(chainId: 'b-1')),
        notifier.addSuggested({
          'chainId': 'c-1',
          'chainName': 'C',
          'rpc': 'https://rpc.c.example',
          'rest': 'https://lcd.c.example',
          'bip44': {'coinType': 118},
          'bech32Config': {'bech32PrefixAccAddr': 'cc'},
          'currencies': [
            {'coinDenom': 'C', 'coinMinimalDenom': 'uc', 'coinDecimals': 6},
          ],
        }),
      ]);
      await notifier.remove('b-1');
      expect(
        container.read(customChainsProvider).map((c) => c.chainId),
        ['a-1', 'c-1'],
      );
      expect(ChainCatalog.instance.customOnly.map((c) => c.chainId), ['a-1', 'c-1']);
    });

    test('a bad suggestion throws a sentence and stores nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(customChainsProvider.notifier);
      await expectLater(
        notifier.addSuggested({'chainId': 'cosmoshub-4'}),
        throwsA(isA<ChainDraftError>()),
      );
      expect(container.read(customChainsProvider), isEmpty);
    });
  });
}
