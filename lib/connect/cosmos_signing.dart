/// Signatures for dApp requests on Cosmos SDK chains, made by the kernel over
/// the exact bytes the chain verifies: a Direct `SignDoc`, Amino sign bytes or
/// an ADR-036 document.
///
/// Nothing here holds key maths. The bytes are assembled in Dart (sorted,
/// escaped JSON; protobuf with proto3 defaults omitted) and handed to
/// [WalletKernel.signBytes], which hashes them as the chain does (SHA-256, or
/// keccak256 on an `eth-key-sign` chain) and signs with the key it derives,
/// the same code the extension runs as WebAssembly. A second Dart signer, as
/// this file used to carry, derived Ethermint keys wrong and could not sign
/// for them at all.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:bech32/bech32.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/crypto/proto_writer.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';

/* -------------------------------------------------------------------------- *
 * Amino
 * -------------------------------------------------------------------------- */

/// CosmJS `serializeSignDoc` as extension 0.1.5 signs it: keys sorted
/// recursively, compact JSON, then [escapeAminoJson]. The chain rebuilds these
/// bytes with Go's encoding/json, so a memo like "rent & food" signed without
/// the escapes verifies against nothing.
Uint8List aminoSignBytes(Object? signDoc) =>
    Uint8List.fromList(utf8.encode(escapeAminoJson(jsonEncode(_canonical(signDoc)))));

/// The escapes Go's encoding/json writes inside strings and `jsonEncode` does
/// not: `&`, `<`, `>` (CosmJS `escapeCharacters`, what Keplr signs) and U+2028,
/// U+2029 (Go escapes them unconditionally; CosmJS does not). In valid JSON
/// these characters only occur inside string values.
String escapeAminoJson(String json) => json
    .replaceAll('&', r'\u0026')
    .replaceAll('<', r'\u003c')
    .replaceAll('>', r'\u003e')
    .replaceAll('\u2028', r'\u2028')
    .replaceAll('\u2029', r'\u2029');

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _canonical(value[k])};
  }
  if (value is List) return value.map(_canonical).toList();
  // A JSON number the page wrote as `1` reaches Dart as an int, but one that
  // went through a double (`1.0`) must still print as `1`, as JSON.stringify does.
  if (value is double &&
      value.isFinite &&
      value == value.truncateToDouble() &&
      value.abs() < 1e21) {
    return value.toInt();
  }
  return value;
}

/// The ADR-036 amino document signed for `signArbitrary(chainId, signer, data)`:
/// empty chain id, one `sign/MsgSignData`, the data in base64.
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

Uint8List adr36SignBytes(String signer, List<int> data) =>
    aminoSignBytes(adr36SignDoc(signer, data));

/// False for ADR-036 data that is itself a transaction sign doc, so a site
/// cannot get a transaction signed by calling it "a message".
bool adr36PayloadIsSafe(List<int> data) {
  final String text;
  try {
    text = utf8.decode(data, allowMalformed: false);
  } on FormatException {
    return true;
  }
  final Object? parsed;
  try {
    parsed = jsonDecode(text);
  } on FormatException {
    return true;
  }
  if (parsed is! Map) return true;
  return !(parsed.containsKey('msgs') &&
      parsed.containsKey('fee') &&
      parsed.containsKey('chain_id'));
}

/// secp256k1 check of a compact `r||s` signature over the ADR-036 sign bytes
/// (SHA-256 digest), as the extension's `verifyAdr36` does.
bool verifyAdr36({
  required String signer,
  required List<int> data,
  required List<int> publicKey,
  required List<int> signature,
}) =>
    verifySecp256k1Sha256(
      signBytes: adr36SignBytes(signer, data),
      publicKey: publicKey,
      signature: signature,
    );

/// Whether [signature] (64-byte `r||s`) is [publicKey]'s over SHA-256 of
/// [signBytes]. A high-S signature, which no Cosmos chain accepts, does not
/// verify (noble's default, which the extension uses).
bool verifySecp256k1Sha256({
  required List<int> signBytes,
  required List<int> publicKey,
  required List<int> signature,
}) {
  try {
    if (signature.length != 64) return false;
    final digest = Uint8List.fromList(sha256.convert(signBytes).bytes);
    final params = pc.ECDomainParameters('secp256k1');
    final point = params.curve.decodePoint(publicKey);
    if (point == null) return false;
    final r = _bigInt(signature.sublist(0, 32));
    final s = _bigInt(signature.sublist(32));
    if (r == BigInt.zero || s == BigInt.zero || r >= params.n || s > params.n >> 1) return false;
    final verifier = pc.ECDSASigner()
      ..init(false, pc.PublicKeyParameter<pc.ECPublicKey>(pc.ECPublicKey(point, params)));
    return verifier.verifySignature(digest, pc.ECSignature(r, s));
  } catch (_) {
    return false;
  }
}

