import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';

/// Signatures CosmJS produced from a public test mnemonic. A dApp verifies
/// what the wallet returns with CosmJS, so the bytes must match exactly.
void main() {
  final vectors = jsonDecode(
    File('test/fixtures/cosmos-signing-vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final keyring = CosmosKeyring(vectors['mnemonic'] as String);
  final accounts = (vectors['accounts'] as List).cast<Map<String, dynamic>>();

  CosmosSigningKey keyFor(String address) {
    final account = accounts.firstWhere((a) => a['address'] == address);
    return keyring.key(
      coinType: account['coinType'] as int,
      accountIndex: account['accountIndex'] as int,
    );
  }

  String toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  test('derives the same keys and addresses', () {
    for (final a in accounts) {
      final key = keyring.key(coinType: a['coinType'], accountIndex: a['accountIndex']);
      expect(base64Encode(key.publicKey), a['pubKey']);
      expect(key.address(a['prefix']), a['address']);
    }
  });

  group('amino', () {
    for (final v in (vectors['amino'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'], () {
        expect(utf8.decode(aminoSignBytes(v['signDoc'])), v['signBytes']);
        final result = signAminoResult(keyFor(v['signer']), v['signDoc']);
        expect(result['signed'], v['signDoc']);
        final signature = result['signature'] as Map<String, Object?>;
        expect(signature['signature'], v['signature']);
        expect(
          (signature['pub_key'] as Map)['value'],
          accounts.firstWhere((a) => a['address'] == v['signer'])['pubKey'],
        );
      });
    }
  });

  group('direct', () {
    for (final v in (vectors['direct'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'], () {
        final doc = DirectSignDoc.fromWire(v['signDoc']);
        expect(toHex(doc.signBytes), v['signBytes']);
        final result = signDirectResult(keyFor(v['signer']), doc);
        expect(result['signed'], v['signDoc']);
        expect((result['signature'] as Map)['signature'], v['signature']);

        final summary = TxSummary.fromDirect(doc)!;
        final expected = v['summary'] as Map<String, dynamic>;
        expect(summary.messages, expected['messages']);
        expect(summary.memo, expected['memo']);
        expect(
          [for (final c in summary.fee) {'denom': c.denom, 'amount': c.amount}],
          expected['fee'],
        );
        expect(summary.gas, expected['gas']);
      });
    }
  });

  group('ADR-036', () {
    for (final v in (vectors['adr36'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'], () {
        final data = v['encoding'] == 'utf8'
            ? utf8.encode(v['data'] as String)
            : base64Decode(v['data'] as String);
        final signature = signArbitraryResult(keyFor(v['signer']), v['signer'], data);
        expect(signature['signature'], v['signature']);
      });
    }
  });

  test('refuses malformed direct documents', () {
    final good = ((vectors['direct'] as List).first as Map<String, dynamic>)['signDoc']
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
  });

  test('summarises amino documents and survives garbage bytes', () {
    final amino = ((vectors['amino'] as List).first as Map<String, dynamic>)['signDoc'];
    final summary = TxSummary.fromAmino(amino)!;
    expect(summary.messages, ['cosmos-sdk/MsgSend']);
    expect(summary.fee.single.toString(), '5000 uatom');
    expect(summary.gas, '200000');
    final garbage = DirectSignDoc.fromWire({
      'bodyBytes': base64Encode([0x0a, 0xff, 0xff]),
      'authInfoBytes': '',
      'chainId': 'cosmoshub-4',
      'accountNumber': '1',
    });
    expect(TxSummary.fromDirect(garbage), isNull);
  });
}
