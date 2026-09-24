/// Signatures for dApp requests on Cosmos SDK chains, byte for byte what CosmJS
/// produces and verifies: amino JSON, protobuf `SignDoc` (sign mode direct)
/// and ADR-036 for arbitrary data and sign-in messages.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:bech32/bech32.dart';
import 'package:bip32/bip32.dart' as bip32;
import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart';
import 'package:pointycastle/digests/ripemd160.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/crypto/proto_writer.dart';

/// Keys under one recovery phrase. The seed is computed once, which is the
/// slow part.
class CosmosKeyring {
  CosmosKeyring(String phrase, {String passphrase = ''})
      : _root = bip32.BIP32.fromSeed(
          bip39.mnemonicToSeed(phrase.trim(), passphrase: passphrase),
        );

  final bip32.BIP32 _root;

  /// `m/44'/<coinType>'/<accountIndex>'/0/0`, the path the wallet uses everywhere.
  CosmosSigningKey key({required int coinType, required int accountIndex}) =>
      CosmosSigningKey._(_root.derivePath("m/44'/$coinType'/$accountIndex'/0/0"));
}

class CosmosSigningKey {
  CosmosSigningKey._(this._node);

  final bip32.BIP32 _node;

  /// Compressed secp256k1 public key, 33 bytes.
  Uint8List get publicKey => Uint8List.fromList(_node.publicKey);

  String address(String prefix) => cosmosAddress(publicKey, prefix);

  /// secp256k1 over SHA-256(signBytes): 64 bytes r||s, low S, RFC 6979 nonce.
  Uint8List sign(List<int> signBytes) {
    final digest = Uint8List.fromList(sha256.convert(signBytes).bytes);
    return Uint8List.fromList(_node.sign(digest));
  }

  /// The `StdSignature` CosmJS expects.
  Map<String, Object?> stdSignature(List<int> signBytes) => {
        'pub_key': {
          'type': 'tendermint/PubKeySecp256k1',
          'value': base64Encode(publicKey),
        },
        'signature': base64Encode(sign(signBytes)),
      };
}

/// Bech32 address of a compressed secp256k1 key: ripemd160(sha256(key)).
String cosmosAddress(List<int> publicKey, String prefix) {
  final hash = RIPEMD160Digest().process(
    Uint8List.fromList(sha256.convert(publicKey).bytes),
  );
  return bech32.encode(Bech32(prefix, _toWords(hash)));
}

List<int> _toWords(Uint8List bytes) {
  var acc = 0;
  var bits = 0;
  final out = <int>[];
  for (final byte in bytes) {
    acc = ((acc << 8) | byte) & 0xfff;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.add((acc >> bits) & 31);
    }
  }
  if (bits > 0) out.add((acc << (5 - bits)) & 31);
  return out;
}

/// CosmJS `serializeSignDoc`: keys sorted recursively, compact JSON, `&<>`
/// escaped the way Go's encoder writes them.
Uint8List aminoSignBytes(Object? signDoc) {
  final json = jsonEncode(_canonical(signDoc))
      .replaceAll('&', r'\u0026')
      .replaceAll('<', r'\u003c')
      .replaceAll('>', r'\u003e');
  return Uint8List.fromList(utf8.encode(json));
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _canonical(value[k])};
  }
  if (value is List) return value.map(_canonical).toList();
  if (value is double &&
      value.isFinite &&
      value == value.truncateToDouble() &&
      value.abs() < 1e21) {
    return value.toInt();
  }
  return value;
}

/// The ADR-036 amino document signed for `signArbitrary(chainId, signer, data)`.
Map<String, Object?> adr36SignDoc(String signer, List<int> data) => {
      'account_number': '0',
      'chain_id': '',
      'fee': {'amount': <Object?>[], 'gas': '0'},
      'memo': '',
      'msgs': [
        {
          'type': 'sign/MsgSignData',
          'value': {'data': base64Encode(data), 'signer': signer},
        },
      ],
      'sequence': '0',
    };