BigInt _bigInt(List<int> bytes) {
  var out = BigInt.zero;
  for (final b in bytes) {
    out = (out << 8) | BigInt.from(b);
  }
  return out;
}

/* -------------------------------------------------------------------------- *
 * Bytes off the wire
 * -------------------------------------------------------------------------- */

const _maxWireBytes = 256 * 1024;
final _hex = RegExp(r'^0x(?:[0-9a-fA-F]{2})*$');
final _base64 = RegExp(r'^[A-Za-z0-9+/_-]*={0,2}$');

int _byte(Object? value, String label) {
  if (value is int && value >= 0 && value <= 255) return value;
  if (value is double && value == value.truncateToDouble() && value >= 0 && value <= 255) {
    return value.toInt();
  }
  throw ConnectException('INVALID_PARAMS', '$label is not a byte array');
}

/// Bytes from what survives the page-to-wallet hop: a number array, the
/// index-keyed object JSON makes of a `Uint8Array`, base64 (standard or URL
/// safe), or hex with its `0x` prefix. Plain hex is also valid base64, and
/// reading one string two ways would sign other bytes than the page meant, so
/// hex needs its prefix (zunia-extension/lib/provider-guards.ts).
Uint8List bytesFromWire(Object? value, String label) {
  if (value is Uint8List) return value;
  if (value is List) {
    if (value.length > _maxWireBytes) {
      throw ConnectException('INVALID_PARAMS', '$label is too large');
    }
    return Uint8List.fromList([for (final v in value) _byte(v, label)]);
  }
  if (value is String) {
    if (value.length > _maxWireBytes * 2) {
      throw ConnectException('INVALID_PARAMS', '$label is too large');
    }
    if (value.startsWith('0x')) {
      if (_hex.hasMatch(value)) return bytesOfHex(value);
      throw ConnectException('INVALID_PARAMS', '$label is not valid hex');
    }
    if (_base64.hasMatch(value)) {
      try {
        return base64.decode(base64.normalize(value.replaceAll('-', '+').replaceAll('_', '/')));
      } on FormatException {
        // Refused below.
      }
    }
    throw ConnectException('INVALID_PARAMS', '$label is not hex or base64');
  }
  if (value is Map) {
    if (value.length > _maxWireBytes) {
      throw ConnectException('INVALID_PARAMS', '$label is too large');
    }
    final out = Uint8List(value.length);
    final seen = List<bool>.filled(value.length, false);
    for (final entry in value.entries) {
      final index = int.tryParse('${entry.key}');
      if (index == null || index < 0 || index >= value.length || seen[index]) {
        throw ConnectException('INVALID_PARAMS', '$label is not a byte array');
      }
      seen[index] = true;
      out[index] = _byte(entry.value, label);
    }
    return out;
  }
  throw ConnectException('INVALID_PARAMS', '$label is missing');
}

final _maxUint64 = (BigInt.one << 64) - BigInt.one;
final _decimal = RegExp(r'^\d{1,20}$');

/// An unsigned 64-bit integer from a number, a decimal string, a Long-like
/// `{low, high}` object, or nothing (0).
BigInt u64FromWire(Object? value, String label) {
  BigInt out;
  if (value == null) {
    out = BigInt.zero;
  } else if (value is int) {
    out = BigInt.from(value);
  } else if (value is double) {
    if (value != value.truncateToDouble() || value.abs() > 9007199254740991) {
      throw ConnectException('INVALID_PARAMS', '$label is not an integer');
    }
    out = BigInt.from(value);
  } else if (value is String) {
    if (!_decimal.hasMatch(value.trim())) {
      throw ConnectException('INVALID_PARAMS', '$label is not an integer');
    }
    out = BigInt.parse(value.trim());
  } else if (value is Map && value['low'] is num && value['high'] is num) {
    final low = (value['low'] as num).toInt() & 0xffffffff;
    final high = (value['high'] as num).toInt() & 0xffffffff;
    out = (BigInt.from(high) << 32) | BigInt.from(low);
  } else {
    throw ConnectException('INVALID_PARAMS', '$label is not an integer');
  }
  if (out < BigInt.zero || out > _maxUint64) {
    throw ConnectException('INVALID_PARAMS', '$label is out of range');
  }
  return out;
}

/* -------------------------------------------------------------------------- *
 * Direct
 * -------------------------------------------------------------------------- */

/// A `cosmos.tx.v1beta1.SignDoc` to sign in direct mode.
class DirectSignDoc {
  const DirectSignDoc({
    required this.bodyBytes,
    required this.authInfoBytes,
    required this.chainId,
    required this.accountNumber,
  });

