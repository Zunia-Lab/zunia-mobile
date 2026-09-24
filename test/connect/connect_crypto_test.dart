import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';

/// The same vectors run in `@zunialab/sdk-core`: if either side drifts, the
/// dApp and the wallet stop understanding each other.
void main() {
  final vectors = jsonDecode(
    File('test/fixtures/connect-v2-vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  Uint8List hex(String value) => Uint8List.fromList([
        for (var i = 0; i < value.length; i += 2)
          int.parse(value.substring(i, i + 2), radix: 16),
      ]);
  String toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  group('key agreement', () {
    for (final v in (vectors['keyAgreement'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'], () async {
        final sessionId = v['sessionId'] as String;
        final dapp = await ConnectKeyPair.fromSecret(hex(v['dappSecretKey']));
        final wallet = await ConnectKeyPair.fromSecret(hex(v['walletSecretKey']));
        expect(bytesToBase64Url(dapp.publicKey), v['dappPublicKey']);
        expect(bytesToBase64Url(wallet.publicKey), v['walletPublicKey']);
        expect(toHex(await wallet.sharedSecret(dapp.publicKey)), v['sharedSecret']);
        expect(
          toHex(connectTranscript(sessionId, dapp.publicKey, wallet.publicKey)),
          v['transcript'],
        );

        final fromWallet = await deriveConnectKeys(
          role: ConnectRole.wallet,
          sessionId: sessionId,
          own: wallet,
          peerPublicKey: dapp.publicKey,
        );
        final fromDapp = await deriveConnectKeys(
          role: ConnectRole.dapp,
          sessionId: sessionId,
          own: dapp,
          peerPublicKey: wallet.publicKey,
        );
        for (final keys in [fromWallet, fromDapp]) {
          expect(toHex(keys.dappToWallet), v['dappToWallet']);
          expect(toHex(keys.walletToDapp), v['walletToDapp']);
          expect(keys.verificationCode, v['verificationCode']);
        }
      });
    }
  });

  group('frames', () {
    for (final v in (vectors['frames'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'], () {
        final key = hex(v['key']);
        final nonce = base64UrlToBytes(v['nonce']);
        final aad = utf8.encode(v['aad'] as String);
        final sender = v['sender'] == 'dapp' ? ConnectRole.dapp : ConnectRole.wallet;
        expect(frameAad(v['sessionId'], sender), aad);
        final sealed = encryptFrame(key, nonce, aad, utf8.encode(v['plaintext']));
        expect(bytesToBase64Url(sealed), v['ciphertext']);
        final opened = decryptFrame(key, nonce, aad, base64UrlToBytes(v['ciphertext']));
        expect(utf8.decode(opened), v['plaintext']);
      });
    }
  });

  test('verification codes', () {
    for (final v in (vectors['verificationCodes'] as List).cast<Map<String, dynamic>>()) {
      expect(verificationCodeFrom(hex(v['bytes'])), v['code'], reason: v['bytes']);
    }
  });

  group('cipher', () {
    late ConnectCipher dapp;
    late ConnectCipher wallet;

    setUp(() async {
      final v = (vectors['keyAgreement'] as List).first as Map<String, dynamic>;
      final sessionId = v['sessionId'] as String;
      dapp = ConnectCipher(
        role: ConnectRole.dapp,
        sessionId: sessionId,
        dappToWallet: hex(v['dappToWallet']),
        walletToDapp: hex(v['walletToDapp']),
      );
      wallet = ConnectCipher(
        role: ConnectRole.wallet,
        sessionId: sessionId,
        dappToWallet: hex(v['dappToWallet']),
        walletToDapp: hex(v['walletToDapp']),
      );
    });

    test('opens what the other side seals, in both directions', () {
      final request = wallet.open(
        dapp.seal('connect_request', id: 'req-1', payload: {'chains': ['cosmoshub-4']}),
      );
      expect(request.seq, 1);
      expect(request.type, 'connect_request');
      expect(request.id, 'req-1');
      expect(request.payload, {'chains': ['cosmoshub-4']});
      expect(dapp.open(wallet.seal('result', id: 'req-1', payload: true)).payload, true);
      expect((dapp.sendSeq, dapp.receiveSeq), (1, 1));
      expect((wallet.sendSeq, wallet.receiveSeq), (1, 1));
    });

    test('ignores a resent copy but refuses a forgery', () {
      final frame = dapp.seal('sign_amino', id: '2');
      expect(wallet.openFresh(frame)?.id, '2');
      expect(wallet.openFresh(frame), isNull);
      expect(
        () => wallet.open(frame),
        throwsA(isA<ConnectException>().having((e) => e.code, 'code', 'PAIRING_FAILED')),
      );

      final tampered = base64UrlToBytes(dapp.seal('x').c);
      tampered[0] ^= 1;
      expect(
        () => wallet.openFresh(SealedFrame(n: frame.n, c: bytesToBase64Url(tampered))),
        throwsA(isA<ConnectException>()),
      );
    });

    test('refuses its own frames and frames for another session', () {
      expect(() => dapp.open(dapp.seal('own')), throwsA(isA<ConnectException>()));
      final v = (vectors['keyAgreement'] as List).first as Map<String, dynamic>;
      final elsewhere = ConnectCipher(
        role: ConnectRole.wallet,
        sessionId: 'aB-_09zzYYxxWWvvUUttSs',
        dappToWallet: hex(v['dappToWallet']),
        walletToDapp: hex(v['walletToDapp']),
      );
      expect(() => elsewhere.open(dapp.seal('d')), throwsA(isA<ConnectException>()));
    });

    test('resumes from saved sequence numbers', () {
      wallet.open(dapp.seal('a'));
      final v = (vectors['keyAgreement'] as List).first as Map<String, dynamic>;
      final restored = ConnectCipher(
        role: ConnectRole.dapp,
        sessionId: v['sessionId'],
        dappToWallet: hex(v['dappToWallet']),
        walletToDapp: hex(v['walletToDapp']),
        sendSeq: dapp.sendSeq,
      );
      expect(wallet.open(restored.seal('b')).seq, 2);
    });
  });

  test('refuses unusable peer keys', () async {
    final own = await ConnectKeyPair.generate();
    for (final peer in [Uint8List(32), Uint8List(31)]) {
      await expectLater(
        deriveConnectKeys(
          role: ConnectRole.wallet,
          sessionId: 'Zf3kQ9xTn2LmP8vR4sWb1A',
          own: own,
          peerPublicKey: peer,
        ),
        throwsA(isA<ConnectException>().having((e) => e.code, 'code', 'PAIRING_FAILED')),
      );
    }
  });
}
