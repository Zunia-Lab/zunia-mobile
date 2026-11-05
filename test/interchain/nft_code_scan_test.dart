/// The chain scan that stands in for an NFT indexer on CosmWasm chains.
///
/// Mirrors the extension's `scanCw721Contracts`: one verdict per wasm code,
/// kept for good; instances listed only for CW721 codes; and no verdict at all
/// when the node would not answer, because a cached guess would be permanent.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/nft.dart';
import 'package:zunia_mobile/services/interchain/nft_code_scan.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

const _chain = ChainInfo(
  chainId: 'safrochain-1',
  chainName: 'Safrochain',
  bech32Prefix: 'addr_safro',
  coinMinimalDenom: 'usafro',
  features: ['cosmwasm'],
  rest: 'https://lcd.safro.example',
);

const _owner = 'addr_safro1owner00000000000000000000000000000';
const _nft = 'addr_safro1nft000000000000000000000000000000000';
const _nft2 = 'addr_safro1nft200000000000000000000000000000000';
const _dex = 'addr_safro1dex000000000000000000000000000000000';

final RegExp _smartPath = RegExp(
  r'^/cosmwasm/wasm/v1/contract/([^/]+)/smart/(.+)$',
);
final RegExp _codeContracts = RegExp(
  r'^/cosmwasm/wasm/v1/code/([^/]+)/contracts$',
);

/// A chain whose code list is [codes] (code id to instances). A smart query to
/// a contract in [cw721] answers; one in [down] fails like a dead node; any
/// other is refused the way wasmd refuses an unknown query.
class _Chain implements LcdClient {
  _Chain(this.codes, {this.cw721 = const {}, this.down = const {}});

  final Map<String, List<String>> codes;
  final Set<String> cw721;
  final Set<String> down;

  @override
  final String chainId = _chain.chainId;

  final List<String> paths = [];

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    paths.add(path);
    if (path == '/cosmwasm/wasm/v1/code') {
      return {
        'code_infos': [
          for (final id in codes.keys) {'code_id': id},
        ],
      };
    }
    final instances = _codeContracts.firstMatch(path);
    if (instances != null) {
      return {'contracts': codes[instances.group(1)] ?? const <String>[]};
    }
    final smart = _smartPath.firstMatch(path)!;
    final contract = Uri.decodeComponent(smart.group(1)!);
    jsonDecode(utf8.decode(base64Url.decode(smart.group(2)!)));
    if (down.contains(contract)) {
      throw InterchainError(
        InterchainErrorCode.lcdUnreachable,
        '$chainId: timed out',
        chainId: chainId,
      );
    }
    if (!cw721.contains(contract)) {
      throw InterchainError(
        InterchainErrorCode.lcdUnreachable,
        '$chainId: answered HTTP 500: unknown variant `tokens`: query wasm '
        'contract failed',
        chainId: chainId,
        httpStatus: 500,
      );
    }
    return {
      'data': {'tokens': <String>[]},
    };
  }

  int get smartQueries => paths.where((p) => p.contains('/smart/')).length;
}

class _MemoryStore implements NftCodeScanStore {
  final Map<String, NftCodeScanRecord> records = {};

  @override
  Future<NftCodeScanRecord> read(String chainId) async =>
      records[chainId] ?? const NftCodeScanRecord();

  @override
  Future<void> write(String chainId, NftCodeScanRecord record) async {
    records[chainId] = record;
  }
}

NftCodeScanner _scanner(
  LcdClient lcd,
  NftCodeScanStore store, [
  DateTime Function()? now,
]) => NftCodeScanner(
  NftChainContext(chain: _chain, lcd: lcd),
  store: store,
  now: now,
);