final _decimal = RegExp(r'^\d{1,20}$');
final _maxUint64 = (BigInt.one << 64) - BigInt.one;

/// A `sign_direct` document as the SDK sends it: bytes in base64 and the
/// account number as a decimal string.
class DirectSignDoc {
  const DirectSignDoc({
    required this.bodyBytes,
    required this.authInfoBytes,
    required this.chainId,
    required this.accountNumber,
  });

  /// Throws `INVALID_PARAMS` when a field is missing or malformed.
  factory DirectSignDoc.fromWire(Object? value) {
    if (value is! Map) {
      throw const ConnectException('INVALID_PARAMS', 'signDoc must be an object');
    }
    final body = value['bodyBytes'];
    final authInfo = value['authInfoBytes'];
    final chainId = value['chainId'];
    final accountNumber = value['accountNumber'];
    if (body is! String ||
        authInfo is! String ||
        chainId is! String ||
        accountNumber is! String ||
        !_decimal.hasMatch(accountNumber)) {
      throw const ConnectException(
        'INVALID_PARAMS',
        'signDoc needs bodyBytes, authInfoBytes, chainId and accountNumber',
      );
    }
    final number = BigInt.parse(accountNumber);
    if (number > _maxUint64) {
      throw const ConnectException('INVALID_PARAMS', 'accountNumber is too large');
    }
    try {
      return DirectSignDoc(
        bodyBytes: base64Decode(body),
        authInfoBytes: base64Decode(authInfo),
        chainId: chainId,
        accountNumber: number,
      );
    } on FormatException {
      throw const ConnectException(
        'INVALID_PARAMS',
        'bodyBytes and authInfoBytes must be base64',
      );
    }
  }

  final Uint8List bodyBytes;
  final Uint8List authInfoBytes;
  final String chainId;
  final BigInt accountNumber;

  /// `cosmos.tx.v1beta1.SignDoc`, proto3 defaults omitted as CosmJS does.
  Uint8List get signBytes => ProtoWriter()
      .bytes(1, bodyBytes)
      .bytes(2, authInfoBytes)
      .string(3, chainId)
      .uint64(4, accountNumber)
      .intoBytes();

  Map<String, Object?> toWire() => {
        'bodyBytes': base64Encode(bodyBytes),
        'authInfoBytes': base64Encode(authInfoBytes),
        'chainId': chainId,
        'accountNumber': accountNumber.toString(),
      };
}

/// The `result` payload for `sign_amino`: the document as signed, unchanged.
Map<String, Object?> signAminoResult(CosmosSigningKey key, Object? signDoc) => {
      'signed': signDoc,
      'signature': key.stdSignature(aminoSignBytes(signDoc)),
    };

/// The `result` payload for `sign_direct`.
Map<String, Object?> signDirectResult(CosmosSigningKey key, DirectSignDoc doc) => {
      'signed': doc.toWire(),
      'signature': key.stdSignature(doc.signBytes),
    };

/// The `result` payload for `sign_arbitrary`: an ADR-036 `StdSignature`.
Map<String, Object?> signArbitraryResult(
  CosmosSigningKey key,
  String signer,
  List<int> data,
) =>
    key.stdSignature(aminoSignBytes(adr36SignDoc(signer, data)));

class CoinAmount {
  const CoinAmount(this.denom, this.amount);

  final String denom;
  final String amount;

  @override
  String toString() => '$amount $denom';
}

/// What a transaction does, for the approval screen.
class TxSummary {
  const TxSummary({
    required this.messages,
    required this.memo,
    required this.fee,
    this.gas,
  });

  /// Amino types (`cosmos-sdk/MsgSend`) or protobuf type URLs
  /// (`/cosmos.bank.v1beta1.MsgSend`).
  final List<String> messages;
  final String memo;
  final List<CoinAmount> fee;
  final String? gas;

