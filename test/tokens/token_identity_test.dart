import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';

import '../support/catalog.dart';

/// The extension's token-identity suite (lib/__tests__/token-identity.test.ts,
/// 0.1.5) against the same bundled table and the same audit fixture, so a
/// balance reads the same ticker on the phone as in the extension.
const usdcInjErc20 = 'erc20:0xa00C59fF5a080D2b954d0c75e46E22a0c371235a';
const usdcInjOnOsmosis = 'ibc/794C7D7F3B857713878A3A1927251FA6AC1EEE520424C1F6FAFE9BA26D476138';
const usdcNOnOsmosis = 'ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4';
const usdcNOnInjective = 'ibc/2CBC2EA121AE42563B08028466F37B600F2D7D4282342DE938283CC3FB2BC00E';
const usdcAxlOnOsmosis = 'ibc/D189335C6E4A68B513C10AB227BF1C1D38C746766278BA3EEB4FB14124F1D858';
const allUsdc =
    'factory/osmo147h5x9pcj7lm0cttlaefx6sqq5vdfnmwfcqxkmjd7exqm9gc7grqhr75m0/alloyed/allUSDC';
const hubEurekaEth = 'ibc/C0B53D3D23827AE38058BED0BDCD554229278AF530A8D265FCF6DFF7C4B2ADFF';
const eurekaEthOnOsmosis = 'ibc/20850C646CDDDC2270E9BBDB08558B5FEE57B647EC6827F41096AABFD8A0471B';
const picassoEth = 'ibc/F9D075D4079FC56A9C49B601E54A45292C319D8B0E8CC0F8439041130AA7166C';
const wormholeSolanaUsdc =
    'factory/wormhole14ejqjyq8um4p3xfqj74yld5waqljf88fz25yxnma0cngspxe3les00fpjx/HJk1XMDRNUbRrpKkNZYui7SwWDMjXZAsySzqgyNcQoU3';
const unlisted = 'ibc/0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF';