  /// Zunia Connect's wire form: bytes in base64 and the account number as a
  /// decimal string. Throws `INVALID_PARAMS` when a field is missing or malformed.
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

  /// The in-app browser's wire form, which is whatever a page's `Uint8Array`
  /// and `Long` became on the way: see [bytesFromWire] and [u64FromWire].
  factory DirectSignDoc.fromProvider(Object? value) {
    if (value is! Map) {
      throw const ConnectException('INVALID_PARAMS', 'signDoc must be an object');
    }
    final chainId = value['chainId'];
    if (chainId is! String || chainId.isEmpty) {
      throw const ConnectException('INVALID_PARAMS', 'signDoc.chainId is missing');
    }
    final body = bytesFromWire(value['bodyBytes'], 'signDoc.bodyBytes');
    if (body.isEmpty) {
      throw const ConnectException('INVALID_PARAMS', 'signDoc.bodyBytes is empty');
    }
    return DirectSignDoc(
      bodyBytes: body,
      authInfoBytes: bytesFromWire(value['authInfoBytes'], 'signDoc.authInfoBytes'),
      chainId: chainId,
      accountNumber: u64FromWire(value['accountNumber'], 'signDoc.accountNumber'),
    );
  }

  final Uint8List bodyBytes;
  final Uint8List authInfoBytes;
  final String chainId;
  final BigInt accountNumber;

  /// `cosmos.tx.v1beta1.SignDoc`, fields 1 to 4 in order with proto3 defaults
  /// omitted: CosmJS `makeSignBytes`, byte for byte.
  Uint8List get signBytes => ProtoWriter()
      .bytes(1, bodyBytes)
      .bytes(2, authInfoBytes)
      .string(3, chainId)
      .uint64(4, accountNumber)
      .intoBytes();

  DirectSignDoc withAuthInfo(Uint8List next) => DirectSignDoc(
        bodyBytes: bodyBytes,
        authInfoBytes: next,
        chainId: chainId,
        accountNumber: accountNumber,
      );

  /// Zunia Connect's wire form.
  Map<String, Object?> toWire() => {
        'bodyBytes': base64Encode(bodyBytes),
        'authInfoBytes': base64Encode(authInfoBytes),
        'chainId': chainId,
        'accountNumber': accountNumber.toString(),
      };

  /// The browser's: plain arrays and a decimal string survive the bridge.
  Map<String, Object?> toProviderWire() => {
        'bodyBytes': bodyBytes.toList(),
        'authInfoBytes': authInfoBytes.toList(),
        'chainId': chainId,
        'accountNumber': accountNumber.toString(),
      };
}

/* -------------------------------------------------------------------------- *
 * Keys
 * -------------------------------------------------------------------------- */

/// The account at [accountIndex] of a phrase on [chain]: derived and used by
/// the kernel, with the chain's own address scheme and signing hash.
class CosmosSigningKey {
  CosmosSigningKey({
    required String phrase,
    required this.chain,
    this.accountIndex = 0,
  }) : _phrase = phrase;

  final String _phrase;
  final ChainEntry chain;

  /// BIP-44 address index: `m/44'/<coin type>'/0'/0/<accountIndex>`.
  final int accountIndex;

  late final DerivedAccount account = WalletKernel.instance.deriveAddress(
    phrase: _phrase,
    chain: chain,
    accountIndex: accountIndex,
  );

  /// Compressed secp256k1 public key, 33 bytes.
  Uint8List get publicKey => account.publicKey;

  /// The address on [chain], or the same 20 bytes under another [prefix].
  String address([String? prefix]) {
    if (prefix == null || prefix == chain.bech32Prefix) return account.address;
    return rebech32(account.address, prefix);
  }

  /// `secp256k1` or, on a chain with Ethereum-style addresses, `eth_secp256k1`.
  String get algo => chain.usesEthAddress ? 'eth_secp256k1' : 'secp256k1';

  /// 64-byte `r||s` over [signBytes], hashed as [chain] verifies.
  Uint8List sign(List<int> signBytes) => WalletKernel.instance.signBytes(
        phrase: _phrase,
        chain: chain,
        bytes: Uint8List.fromList(signBytes),
        accountIndex: accountIndex,
      );

  /// The `StdSignature` CosmJS, Keplr and the extension hand back.
  Map<String, Object?> stdSignature(List<int> signBytes) => {
        'pub_key': {
          'type': 'tendermint/PubKeySecp256k1',
          'value': base64Encode(publicKey),
        },
        'signature': base64Encode(sign(signBytes)),
      };
}