  static TxSummary? fromAmino(Object? signDoc) {
    if (signDoc is! Map) return null;
    final msgs = signDoc['msgs'];
    final fee = signDoc['fee'];
    return TxSummary(
      messages: [
        if (msgs is List)
          for (final m in msgs)
            if (m is Map && m['type'] is String) m['type'] as String else '?',
      ],
      memo: signDoc['memo'] is String ? signDoc['memo'] as String : '',
      fee: [
        if (fee is Map && fee['amount'] is List)
          for (final c in fee['amount'] as List)
            if (c is Map) CoinAmount('${c['denom']}', '${c['amount']}'),
      ],
      gas: fee is Map && fee['gas'] != null ? '${fee['gas']}' : null,
    );
  }

  /// Reads `TxBody` and `AuthInfo`. Null when the bytes do not parse.
  static TxSummary? fromDirect(DirectSignDoc doc) {
    try {
      final messages = <String>[];
      var memo = '';
      final body = _ProtoReader(doc.bodyBytes);
      while (!body.done) {
        final (field, wire) = body.tag();
        if (field == 1 && wire == 2) {
          final any = _ProtoReader(body.bytes());
          var typeUrl = '?';
          while (!any.done) {
            final (f, w) = any.tag();
            if (f == 1 && w == 2) {
              typeUrl = utf8.decode(any.bytes());
            } else {
              any.skip(w);
            }
          }
          messages.add(typeUrl);
        } else if (field == 2 && wire == 2) {
          memo = utf8.decode(body.bytes());
        } else {
          body.skip(wire);
        }
      }
      final fee = <CoinAmount>[];
      String? gas;
      final authInfo = _ProtoReader(doc.authInfoBytes);
      while (!authInfo.done) {
        final (field, wire) = authInfo.tag();
        if (field == 2 && wire == 2) {
          final feeReader = _ProtoReader(authInfo.bytes());
          while (!feeReader.done) {
            final (f, w) = feeReader.tag();
            if (f == 1 && w == 2) {
              final coin = _ProtoReader(feeReader.bytes());
              var denom = '';
              var amount = '';
              while (!coin.done) {
                final (cf, cw) = coin.tag();
                if (cf == 1 && cw == 2) {
                  denom = utf8.decode(coin.bytes());
                } else if (cf == 2 && cw == 2) {
                  amount = utf8.decode(coin.bytes());
                } else {
                  coin.skip(cw);
                }
              }
              fee.add(CoinAmount(denom, amount));
            } else if (f == 2 && w == 0) {
              gas = feeReader.varint().toString();
            } else {
              feeReader.skip(w);
            }
          }
        } else {
          authInfo.skip(wire);
        }
      }
      return TxSummary(messages: messages, memo: memo, fee: fee, gas: gas);
    } catch (_) {
      return null;
    }
  }
}

class _ProtoReader {
  _ProtoReader(this._bytes);

  final Uint8List _bytes;
  int _at = 0;

  bool get done => _at >= _bytes.length;

  (int, int) tag() {
    final key = varint().toInt();
    return (key >> 3, key & 7);
  }

  BigInt varint() {
    var result = BigInt.zero;
    var shift = 0;
    while (true) {
      if (_at >= _bytes.length || shift > 63) {
        throw const FormatException('Bad varint');
      }
      final byte = _bytes[_at++];
      result |= BigInt.from(byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }

  Uint8List bytes() {
    final length = varint().toInt();
    if (length < 0 || _at + length > _bytes.length) {
      throw const FormatException('Bad length');
    }
    final out = Uint8List.sublistView(_bytes, _at, _at + length);
    _at += length;
    return out;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        _at += 8;
      case 2:
        bytes();
      case 5:
        _at += 4;
      default:
        throw const FormatException('Unsupported wire type');
    }
    if (_at > _bytes.length) throw const FormatException('Truncated');
  }
}