void main() {
  late Map<String, dynamic> audit;

  setUpAll(() async {
    await loadBundledData();
    audit = jsonDecode(File('test/fixtures/token-identity/audit-traces.json').readAsStringSync())
        as Map<String, dynamic>;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChainCatalog.instance.setCustom(const []);
    resetTokenIdentityState();
  });

  group("the audit's vouchers", () {
    test('hash to their denoms, and the table holds each live trace', () {
      for (final trace in (audit['traces'] as List).cast<Map<String, dynamic>>()) {
        expect(ibcDenomFor(trace['path'] as String, trace['baseDenom'] as String), trace['denom']);
        final row = tokenTableRows(trace['chainId'] as String)
            .where((candidate) => candidate.denom == trace['denom'])
            .firstOrNull;
        expect(row, isNotNull, reason: trace['denom'] as String);
        expect(row!.path, trace['path']);
        expect(row.baseDenom, trace['baseDenom']);
      }
    });

    test('map each first-hop channel to the chain at its other end', () {
      for (final channel in (audit['channels'] as List).cast<Map<String, dynamic>>()) {
        expect(
          channelCounterpartyOf(channel['chainId'] as String, channel['channelId'] as String),
          channel['counterpartyChainId'],
          reason: channel['channelId'] as String,
        );
      }
      expect(channelCounterpartyOf('osmosis-1', 'channel-999999'), isNull);
    });

    test('read as the naming table, proven, with known decimals', () {
      for (final expected in (audit['naming'] as List).cast<Map<String, dynamic>>()) {
        final identity = identityOf(expected['chainId'] as String, expected['denom'] as String);
        final label = '${expected['chainId']}:${expected['denom']}';
        expect(identity.ticker, expected['ticker'], reason: label);
        expect(identity.originChainId, expected['originChainId'], reason: label);
        expect(identity.originDenom, expected['originDenom'], reason: label);
        expect(identity.provenance, isNot(TokenProvenance.unknown), reason: label);
        expect(identity.proven, isTrue, reason: label);
        expect(identity.decimalsKnown, isTrue, reason: label);
        expect(identity.key, label);
      }
    });

    test("never reads Noble USDC as Axelar's, nor Picasso ETH as STOS", () {
      final noble = identityOf('osmosis-1', usdcNOnOsmosis);
      final axelar = identityOf('osmosis-1', usdcAxlOnOsmosis);
      expect(noble.ticker, isNot(axelar.ticker));
      expect(noble.originChainName, 'Noble');
      expect(axelar.originChainName, 'Axelar');
      expect(identityOf('injective-1', usdcNOnInjective).ticker, 'USDC.n');
      final eth = identityOf(
        'osmosis-1',
        'ibc/A23E590BA7E0D808706FB5085A449B3B9D6864AE4DDE7DAF936243CEBB2A3D43',
      );
      expect(eth.ticker, 'ETH.pica');
      expect(eth.family, 'ETH');
      expect(eth.decimals, 18);
    });
  });

  group('USDC.inj', () {
    test('keeps the mixed-case erc20 origin that hashes to the voucher Osmosis trades', () {
      final onOsmosis = identityOf('osmosis-1', usdcInjOnOsmosis);
      expect(onOsmosis.originDenom, usdcInjErc20);
      expect(ibcDenomFor('transfer/channel-122', usdcInjErc20), usdcInjOnOsmosis);
      expect(osmosisDenomOf('injective-1', usdcInjErc20), usdcInjOnOsmosis);
      final lowercase = usdcInjErc20.toLowerCase();
      expect(
        ibcDenomFor('transfer/channel-122', lowercase),
        'ibc/D3B2A035362AF6B16BE95236AD85D408259B3611CA220781ECB7922C60ED7436',
      );
      expect(osmosisDenomOf('injective-1', lowercase), isNull);
      final onInjective = identityOf('injective-1', usdcInjErc20);
      expect(onInjective.ticker, 'USDC.inj');
      expect(onInjective.osmosisDenom, usdcInjOnOsmosis);
      expect(onInjective.kind, TokenKind.erc20);
    });

    test('does not lend its name to another spelling of the erc20 denom', () {
      for (final spelling in [
        usdcInjErc20.toLowerCase(),
        'erc20:0xA00C59fF5a080D2b954d0c75e46E22a0c371235a',
      ]) {
        final identity = identityOf('injective-1', spelling);
        expect(identity.provenance, TokenProvenance.unknown, reason: spelling);
        expect(identity.proven, isFalse);
        expect(identity.decimalsKnown, isFalse);
        expect(identity.ticker, isNot('USDC.inj'));
        expect(identity.osmosisDenom, isNull);
      }
    });

    test("gives the Osmosis row the issuer's channel pair for delivery to Injective", () {
      final row = tokenTableRows('osmosis-1').firstWhere((r) => r.denom == usdcInjOnOsmosis);
      expect(row.originChainId, 'injective-1');
      expect(row.originDenom, usdcInjErc20);
      expect(row.channelId, 'channel-122');
      expect(row.counterpartyChainId, 'injective-1');
      expect(row.counterpartyChannelId, 'channel-8');
      expect(row.verified, isTrue);
      expect(row.stable, isTrue);
    });
  });

  group("the issuer's own denom", () {
    String unguarded(TokenIdentity identity) => tickerFor(TickerInput(
          family: identity.family,
          originChainId: identity.originChainId,
          bridge: identity.bridge,
          sourceNetwork: identity.sourceNetwork,
          alloyed: identity.alloyed,
        ));

    test('reads exactly like the voucher that proves it, on every issuer', () {
      var checked = 0;
      for (final row in tokenTableRows('osmosis-1')) {
        if (row.channelId == null || row.counterpartyChainId != row.originChainId) continue;
        final onOsmosis = identityOf('osmosis-1', row.denom);
        final atIssuer = identityOf(row.originChainId, row.originDenom);
        final label = '${row.originChainId}:${row.originDenom}';
        expect(atIssuer.proven, isTrue, reason: label);
        expect(
          [atIssuer.originChainId, atIssuer.originDenom],
          [onOsmosis.originChainId, onOsmosis.originDenom],
          reason: label,
        );
        expect(unguarded(atIssuer), unguarded(onOsmosis), reason: label);
        expect(
          atIssuer.decimalsKnown ? atIssuer.decimals : false,
          onOsmosis.decimalsKnown ? onOsmosis.decimals : false,
          reason: label,
        );
        checked += 1;
      }
      expect(checked, greaterThan(250));
    });

    test('names issuer denoms the catalog does not list or names its own way', () {
      final usdt = identityOf('axelar-dojo-1', 'polygon-uusdt');
      expect(usdt.ticker, 'USDT.axl.polygon');
      expect(usdt.decimals, 6);
      expect(usdt.provenance, TokenProvenance.table);
      expect(usdt.proven, isTrue);
      expect(usdt.kind, TokenKind.other);
      final eth = identityOf('centauri-1', picassoEth);
      expect(eth.ticker, 'ETH.pica');
      expect(eth.originChainId, 'centauri-1');
      expect(eth.path, 'transfer/channel-52');
      expect(eth.decimals, 18);
      expect(identityOf('wormchain', wormholeSolanaUsdc).ticker, 'USDC.wh.sol');
      final lbtc = tokenTableRows('osmosis-1')
          .firstWhere((row) => row.aliases.contains('LBTC') || row.family == 'LBTC');
      expect(lbtc.originChainId, 'cosmoshub-4');
      final lbtcOnOsmosis = identityOf('osmosis-1', lbtc.denom);
      expect(lbtcOnOsmosis.originChainId, 'ledger-mainnet-1');
      expect(lbtcOnOsmosis.originDenom, 'uclbtc');
      expect(lbtcOnOsmosis.hopChainIds, ['cosmoshub-4', 'ledger-mainnet-1']);
      expect(tokenText(lbtcOnOsmosis, TokenTextVariant.row), 'Lombard Ledger LBTC · on Osmosis');
      const roar = 'terra1lxx40s29qvkrcj8fsa3yzyehy7w50umdvvnls2r830rys6lu2zns63eelv';
      expect(identityOf('phoenix-1', roar).ticker, 'ROAR');
      expect(identityOf('phoenix-1', 'cw20:$roar').ticker, 'ROAR');
    });

    test("names the Hub's Eureka tokens, which no channel walk can", () {
      final row = tokenTableRows('cosmoshub-4').firstWhere((r) => r.denom == hubEurekaEth);
      expect(row.originChainId, 'cosmoshub-4');
      expect(row.originDenom, hubEurekaEth);
      expect(row.path, 'transfer/08-wasm-1369');
      expect(row.channelId, isNull);
      expect(row.counterpartyChainId, isNull);
      expect(ibcDenomFor(row.path, row.baseDenom), hubEurekaEth);
      final hub = identityOf('cosmoshub-4', hubEurekaEth);
      expect(hub.ticker, 'ETH.eureka');
      expect(hub.bridge, 'eureka');
      expect(hub.provenance, TokenProvenance.table);
      expect(hub.proven, isTrue);
      expect(hub.decimals, 18);
      expect(hub.osmosisDenom, eurekaEthOnOsmosis);
      final onOsmosis = identityOf('osmosis-1', eurekaEthOnOsmosis);
      expect(onOsmosis.ticker, 'ETH.eureka');
      expect(onOsmosis.originChainId, 'cosmoshub-4');
      expect(onOsmosis.originDenom, hubEurekaEth);
      expect(channelCounterpartyOf('cosmoshub-4', '08-wasm-1369'), isNull);
    });
  });

  group('tickers', () {
    test("name each chain's staking coin by the identity rule", () {
      String ticker(String chainId) => chainTicker(ChainCatalog.instance.find(chainId)!);
      expect(ticker('cosmoshub-4'), 'ATOM');
      expect(ticker('noble-1'), 'USDC.n');
      expect(ticker('axelar-dojo-1'), 'AXL');
      expect(ticker('osmosis-1'), 'OSMO');
      expect(ticker('injective-1'), 'INJ');
      expect(ticker('phoenix-1'), 'LUNA');
      expect(ticker('columbus-5'), 'LUNC');
      expect(feeTicker(ChainCatalog.instance.find('atomone-1')!), 'PHOTON');
    });

    test("never tag a chain that pays gas in someone else's coin", () {
      for (final chainId in ['intergaze-1', 'moo-1']) {
        final entry = ChainCatalog.instance.find(chainId);
        if (entry == null) continue;
        expect(chainTicker(entry), 'INIT', reason: chainId);
      }
      final intergaze = ChainCatalog.instance.find('intergaze-1');
      if (intergaze != null) {
        expect(identityOf('intergaze-1', intergaze.coinMinimalDenom).ticker, 'INIT');
      }
    });

    test('match the naming table for every variant', () {
      String viaOrigin(String originChainId, String originDenom) {
        final denom = osmosisDenomOf(originChainId, originDenom);
        if (denom == null) fail('$originChainId:$originDenom has no Osmosis voucher');
        return identityOf('osmosis-1', denom).ticker;
      }

      expect({
        'USDC (Noble)': viaOrigin('noble-1', 'uusdc'),
        'USDC (Injective)': viaOrigin('injective-1', usdcInjErc20),
        'USDC (Axelar)': viaOrigin('axelar-dojo-1', 'uusdc'),
        'USDC (Axelar, Polygon)': viaOrigin('axelar-dojo-1', 'polygon-uusdc'),
        'USDC (Axelar, Avalanche)': viaOrigin('axelar-dojo-1', 'avalanche-uusdc'),
        'USDC (Gravity)':
            viaOrigin('gravity-bridge-3', 'gravity0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'),
        'USDC (alloy)': identityOf('osmosis-1', allUsdc).ticker,
        'USDT (Kava)': viaOrigin('kava_2222-10', 'erc20/tether/usdt'),
        'USDT (Axelar)': viaOrigin('axelar-dojo-1', 'uusdt'),
        'USDT (Axelar, Arbitrum)': viaOrigin('axelar-dojo-1', 'arbitrum-uusdt'),
        'USDT (Peggy)': viaOrigin('injective-1', 'peggy0xdAC17F958D2ee523a2206206994597C13D831ec7'),
        'USDT (Gravity)':
            viaOrigin('gravity-bridge-3', 'gravity0xdAC17F958D2ee523a2206206994597C13D831ec7'),
        'ETH (Axelar)': viaOrigin('axelar-dojo-1', 'weth-wei'),
        'ETH (Axelar, Arbitrum)': viaOrigin('axelar-dojo-1', 'arbitrum-weth-wei'),
        'ETH (Gravity)':
            viaOrigin('gravity-bridge-3', 'gravity0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'),
        'ETH (Picasso)': viaOrigin('centauri-1', picassoEth),
        'USDC (Wormhole, Solana)': viaOrigin('wormchain', wormholeSolanaUsdc),
        'WBTC (Axelar)': viaOrigin('axelar-dojo-1', 'wbtc-satoshi'),
        'WBTC (Osmosis)': identityOf(
          'osmosis-1',
          'factory/osmo1z0qrq605sjgcqpylfl4aa6s90x738j7m58wyatt0tdzflg2ha26q67k743/wbtc',
        ).ticker,
        'DAI (Axelar)': viaOrigin('axelar-dojo-1', 'dai-wei'),
        'ATOM (Hub)': viaOrigin('cosmoshub-4', 'uatom'),
        'stATOM (Stride)': viaOrigin('stride-1', 'stuatom'),
        'LUNA (Terra)': viaOrigin('phoenix-1', 'uluna'),
        'AXL (Axelar)': viaOrigin('axelar-dojo-1', 'uaxl'),
      }, {
        'USDC (Noble)': 'USDC.n',
        'USDC (Injective)': 'USDC.inj',
        'USDC (Axelar)': 'USDC.axl',
        'USDC (Axelar, Polygon)': 'USDC.axl.polygon',
        'USDC (Axelar, Avalanche)': 'USDC.axl.avax',
        'USDC (Gravity)': 'USDC.grv',
        'USDC (alloy)': 'allUSDC',
        'USDT (Kava)': 'USDT.kava',
        'USDT (Axelar)': 'USDT.axl',
        'USDT (Axelar, Arbitrum)': 'USDT.axl.arb',
        'USDT (Peggy)': 'USDT.peggy',
        'USDT (Gravity)': 'USDT.grv',
        'ETH (Axelar)': 'ETH.axl',
        'ETH (Axelar, Arbitrum)': 'ETH.axl.arb',
        'ETH (Gravity)': 'ETH.grv',
        'ETH (Picasso)': 'ETH.pica',
        'USDC (Wormhole, Solana)': 'USDC.wh.sol',
        'WBTC (Axelar)': 'WBTC.axl',
        'WBTC (Osmosis)': 'WBTC.osmo',
        'DAI (Axelar)': 'DAI.axl',
        'ATOM (Hub)': 'ATOM',
        'stATOM (Stride)': 'stATOM',
        'LUNA (Terra)': 'LUNA',
        'AXL (Axelar)': 'AXL',
      });
    });

    test('apply the rule from origin, bridge and network', () {
      expect(tickerFor(const TickerInput(family: 'USDC', originChainId: 'osmosis-1', alloyed: true)),
          'allUSDC');
      expect(tickerFor(const TickerInput(family: 'USDC', originChainId: 'noble-1')), 'USDC.n');
      expect(
        tickerFor(const TickerInput(
          family: 'USDC',
          originChainId: 'axelar-dojo-1',
          bridge: 'axl',
          sourceNetwork: 'polygon',
        )),
        'USDC.axl.polygon',
      );
      expect(
        tickerFor(const TickerInput(
          family: 'WAVAX',
          originChainId: 'axelar-dojo-1',
          bridge: 'axl',
          sourceNetwork: 'avax',
        )),
        'WAVAX.axl',
      );
      expect(tickerFor(const TickerInput(family: 'ATOM', originChainId: 'cosmoshub-4')), 'ATOM');
      expect(tickerFor(const TickerInput(family: 'ATOM', originChainId: 'thorchain-1')), 'ATOM.thor');
      expect(
        tickerFor(const TickerInput(family: 'ETH', originChainId: 'injective-1', bridge: 'peggy')),
        'ETH.peggy',
      );
      expect(tickerFor(const TickerInput(family: 'USDC', originChainId: null)), 'USDC');
      expect(tickerFor(const TickerInput(family: 'OSMO', originChainId: 'osmo-test-5')), 'OSMO');
    });

    test('strip issuer decorations down to the family', () {
      expect(familyOf('axlUSDC'), 'USDC');
      expect(familyOf('PolygonUSDC.axl'), 'USDC');
      expect(familyOf('USDC.e.matic.axl'), 'USDC');
      expect(familyOf('USDC.n'), 'USDC');
      expect(familyOf('solana.USDC.wh'), 'USDC');
      expect(familyOf('avalanche.USDC.wh'), 'USDC');
      expect(familyOf('USDt'), 'USDT');
      expect(familyOf('WETH'), 'ETH');
      expect(familyOf('wETH'), 'ETH');
      expect(familyOf('ETH.BASE'), 'ETH');
      expect(familyOf('stATOM'), 'stATOM');
      expect(familyOf('wstETH'), 'wstETH');
      expect(familyOf('DGN.old'), 'DGN.old');
    });

    test('leave no two denoms on one chain with the same ticker', () {
      final denomsByChain = <String, Set<String>>{};
      void add(String chainId, String denom) =>
          denomsByChain.putIfAbsent(chainId, () => <String>{}).add(denom);
      for (final row in tokenTableRows()) {
        add(row.heldOnChainId, row.denom);
        if (row.channelId != null && row.counterpartyChainId == row.originChainId) {
          add(row.originChainId, row.originDenom);
        }
      }
      for (final chainId in denomsByChain.keys.toList()) {
        for (final currency in ChainCatalog.instance.find(chainId)?.currencies ?? const []) {
          if (!currency.coinMinimalDenom.startsWith('ibc/')) add(chainId, currency.coinMinimalDenom);
        }
      }
      expect(denomsByChain.length, greaterThan(100));
      for (final MapEntry(key: chainId, value: denoms) in denomsByChain.entries) {
        final byTicker = <String, List<String>>{};
        for (final denom in denoms) {
          if (denom.startsWith('cw20:') && denoms.contains(denom.substring(5))) continue;
          byTicker.putIfAbsent(identityOf(chainId, denom).ticker, () => []).add(denom);
        }
        final shared = byTicker.entries.where((entry) => entry.value.length > 1).toList();
        expect(shared, isEmpty, reason: chainId);
      }
    });
  });

  group('custom chains and testnets', () {
    test('cannot rename OSMO, and are never proven', () {
      ChainCatalog.instance.setCustom([customChain()]);
      expect(chainTicker(ChainCatalog.instance.find('osmosis-1')!), 'OSMO');
      expect(identityOf('osmosis-1', 'uosmo').ticker, 'OSMO');
      expect(identityOf('osmosis-1', 'uosmo').proven, isTrue);
      expect(chainTicker(ChainCatalog.instance.find('my-osmo-fork-1')!), 'OSMO');
      final forked = identityOf('my-osmo-fork-1', 'uosmo');
      expect(forked.ticker, 'OSMO');
      expect(forked.testnet, isTrue);
      expect(forked.proven, isFalse);
    });

    test("keep a mainnet asset's name on a chain the user added, unproven", () {
      ChainCatalog.instance.setCustom([
        customChain(
          chainId: 'stargaze-1',
          chainName: 'My Stargaze',
          bech32Prefix: 'stars',
          network: 'mainnet',
        ),
      ]);
      final row = tokenTableRows('stargaze-1').firstWhere((r) => r.originChainId == 'osmosis-1');
      final held = identityOf('stargaze-1', row.denom);
      expect(held.originChainId, 'osmosis-1');
      expect(held.testnet, isTrue);
      expect(held.proven, isFalse);
      expect(held.name.startsWith('Osmosis '), isTrue);
      expect(tokenText(held, TokenTextVariant.row), '${held.name} · on My Stargaze');
    });

    test('show a testnet coin under its own symbol', () {
      final testnet = ChainCatalog.instance.find('osmo-test-5')!;
      final identity = identityOf('osmo-test-5', testnet.coinMinimalDenom);
      expect(identity.ticker, testnet.coinDenom);
      expect(identity.testnet, isTrue);
    });

    test('only name a base denom by an issuer when exactly one registry chain issues it', () {
      expect(uniqueIssuerOf('uusdc'), isNull);
      expect(uniqueIssuerOf('uluna'), isNull);
      expect(uniqueIssuerOf('uatom')?.entry.chainId, 'cosmoshub-4');
      expect(uniqueIssuerOf('wei'), isNull);
      ChainCatalog.instance.setCustom([customChain(chainId: 'mine-1', coinMinimalDenom: 'uatom')]);
      expect(uniqueIssuerOf('uatom')?.entry.chainId, 'cosmoshub-4');
    });
  });

  group('unknown and unproven identities', () {
    test('leave an unlisted voucher unknown, in base units', () {
      final identity = identityOf('osmosis-1', unlisted);
      expect(identity.provenance, TokenProvenance.unknown);
      expect(identity.proven, isFalse);
      expect(identity.originChainId, isNull);
      expect(identity.originDenom, isNull);
      expect(identity.decimals, 0);
      expect(identity.decimalsKnown, isFalse);
      expect(identity.logoUrl, isNull);
      expect(identity.ticker, 'IBC·0123');
      expect(identity.kind, TokenKind.ibc);
      expect(tokenText(identity, TokenTextVariant.row), 'Unknown origin · on Osmosis · ibc/0123…ABCDEF');
    });

    test('know where an unlisted local token was minted but not its name', () {
      final identity = identityOf('osmosis-1', 'factory/osmo1creator/uflower');
      expect(identity.provenance, TokenProvenance.native);
      expect(identity.originChainId, 'osmosis-1');
      expect(identity.ticker, 'uflower');
      expect(identity.proven, isFalse);
      expect(identity.decimalsKnown, isFalse);
      expect(identity.kind, TokenKind.factory);
    });

    test('name a legacy Peggy denom from the Ethereum contract it embeds', () {
      final identity = identityOf('injective-1', 'peggy0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48');
      expect(identity.ticker, 'USDC.peggy');
      expect(identity.decimals, 6);
      expect(identity.bridge, 'peggy');
      expect(identity.proven, isTrue);
    });

    test('read a contract denom only on the chain whose bridge mints it', () {
      for (final chainId in ['injective-888', 'osmosis-1']) {
        final identity = identityOf(chainId, 'peggy0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48');
        expect(identity.proven, isFalse, reason: chainId);
        expect(identity.ticker.startsWith('USDC'), isFalse, reason: chainId);
      }
    });

    test('treat a packet path as a path, not a bank denom', () {
      expect(identityOf('osmosis-1', 'transfer/channel-750/uusdc').provenance, TokenProvenance.unknown);
      expect(
        identityOf('cosmoshub-4', 'transfer/08-wasm-1369/0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2')
            .provenance,
        TokenProvenance.unknown,
      );
    });

    test("never let a token nobody lists wear a listed token's ticker", () {
      const cases = [
        ('osmosis-1', 'factory/osmo1qyqszqgpqyqszqgpqyqszqgpqyqszqgpjnp7du/USDC.n', 'USDC.n'),
        ('osmosis-1', 'factory/osmo1qyqszqgpqyqszqgpqyqszqgpqyqszqgpjnp7du/OSMO', 'OSMO'),
        ('osmosis-1', 'factory/osmo1qyqszqgpqyqszqgpqyqszqgpqyqszqgpjnp7du/allUSDC', 'allUSDC'),
        ('osmosis-1', 'factory/osmo1qyqszqgpqyqszqgpqyqszqgpqyqszqgpjnp7du/atom', 'ATOM'),
        ('injective-1', 'factory/inj1qyqszqgpqyqszqgpqyqszqgpqyqszqgpvk3zns/USDC.inj', 'USDC.inj'),
      ];
      for (final (chainId, denom, real) in cases) {
        final identity = identityOf(chainId, denom);
        expect(identity.ticker.toUpperCase(), isNot(real.toUpperCase()), reason: denom);
        expect(RegExp(r'·[0-9A-F]{4}$').hasMatch(identity.ticker), isTrue, reason: denom);
        expect(identity.name.startsWith('Unlisted '), isTrue, reason: denom);
        expect(identity.proven, isFalse);
      }
      expect(identityOf('osmosis-1', usdcNOnOsmosis).ticker, 'USDC.n');
      expect(identityOf('osmosis-1', 'factory/osmo1creator/uflower').ticker, 'uflower');
    });

    test('never throw', () {
      expect(identityOf('', '').provenance, TokenProvenance.unknown);
      expect(identityOf('not-a-chain', 'ibc/XYZ').provenance, TokenProvenance.unknown);
    });
  });

  group('unlisted local tokens', () {
    const impostor = 'factory/osmo1qyqszqgpqyqszqgpqyqszqgpqyqszqgpjnp7du/USDC.n';

    test('never call a token nothing lists native, in any wording', () {
      const cases = [
        ('osmosis-1', impostor),
        ('osmosis-1', 'factory/osmo1creator/uflower'),
        ('injective-1', 'factory/inj1qyqszqgpqyqszqgpqyqszqgpqyqszqgpvk3zns/USDC.inj'),
        ('injective-1', 'erc20:0x0000000000000000000000000000000000000001'),
        ('cosmoshub-4', 'uunlisted'),
        ('cosmoshub-4', 'cw20:cosmos1xyz'),
        ('osmo-test-5', 'factory/osmo1creator/utest'),
      ];
      for (final (chainId, denom) in cases) {
        final identity = identityOf(chainId, denom);
        expect(identity.originChainId, chainId, reason: denom);
        expect(identity.listed, isFalse, reason: denom);
        expect(identity.proven, isFalse, reason: denom);
        expect(identity.provenance, isNot(TokenProvenance.unknown), reason: denom);
        final held = identity.heldOnChainName;
        expect(tokenText(identity, TokenTextVariant.row), 'Unlisted token · on $held');
        expect(tokenText(identity, TokenTextVariant.a11y), '${identity.ticker}, unlisted token, on $held');
        expect(
          tokenText(identity, TokenTextVariant.sentence),
          '${identity.ticker} (unlisted token) on $held',
        );
        expect(isUnlistedLocal(identity), isTrue, reason: denom);
      }
      final fake = identityOf('osmosis-1', impostor);
      expect(RegExp(r'^USDC\.n·[0-9A-F]{4}$').hasMatch(fake.ticker), isTrue);
      expect(tokenText(fake, TokenTextVariant.row), 'Unlisted token · on Osmosis');
    });

    test('keep Native for a chain own coin and the local tokens a registry names', () {
      const listed = [
        ('osmosis-1', 'uosmo', 'Native on Osmosis'),
        ('injective-1', usdcInjErc20, 'Native on Injective'),
        ('injective-1', 'peggy0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', 'Native on Injective'),
        ('cosmoshub-4', hubEurekaEth, 'Native on Cosmos Hub'),
        ('axelar-dojo-1', 'polygon-uusdt', 'Native on Axelar'),
        ('osmo-test-5', 'uosmo', 'Native on Osmosis Testnet'),
      ];
      for (final (chainId, denom, row) in listed) {
        final identity = identityOf(chainId, denom);
        expect(identity.listed, isTrue, reason: denom);
        expect(isUnlistedLocal(identity), isFalse, reason: denom);
        expect(tokenText(identity, TokenTextVariant.row), row, reason: denom);
      }
      expect(
        tokenText(
          identityOf('injective-888', 'peggy0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'),
          TokenTextVariant.row,
        ),
        'Unlisted token · on Injective (Testnet)',
      );
      final unknown = identityOf('osmosis-1', unlisted);
      expect(unknown.listed, isFalse);
      expect(isUnlistedLocal(unknown), isFalse);
    });

    test('name every registry, table and catalog token as listed', () {
      final seen = <String>{};
      final unlistedKeys = <String>[];
      void check(String chainId, String denom) {
        final key = '$chainId:$denom';
        if (!seen.add(key)) return;
        final identity = identityOf(chainId, denom);
        if (identity.listed) {
          expect(tokenText(identity, TokenTextVariant.row).contains('Unlisted'), isFalse, reason: key);
        } else if (identity.provenance != TokenProvenance.unknown) {
          unlistedKeys.add(key);
        }
      }

      for (final row in tokenTableRows()) {
        check(row.heldOnChainId, row.denom);
        check(row.originChainId, row.originDenom);
      }
      for (final entry in ChainCatalog.instance.all) {
        check(entry.chainId, entry.coinMinimalDenom);
        for (final currency in entry.currencies) {
          check(entry.chainId, currency.coinMinimalDenom);
        }
      }
      expect(seen.length, greaterThan(1400));
      expect(unlistedKeys, [
        'migaloo-1:factory/migaloo1t862qdu9mj5hr3j727247acypym3ej47axu22rrapm4tqlcpuseqltxwq5/ophir',
      ]);
    });

    test("call a user-added chain's own coin native, and an unlisted mint unlisted", () {
      ChainCatalog.instance.setCustom([
        customChain(chainId: 'mine-1', chainName: 'Mine', coinDenom: 'MINE', coinMinimalDenom: 'umine'),
      ]);
      final coin = identityOf('mine-1', 'umine');
      expect(coin.listed, isTrue);
      expect(coin.proven, isFalse);
      expect(coin.testnet, isTrue);
      expect(tokenText(coin, TokenTextVariant.row), 'Native on Mine');
      final minted = identityOf('mine-1', 'factory/mine1creator/ufoo');
      expect(minted.listed, isFalse);
      expect(tokenText(minted, TokenTextVariant.row), 'Unlisted token · on Mine');
    });
  });

  group('logos', () {
    test("never use a chain icon for a token that is not that chain's coin", () {
      final icons = {
        for (final entry in ChainCatalog.instance.all)
          if (entry.iconUrl != null) entry.iconUrl!,
      };
      final identities = [
        for (final row in tokenTableRows()) identityOf(row.heldOnChainId, row.denom),
        for (final row in tokenTableRows()) identityOf(row.originChainId, row.originDenom),
      ];
      var checked = 0;
      for (final identity in identities) {
        final logo = identity.logoUrl;
        if (logo == null || identity.kind == TokenKind.native) continue;
        checked += 1;
        expect(icons.contains(logo), isFalse, reason: identity.key);
        expect(RegExp(r'/chain\.(png|svg)$').hasMatch(logo), isFalse, reason: identity.key);
      }
      expect(checked, greaterThan(300));
      expect(identityOf('osmosis-1', usdcNOnOsmosis).logoUrl, matches(RegExp(r'usdc\.(png|svg)$')));
    });
  });

  group('text', () {
    test('separates the issuer from the location', () {
      final onOsmosis = identityOf('osmosis-1', usdcInjOnOsmosis);
      expect(tokenText(onOsmosis, TokenTextVariant.pill), 'on Osmosis');
      expect(tokenText(onOsmosis, TokenTextVariant.row), 'Injective USDC · on Osmosis');
      expect(tokenText(onOsmosis, TokenTextVariant.sentence), 'USDC.inj (Injective USDC) on Osmosis');
      expect(tokenText(onOsmosis, TokenTextVariant.a11y), 'USDC from Injective, on Osmosis');
      final atHome = identityOf('injective-1', usdcInjErc20);
      expect(tokenText(atHome, TokenTextVariant.row), 'Native on Injective');
      expect(tokenText(atHome, TokenTextVariant.sentence), 'USDC.inj on Injective');
      expect(tokenText(atHome, TokenTextVariant.a11y), 'USDC.inj, native on Injective');
      expect(tokenText(identityOf('osmosis-1', usdcNOnOsmosis), TokenTextVariant.row),
          'Noble USDC · on Osmosis');
      expect(tokenText(identityOf('injective-1', usdcNOnInjective), TokenTextVariant.a11y),
          'USDC from Noble, on Injective');
      expect(tokenText(identityOf('osmosis-1', allUsdc), TokenTextVariant.row),
          'Alloyed USDC · Osmosis only');
      expect(
        identityOf('osmosis-1', osmosisDenomOf('axelar-dojo-1', 'polygon-uusdc') ?? '').name,
        'Axelar USDC from Polygon',
      );
      final unknown = identityOf('osmosis-1', unlisted);
      expect(tokenText(unknown, TokenTextVariant.a11y), 'Unknown token ibc/0123…ABCDEF, on Osmosis');
      expect(tokenText(unknown, TokenTextVariant.sentence), 'unknown token ibc/0123…ABCDEF on Osmosis');
    });

    test('keyword search finds every name users have seen', () {
      final noble = tokenKeywords(identityOf('osmosis-1', usdcNOnOsmosis)).join(' ').toLowerCase();
      expect(noble, contains('usdc.noble'));
      expect(noble, contains('noble'));
      final axelar = tokenKeywords(identityOf('osmosis-1', usdcAxlOnOsmosis)).join(' ').toLowerCase();
      expect(axelar, contains('axlusdc'));
    });

    test('shortens every long denom one way', () {
      expect(shortDenom(usdcNOnOsmosis), 'ibc/498A…6BA6E4');
      expect(shortDenom(usdcInjErc20), 'erc20:0xa00C…235a');
      expect(shortDenom('peggy0xdAC17F958D2ee523a2206206994597C13D831ec7'), 'peggy0xdAC1…1ec7');
      expect(shortDenom('factory/osmo1abcdefghijklmnop/uflower'), 'factory/osmo1a…mnop/uflower');
      expect(shortDenom('uatom'), 'uatom');
    });

    test('labels every kind', () {
      expect(TokenKind.values.map(tokenKindLabel).toList(),
          ['Native', 'IBC', 'Factory', 'ERC-20', 'Peggy', 'CW20', 'Asset']);
    });
  });

  group('the bundled table', () {
    test('holds only vouchers whose trace hashes to their denom', () {
      final vouchers = tokenTableRows().where((row) => row.path.isNotEmpty).toList();
      expect(vouchers.length, greaterThan(300));
      for (final row in vouchers) {
        expect(ibcDenomFor(row.path, row.baseDenom), row.denom, reason: '${row.heldOnChainId}:${row.denom}');
      }
    });

    test('trusts decimals only where the catalog and the table agree', () {
      for (final row in tokenTableRows()) {
        final catalog = findCurrencyOn(row.originChainId, row.originDenom)?.currency.coinDecimals;
        final identity = identityOf(row.heldOnChainId, row.denom);
        if (catalog == null || catalog == row.decimals) {
          expect(identity.decimals, row.decimals, reason: identity.key);
          expect(identity.decimalsKnown, isTrue, reason: identity.key);
        } else {
          expect(identity.decimalsKnown, isFalse, reason: identity.key);
          expect(identity.decimals, 0, reason: identity.key);
        }
      }
    });
  });

  group('identifyHeld', () {
    final akashUsdc = ibcDenomFor('transfer/channel-999', 'uusdc');

    TraceLookup answering(Map<String, TraceLookupResult> answers, List<String> calls) =>
        (chainId, denom) async {
          calls.add(denom);
          return answers[denom];
        };

    test('walks an unlisted voucher once and names it from its origin', () async {
      final calls = <String>[];
      final lookup = answering({
        akashUsdc: (
          baseDenom: 'uusdc',
          path: 'transfer/channel-999',
          originChainId: 'noble-1',
          hopChainIds: null,
        ),
      }, calls);
      final found = await identifyHeld('akashnet-2', [akashUsdc, 'uakt'], lookup: lookup);
      final usdc = found[akashUsdc]!;
      expect(usdc.ticker, 'USDC.n');
      expect(usdc.provenance, TokenProvenance.channelWalk);
      expect(usdc.proven, isFalse);
      expect(usdc.originChainId, 'noble-1');
      expect(usdc.osmosisDenom, usdcNOnOsmosis);
      expect(usdc.decimals, 6);
      expect(tokenText(usdc, TokenTextVariant.row), 'Noble USDC · on Akash');
      expect(found['uakt']!.ticker, 'AKT');
      expect(calls, [akashUsdc]);
      await identifyHeld('akashnet-2', [akashUsdc], lookup: lookup);
      expect(calls, hasLength(1));
      final stored = (await SharedPreferences.getInstance()).getString('zunia.tokens.identityFacts');
      expect(stored, contains('"version":1'));
    });

    test('proves a walk only when every hop crossed a registry-canonical channel', () async {
      final canonical = ibcDenomFor('transfer/channel-62', 'uusdc');
      final lookalike = ibcDenomFor('transfer/channel-4242', 'uusdc');
      final found = await identifyHeld('agoric-3', [canonical, lookalike], lookup: (chainId, denom) async {
        if (denom == canonical) {
          return (
            baseDenom: 'uusdc',
            path: 'transfer/channel-62',
            originChainId: 'noble-1',
            hopChainIds: <String?>['noble-1'],
          );
        }
        return (
          baseDenom: 'uusdc',
          path: 'transfer/channel-4242',
          originChainId: 'noble-1',
          hopChainIds: <String?>['noble-1'],
        );
      });
      expect(found[canonical]!.provenance, TokenProvenance.channelWalk);
      expect(found[canonical]!.proven, isTrue);
      expect(found[lookalike]!.proven, isFalse);
    });

    test('rejects a trace whose hash does not match, and asks about it once', () async {
      final calls = <String>[];
      final lookup = answering({
        akashUsdc: (
          baseDenom: 'uatom',
          path: 'transfer/channel-999',
          originChainId: 'cosmoshub-4',
          hopChainIds: null,
        ),
      }, calls);
      final found = await identifyHeld('akashnet-2', [akashUsdc], lookup: lookup);
      expect(found[akashUsdc]!.provenance, TokenProvenance.unknown);
      await identifyHeld('akashnet-2', [akashUsdc], lookup: lookup);
      expect(calls, hasLength(1));
    });

    test('asks nothing about denoms the table or the catalog already name', () async {
      final found = await identifyHeld(
        'osmosis-1',
        [usdcNOnOsmosis, 'uosmo', allUsdc],
        lookup: (_, _) => throw StateError('should not be asked'),
      );
      expect(found.values.map((entry) => entry.ticker).toList(), ['USDC.n', 'OSMO', 'allUSDC']);
    });

    test('tags a second route of an asset the chain already lists', () async {
      final canonical = tokenTableRows('juno-1')
          .firstWhere((row) => row.originChainId == 'noble-1' && row.originDenom == 'uusdc');
      final detour = ibcDenomFor('transfer/channel-999', 'uusdc');
      await identifyHeld('juno-1', [detour], lookup: (_, _) async => (
            baseDenom: 'uusdc',
            path: 'transfer/channel-999',
            originChainId: 'noble-1',
            hopChainIds: null,
          ));
      expect(identityOf('juno-1', canonical.denom).ticker, 'USDC.n');
      expect(identityOf('juno-1', detour).ticker, 'USDC.n·${detour.substring(4, 8)}');
    });

    test('re-checks stored facts and drops a forged one', () {
      final forged = ibcDenomFor('transfer/channel-998', 'uusdc');
      final facts = parseTraceFacts({
        'version': 1,
        'facts': {
          'akashnet-2:$akashUsdc': {'o': 'noble-1', 'b': 'uusdc', 'p': 'transfer/channel-999', 'at': 1},
          'akashnet-2:$forged': {'o': 'axelar-dojo-1', 'b': 'uaxl', 'p': 'transfer/channel-998', 'at': 1},
        },
      });
      expect(facts.keys, ['akashnet-2:$akashUsdc']);
      expect(parseTraceFacts({'version': 0, 'facts': {}}), isEmpty);
    });

    test('asks one batch per read and leaves the rest for the next', () async {
      final vouchers = [
        for (var i = 0; i < 40; i++) ibcDenomFor('transfer/channel-${5000 + i}', 'uusdc'),
      ];
      var asked = 0;
      Future<TraceLookupResult?> lookup(String chainId, String denom) async {
        asked += 1;
        return (
          baseDenom: 'uusdc',
          path: 'transfer/channel-${5000 + vouchers.indexOf(denom)}',
          originChainId: 'noble-1',
          hopChainIds: null,
        );
      }

      await identifyHeld('akashnet-2', vouchers, lookup: lookup);
      expect(asked, 32);
      await identifyHeld('akashnet-2', vouchers, lookup: lookup);
      expect(asked, 40);
      expect(
        vouchers.where((denom) => identityOf('akashnet-2', denom).originChainId == 'noble-1'),
        hasLength(40),
      );
    });

    test('never proves a testnet walk that claims a mainnet issuer', () async {
      final voucher = ibcDenomFor('transfer/channel-7', 'uusdc');
      await identifyHeld('osmo-test-5', [voucher], lookup: (_, _) async => (
            baseDenom: 'uusdc',
            path: 'transfer/channel-7',
            originChainId: 'noble-1',
            hopChainIds: null,
          ));
      final walked = identityOf('osmo-test-5', voucher);
      expect(walked.originChainId, 'noble-1');
      expect(walked.testnet, isTrue);
      expect(walked.proven, isFalse);
    });

    test('does not dress a walked token nobody lists as a variant of a real one', () async {
      const base = 'factory/neutron1qyqszqgpqyqszqgpqyqszqgpqyqszqgpz3jc3a/USDC.n';
      final impostor = ibcDenomFor('transfer/channel-874', base);
      await identifyHeld('osmosis-1', [impostor], lookup: (_, _) async => (
            baseDenom: base,
            path: 'transfer/channel-874',
            originChainId: 'neutron-1',
            hopChainIds: null,
          ));
      final walked = identityOf('osmosis-1', impostor);
      expect(walked.provenance, TokenProvenance.channelWalk);
      expect(walked.proven, isFalse);
      expect(RegExp(r'^USDC\.n·[0-9A-F]{4}$').hasMatch(walked.ticker), isTrue);
      expect(walked.name, 'Unlisted Neutron token');
      expect(walked.listed, isFalse);
      expect(tokenText(walked, TokenTextVariant.row), 'Unlisted Neutron token · on Osmosis');
      expect(tokenText(walked, TokenTextVariant.a11y), 'Unlisted Neutron token, on Osmosis');
      expect(identityOf('osmosis-1', usdcNOnOsmosis).ticker, 'USDC.n');
    });

    test("reads an alloy held off Osmosis as a voucher, not as 'Neutron only'", () async {
      final voucher = ibcDenomFor('transfer/channel-10', allUsdc);
      await identifyHeld('neutron-1', [voucher], lookup: (_, _) async => (
            baseDenom: allUsdc,
            path: 'transfer/channel-10',
            originChainId: 'osmosis-1',
            hopChainIds: null,
          ));
      final held = identityOf('neutron-1', voucher);
      expect(held.ticker, 'allUSDC');
      expect(tokenText(held, TokenTextVariant.row), 'Alloyed USDC · on Neutron');
      expect(tokenText(identityOf('osmosis-1', allUsdc), TokenTextVariant.row),
          'Alloyed USDC · Osmosis only');
    });
  });

  group('held rows', () {
    test('take metadata decimals only for a token nothing names', () {
      expect(heldTokenIdentity('osmosis-1', unlisted, metadataDecimals: 6).decimalsKnown, isTrue);
      expect(heldTokenIdentity('osmosis-1', unlisted, metadataDecimals: 6).decimals, 6);
      expect(heldTokenIdentity('osmosis-1', unlisted, metadataDecimals: 99).decimalsKnown, isFalse);
      expect(heldTokenIdentity('osmosis-1', usdcNOnOsmosis, metadataDecimals: 18).decimals, 6);
    });
  });
}
