/// Mnemonic, sealing and address derivation for the app.
///
/// The Rust kernel behind `zunia_core` is the reference implementation and is
/// used whenever its native library ships with the build. When it is absent,
/// this falls back to the same BIP-39 / BIP-32 / secp256k1 / bech32 primitives
/// in pure Dart, so addresses are always real rather than placeholders. Both
/// paths agree with the golden vectors in `zunia-core/tests/vectors`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:bech32/bech32.dart';
import 'package:bip32/bip32.dart' as bip32;
import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart';
import 'package:pointycastle/digests/ripemd160.dart';
import 'package:zunia_core/zunia_core.dart';

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/keystore.dart';

class DerivedAccount {
  const DerivedAccount({
    required this.chainId,
    required this.address,
    required this.path,
    required this.publicKey,
  });

  final String chainId;
  final String address;
  final String path;
  final Uint8List publicKey;
}

class WalletKernel {
  WalletKernel._(this._core);

  static WalletKernel? _instance;

  /// Null when the native library is not bundled for this platform.
  final ZuniaCore? _core;

  static WalletKernel get instance => _instance ??= WalletKernel._(_tryOpen());

  static ZuniaCore? _tryOpen() {
    try {
      return ZuniaCore.open();
    } catch (_) {
      return null;
    }
  }

  /// True when the audited Rust kernel is doing the work.
  bool get usingNativeCore => _core != null;

  String generateMnemonic({int words = 12}) {
    final core = _core;
    if (core != null) return core.generateMnemonic(words: words);
    return bip39.generateMnemonic(strength: words == 24 ? 256 : 128);
  }

  bool validateMnemonic(String phrase) =>
      bip39.validateMnemonic(phrase.trim().replaceAll(RegExp(r'\s+'), ' '));

  String sealKeyring({
    required String phrase,
    required String password,
    Map<String, Object?> metadata = const {},
  }) {
    final core = _core;
    if (core != null) {
      return core.sealKeyring(
        phrase: phrase,
        password: password,
        metadata: metadata,
      );
    }
    return Keystore.localSealFallback(phrase: phrase, password: password);
  }

  String openKeyring({
    required String envelopeJson,
    required String password,
  }) {
    final core = _core;
    if (core != null) {
      return core.openKeyring(envelopeJson: envelopeJson, password: password);
    }
    return Keystore.localOpenFallback(
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
    final core = _core;
    if (core != null) {
      final row = core.deriveAddress(
        phrase: phrase,
        passphrase: passphrase,
        chainJson: chain.toChainJson(),
        accountIndex: accountIndex,
      );
      return DerivedAccount(
        chainId: chain.chainId,
        address: (row['bech32Address'] ?? row['address']) as String,
        path: row['path'] as String? ?? _path(chain.coinType, accountIndex),
        publicKey: _decodePubKey(row['pubKey']),
      );
    }
    return _deriveLocally(
      phrase: phrase,
      chain: chain,
      accountIndex: accountIndex,
      passphrase: passphrase,
    );
  }

  DerivedAccount _deriveLocally({
    required String phrase,
    required ChainEntry chain,
    required int accountIndex,
    required String passphrase,
  }) {
    final seed = bip39.mnemonicToSeed(phrase.trim(), passphrase: passphrase);
    final path = _path(chain.coinType, accountIndex);
    final node = bip32.BIP32.fromSeed(seed).derivePath(path);
    final pubKey = Uint8List.fromList(node.publicKey);
    final digest = RIPEMD160Digest().process(
      Uint8List.fromList(sha256.convert(pubKey).bytes),
    );
    final address = bech32.encode(
      Bech32(chain.bech32Prefix, _toWords(digest)),
    );
    return DerivedAccount(
      chainId: chain.chainId,
      address: address,
      path: path,
      publicKey: pubKey,
    );
  }

  static String _path(int coinType, int accountIndex) =>
      "m/44'/$coinType'/$accountIndex'/0/0";

  static Uint8List _decodePubKey(Object? raw) {
    if (raw is String) {
      try {
        return base64Decode(raw);
      } catch (_) {
        return Uint8List(0);
      }
    }
    if (raw is List) {
      return Uint8List.fromList(raw.cast<int>());
    }
    return Uint8List(0);
  }

  /// 8-bit groups to the 5-bit groups bech32 expects.
  static List<int> _toWords(Uint8List bytes) {
    var acc = 0;
    var bits = 0;
    final out = <int>[];
    for (final byte in bytes) {
      acc = (acc << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.add((acc >> bits) & 31);
      }
    }
    if (bits > 0) out.add((acc << (5 - bits)) & 31);
    return out;
  }
}