/// Keys under one recovery phrase, for callers that know a coin type rather
/// than a chain (Zunia Connect's tests, address checks). Everything goes
/// through the kernel; prefer [CosmosSigningKey] with the real chain, which
/// also gets Ethermint addresses and keccak signing right.
class CosmosKeyring {
  CosmosKeyring(this._phrase);

  final String _phrase;

  /// `m/44'/<coinType>'/0'/0/<accountIndex>` on a plain Cosmos chain.
  CosmosSigningKey key({required int coinType, required int accountIndex}) =>
      CosmosSigningKey(
        phrase: _phrase,
        chain: _derivationChain(coinType),
        accountIndex: accountIndex,
      );

  CosmosSigningKey forChain(ChainEntry chain, {int accountIndex = 0}) =>
      CosmosSigningKey(phrase: _phrase, chain: chain, accountIndex: accountIndex);
}

/// A chain document with nothing but a coin type, SHA-256 signing and
/// Cosmos-style addresses: the kernel needs a whole one to derive.
ChainEntry _derivationChain(int coinType) => ChainEntry(
      chainId: 'cosmoshub-4',
      chainName: 'Cosmos Hub',
      bech32Prefix: 'cosmos',
      coinType: coinType,
      network: 'mainnet',
      coinDenom: 'ATOM',
      coinMinimalDenom: 'uatom',
      coinDecimals: 6,
      feeDenom: 'ATOM',
      feeMinimalDenom: 'uatom',
      feeDecimals: 6,
      features: const [],
    );

/// [address]'s bytes under [prefix]. Public data only: no key is involved.
String rebech32(String address, String prefix) {
  final decoded = bech32.decode(address, 128);
  return bech32.encode(Bech32(prefix, decoded.data), 128);
}

/// The bytes of a bech32 address, or null when it is not one.
Uint8List? bech32Bytes(String address) {
  try {
    final decoded = bech32.decode(address, 128);
    return Uint8List.fromList(_convertBits(decoded.data, 5, 8, pad: false));
  } catch (_) {
    return null;
  }
}

/// [address]'s bech32 prefix when it is one a prompt can show as it is:
/// printable lowercase ASCII, a valid checksum, and 20 bytes (an account) or 32
/// (a contract or a module account). Anything else that reads like an address,
/// a bidi override or a NUL inside it included, is not one.
String? shownAddressPrefix(Object? address) {
  if (address is! String ||
      address.isEmpty ||
      address.length > 90 ||
      address != address.toLowerCase() ||
      !RegExp(r'^[\x21-\x7e]+$').hasMatch(address)) {
    return null;
  }
  try {
    final decoded = bech32.decode(address, 90);
    final length = _convertBits(decoded.data, 5, 8, pad: false).length;
    return length == 20 || length == 32 ? decoded.hrp : null;
  } catch (_) {
    return null;
  }
}

List<int> _convertBits(List<int> data, int from, int to, {required bool pad}) {
  var acc = 0;
  var bits = 0;
  final out = <int>[];
  final maxv = (1 << to) - 1;
  for (final value in data) {
    if (value < 0 || (value >> from) != 0) {
      throw const FormatException('Invalid bech32 data');
    }
    acc = (acc << from) | value;
    bits += from;
    while (bits >= to) {
      bits -= to;
      out.add((acc >> bits) & maxv);
    }
  }
  if (pad) {
    if (bits > 0) out.add((acc << (to - bits)) & maxv);
  } else if (bits >= from || ((acc << (to - bits)) & maxv) != 0) {
    throw const FormatException('Invalid bech32 padding');
  }
  return out;
}

/// The same 20-byte account as [bech32Address], as an EIP-55 checksummed hex
/// address (what `getKey` returns on chains with Ethereum-style addresses).
String ethereumHexAddress(String bech32Address) {
  final bytes = bech32Bytes(bech32Address);
  if (bytes == null || bytes.length != 20) {
    throw const FormatException('An Ethereum address is 20 bytes');
  }
  final lower = hexOf(bytes);
  final hash = pc.KeccakDigest(256).process(Uint8List.fromList(utf8.encode(lower)));
  final out = StringBuffer('0x');
  for (var i = 0; i < lower.length; i++) {
    final ch = lower[i];
    if (RegExp(r'[0-9]').hasMatch(ch)) {
      out.write(ch);
      continue;
    }
    final byte = hash[i >> 1];
    final nibble = i.isEven ? byte >> 4 : byte & 0x0f;
    out.write(nibble >= 8 ? ch.toUpperCase() : ch);
  }
  return out.toString();
}

/* -------------------------------------------------------------------------- *
 * Results, in Zunia Connect's shapes
 * -------------------------------------------------------------------------- */

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
    key.stdSignature(adr36SignBytes(signer, data));
