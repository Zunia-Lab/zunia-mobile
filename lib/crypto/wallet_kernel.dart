/// Mnemonics, sealing, derivation and signing for the app: all of it in the
/// Rust kernel (`zunia_core`), the same code the extension runs as WebAssembly.
///
/// There is no Dart fallback. A second implementation is a second set of
/// addresses and a second set of bugs: the one this app used to carry derived
/// Ethermint addresses wrong and sealed the phrase with a repeating-key XOR. A
/// build without its native library cannot sign, and says so (see
/// [WalletKernel.isAvailable] and `KernelMissingScreen`).
library;

import 'dart:convert';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/foundation.dart';
import 'package:zunia_core/zunia_core.dart';

import 'package:zunia_mobile/chains/chain_catalog.dart';

class DerivedAccount {
  const DerivedAccount({
    required this.chainId,
    required this.address,
    required this.path,
    required this.publicKey,
    this.ethAddress,
  });

  final String chainId;
  final String address;

  /// `m/44'/<coin type>'/0'/0/<index>`, as the extension derives it.
  final String path;

  /// 33-byte compressed secp256k1 key.
  final Uint8List publicKey;

  /// `0x...` on chains that derive Ethereum-style addresses.
  final String? ethAddress;

  String get publicKeyHex => _hex(publicKey);
}

/// The native kernel did not load: the build is missing `libzunia_ffi`.
class KernelUnavailableException implements Exception {
  const KernelUnavailableException(this.reason);
  final String reason;

  @override
  String toString() => 'Signing core unavailable: $reason';
}

class WalletKernel {
  WalletKernel._(this._core, this._loadError);

  static WalletKernel? _instance;

  final ZuniaCore? _core;
  final String? _loadError;

  static WalletKernel get instance => _instance ??= _open();

  static WalletKernel _open() {
    try {
      return WalletKernel._(ZuniaCore.open(), null);
    } catch (e) {
      return WalletKernel._(null, '$e');
    }
  }

  /// Uses [core] instead of the bundled library: tests on the host load a
  /// kernel built for the development machine.
  @visibleForTesting
  static void debugUse(ZuniaCore? core) {
    _instance = core == null ? null : WalletKernel._(core, null);
  }

  /// True when the native kernel loaded. Nothing can be signed otherwise.
  bool get isAvailable => _core != null;

  /// Kept for the About row: the kernel is the only path there is.
  bool get usingNativeCore => isAvailable;

  /// Why the kernel did not load, for the screen that says so.
  String? get loadError => _loadError;

  String get kernelVersion => _require().kernelVersion;

  ZuniaCore get core => _require();

  ZuniaCore _require() {
    final core = _core;
    if (core == null) {
      throw KernelUnavailableException(_loadError ?? 'not loaded');
    }
    return core;
  }

  String generateMnemonic({int words = 12}) =>
      _require().generateMnemonic(words: words);

  /// Checksum and word list only; does not touch key material.
  bool validateMnemonic(String phrase) =>
      bip39.validateMnemonic(normalizePhrase(phrase));

  static String normalizePhrase(String phrase) =>
      phrase.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Argon2id + AEAD envelope (zunia-core `KeyringEnvelope`), as JSON.
  String sealKeyring({
    required String phrase,
    required String password,
    Map<String, Object?> metadata = const {},
  }) {
    return _require().sealKeyring(
      phrase: phrase,
      password: password,
      metadata: metadata,
    );
  }

  /// The phrase inside [envelopeJson]; throws on a wrong password.
  String openKeyring({
    required String envelopeJson,
    required String password,
  }) {
    return _require().openKeyring(
      envelopeJson: envelopeJson,
      password: password,
    );
  }

  DerivedAccount deriveAddress({
    required String phrase,
    required ChainEntry chain,
    int accountIndex = 0,
    String passphrase = '',
  }) {
    final row = _require().deriveAddress(
      phrase: phrase,
      passphrase: passphrase,
      chainJson: chain.toChainJson(),
      accountIndex: accountIndex,
    );
    return DerivedAccount(
      chainId: chain.chainId,
      address: row['address'] as String,
      path: row['path'] as String,
      publicKey: _unhex(row['publicKeyHex'] as String),
      ethAddress: row['ethAddress'] as String?,
    );
  }

  /// Signs bytes a site handed over (a Direct `SignDoc`, Amino sign bytes or
  /// an ADR-036 document) and returns the 64-byte `r||s` signature.
  ///
  /// The kernel picks SHA-256 or keccak256 from the chain's features, so a
  /// caller cannot sign an Injective document with the Cosmos hash.
  Uint8List signBytes({
    required String phrase,
    required ChainEntry chain,
    required Uint8List bytes,
    int accountIndex = 0,
  }) {
    final hex = _require().signCosmos(
      phrase: phrase,
      chainJson: chain.toChainJson(),
      accountIndex: accountIndex,
      signBytesHex: _hex(bytes),
    );
    return _unhex(hex);
  }

  /// What a Direct `SignDoc` says, in the kernel's words (payload v2). Throws
  /// when the document cannot be trusted at all.
  Map<String, dynamic> decodeDirect(Uint8List signDoc) =>
      _require().decodeDirectTx(signDocHex: _hex(signDoc));
}

String _hex(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

Uint8List _unhex(String hex) {
  final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
  if (clean.length.isOdd) throw const FormatException('odd-length hex');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Lowercase hex, as the kernel reads and writes it.
String hexOf(List<int> bytes) => _hex(bytes);

/// Bytes of a hex string, with or without `0x`.
Uint8List bytesOfHex(String hex) => _unhex(hex);

/// Base64 of a byte string; a helper for the wire formats around signing.
String b64(List<int> bytes) => base64Encode(bytes);
