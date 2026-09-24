/// End-to-end encryption for zunia.connect.v2, the QR pairing between a dApp
/// and this wallet.
///
/// - X25519 between the dApp key (in the QR code) and the wallet key (sent in
///   the `hello` frame). The session id and both public keys are bound into
///   the HKDF-SHA256 salt.
/// - One ChaCha20-Poly1305 key per direction, a random 96-bit nonce per frame,
///   and `zunia.connect.v2|<sessionId>|<direction>` as associated data.
/// - A sequence number inside each plaintext; a receiver ignores anything not
///   newer than the last frame it accepted.
/// - A 6-digit code from the same secret. Both screens show it; a relay that
///   swapped keys produces two different codes.
///
/// This is the same construction as `@zunialab/sdk-core`. The shared vectors
/// in `test/fixtures/connect-v2-vectors.json` keep the two identical.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

const String kConnectV2 = 'zunia.connect.v2';

enum ConnectRole { dapp, wallet }

/// A failure with one of the codes the SDK understands (`USER_REJECTED`,
/// `INVALID_PARAMS`, `ORIGIN_MISMATCH`, ...) or a pairing code such as
/// `PAIRING_FAILED`.
class ConnectException implements Exception {
  const ConnectException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

final _base64Url = RegExp(r'^[A-Za-z0-9_-]*$');

String bytesToBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List base64UrlToBytes(String value) {
  if (!_base64Url.hasMatch(value) || value.length % 4 == 1) {
    throw const FormatException('Expected unpadded base64url');
  }
  return base64Url.decode(base64Url.normalize(value));
}

final Random _random = Random.secure();

Uint8List randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _random.nextInt(256);
  }
  return out;
}

const _x25519 = DartX25519();
const _aead = DartChacha20.poly1305Aead();

class ConnectKeyPair {
  ConnectKeyPair._(this.secretKey, this.publicKey, this._pair);

  final Uint8List secretKey;
  final Uint8List publicKey;
  final SimpleKeyPair _pair;

  static Future<ConnectKeyPair> generate() => fromSecret(randomBytes(32));

  static Future<ConnectKeyPair> fromSecret(List<int> secretKey) async {
    if (secretKey.length != 32) {
      throw const ConnectException(
        'PAIRING_FAILED',
        'An X25519 secret key is 32 bytes',
      );
    }
    final pair = await _x25519.newKeyPairFromSeed(secretKey);
    final publicKey = await pair.extractPublicKey();
    return ConnectKeyPair._(
      Uint8List.fromList(secretKey),
      Uint8List.fromList(publicKey.bytes),
      pair,
    );
  }

  Future<Uint8List> sharedSecret(List<int> peerPublicKey) async {
    final secret = await _x25519.sharedSecretKey(
      keyPair: _pair,
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }
}

class ConnectSessionKeys {
  const ConnectSessionKeys({
    required this.dappToWallet,
    required this.walletToDapp,
    required this.verificationCode,
  });

  final Uint8List dappToWallet;
  final Uint8List walletToDapp;