void main() {
  test('keeps the instances of CW721 codes and drops the rest', () async {
    final lcd = _Chain(
      {
        '12': [_nft, _nft2],
        '11': [_dex],
      },
      cw721: {_nft, _nft2},
    );
    final store = _MemoryStore();

    final result = await _scanner(lcd, store).scan(_owner);

    expect(result.contracts, [_nft, _nft2]);
    expect(result.codesScanned, 2);
    expect(store.records[_chain.chainId]!.codes, {'12': true, '11': false});
    // One probe per code, not per instance.
    expect(lcd.smartQueries, 2);
  });

  test('asks for the newest codes first', () async {
    final lcd = _Chain(
      {
        '1': [_nft],
      },
      cw721: {_nft},
    );
    await _scanner(lcd, _MemoryStore()).scan(_owner);
    expect(
      lcd.paths.first,
      '/cosmwasm/wasm/v1/code',
      reason: 'the stub ignores the query; the client adds it',
    );
  });

  test('reuses a recent scan without touching the chain', () async {
    final lcd = _Chain(
      {
        '12': [_nft],
      },
      cw721: {_nft},
    );
    final store = _MemoryStore();
    var now = DateTime(2026, 10, 22, 9);
    await _scanner(lcd, store, () => now).scan(_owner);
    final before = lcd.paths.length;

    now = now.add(const Duration(hours: 1));
    final cached = await _scanner(lcd, store, () => now).scan(_owner);

    expect(cached.fromCache, isTrue);
    expect(cached.contracts, [_nft]);
    expect(lcd.paths.length, before);
  });

  test(
    'force and an expired scan both list the chain again, but keep verdicts',
    () async {
      final lcd = _Chain(
        {
          '12': [_nft],
          '11': [_dex],
        },
        cw721: {_nft},
      );
      final store = _MemoryStore();
      var now = DateTime(2026, 10, 22, 9);
      await _scanner(lcd, store, () => now).scan(_owner);
      final probes = lcd.smartQueries;

      final forced = await _scanner(
        lcd,
        store,
        () => now,
      ).scan(_owner, force: true);
      expect(forced.fromCache, isFalse);

      now = now.add(kNftScanContractsTtl + const Duration(minutes: 1));
      final expired = await _scanner(lcd, store, () => now).scan(_owner);
      expect(expired.contracts, [_nft]);
      // Code verdicts never expire: neither rescan probed a code again.
      expect(lcd.smartQueries, probes);
    },
  );

  test('a node that will not answer leaves the code unjudged', () async {
    final lcd = _Chain(
      {
        '12': [_nft],
      },
      down: {_nft},
    );
    final store = _MemoryStore();

    final result = await _scanner(lcd, store).scan(_owner);

    expect(result.contracts, isEmpty);
    expect(
      store.records[_chain.chainId]!.codes,
      isEmpty,
      reason: 'an outage cached as "not a CW721" would hide it for good',
    );
  });

  test(
    'a second instance can vouch for a code whose first one is dead',
    () async {
      final lcd = _Chain(
        {
          '12': [_nft, _nft2],
        },
        cw721: {_nft2},
        down: {_nft},
      );
      final result = await _scanner(lcd, _MemoryStore()).scan(_owner);
      expect(result.contracts, [_nft, _nft2]);
    },
  );

  test('stops at the contract budget', () async {
    final codes = <String, List<String>>{};
    final cw721 = <String>{};
    for (var code = 0; code < 3; code++) {
      codes['$code'] = [
        for (var i = 0; i < kNftScanMaxContractsPerCode; i++)
          'addr_safro1c${code}i$i'.padRight(44, '0'),
      ];
      cw721.addAll(codes['$code']!);
    }
    final lcd = _Chain(codes, cw721: cw721);
    final result = await _scanner(lcd, _MemoryStore()).scan(_owner);
    expect(result.contracts, hasLength(kNftScanMaxContracts));
  });

  test(
    'the app store survives a round trip and drops another version',
    () async {
      SharedPreferences.setMockInitialValues({});
      const store = SharedPrefsNftCodeScanStore();
      final at = DateTime.fromMillisecondsSinceEpoch(1761123456000);
      await store.write(
        'safrochain-1',
        NftCodeScanRecord(
          codes: const {'12': true},
          contracts: const [_nft],
          contractsAt: at,
        ),
      );
      final back = await store.read('safrochain-1');
      expect(back.codes, {'12': true});
      expect(back.contracts, [_nft]);
      expect(back.contractsAt, at);

      SharedPreferences.setMockInitialValues({
        'zunia.nft.wasmScan': jsonEncode({
          'version': 0,
          'chains': {
            'safrochain-1': {
              'codes': {'12': false},
            },
          },
        }),
      });
      expect((await store.read('safrochain-1')).codes, isEmpty);
    },
  );
}
