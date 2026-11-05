/// dApp signatures are the kernel's, over the bytes the chain verifies.
///
/// Three references, none of them this code: the CosmJS signatures in
/// test/fixtures/cosmos-signing-vectors.json, zunia-core's golden sign bytes
/// (tests/vectors/cosmos-signing.json, CosmJS and osmojs) and five amino
/// transactions cosmoshub-4 itself accepted (tests/vectors/chain-verified-amino.json).
library;

import 'dart:convert';
import 'dart:io';

import 'package:bech32/bech32.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';

import '../support/kernel.dart';

const _coreVectors = '../zunia-core/tests/vectors';

Map<String, dynamic>? _coreFile(String name) {
  final file = File('$_coreVectors/$name');
  return file.existsSync() ? jsonDecode(file.readAsStringSync()) as Map<String, dynamic> : null;
}

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/cosmos-signing-vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final accounts = (fixture['accounts'] as List).cast<Map<String, dynamic>>();
  final cosmosSigning = _coreFile('cosmos-signing.json');
  final chainVerified = _coreFile('chain-verified-amino.json');
  final coreSkip = cosmosSigning == null ? 'zunia-core vectors not checked out next to this repo' : false;

  CosmosSigningKey keyFor(String address) {
    final account = accounts.firstWhere((a) => a['address'] == address);
    return CosmosKeyring(fixture['mnemonic'] as String).key(
      coinType: account['coinType'] as int,
      accountIndex: account['accountIndex'] as int,
    );
  }

  group('amino sign bytes', () {
    test('escape & < > and U+2028 U+2029 the way Go writes them', () {
      final bytes = aminoSignBytes({
        'memo': 'a < b & c > d \u2028 e \u2029',
        'b': 1.0,
        'a': [
          {'z': true, 'y': null},
        ],
      });
      expect(
        utf8.decode(bytes),
        r'{"a":[{"y":null,"z":true}],"b":1,"memo":"a \u003c b \u0026 c \u003e d \u2028 e \u2029"}',
      );
    });

    test('match zunia-core goldens byte for byte, every case', () {
      for (final c in (cosmosSigning!['cases'] as List).cast<Map<String, dynamic>>()) {
        final amino = c['amino'] as Map<String, dynamic>;
        final doc = jsonDecode(amino['sign_doc'] as String);
        expect(hexOf(aminoSignBytes(doc)), amino['sign_bytes_hex'], reason: c['name'] as String);
      }
    }, skip: coreSkip);

    test('rebuild what cosmoshub-4 verified, and the chain signature checks', () {
      for (final c in (chainVerified!['cases'] as List).cast<Map<String, dynamic>>()) {
        final message = c['message'] as Map<String, dynamic>;
        final Map<String, dynamic> value;
        final String type;
        if (message['@type'] == '/cosmos.gov.v1beta1.MsgVote') {
          type = 'cosmos-sdk/MsgVote';
          const options = {
            'VOTE_OPTION_YES': 1,
            'VOTE_OPTION_ABSTAIN': 2,
            'VOTE_OPTION_NO': 3,
            'VOTE_OPTION_NO_WITH_VETO': 4,
          };
          value = {
            'option': options[message['option']],
            'proposal_id': message['proposal_id'],
            'voter': message['voter'],
          };
        } else {
          type = 'cosmos-sdk/MsgTransfer';
          final height = message['timeout_height'] as Map<String, dynamic>;
          value = {
            'receiver': message['receiver'],
            'sender': message['sender'],
            'source_channel': message['source_channel'],
            'source_port': message['source_port'],
            'timeout_height': height['revision_height'] == '0' && height['revision_number'] == '0'
                ? <String, dynamic>{}
                : height,
            'timeout_timestamp': message['timeout_timestamp'],
            'token': message['token'],
            if ((message['memo'] as String).isNotEmpty) 'memo': message['memo'],
          };
        }
        final doc = {
          'account_number': c['accountNumber'],
          'chain_id': c['chainId'],
          'fee': c['fee'],
          'memo': c['memo'],
          'msgs': [
            {'type': type, 'value': value},
          ],
          'sequence': c['sequence'],
          if (c['timeoutHeight'] != '0') 'timeout_height': c['timeoutHeight'],
        };
        final bytes = aminoSignBytes(doc);
        expect(hexOf(bytes), c['signBytesHex'], reason: c['name'] as String);
        expect(
          verifySecp256k1Sha256(
            signBytes: bytes,
            publicKey: base64Decode(c['pubKey'] as String),
            signature: base64Decode(c['signature'] as String),
          ),
          isTrue,
          reason: c['name'] as String,
        );
      }
    }, skip: chainVerified == null ? coreSkip : false);
  });

  group('direct sign bytes', () {
    test('match zunia-core goldens, from Connect wire and from a page', () {
      final signer = cosmosSigning!['signer'] as Map<String, dynamic>;
      for (final c in (cosmosSigning['cases'] as List).cast<Map<String, dynamic>>()) {
        final direct = c['direct'] as Map<String, dynamic>;
        final body = bytesOfHex(direct['body_bytes_hex'] as String);
        final authInfo = bytesOfHex(direct['auth_info_bytes_hex'] as String);
        final wire = DirectSignDoc.fromWire({
          'bodyBytes': base64Encode(body),
          'authInfoBytes': base64Encode(authInfo),
          'chainId': signer['chain_id'],
          'accountNumber': '${signer['account_number']}',
        });
        expect(hexOf(wire.signBytes), direct['sign_bytes_hex'], reason: c['name'] as String);
        // A page's Uint8Array arrives as an index-keyed object, its Long as {low, high}.
        final page = DirectSignDoc.fromProvider({
          'bodyBytes': {for (var i = 0; i < body.length; i++) '$i': body[i]},
          'authInfoBytes': authInfo.toList(),
          'chainId': signer['chain_id'],
          'accountNumber': {'low': signer['account_number'], 'high': 0, 'unsigned': true},
        });
        expect(hexOf(page.signBytes), direct['sign_bytes_hex'], reason: c['name'] as String);
      }
    }, skip: coreSkip);

    test('refuses malformed documents', () {
      final good = ((fixture['direct'] as List).first as Map<String, dynamic>)['signDoc']
          as Map<String, dynamic>;
      for (final bad in [
        null,
        {...good, 'accountNumber': '-1'},
        {...good, 'accountNumber': '18446744073709551616'},
        {...good, 'accountNumber': 5},
        {...good, 'bodyBytes': '***'},
        {...good}..remove('chainId'),
      ]) {
        expect(() => DirectSignDoc.fromWire(bad), throwsA(isA<ConnectException>()), reason: '$bad');
      }
      for (final bad in [
        {'chainId': 'x', 'bodyBytes': <int>[], 'authInfoBytes': <int>[]},
        {'chainId': 'x', 'bodyBytes': [256], 'authInfoBytes': <int>[]},
        {'chainId': 'x', 'bodyBytes': 'abcd', 'authInfoBytes': '0xZZ'},
        {'chainId': 'x', 'bodyBytes': [1], 'authInfoBytes': <int>[], 'accountNumber': -1},
        {'bodyBytes': [1], 'authInfoBytes': <int>[]},
      ]) {
        expect(() => DirectSignDoc.fromProvider(bad), throwsA(isA<ConnectException>()), reason: '$bad');
      }
    });
  });

  group('kernel signatures', () {
    // The fixture was made on m/44'/118'/<account>'/0/0, the path the Dart
    // signer this replaced used. The app derives every address at
    // m/44'/118'/0'/0/<index> (the extension's path), so the two agree only for
    // the first account: there the signatures must be CosmJS's byte for byte.
    // The second account's rows were the old bug (a site was shown one address
    // and got signatures from another key); for them the bytes still match and
    // the kernel's own signature must verify.
    bool cosmJsPath(String address) =>
        accounts.firstWhere((a) => a['address'] == address)['accountIndex'] == 0;

    test('derive the CosmJS keys and addresses on the shared path', () {
      final keyring = CosmosKeyring(fixture['mnemonic'] as String);
      for (final a in accounts) {
        final key = keyring.key(coinType: a['coinType'] as int, accountIndex: a['accountIndex'] as int);
        if (a['accountIndex'] == 0) {
          expect(base64Encode(key.publicKey), a['pubKey']);
          expect(key.address(a['prefix'] as String), a['address']);
        } else {
          expect(key.account.path, "m/44'/118'/0'/0/${a['accountIndex']}");
          expect(key.address(a['prefix'] as String), isNot(a['address']));
        }
      }
    }, skip: kernelSkip);

    void expectSigned(String name, String signer, List<int> signBytes, String signature, String expected) {
      final key = keyFor(signer);
      if (cosmJsPath(signer)) {
        expect(signature, expected, reason: name);
      } else {
        expect(
          verifySecp256k1Sha256(signBytes: signBytes, publicKey: key.publicKey, signature: base64Decode(signature)),
          isTrue,
          reason: name,
        );
      }
    }

    test('amino: CosmJS signatures, and the document comes back unchanged', () {
      for (final v in (fixture['amino'] as List).cast<Map<String, dynamic>>()) {
        final signer = v['signer'] as String;
        expect(utf8.decode(aminoSignBytes(v['signDoc'])), v['signBytes'], reason: v['name'] as String);
        final result = signAminoResult(keyFor(signer), v['signDoc']);
        expect(result['signed'], v['signDoc']);
        final signature = result['signature'] as Map<String, Object?>;
        expectSigned(
          v['name'] as String,
          signer,
          aminoSignBytes(v['signDoc']),
          signature['signature'] as String,
          v['signature'] as String,
        );
        expect((signature['pub_key'] as Map)['value'], base64Encode(keyFor(signer).publicKey));
      }
    }, skip: kernelSkip);

    test('direct: CosmJS signatures', () {
      for (final v in (fixture['direct'] as List).cast<Map<String, dynamic>>()) {
        final doc = DirectSignDoc.fromWire(v['signDoc']);
        expect(hexOf(doc.signBytes), v['signBytes']);
        final result = signDirectResult(keyFor(v['signer'] as String), doc);
        expect(result['signed'], v['signDoc']);
        expectSigned(
          v['name'] as String,
          v['signer'] as String,
          doc.signBytes,
          (result['signature'] as Map)['signature'] as String,
          v['signature'] as String,
        );
      }
    }, skip: kernelSkip);

    test('zunia-core goldens: the signature verifies over the golden bytes', () {
      final key = cosmosSigning!['key'] as Map<String, dynamic>;
      final signer = CosmosKeyring(key['mnemonic'] as String).key(coinType: 118, accountIndex: 0);
      expect(hexOf(signer.publicKey), key['pubkey_compressed_hex']);
      expect(signer.address(), (key['addresses'] as Map)['cosmos']);
      expect(signer.address('osmo'), (key['addresses'] as Map)['osmo']);
      for (final c in (cosmosSigning['cases'] as List).cast<Map<String, dynamic>>()) {
        for (final mode in ['amino', 'direct']) {
          final bytes = bytesOfHex((c[mode] as Map)['sign_bytes_hex'] as String);
          final signature = signer.sign(bytes);
          expect(signature, hasLength(64));
          expect(
            verifySecp256k1Sha256(signBytes: bytes, publicKey: signer.publicKey, signature: signature),
            isTrue,
            reason: '${c['name']} $mode',
          );
        }
      }
    }, skip: kernelSkip == false ? coreSkip : kernelSkip);
  });

  group('ADR-036', () {
    test('sign bytes match zunia-core goldens', () {
      final key = cosmosSigning!['key'] as Map<String, dynamic>;
      final address = (key['addresses'] as Map)['cosmos'] as String;
      for (final v in (cosmosSigning['adr36'] as List).cast<Map<String, dynamic>>()) {
        final data = base64Decode(v['data_base64'] as String);
        expect(utf8.decode(adr36SignBytes(address, data)), v['sign_doc']);
        expect(hexOf(adr36SignBytes(address, data)), v['sign_bytes_hex']);
      }
    }, skip: coreSkip);

    test('signatures are CosmJS-identical and verifyAdr36 accepts only them', () {
      for (final v in (fixture['adr36'] as List).cast<Map<String, dynamic>>()) {
        final data = v['encoding'] == 'utf8'
            ? utf8.encode(v['data'] as String)
            : base64Decode(v['data'] as String);
        final key = keyFor(v['signer'] as String);
        final signature = signArbitraryResult(key, v['signer'] as String, data);
        if (accounts.firstWhere((a) => a['address'] == v['signer'])['accountIndex'] == 0) {
          expect(signature['signature'], v['signature'], reason: v['name'] as String);
        }
        final sig = base64Decode(signature['signature'] as String);
        expect(
          verifyAdr36(signer: v['signer'] as String, data: data, publicKey: key.publicKey, signature: sig),
          isTrue,
        );
        // Other data, another signer, a flipped bit: false, never a throw.
        expect(
          verifyAdr36(signer: v['signer'] as String, data: [...data, 1], publicKey: key.publicKey, signature: sig),
          isFalse,
        );
        expect(
          verifyAdr36(
            signer: accounts.firstWhere((a) => a['address'] != v['signer'])['address'] as String,
            data: data,
            publicKey: key.publicKey,
            signature: sig,
          ),
          isFalse,
        );
        final flipped = [...sig]..[10] ^= 1;
        expect(
          verifyAdr36(signer: v['signer'] as String, data: data, publicKey: key.publicKey, signature: flipped),
          isFalse,
        );
        expect(
          verifyAdr36(signer: v['signer'] as String, data: data, publicKey: [1, 2, 3], signature: sig),
          isFalse,
        );
      }
    }, skip: kernelSkip);

    test('a transaction dressed up as a message is not safe to sign', () {
      final tx = utf8.encode(jsonEncode({'chain_id': 'x', 'fee': {}, 'msgs': []}));
      expect(adr36PayloadIsSafe(tx), isFalse);
      expect(adr36PayloadIsSafe(utf8.encode('hello')), isTrue);
      expect(adr36PayloadIsSafe([0xff, 0xfe]), isTrue);
      expect(adr36PayloadIsSafe(utf8.encode('{"msgs":[]}')), isTrue);
    });
  });

  test('Ethereum-style addresses get their EIP-55 hex form', () {
    // 20 bytes of 0x5aAeb6...: the EIP-55 specification's own example.
    final injective = _bech32Of('inj', bytesOfHex('5aaeb6053f3e94c9b9a09f33669435e7ef1beaed'));
    expect(ethereumHexAddress(injective), '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed');
    expect(rebech32(injective, 'evmos'), startsWith('evmos1'));
    expect(bech32Bytes(rebech32(injective, 'evmos')), bytesOfHex('5aaeb6053f3e94c9b9a09f33669435e7ef1beaed'));
  });
}

String _bech32Of(String prefix, List<int> bytes) {
  final words = <int>[];
  var acc = 0;
  var bits = 0;
  for (final b in bytes) {
    acc = (acc << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      words.add((acc >> bits) & 31);
    }
  }
  if (bits > 0) words.add((acc << (5 - bits)) & 31);
  return bech32.encode(Bech32(prefix, words));
}