  /// Six digits, zero-padded, shown on both screens.
  final String verificationCode;
}

/// The salt: SHA-256("zunia.connect.v2" 0x00 sessionId 0x00 dappPublicKey walletPublicKey).
Uint8List connectTranscript(
  String sessionId,
  List<int> dappPublicKey,
  List<int> walletPublicKey,
) {
  final input = <int>[
    ...utf8.encode(kConnectV2),
    0,
    ...utf8.encode(sessionId),
    0,
    ...dappPublicKey,
    ...walletPublicKey,
  ];
  return Uint8List.fromList(hashes.sha256.convert(input).bytes);
}

/// Four HKDF bytes, big-endian, modulo one million, zero-padded to six digits.
String verificationCodeFrom(List<int> bytes) {
  final value =
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  return (value % 1000000).toString().padLeft(6, '0');
}

Future<ConnectSessionKeys> deriveConnectKeys({
  required ConnectRole role,
  required String sessionId,
  required ConnectKeyPair own,
  required List<int> peerPublicKey,
}) async {
  if (peerPublicKey.length != 32) {
    throw const ConnectException(
      'PAIRING_FAILED',
      'The peer key must be 32 bytes',
    );
  }
  final dappPublicKey = role == ConnectRole.dapp ? own.publicKey : peerPublicKey;
  final walletPublicKey =
      role == ConnectRole.dapp ? peerPublicKey : own.publicKey;
  final Uint8List shared;
  try {
    shared = await own.sharedSecret(peerPublicKey);
  } catch (_) {
    throw const ConnectException('PAIRING_FAILED', 'The peer key is not usable');
  }
  if (shared.every((byte) => byte == 0)) {
    throw const ConnectException('PAIRING_FAILED', 'The peer key is not usable');
  }
  final salt = connectTranscript(sessionId, dappPublicKey, walletPublicKey);
  Future<Uint8List> expand(String info, int length) async {
    final hkdf = DartHkdf(hmac: DartHmac.sha256(), outputLength: length);
    final key = await hkdf.deriveKey(
      secretKey: SecretKeyData(shared),
      nonce: salt,
      info: utf8.encode('$kConnectV2 $info'),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  return ConnectSessionKeys(
    dappToWallet: await expand('dapp->wallet', 32),
    walletToDapp: await expand('wallet->dapp', 32),
    verificationCode: verificationCodeFrom(await expand('verification code', 4)),
  );
}

String _direction(ConnectRole sender) =>
    sender == ConnectRole.dapp ? 'dapp->wallet' : 'wallet->dapp';

Uint8List frameAad(String sessionId, ConnectRole sender) =>
    Uint8List.fromList(utf8.encode('$kConnectV2|$sessionId|${_direction(sender)}'));

/// ChaCha20-Poly1305; the result is the ciphertext followed by the 16-byte tag.
Uint8List encryptFrame(
  List<int> key,
  List<int> nonce,
  List<int> aad,
  List<int> plaintext,
) {
  final box = _aead.encryptSync(
    plaintext,
    secretKey: SecretKeyData(key),
    nonce: nonce,
    aad: aad,
  );
  return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
}

/// Throws [SecretBoxAuthenticationError] when the tag does not match.
Uint8List decryptFrame(
  List<int> key,
  List<int> nonce,
  List<int> aad,
  List<int> ciphertext,
) {
  if (ciphertext.length < 16) throw SecretBoxAuthenticationError();
  final split = ciphertext.length - 16;
  final box = SecretBox(
    ciphertext.sublist(0, split),
    nonce: nonce,
    mac: Mac(ciphertext.sublist(split)),
  );
  return Uint8List.fromList(
    _aead.decryptSync(box, secretKey: SecretKeyData(key), aad: aad),
  );
}

class SealedFrame {
  const SealedFrame({required this.n, required this.c});

  /// 12-byte nonce, unpadded base64url.
  final String n;

  /// Ciphertext and 16-byte tag, unpadded base64url.
  final String c;
}

class ConnectEnvelope {
  const ConnectEnvelope({
    required this.seq,
    required this.type,
    this.id,
    this.payload,
  });

  final int seq;
  final String type;
  final String? id;
  final Object? payload;
}

/// Seals outgoing frames and opens incoming ones for one side of a session.
class ConnectCipher {
  ConnectCipher({
    required ConnectRole role,
    required String sessionId,
    required List<int> dappToWallet,
    required List<int> walletToDapp,
    int sendSeq = 0,
    int receiveSeq = 0,
    Uint8List Function(int length)? nonceSource,
  })  : _sendKey = Uint8List.fromList(
          role == ConnectRole.dapp ? dappToWallet : walletToDapp,
        ),
        _receiveKey = Uint8List.fromList(
          role == ConnectRole.dapp ? walletToDapp : dappToWallet,
        ),
        _sendAad = frameAad(sessionId, role),
        _receiveAad = frameAad(
          sessionId,
          role == ConnectRole.dapp ? ConnectRole.wallet : ConnectRole.dapp,
        ),
        _sendSeq = sendSeq,
        _receiveSeq = receiveSeq,
        _nonce = nonceSource ?? randomBytes;

  final Uint8List _sendKey;
  final Uint8List _receiveKey;
  final Uint8List _sendAad;
  final Uint8List _receiveAad;
  final Uint8List Function(int length) _nonce;
  int _sendSeq;
  int _receiveSeq;

  int get sendSeq => _sendSeq;
  int get receiveSeq => _receiveSeq;

  SealedFrame seal(String type, {String? id, Object? payload}) {
    final seq = _sendSeq + 1;
    final envelope = <String, Object?>{
      'seq': seq,
      'type': type,
      'id': ?id,
      'payload': ?payload,
    };
    final nonce = _nonce(12);
    final ciphertext = encryptFrame(
      _sendKey,
      nonce,
      _sendAad,
      utf8.encode(jsonEncode(envelope)),
    );
    _sendSeq = seq;
    return SealedFrame(n: bytesToBase64Url(nonce), c: bytesToBase64Url(ciphertext));
  }

  /// Throws `PAIRING_FAILED` for a forged, tampered, replayed or reordered frame.
  ConnectEnvelope open(SealedFrame frame) {
    final envelope = openFresh(frame);
    if (envelope == null) {
      throw const ConnectException(
        'PAIRING_FAILED',
        'A frame was replayed or reordered',
      );
    }
    return envelope;
  }

  /// Like [open], but returns null for an authentic frame that is not newer
  /// than the last one accepted: a copy the other side resent after a
  /// reconnect. Forged and tampered frames still throw.
  ConnectEnvelope? openFresh(SealedFrame frame) {
    Object? decoded;
    try {
      final plaintext = decryptFrame(
        _receiveKey,
        base64UrlToBytes(frame.n),
        _receiveAad,
        base64UrlToBytes(frame.c),
      );
      decoded = jsonDecode(utf8.decode(plaintext));
    } catch (_) {
      throw const ConnectException('PAIRING_FAILED', 'A frame failed to decrypt');
    }
    if (decoded is! Map || decoded['seq'] is! int || decoded['type'] is! String) {
      throw const ConnectException(
        'PAIRING_FAILED',
        'A frame has no valid envelope',
      );
    }
    final seq = decoded['seq'] as int;
    if (seq <= _receiveSeq) return null;
    _receiveSeq = seq;
    final id = decoded['id'];
    return ConnectEnvelope(
      seq: seq,
      type: decoded['type'] as String,
      id: id is String ? id : null,
      payload: decoded['payload'],
    );
  }
}
