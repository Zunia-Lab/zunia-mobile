/// The NFT config parsers.
///
/// Pure functions on purpose: a `--dart-define` cannot be varied inside a test
/// run, so the parsing has to be testable without one. A malformed segment must
/// never take the whole surface down — a typo in one chain's bridge address
/// would otherwise disable NFTs on every chain.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/config/nft_config.dart';
import 'package:zunia_mobile/services/interchain/registry.dart';

void main() {
  group('parseCsvConfig', () {
    test('trims and drops blanks', () {
      expect(parseCsvConfig(' a , b ,, c '), ['a', 'b', 'c']);
      expect(parseCsvConfig(''), isEmpty);
      expect(parseCsvConfig('   '), isEmpty);
    });
  });

  group('parseChainListConfig', () {
    test('reads a per-chain list', () {
      expect(
        parseChainListConfig('chain-a=addr1,addr2;chain-b=addr3'),
        {
          'chain-a': ['addr1', 'addr2'],
          'chain-b': ['addr3'],
        },
      );
    });

    test('merges repeated chains without duplicating', () {
      expect(
        parseChainListConfig('chain-a=addr1;chain-a=addr1,addr2'),
        {
          'chain-a': ['addr1', 'addr2'],
        },
      );
    });

    test('skips malformed segments instead of failing the whole config', () {
      expect(
        parseChainListConfig('broken;=addr;chain-a=;chain-b=addr3'),
        {
          'chain-b': ['addr3'],
        },
      );
      expect(parseChainListConfig(''), isEmpty);
    });
  });

  group('parseChainValueConfig', () {
    test('reads one value per key and keeps a directed pair intact', () {
      expect(
        parseChainValueConfig('a>b=channel-3;c=addr1'),
        {'a>b': 'channel-3', 'c': 'addr1'},
      );
    });

    test('drops empty keys and empty values', () {
      expect(parseChainValueConfig('=x;y=;z=v'), {'z': 'v'});
    });
  });

  test('ics721ChannelKey is the directed pair the channel map is keyed by', () {
    expect(ics721ChannelKey('a', 'b'), 'a>b');
    expect(ics721ChannelKey('a', 'b'), isNot(ics721ChannelKey('b', 'a')));
  });

  test('this build ships no bridge, no channel and no gateway', () {
    // Each of these is deployment data. A default would be a guess, and for the
    // bridge a wrong guess escrows a collectible where nothing can release it.
    expect(kIcs721Bridges, isEmpty);
    expect(kIcs721Channels, isEmpty);
    expect(kNftIpfsGateways, isEmpty);
    expect(kNftArweaveGateways, isEmpty);
    expect(kNftKnownCollections, isEmpty);
    expect(kNftIndexerAvailable, isFalse);
  });

  group('registry features reach the engine', () {
    // The whole NFT surface is gated on this array. The catalog generator drops
    // it today, so this pins the two halves that must both work: absent stays
    // null (never []), and present is carried through to the engine's
    // ChainInfo, so fixing the generator needs no further client change.
    ChainEntry parse(Map<String, dynamic> extra) => ChainEntry.fromJson({
          'chainId': 'c-1',
          'chainName': 'Chain One',
          'bech32Prefix': 'c',
          'coinMinimalDenom': 'uc',
          ...extra,
        });

    test('an absent features array stays null, not empty', () {
      expect(parse(const {}).features, isNull);
      expect(CatalogChainRegistry.fromEntry(parse(const {})).features, isNull);
    });

    test('a present features array reaches ChainInfo intact', () {
      final entry = parse(const {
        'features': ['cosmwasm', 'ibc-transfer', 7],
      });
      // Non-strings are dropped rather than stringified: a capability flag is
      // a name, and coercing 7 into "7" would invent one.
      expect(entry.features, ['cosmwasm', 'ibc-transfer']);
      expect(
        CatalogChainRegistry.fromEntry(entry).features,
        ['cosmwasm', 'ibc-transfer'],
      );
    });

    test('an empty array is preserved as a real "declares nothing"', () {
      expect(parse(const {'features': <String>[]}).features, isEmpty);
    });
  });
}
