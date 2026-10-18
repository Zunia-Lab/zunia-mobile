import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/portfolio/portfolio.dart';
import 'package:zunia_mobile/prices/price_service.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';

import '../support/catalog.dart';

/// Home's rows and headline (extension lib/portfolio.ts and home-assets.ts,
/// 0.1.5): which price applies to which token, the order rows come in, and a
/// total that leaves out what was not read instead of counting it as zero.
const osmoUsdcN = 'ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4';
const osmoAtom = 'ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2';
const unlisted = 'ibc/0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF';
const factoryUsdcN = 'factory/osmo1qyqszqgpqyqszqgpqyqszqgpqyqszqgpjnp7du/USDC.n';

ChainEntry chain(String chainId) => ChainCatalog.instance.find(chainId)!;

ChainBalance balance(
  String chainId, {
  String available = '0',
  String staked = '0',
  String rewards = '0',
  List<HeldToken> tokens = const [],
  bool stakingKnown = true,
  bool rewardsKnown = true,
}) =>
    ChainBalance(
      chainId: chainId,
      available: available,
      staked: staked,
      rewards: rewards,
      tokens: tokens,
      stakingKnown: stakingKnown,
      rewardsKnown: rewardsKnown,
    );

const prices = <String, SpotPrice>{
  'osmosis-1': SpotPrice(price: 0.5, change24h: 10),
  'cosmoshub-4': SpotPrice(price: 4, change24h: -5),
  'noble-1': SpotPrice(price: 1, change24h: 0),
};

void main() {
  setUpAll(loadBundledData);

  group('priceChainOf', () {
    test("prices a chain's own coin at its chain's price", () {
      expect(priceChainOf(identityOf('osmosis-1', 'uosmo')), 'osmosis-1');
      expect(priceChainOf(identityOf('cosmoshub-4', 'uatom')), 'cosmoshub-4');
    });

    test("prices a proven voucher at its origin chain's price", () {
      expect(priceChainOf(identityOf('osmosis-1', osmoAtom)), 'cosmoshub-4');
    });

    test('never prices what nothing proves, or what has no known decimals', () {
      expect(priceChainOf(identityOf('osmosis-1', unlisted)), isNull);
      expect(priceChainOf(identityOf('osmosis-1', factoryUsdcN)), isNull);
      expect(priceChainOf(identityOf('osmosis-1', osmoAtom).copyWith(proven: false)), isNull);
      expect(priceChainOf(identityOf('osmosis-1', osmoAtom).copyWith(decimalsKnown: false)), isNull);
    });

    test('prices SAF on its own chain, where its exchange market quotes it', () {
      final saf = identityOf('safrochain-1', 'usaf');
      expect(priceChainOf(saf), 'safrochain-1');
      expect(priceChainOf(saf, exchangePriced: const {'safrochain-1'}), 'safrochain-1');
    });
  });

  group('homeAssets', () {
    test("lists every enabled chain's coin and each non-zero holding, best value first", () {
      final assets = homeAssets(
        [chain('osmosis-1'), chain('cosmoshub-4'), chain('noble-1')],
        {
          'osmosis-1': balance('osmosis-1', available: '2000000', tokens: const [
            HeldToken(denom: 'uosmo', amount: '2000000'),
            HeldToken(denom: osmoAtom, amount: '3000000'),
            HeldToken(denom: unlisted, amount: '7'),
            HeldToken(denom: factoryUsdcN, amount: '0'),
          ]),
          'cosmoshub-4': balance('cosmoshub-4'),
        },
        prices,
      );
      expect([for (final asset in assets) asset.key], [
        'osmosis-1:$osmoAtom', // 3 ATOM × 4 = 12
        'osmosis-1:uosmo', // 2 OSMO × 0.5 = 1
        'osmosis-1:$unlisted', // held, unpriced
        'cosmoshub-4:uatom', // zero
        'noble-1:${chain('noble-1').coinMinimalDenom}', // not read
      ]);
      expect(assets.first.fiatValue, 12);
      expect(assets.first.change24h, -5);
      expect(assets.first.group, AssetGroupKind.ibc);
      expect(assets[2].fiatValue, isNull);
      expect(assets[3].held, isFalse);
      expect(assets[3].amountKnown, isTrue);
      expect(assets.last.amountKnown, isFalse);
      expect(assets.last.fiatValue, isNull);
    });

    test('groups by network in the enabled-chain order, dropping empty groups', () {
      final assets = homeAssets(
        [chain('osmosis-1'), chain('cosmoshub-4')],
        {
          'osmosis-1': balance('osmosis-1', available: '1000000'),
          'cosmoshub-4': balance('cosmoshub-4', available: '1000000'),
        },
        prices,
      );
      final groups = groupHomeAssets(assets, ['osmosis-1', 'cosmoshub-4']);
      expect([for (final group in groups) group.chain.chainId], ['osmosis-1', 'cosmoshub-4']);
      expect(groups.first.fiatValue, 0.5);
      expect(groups.last.fiatValue, 4);
    });
  });

  group('computePortfolio', () {
    test('adds what is held, staked and earned at the chain price, with a weighted 24h change', () {
      final chains = [chain('osmosis-1'), chain('cosmoshub-4')];
      final balances = {
        'osmosis-1': balance('osmosis-1', available: '2000000', staked: '4000000', rewards: '2000000'),
        'cosmoshub-4': balance('cosmoshub-4', available: '1000000', tokens: const [
          HeldToken(denom: 'uatom', amount: '1000000'),
        ]),
      };
      final assets = homeAssets(chains, balances, prices);
      final totals = computePortfolio(chains, balances, prices, assets);
      // OSMO: (2 + 4 + 2) × 0.5 = 4. ATOM: 1 × 4 = 4.
      expect(totals.total, 8);
      expect(totals.staked, 2);
      expect(totals.claimable, 1);
      expect(totals.change24h, closeTo((4 * 10 + 4 * -5) / 8, 1e-9));
      expect(totals.pricedChains, 2);
      expect(totals.pricedAssets, 2);
      expect(totals.unpricedAssets, 0);
      expect(totals.hasTotal, isTrue);
    });

    test('leaves out staked and reward amounts the chain could not read', () {
      final chains = [chain('osmosis-1')];
      final balances = {
        'osmosis-1': balance(
          'osmosis-1',
          available: '2000000',
          staked: '999000000',
          rewards: '999000000',
          stakingKnown: false,
          rewardsKnown: false,
        ),
      };
      final totals = computePortfolio(chains, balances, prices, homeAssets(chains, balances, prices));
      expect(totals.total, 1);
      expect(totals.staked, 0);
      expect(totals.claimable, 0);
    });

    test('counts a held token no price applies to as unpriced, never as zero value', () {
      final chains = [chain('osmosis-1')];
      final balances = {
        'osmosis-1': balance('osmosis-1', tokens: const [HeldToken(denom: unlisted, amount: '5')]),
      };
      final totals = computePortfolio(chains, balances, prices, homeAssets(chains, balances, prices));
      expect(totals.unpricedAssets, 1);
      expect(totals.total, 0);
    });

    test('has no headline before any price arrives', () {
      final chains = [chain('osmosis-1')];
      final balances = {'osmosis-1': balance('osmosis-1', available: '2000000')};
      final totals = computePortfolio(chains, balances, const {}, homeAssets(chains, balances, const {}));
      expect(totals.hasTotal, isFalse);
      expect(totals.change24h, isNull);
    });
  });
}
