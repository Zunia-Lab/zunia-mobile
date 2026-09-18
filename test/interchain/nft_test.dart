/// Ported from `zunia-sdk/packages/interchain/src/nft.test.ts`, same vectors and
/// same assertions.
///
/// Nothing here touches the network: the [LcdClient] is a stub that decodes the
/// base64url query out of the path and answers from a handler, and the metadata
/// fetcher is a plain function. Every assertion is on a shape that has to be
/// exactly right — the base64 nesting in `send_nft`, the ICS721
/// `IbcOutgoingMsg`, the `addr_safro` prefix, and what each parser does with a
/// broken body.
///
/// Two TS tests have no twin here and the reason is the port, not the coverage:
/// there is no `AbortSignal` anywhere in the Dart engine (`LcdRequestOptions`
/// carries none), so "stops immediately when the caller aborted" cannot be
/// expressed; and `buildExecuteContractMsg` does not exist because [NftExecute]
/// carries the execute body rather than proto-JSON. The base64 assertion that
/// test made is instead made against the `send_nft` payload, which is the level
/// this port actually encodes.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/nft.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

/* -------------------------------------------------------------------------- *
 * Fixtures
 * -------------------------------------------------------------------------- */

const safro = ChainInfo(
  chainId: 'safrochain-1',
  chainName: 'Safrochain',
  // The whole point of the prefix tests: an underscore, which `[a-z]+1`
  // rejects.
  bech32Prefix: 'addr_safro',
  coinMinimalDenom: 'usafro',
  features: ['cosmwasm'],
  rest: 'https://lcd.safro.example',
);

const osmosis = ChainInfo(
  chainId: 'osmosis-1',
  chainName: 'Osmosis',
  bech32Prefix: 'osmo',
  coinMinimalDenom: 'uosmo',
  features: ['cosmwasm', 'ibc-transfer'],
  rest: 'https://lcd.osmosis.example',
);

const noWasm = ChainInfo(
  chainId: 'nowasm-1',
  chainName: 'Safrochain',
  bech32Prefix: 'addr_safro',
  coinMinimalDenom: 'usafro',
  features: ['stargate'],
);

const noFeatures = ChainInfo(
  chainId: 'unknown-1',
  chainName: 'Safrochain',
  bech32Prefix: 'addr_safro',
  coinMinimalDenom: 'usafro',
);

const owner = 'addr_safro1owner00000000000000000000000000000';
const recipient = 'addr_safro1recipient0000000000000000000000000';
const collection = 'addr_safro1collection00000000000000000000000';
const bridge = 'addr_safro1bridge0000000000000000000000000000';
const osmoRecipient = 'osmo1recipient000000000000000000000000000000';

const a = 'addr_safro1aaa0000000000000000000000000000000000';
const b = 'addr_safro1bbb0000000000000000000000000000000000';
const c = 'addr_safro1ccc0000000000000000000000000000000000';

/* -------------------------------------------------------------------------- *
 * Stub LCD
 * -------------------------------------------------------------------------- */

class _StubCall {
  const _StubCall(this.contract, this.query);

  final String contract;
  final Map<String, Object?> query;

  String get action => query.keys.first;
}

/// Handed back by a handler that wants its body returned verbatim, so the
/// `{ data: … }` unwrapper can itself be tested.
class _Raw {
  const _Raw(this.body);

  final Object? body;
}

final RegExp _smartPath =
    RegExp(r'^/cosmwasm/wasm/v1/contract/([^/]+)/smart/(.+)$');

/// An [LcdClient] that decodes the smart-query path and answers from
/// `handler`. Returning a value wraps it in the `{ data: … }` envelope; throwing
/// propagates, so a handler can simulate an HTTP 400 from wasmd.
class _StubLcd implements LcdClient {
  _StubLcd(this._handler);

  final Object? Function(_StubCall call) _handler;

  /// Always the fixture chain: every context in this file reads Safrochain, and
  /// a per-stub override would let a test assert against a chain id the context
  /// does not have.
  @override
  final String chainId = safro.chainId;

  final List<_StubCall> calls = [];

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    final match = _smartPath.firstMatch(path);
    expect(match, isNotNull, reason: 'unexpected path $path');
    final contract = Uri.decodeComponent(match!.group(1)!);
    final encoded = match.group(2)!;
    final padding = (4 - encoded.length % 4) % 4;
    final query = jsonDecode(
      utf8.decode(base64Url.decode(encoded + ('=' * padding))),
    ) as Map<String, Object?>;
    final call = _StubCall(contract, query);
    calls.add(call);
    final result = _handler(call);
    if (result is _Raw) return result.body;
    return <String, Object?>{'data': result};
  }
}

NftChainContext _ctx(_StubLcd stub, [ChainInfo chain = safro]) =>
    NftChainContext(chain: chain, lcd: stub);

Matcher _throwsCode(InterchainErrorCode code) => throwsA(
      isA<InterchainError>().having((e) => e.code, 'code', code),
    );

/// The inner `Binary` of a `send_nft`, decoded.
Map<String, Object?> _innerMsgOf(NftExecute execute) {
  final send = (execute.msg['send_nft'] as Map<String, Object?>?)!;
  return jsonDecode(utf8.decode(base64.decode(send['msg']! as String)))
      as Map<String, Object?>;
}

NftTransferRequest _ics721Request({
  String? recipientOverride,
  String chainId = 'safrochain-1',
  String? destChainId = 'osmosis-1',
  String? channelId = 'channel-12',
  String? bridgeContract = bridge,
  int? timeoutMinutes,
  String? memo,
}) =>
    NftTransferRequest(
      chainId: chainId,
      collectionAddress: collection,
      tokenId: '7',
      sender: owner,
      recipient: recipientOverride ?? osmoRecipient,
      destChainId: destChainId,
      channelId: channelId,
      bridgeContract: bridgeContract,
      timeoutMinutes: timeoutMinutes,
      memo: memo,
    );

void main() {
  /* ------------------------------------------------------------------ *
   * Capability gate
   * ------------------------------------------------------------------ */

  group('cosmwasm gate', () {
    test('declared, missing, and unknown feature lists', () {
      expect(supportsCosmWasm(safro), isTrue);
      expect(supportsCosmWasm(noWasm), isFalse);
      // Absent is not the same as declared, and defaults to refusing.
      expect(supportsCosmWasm(noFeatures), isFalse);
      expect(
        supportsCosmWasm(noFeatures, allowUnknownFeatures: true),
        isTrue,
      );
      expect(supportsCosmWasm(noWasm, allowUnknownFeatures: true), isFalse);

      expect(
        () => assertCosmWasmChain(noWasm),
        _throwsCode(InterchainErrorCode.unsupportedChain),
      );
      expect(
        () => assertCosmWasmChain(noFeatures),
        _throwsCode(InterchainErrorCode.unsupportedChain),
      );
      assertCosmWasmChain(safro);
    });

    test('the message names the feature and the chain', () {
      try {
        assertCosmWasmChain(noWasm);
        fail('expected unsupportedChain');
      } on InterchainError catch (error) {
        expect(error.message, contains('cosmwasm'));
        expect(error.chainId, 'nowasm-1');
      }
    });
  });

  /* ------------------------------------------------------------------ *
   * bech32 prefixes
   * ------------------------------------------------------------------ */

  group('addressHasPrefix', () {
    test('handles the underscore in addr_safro', () {
      expect(addressHasPrefix(owner, 'addr_safro'), isTrue);
      expect(addressHasPrefix(osmoRecipient, 'osmo'), isTrue);

      // Wrong chain.
      expect(addressHasPrefix(osmoRecipient, 'addr_safro'), isFalse);
      expect(addressHasPrefix(owner, 'osmo'), isFalse);

      // Not a partial match on the segment before the underscore.
      expect(addressHasPrefix(owner, 'addr'), isFalse);
      expect(addressHasPrefix('addr1abc', 'addr_safro'), isFalse);

      // Separator and payload both required.
      expect(addressHasPrefix('addr_safro', 'addr_safro'), isFalse);
      expect(addressHasPrefix('addr_safro1', 'addr_safro'), isFalse);
      expect(addressHasPrefix('', 'addr_safro'), isFalse);
      expect(addressHasPrefix(owner, ''), isFalse);
    });

    test('message builders reject an address from another chain', () {
      expect(
        () => buildTransferNftMsg(
          safro,
          sender: owner,
          collectionAddress: collection,
          tokenId: '1',
          recipient: osmoRecipient,
        ),
        _throwsCode(InterchainErrorCode.contractError),
      );
      expect(
        () => buildTransferNftMsg(
          safro,
          sender: osmoRecipient,
          collectionAddress: collection,
          tokenId: '1',
          recipient: recipient,
        ),
        _throwsCode(InterchainErrorCode.contractError),
      );
    });
  });

  /* ------------------------------------------------------------------ *
   * Smart queries
   * ------------------------------------------------------------------ */

  group('smart queries', () {
    test('smartQueryPath encodes the query as unpadded base64url', () {
      final path = smartQueryPath(collection, {'num_tokens': <String, Object?>{}});
      final match = _smartPath.firstMatch(path);
      expect(match, isNotNull);
      expect(match!.group(1), collection);
      expect(match.group(2), isNot(contains('=')),
          reason: 'base64url in a path must not be padded');
      final encoded = match.group(2)!;
      final padding = (4 - encoded.length % 4) % 4;
      expect(
        utf8.decode(base64Url.decode(encoded + ('=' * padding))),
        '{"num_tokens":{}}',
      );
    });

    test('smartQueryPath refuses an empty contract and escapes a hostile one',
        () {
      expect(
        () => smartQueryPath('   ', {'num_tokens': <String, Object?>{}}),
        _throwsCode(InterchainErrorCode.contractError),
      );
      final path =
          smartQueryPath('evil/../../foo', {'num_tokens': <String, Object?>{}});
      expect(path, isNot(contains('../')));
    });

    test('unwrapSmartQueryData accepts inline JSON, base64 bytes and a string',
        () {
      expect(
        unwrapSmartQueryData({'data': <String, Object?>{'count': 1}}, 'c-1'),
        {'count': 1},
      );
      expect(
        unwrapSmartQueryData(
          {'data': base64.encode(utf8.encode('{"count":2}'))},
          'c-1',
        ),
        {'count': 2},
      );
      // A contract may legitimately answer with a bare string; it must survive
      // the base64 attempt rather than becoming an error.
      expect(unwrapSmartQueryData({'data': 'hello'}, 'c-1'), 'hello');
    });

    test('unwrapSmartQueryData rejects a body with no usable data', () {
      for (final body in <Object?>[
        null,
        42,
        'text',
        <Object?>[],
        <String, Object?>{},
        <String, Object?>{'data': null},
        <String, Object?>{'result': <String, Object?>{}},
      ]) {
        expect(
          () => unwrapSmartQueryData(body, 'c-1'),
          _throwsCode(InterchainErrorCode.malformedResponse),
        );
      }
    });

    test('smartQuery reclassifies an HTTP 400 as a contract error', () async {
      final stub = _StubLcd((_) => throw InterchainError(
            InterchainErrorCode.lcdUnreachable,
            'HTTP 400',
            chainId: safro.chainId,
            httpStatus: 400,
          ));
      try {
        await smartQuery(stub, collection, {'num_tokens': <String, Object?>{}});
        fail('expected contractError');
      } on InterchainError catch (error) {
        expect(error.code, InterchainErrorCode.contractError);
        expect(error.message, contains('num_tokens'));
      }
    });

    test('smartQuery leaves cancellation and the reads gate alone', () async {
      for (final code in [
        InterchainErrorCode.aborted,
        InterchainErrorCode.readsDisabled,
      ]) {
        final stub = _StubLcd((_) => throw InterchainError(code, 'stop'));
        await expectLater(
          smartQuery(stub, collection, {'num_tokens': <String, Object?>{}}),
          _throwsCode(code),
        );
      }
    });
  });

  /* ------------------------------------------------------------------ *
   * Token id lists
   * ------------------------------------------------------------------ */

  group('token id lists', () {
    test('listOwnedTokenIds sends the spec query and reports a cursor',
        () async {
      final stub = _StubLcd((_) => {'tokens': ['1', '2', '3']});
      final page = await listOwnedTokenIds(_ctx(stub), collection, owner,
          limit: 3);

      expect(stub.calls.first.query, {
        'tokens': {'owner': owner, 'limit': 3},
      });
      expect(page.tokenIds, ['1', '2', '3']);
      // A full page means there may be another.
      expect(page.nextStartAfter, '3');
    });

    test('listOwnedTokenIds omits start_after until there is a cursor',
        () async {
      final stub = _StubLcd((_) => {'tokens': ['9']});
      await listOwnedTokenIds(_ctx(stub), collection, owner,
          limit: 3, startAfter: '8');
      expect(stub.calls.first.query, {
        'tokens': {'owner': owner, 'start_after': '8', 'limit': 3},
      });
    });

    test('listOwnedTokenIds clamps the page size', () async {
      final stub = _StubLcd((_) => {'tokens': <Object?>[]});
      await listOwnedTokenIds(_ctx(stub), collection, owner, limit: 5000);
      await listOwnedTokenIds(_ctx(stub), collection, owner, limit: 0);
      await listOwnedTokenIds(_ctx(stub), collection, owner);

      final limits = stub.calls
          .map((call) => (call.query['tokens']! as Map)['limit'])
          .toList();
      expect(limits, [100, 1, 30]);
    });

    test('listOwnedTokenIds drops non-string entries and rejects a broken body',
        () async {
      final mixed = _StubLcd((_) => {
            'tokens': <Object?>['a', 7, null, {'id': 'x'}, 'b'],
          });
      final page = await listOwnedTokenIds(_ctx(mixed), collection, owner);
      expect(page.tokenIds, ['a', '7', 'b']);

      for (final body in <Object?>[
        <String, Object?>{},
        <String, Object?>{'tokens': '1'},
        <String, Object?>{'tokens': null},
        <Object?>[],
        'nope',
      ]) {
        final stub = _StubLcd((_) => body);
        await expectLater(
          listOwnedTokenIds(_ctx(stub), collection, owner),
          _throwsCode(InterchainErrorCode.malformedResponse),
        );
      }
    });

    test('listAllTokenIds uses all_tokens, not tokens', () async {
      final stub = _StubLcd((_) => {'tokens': ['1']});
      await listAllTokenIds(_ctx(stub), collection, limit: 2);
      expect(stub.calls.first.query, {
        'all_tokens': {'limit': 2},
      });
    });

    test('listAllOwnedTokenIds pages until the contract runs out', () async {
      final pages = [
        ['1', '2'],
        ['3', '4'],
        ['5'],
      ];
      var index = 0;
      final stub = _StubLcd(
        (_) => {'tokens': index < pages.length ? pages[index++] : <String>[]},
      );

      final result =
          await listAllOwnedTokenIds(_ctx(stub), collection, owner, limit: 2);
      expect(result.tokenIds, ['1', '2', '3', '4', '5']);
      expect(result.truncated, isFalse);
      expect(stub.calls.length, 3);
    });

    test('listAllOwnedTokenIds stops at the cap and says so', () async {
      var next = 0;
      final stub = _StubLcd((_) => {
            'tokens': ['${++next}', '${++next}', '${++next}'],
          });
      final result = await listAllOwnedTokenIds(
        _ctx(stub),
        collection,
        owner,
        limit: 3,
        maxTokens: 5,
      );
      expect(result.tokenIds, ['1', '2', '3', '4', '5']);
      expect(result.truncated, isTrue);
    });

    test('listAllOwnedTokenIds refuses to loop on a repeated page', () async {
      // A full page of the same ids means the cursor never advances. Without
      // the guard this runs until the page budget, hammering a public LCD.
      final stub = _StubLcd((_) => {'tokens': ['same', 'same']});
      final result = await listAllOwnedTokenIds(
        _ctx(stub),
        collection,
        owner,
        limit: 2,
        maxTokens: 50,
      );
      expect(result.tokenIds, ['same']);
      expect(result.truncated, isTrue);
      expect(stub.calls.length, 2);
    });
  });

  /* ------------------------------------------------------------------ *
   * Token detail
   * ------------------------------------------------------------------ */

  group('token detail', () {
    test('getNftInfo parses token_uri and the on-chain extension', () async {
      final stub = _StubLcd((_) => {
            'token_uri': 'ipfs://QmHash/1.json',
            'extension': {
              'name': 'Zebra #1',
              'description': 'on chain',
              'image': 'ipfs://QmImage',
              'animation_url': 'ipfs://QmAnim',
              'external_url': 'https://example.test',
              'attributes': [
                {
                  'trait_type': 'Coat',
                  'value': 'Striped',
                  'display_type': 'string',
                },
              ],
            },
          });

      final info = await getNftInfo(_ctx(stub), collection, '1');
      expect(stub.calls.first.query, {
        'nft_info': {'token_id': '1'},
      });
      expect(info.tokenUri, 'ipfs://QmHash/1.json');
      expect(info.metadata.name, 'Zebra #1');
      expect(info.metadata.externalUrl, 'https://example.test');
      expect(info.metadata.attributes, const [
        NftAttribute(
          traitType: 'Coat',
          value: 'Striped',
          displayType: 'string',
        ),
      ]);
    });

    test('getNftInfo tolerates a token with no metadata at all', () async {
      final stub = _StubLcd((_) => {'token_uri': null, 'extension': null});
      final info = await getNftInfo(_ctx(stub), collection, '1');
      expect(info.tokenUri, isNull);
      expect(info.metadata.name, isNull);
      expect(info.metadata.attributes, isEmpty);
    });

    test('getNftInfo rejects a non-object reply', () async {
      for (final body in <Object?>['nope', 5, <Object?>[]]) {
        final stub = _StubLcd((_) => body);
        await expectLater(
          getNftInfo(_ctx(stub), collection, '1'),
          _throwsCode(InterchainErrorCode.malformedResponse),
        );
      }
    });

    test('getOwnerOf parses approvals and their expirations', () async {
      final stub = _StubLcd((_) => {
            'owner': owner,
            'approvals': <Object?>[
              {
                'spender': recipient,
                'expires': {'at_height': 1234},
              },
              {
                'spender': collection,
                'expires': {'at_time': '1700000000000000000'},
              },
              {
                'spender': bridge,
                'expires': {'never': <String, Object?>{}},
              },
              {
                'spender': bridge,
                'expires': {'some_future_variant': <String, Object?>{}},
              },
              {
                'expires': {'never': <String, Object?>{}},
              },
              'garbage',
            ],
          });

      final ownership = await getOwnerOf(
        _ctx(stub),
        collection,
        '1',
        includeExpired: true,
      );
      expect(stub.calls.first.query, {
        'owner_of': {'token_id': '1', 'include_expired': true},
      });
      expect(ownership.owner, owner);
      expect(ownership.approvals.length, 4);
      expect(ownership.approvals[0].expiresAtHeight, '1234');
      expect(ownership.approvals[1].expiresAtTimeNanos, '1700000000000000000');
      expect(ownership.approvals[2].neverExpires, isTrue);
      // An unknown expiration variant is described as "we do not know", not
      // dropped.
      expect(ownership.approvals[3].neverExpires, isFalse);
      expect(ownership.approvals[3].expiresAtHeight, isNull);
    });

    test('getOwnerOf omits include_expired when the caller did not ask',
        () async {
      final stub =
          _StubLcd((_) => {'owner': owner, 'approvals': <Object?>[]});
      await getOwnerOf(_ctx(stub), collection, '1');
      expect(stub.calls.first.query, {
        'owner_of': {'token_id': '1'},
      });
    });

    test('getOwnerOf rejects a reply with no owner', () async {
      for (final body in <Object?>[
        <String, Object?>{},
        <String, Object?>{'owner': ''},
        <String, Object?>{'owner': 7},
        null,
      ]) {
        final stub = _StubLcd((_) => body);
        await expectLater(
          getOwnerOf(_ctx(stub), collection, '1'),
          _throwsCode(InterchainErrorCode.malformedResponse),
        );
      }
    });

    test('getAllNftInfo splits access from info', () async {
      final stub = _StubLcd((_) => {
            'access': {'owner': owner, 'approvals': <Object?>[]},
            'info': {
              'token_uri': 'https://meta.test/1',
              'extension': {'name': 'One'},
            },
          });
      final all = await getAllNftInfo(_ctx(stub), collection, '1');
      expect(stub.calls.first.query, {
        'all_nft_info': {'token_id': '1'},
      });
      expect(all.access.owner, owner);
      expect(all.info.tokenUri, 'https://meta.test/1');
      expect(all.info.metadata.name, 'One');
    });

    test('getAllNftInfo rejects a half-formed reply', () async {
      for (final body in <Object?>[
        {
          'access': {'owner': owner},
        },
        {'info': <String, Object?>{}},
        {'access': <String, Object?>{}, 'info': <String, Object?>{}},
      ]) {
        final stub = _StubLcd((_) => body);
        await expectLater(
          getAllNftInfo(_ctx(stub), collection, '1'),
          _throwsCode(InterchainErrorCode.malformedResponse),
        );
      }
    });

    test('getNumTokens accepts a number or a stringified uint', () async {
      expect(
        await getNumTokens(_ctx(_StubLcd((_) => {'count': 42})), collection),
        42,
      );
      expect(
        await getNumTokens(_ctx(_StubLcd((_) => {'count': '42'})), collection),
        42,
      );

      for (final body in <Object?>[
        <String, Object?>{},
        <String, Object?>{'count': -1},
        <String, Object?>{'count': 'x'},
        <String, Object?>{'count': 1.5},
        null,
      ]) {
        final stub = _StubLcd((_) => body);
        await expectLater(
          getNumTokens(_ctx(stub), collection),
          _throwsCode(InterchainErrorCode.malformedResponse),
        );
      }
    });

    test('getNftToken builds a token without touching token_uri', () async {
      final stub = _StubLcd((_) => {
            'access': {'owner': owner, 'approvals': <Object?>[]},
            'info': {
              'token_uri': 'ipfs://QmHash/1.json',
              'extension': {'name': 'Zebra', 'image': 'ipfs://QmImage'},
            },
          });
      final token = await getNftToken(_ctx(stub), collection, '7');
      expect(stub.calls.length, 1, reason: 'one round trip, not two');
      expect(token.tokenId, '7');
      expect(token.name, 'Zebra');
      expect(token.description, isNull);
      expect(token.imageUri, 'ipfs://QmImage');
      expect(token.animationUri, isNull);
      expect(token.attributes, isEmpty);
      expect(token.collectionAddress, collection);
      expect(token.chainId, safro.chainId);
      expect(token.owner, owner);
      expect(token.tokenUri, 'ipfs://QmHash/1.json');
    });
  });

  /* ------------------------------------------------------------------ *
   * Collection info
   * ------------------------------------------------------------------ */

  group('collection info', () {
    test('prefers collection_info', () async {
      final stub = _StubLcd((call) => call.action == 'num_tokens'
          ? {'count': 3}
          : {
              'name': 'Zebras',
              'symbol': 'ZEB',
              'extension': {'description': 'd', 'creator': owner},
            });

      final info = await getCollectionInfo(_ctx(stub), collection);
      expect(stub.calls.first.action, 'collection_info');
      expect(info.chainId, safro.chainId);
      expect(info.contractAddress, collection);
      expect(info.name, 'Zebras');
      expect(info.symbol, 'ZEB');
      expect(info.description, 'd');
      expect(info.imageUri, isNull);
      expect(info.tokenCount, 3);
      expect(info.creator, owner);
    });

    test('falls back to contract_info on older contracts', () async {
      final stub = _StubLcd((call) {
        if (call.action == 'collection_info') {
          throw InterchainError(
            InterchainErrorCode.lcdUnreachable,
            'HTTP 400',
            httpStatus: 400,
          );
        }
        if (call.action == 'num_tokens') return {'count': 1};
        return {'name': 'Old', 'symbol': 'OLD'};
      });

      final info = await getCollectionInfo(_ctx(stub), collection);
      expect(
        stub.calls.map((call) => call.action).toList(),
        ['collection_info', 'contract_info', 'num_tokens'],
      );
      expect(info.name, 'Old');
      expect(info.description, isNull);
    });

    test('reports contract-error when neither spelling works', () async {
      final stub = _StubLcd((_) => throw InterchainError(
            InterchainErrorCode.lcdUnreachable,
            'HTTP 400',
            httpStatus: 400,
          ));
      try {
        await getCollectionInfo(_ctx(stub), collection);
        fail('expected contractError');
      } on InterchainError catch (error) {
        expect(error.code, InterchainErrorCode.contractError);
        expect(error.message, contains('neither collection_info nor contract_info'));
      }
    });

    test('does not swallow a genuinely unreachable node', () async {
      final stub = _StubLcd((_) => throw InterchainError(
            InterchainErrorCode.lcdUnreachable,
            'timed out',
          ));
      await expectLater(
        getCollectionInfo(_ctx(stub), collection),
        _throwsCode(InterchainErrorCode.lcdUnreachable),
      );
    });

    test('leaves tokenCount null when num_tokens fails', () async {
      final stub = _StubLcd((call) {
        if (call.action == 'num_tokens') {
          throw InterchainError(
            InterchainErrorCode.lcdUnreachable,
            'HTTP 400',
            httpStatus: 400,
          );
        }
        return {'name': 'Zebras', 'symbol': 'ZEB'};
      });
      final info = await getCollectionInfo(_ctx(stub), collection);
      expect(info.tokenCount, isNull);
    });

    test('can skip the extra num_tokens round trip', () async {
      final stub = _StubLcd((_) => {'name': 'Zebras', 'symbol': 'ZEB'});
      final info = await getCollectionInfo(
        _ctx(stub),
        collection,
        includeTokenCount: false,
      );
      expect(stub.calls.length, 1);
      expect(info.tokenCount, isNull);
    });

    test('rejects a non-object payload', () async {
      final stub = _StubLcd((call) => call.action == 'num_tokens'
          ? {'count': 0}
          : const _Raw(<String, Object?>{'data': 5}));
      await expectLater(
        getCollectionInfo(_ctx(stub), collection),
        _throwsCode(InterchainErrorCode.malformedResponse),
      );
    });
  });

  /* ------------------------------------------------------------------ *
   * Metadata parsing
   * ------------------------------------------------------------------ */

  group('metadata parsing', () {
    test('parseNftMetadata never throws on junk', () {
      for (final body in <Object?>[null, 5, 'text', <Object?>[], true]) {
        final parsed = parseNftMetadata(body);
        expect(parsed.name, isNull);
        expect(parsed.attributes, isEmpty);
      }
    });

    test('coerces attribute values instead of dropping traits', () {
      final parsed = parseNftMetadata({
        'name': '',
        'attributes': <Object?>[
          {'trait_type': 'Level', 'value': 7},
          {'trait_type': 'Shiny', 'value': true},
          {'trait_type': 'Missing', 'value': null},
          {'value': 'no trait type'},
          {
            'trait_type': 'Nested',
            'value': {'a': 1},
          },
          'not an object',
          {'trait_type': 'NoValue'},
        ],
      });
      // An empty string is the same as absent for a display name.
      expect(parsed.name, isNull);
      expect(parsed.attributes, const [
        NftAttribute(traitType: 'Level', value: '7'),
        NftAttribute(traitType: 'Shiny', value: 'true'),
        NftAttribute(traitType: 'Missing', value: ''),
        NftAttribute(traitType: '', value: 'no trait type'),
        NftAttribute(traitType: 'Nested', value: '{"a":1}'),
        NftAttribute(traitType: 'NoValue', value: ''),
      ]);
    });

    test('ignores a non-array attributes field', () {
      expect(
        parseNftMetadata({
          'attributes': {'a': 1},
        }).attributes,
        isEmpty,
      );
      expect(parseNftMetadata({'attributes': 'none'}).attributes, isEmpty);
    });

    test('applyNftMetadata fills gaps without overwriting on-chain values', () {
      const token = NftToken(
        tokenId: '1',
        name: 'On chain',
        collectionAddress: collection,
        chainId: 'safrochain-1',
        owner: owner,
        tokenUri: 'ipfs://Qm',
      );
      final merged = applyNftMetadata(
        token,
        const NftMetadata(
          name: 'Off chain',
          description: 'from the host',
          image: 'https://img.test/1.png',
          attributes: [NftAttribute(traitType: 'Coat', value: 'Striped')],
        ),
      );
      expect(merged.name, 'On chain');
      expect(merged.description, 'from the host');
      expect(merged.imageUri, 'https://img.test/1.png');
      expect(merged.attributes.length, 1);
    });
  });

  /* ------------------------------------------------------------------ *
   * token_uri resolution
   * ------------------------------------------------------------------ */

  group('resolveTokenUri', () {
    test('maps ipfs:// onto every configured gateway', () {
      final resolved = resolveTokenUri(
        'ipfs://QmHash/meta/1.json',
        ipfsGateways: const ['https://a.test/ipfs/', 'https://b.test/ipfs'],
      );
      expect(resolved.kind, ResolvedTokenUriKind.http);
      expect(resolved.urls, [
        'https://a.test/ipfs/QmHash/meta/1.json',
        'https://b.test/ipfs/QmHash/meta/1.json',
      ]);
    });

    test('strips a duplicated ipfs/ segment', () {
      final resolved = resolveTokenUri(
        'ipfs://ipfs/QmHash/1.json',
        ipfsGateways: const ['https://a.test/ipfs/'],
      );
      expect(resolved.urls, ['https://a.test/ipfs/QmHash/1.json']);
    });

    test('treats a bare CID as IPFS', () {
      const cid = 'QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG';
      final resolved =
          resolveTokenUri(cid, ipfsGateways: const ['https://a.test/ipfs']);
      expect(resolved.urls, ['https://a.test/ipfs/$cid']);
    });

    test('refuses ipfs with no gateway configured', () {
      final resolved = resolveTokenUri('ipfs://QmHash');
      expect(resolved.kind, ResolvedTokenUriKind.unsupported);
      expect(resolved.reason, contains('gateway'));
    });

    test('allows https and blocks http unless asked', () {
      expect(
        resolveTokenUri('https://meta.test/1').urls,
        ['https://meta.test/1'],
      );

      final blocked = resolveTokenUri('http://meta.test/1');
      expect(blocked.kind, ResolvedTokenUriKind.unsupported);
      expect(blocked.reason, contains('http'));

      final allowed =
          resolveTokenUri('http://meta.test/1', allowInsecureHttp: true);
      expect(allowed.urls, ['http://meta.test/1']);
    });

    test('decodes data: URIs locally', () {
      const json = '{"name":"Inline"}';
      final b64 = resolveTokenUri(
        'data:application/json;base64,${base64.encode(utf8.encode(json))}',
      );
      expect(b64.kind, ResolvedTokenUriKind.inline);
      expect(b64.inline, json);

      final plain = resolveTokenUri(
        'data:application/json,${Uri.encodeComponent(json)}',
      );
      expect(plain.kind, ResolvedTokenUriKind.inline);
      expect(plain.inline, json);

      expect(
        resolveTokenUri('data:application/json;base64,!!!!').kind,
        ResolvedTokenUriKind.unsupported,
      );
    });

    test('rejects empty and unknown schemes', () {
      expect(resolveTokenUri('   ').kind, ResolvedTokenUriKind.unsupported);
      expect(
        resolveTokenUri('ftp://meta.test/1').kind,
        ResolvedTokenUriKind.unsupported,
      );
      expect(resolveTokenUri('ar://tx').kind, ResolvedTokenUriKind.unsupported);
      expect(
        resolveTokenUri('ar://tx', arweaveGateways: const ['https://ar.test'])
            .urls,
        ['https://ar.test/tx'],
      );
    });
  });

  /* ------------------------------------------------------------------ *
   * Metadata fetching (the privacy opt-in)
   * ------------------------------------------------------------------ */

  group('fetchNftMetadata', () {
    test('reads a data: URI with no fetcher and no network', () async {
      final uri = 'data:application/json;base64,'
          '${base64.encode(utf8.encode('{"name":"Inline"}'))}';
      final result = await fetchNftMetadata(uri);
      expect(result.source, NftMetadataSource.inline);
      expect(result.url, isNull);
      expect(result.metadata.name, 'Inline');
    });

    test('refuses a remote read when no fetcher was supplied', () async {
      // The privacy gate: without a transport there is nothing to leak through.
      try {
        await fetchNftMetadata('https://meta.test/1');
        fail('expected readsDisabled');
      } on InterchainError catch (error) {
        expect(error.code, InterchainErrorCode.readsDisabled);
        expect(error.message, contains('fetcher'));
      }
    });

    test('tries each gateway in order', () async {
      final seen = <String>[];
      final result = await fetchNftMetadata(
        'ipfs://QmHash/1.json',
        ipfsGateways: const ['https://a.test/ipfs', 'https://b.test/ipfs'],
        fetch: (url) async {
          seen.add(url);
          if (url.startsWith('https://a.test')) throw StateError('502');
          return {'name': 'Second gateway'};
        },
      );
      expect(seen, [
        'https://a.test/ipfs/QmHash/1.json',
        'https://b.test/ipfs/QmHash/1.json',
      ]);
      expect(result.source, NftMetadataSource.remote);
      expect(result.url, 'https://b.test/ipfs/QmHash/1.json');
      expect(result.metadata.name, 'Second gateway');
    });

    test('reports lcdUnreachable when every gateway fails', () async {
      await expectLater(
        fetchNftMetadata(
          'ipfs://QmHash',
          ipfsGateways: const ['https://a.test/ipfs'],
          fetch: (_) async => throw StateError('nope'),
        ),
        _throwsCode(InterchainErrorCode.lcdUnreachable),
      );
    });

    test('surfaces an unresolvable token_uri as malformed', () async {
      await expectLater(
        fetchNftMetadata('ftp://meta.test/1'),
        _throwsCode(InterchainErrorCode.malformedResponse),
      );
      await expectLater(
        fetchNftMetadata('data:application/json;base64,!!!'),
        _throwsCode(InterchainErrorCode.malformedResponse),
      );
    });

    test('does not fail on a body that is not a metadata document', () async {
      final result = await fetchNftMetadata(
        'https://meta.test/1',
        fetch: (_) async => 'just a string',
      );
      expect(result.metadata.name, isNull);
      expect(result.metadata.attributes, isEmpty);
    });
  });

  /* ------------------------------------------------------------------ *
   * Discovery
   * ------------------------------------------------------------------ */

  group('discoverNfts', () {
    test('scans a known contract list and admits it is partial', () async {
      final stub = _StubLcd(
        (call) => {'tokens': call.contract == a ? ['1', '2'] : <String>[]},
      );
      final result = await discoverNfts(
        _ctx(stub),
        owner,
        options: const NftDiscoveryOptions(knownContracts: [a, b]),
      );

      expect(result.holdings.length, 1);
      expect(result.holdings.first.contractAddress, a);
      expect(result.holdings.first.source, NftDiscoverySource.known);
      expect(result.holdings.first.tokenIds, ['1', '2']);
      expect(result.complete, isFalse);
      expect(result.limitation, nftDiscoveryLimitation);
      expect(result.issues, isEmpty);
    });

    test('marks a run complete only when an indexer answered', () async {
      final stub = _StubLcd((_) => {'tokens': ['1']});
      final result = await discoverNfts(
        _ctx(stub),
        owner,
        options: NftDiscoveryOptions(indexer: _FakeIndexer(const [a])),
      );

      expect(result.complete, isTrue);
      expect(result.limitation, isNull);
      expect(result.sources, [NftDiscoverySource.indexer]);
    });

    test('records an indexer failure instead of hiding it', () async {
      final stub = _StubLcd((_) => {'tokens': ['1']});
      final result = await discoverNfts(
        _ctx(stub),
        owner,
        options: NftDiscoveryOptions(
          indexer: _FakeIndexer(const [], error: '503 from the index'),
          knownContracts: const [a],
        ),
      );

      expect(result.complete, isFalse);
      expect(result.issues.length, 1);
      expect(result.issues.first.contractAddress, isNull);
      expect(result.issues.first.message, contains('test-indexer'));
      expect(result.issues.first.message, contains('503'));
      // The known-contract path still ran.
      expect(result.holdings.length, 1);
    });

    test('records a per-contract failure and keeps going', () async {
      final stub = _StubLcd((call) {
        if (call.contract == a) {
          throw InterchainError(
            InterchainErrorCode.contractError,
            'not a cw721',
          );
        }
        return {'tokens': ['9']};
      });
      final result = await discoverNfts(
        _ctx(stub),
        owner,
        options: const NftDiscoveryOptions(knownContracts: [a, b]),
      );

      expect(result.holdings.length, 1);
      expect(result.holdings.first.contractAddress, b);
      expect(result.issues.length, 1);
      expect(result.issues.first.contractAddress, a);
    });

    test('always probes a user-supplied contract, cap or not', () async {
      final stub = _StubLcd(
        (call) => {'tokens': call.contract == c ? ['1'] : <String>[]},
      );
      final result = await discoverNfts(
        _ctx(stub),
        owner,
        options: const NftDiscoveryOptions(
          knownContracts: [a, b],
          userContracts: [c],
          maxContracts: 1,
        ),
      );

      expect(stub.calls.map((call) => call.contract).toList(), [a, c]);
      expect(result.holdings.first.source, NftDiscoverySource.user);
    });

    test('labels a contract the user re-added as theirs', () async {
      final stub = _StubLcd((_) => {'tokens': ['1']});
      final result = await discoverNfts(
        _ctx(stub),
        owner,
        options: const NftDiscoveryOptions(
          knownContracts: [a],
          userContracts: [a],
        ),
      );
      expect(stub.calls.length, 1,
          reason: 'the same address must not be probed twice');
      expect(result.holdings.first.source, NftDiscoverySource.user);
    });

    test('refuses a chain without cosmwasm', () async {
      final stub = _StubLcd((_) => {'tokens': <String>[]});
      await expectLater(
        discoverNfts(
          _ctx(stub, noWasm),
          owner,
          options: const NftDiscoveryOptions(knownContracts: [a]),
        ),
        _throwsCode(InterchainErrorCode.unsupportedChain),
      );
      expect(stub.calls, isEmpty,
          reason: 'the gate must run before any request');
    });
  });

  /* ------------------------------------------------------------------ *
   * Message building
   * ------------------------------------------------------------------ */

  group('message building', () {
    test('buildTransferNftMsg produces the spec transfer_nft', () {
      final built = buildTransferNftMsg(
        safro,
        sender: owner,
        collectionAddress: collection,
        tokenId: '42',
        recipient: recipient,
      );
      expect(built.contract, collection,
          reason: 'executed against the collection');
      expect(built.sender, owner);
      expect(built.msg, {
        'transfer_nft': {'recipient': recipient, 'token_id': '42'},
      });
      expect(built.action, 'transfer_nft');
    });

    test('buildTransferNftMsg refuses a chain without cosmwasm and an empty id',
        () {
      expect(
        () => buildTransferNftMsg(
          noWasm,
          sender: owner,
          collectionAddress: collection,
          tokenId: '1',
          recipient: recipient,
        ),
        _throwsCode(InterchainErrorCode.unsupportedChain),
      );
      expect(
        () => buildTransferNftMsg(
          safro,
          sender: owner,
          collectionAddress: collection,
          tokenId: '',
          recipient: recipient,
        ),
        _throwsCode(InterchainErrorCode.contractError),
      );
    });

    test('buildSendNftMsg base64s the inner payload exactly once', () {
      final built = buildSendNftMsg(
        safro,
        sender: owner,
        collectionAddress: collection,
        tokenId: '7',
        contract: bridge,
        msg: const {'hello': 'world'},
      );

      final send = built.msg['send_nft']! as Map<String, Object?>;
      expect(send['contract'], bridge);
      expect(send['token_id'], '7');
      // The inner msg is a cosmwasm Binary: base64 of the JSON, nothing else.
      expect(send['msg'], base64.encode(utf8.encode('{"hello":"world"}')));
      expect(_innerMsgOf(built), {'hello': 'world'});
    });
  });

  /* ------------------------------------------------------------------ *
   * ICS721
   * ------------------------------------------------------------------ */

  group('ICS721', () {
    DateTime fixedNow() => DateTime.fromMillisecondsSinceEpoch(1700000000000);

    test('sends the NFT to the bridge with receiver and channel_id', () {
      final built = buildIcs721TransferMsg(
        safro,
        _ics721Request(timeoutMinutes: 5),
        destChain: osmosis,
        now: fixedNow,
      );

      final send = built.msg['send_nft']! as Map<String, Object?>;
      expect(built.contract, collection, reason: 'executed on the collection');
      expect(send['contract'], bridge, reason: 'targeting the ics721 bridge');

      final outgoing = _innerMsgOf(built);
      expect(outgoing['receiver'], osmoRecipient);
      expect(outgoing['channel_id'], 'channel-12');
      // Nanoseconds, computed with BigInt so nothing is lost above 2^53.
      expect(outgoing['timeout'], {'timestamp': '1700000300000000000'});
      expect(outgoing.containsKey('memo'), isFalse,
          reason: 'an absent memo is omitted, not null');
    });

    test('defaults the timeout rather than omitting it', () {
      final outgoing = _innerMsgOf(
        buildIcs721TransferMsg(safro, _ics721Request(), now: fixedNow),
      );
      final expected = (BigInt.from(
                  1700000000000 + defaultIcs721TimeoutMinutes * 60000) *
              BigInt.from(1000000))
          .toString();
      expect(outgoing['timeout'], {'timestamp': expected});
    });

    test('passes a memo through and accepts a timeout override', () {
      final outgoing = _innerMsgOf(
        buildIcs721TransferMsg(
          safro,
          _ics721Request(memo: 'hello'),
          timeout: const {
            'block': {'revision': 1, 'height': 100},
          },
        ),
      );
      expect(outgoing['memo'], 'hello');
      expect(outgoing['timeout'], {
        'block': {'revision': 1, 'height': 100},
      });
    });

    test('needs a bridge, a channel and a matching chain', () {
      expect(
        () => buildIcs721TransferMsg(
          safro,
          _ics721Request(bridgeContract: null),
        ),
        _throwsCode(InterchainErrorCode.unsupportedChain),
      );
      expect(
        () => buildIcs721TransferMsg(safro, _ics721Request(channelId: null)),
        _throwsCode(InterchainErrorCode.unsupportedChain),
      );
      expect(
        () => buildIcs721TransferMsg(safro, _ics721Request(chainId: 'other-1')),
        _throwsCode(InterchainErrorCode.unsupportedChain),
      );
      expect(
        () => buildIcs721TransferMsg(
          noWasm,
          _ics721Request(chainId: 'nowasm-1'),
        ),
        _throwsCode(InterchainErrorCode.unsupportedChain),
      );
      expect(
        () => buildIcs721TransferMsg(
          safro,
          _ics721Request(recipientOverride: ''),
        ),
        _throwsCode(InterchainErrorCode.contractError),
      );
    });

    test('checks the receiver against the destination, not the source', () {
      // An osmo1 receiver is correct here and must not be rejected by the
      // source chain's prefix.
      expect(
        buildIcs721TransferMsg(safro, _ics721Request(), destChain: osmosis)
            .action,
        'send_nft',
      );
      expect(
        () => buildIcs721TransferMsg(
          safro,
          _ics721Request(recipientOverride: recipient),
          destChain: osmosis,
        ),
        _throwsCode(InterchainErrorCode.contractError),
      );
    });

    test('supportsIcs721 is host configuration, not a registry feature', () {
      expect(supportsIcs721(safro, _ics721Request()), isTrue);
      expect(
        supportsIcs721(safro, _ics721Request(bridgeContract: null)),
        isFalse,
      );
      expect(supportsIcs721(safro, _ics721Request(channelId: null)), isFalse);
      expect(supportsIcs721(noWasm, _ics721Request()), isFalse);
    });

    test('warnings always lead with the voucher warning', () {
      final warnings = ics721TransferWarnings(_ics721Request(timeoutMinutes: 5));
      expect(warnings.first, ics721VoucherWarning);
      expect(warnings.length, 1);

      final vague = ics721TransferWarnings(_ics721Request(destChainId: null));
      expect(vague.length, 3);
      expect(vague.join(' '), contains('receiver address was not checked'));
    });

    test('buildNftTransferMsg picks transfer_nft or ICS721 from destChainId',
        () {
      final sameChain = buildNftTransferMsg(
        safro,
        const NftTransferRequest(
          chainId: 'safrochain-1',
          collectionAddress: collection,
          tokenId: '1',
          sender: owner,
          recipient: recipient,
        ),
      );
      expect(sameChain.msg.containsKey('transfer_nft'), isTrue);

      final explicit = buildNftTransferMsg(
        safro,
        const NftTransferRequest(
          chainId: 'safrochain-1',
          destChainId: 'safrochain-1',
          collectionAddress: collection,
          tokenId: '1',
          sender: owner,
          recipient: recipient,
        ),
      );
      expect(explicit.msg.containsKey('transfer_nft'), isTrue);

      final crossChain =
          buildNftTransferMsg(safro, _ics721Request(), destChain: osmosis);
      expect(crossChain.msg.containsKey('send_nft'), isTrue);
    });
  });

  /* ------------------------------------------------------------------ *
   * Decoding what will be signed (no TS twin)
   * ------------------------------------------------------------------ */

  group('inspectNftExecute', () {
    test('names the token, the collection and the new owner', () {
      final built = buildTransferNftMsg(
        safro,
        sender: owner,
        collectionAddress: collection,
        tokenId: '42',
        recipient: recipient,
      );
      final read = inspectNftExecute(built, collectionName: 'Zebras');
      expect(read.kind, NftExecuteKind.transferNft);
      expect(read.readable, isTrue);
      expect(read.tokenId, '42');
      expect(read.recipient, recipient);
      expect(read.summary, contains('42'));
      expect(read.summary, contains('Zebras'));
      expect(read.summary, contains(recipient));
    });

    test('decodes the ICS721 payload out of the bytes, not the intent', () {
      final built = buildIcs721TransferMsg(
        safro,
        _ics721Request(),
        destChain: osmosis,
      );
      final read = inspectNftExecute(built, destChainName: 'Osmosis');
      expect(read.kind, NftExecuteKind.ics721Transfer);
      expect(read.tokenId, '7');
      expect(read.receivingContract, bridge);
      expect(read.recipient, osmoRecipient);
      expect(read.channelId, 'channel-12');
      expect(read.warnings, contains(ics721VoucherWarning));
      expect(read.summary, contains('Osmosis'));
      expect(read.summary, contains('channel-12'));
    });

    test('a send_nft to an unknown contract is described, not summarised away',
        () {
      final built = buildSendNftMsg(
        safro,
        sender: owner,
        collectionAddress: collection,
        tokenId: '7',
        contract: bridge,
        msg: const {'stake': <String, Object?>{}},
      );
      final read = inspectNftExecute(built);
      expect(read.kind, NftExecuteKind.sendNft);
      expect(read.innerMsg, {'stake': <String, Object?>{}});
      expect(read.warnings.single, contains('does not recognise'));
    });

    test('an unreadable message is unknown, never guessed', () {
      const burn = NftExecute(
        sender: owner,
        contract: collection,
        msg: {
          'burn': {'token_id': '1'},
        },
      );
      expect(inspectNftExecute(burn).kind, NftExecuteKind.unknown);
      expect(inspectNftExecute(burn).readable, isFalse);
      expect(inspectNftExecute(burn).summary, contains('burn'));

      const undecodable = NftExecute(
        sender: owner,
        contract: collection,
        msg: {
          'send_nft': {
            'contract': bridge,
            'token_id': '7',
            'msg': '!!!not base64!!!',
          },
        },
      );
      expect(inspectNftExecute(undecodable).kind, NftExecuteKind.unknown);

      const missingRecipient = NftExecute(
        sender: owner,
        contract: collection,
        msg: {
          'transfer_nft': {'token_id': '1'},
        },
      );
      expect(inspectNftExecute(missingRecipient).kind, NftExecuteKind.unknown);
    });
  });
}

/// An [NftIndexer] that answers from a list, or fails on demand.
class _FakeIndexer implements NftIndexer {
  const _FakeIndexer(this.contracts, {this.error});

  final List<String> contracts;
  final String? error;

  @override
  String get name => 'test-indexer';

  @override
  Future<List<String>> listContracts(String chainId, String owner) async {
    final failure = error;
    if (failure != null) throw StateError(failure);
    return contracts;
  }
}
