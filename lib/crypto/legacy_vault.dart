/// LEGACY, READ-ONLY. Opens the vault format the app wrote before vault v2 so
/// the first unlock after the update can move it over. Nothing writes this
/// format any more; delete this file once no install can still hold one.
///
/// What the old keystore did, and why it is gone:
/// - It took the kernel's Argon2id envelope and "wrapped" it again with a key
///   repeated over the bytes (XOR) plus an HMAC, with no nonce. The key came
///   from 10 000 rounds of SHA-256 over the password and a 32-byte value kept
///   in secure storage. It added nothing to the envelope and its own
///   construction is broken (a repeating keystream).
/// - Without the kernel it sealed the plaintext phrase with that same XOR
///   construction (`local-xor-hmac-sha256`). That is the second inner format
///   handled here.
/// - The wrapped JSON sat in SharedPreferences (`zunia.keystore.envelope`),
///   and biometric unlock kept the password itself in secure storage.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// SharedPreferences key of the wrapped envelope.
const kLegacyEnvelopePrefsKey = 'zunia.keystore.envelope';

/// SharedPreferences key of the old single backup-verified flag.
const kLegacyVerifiedPrefsKey = 'zunia.keystore.backup_verified';

/// Secure storage keys the old keystore used. All of them are deleted once
/// the vault is migrated; the biometric ones as soon as the app starts.
const kLegacyWrappingKey = 'zunia.keystore.wrapping_key';
const kLegacyBioUnlockSecretKey = 'zunia.keystore.bio_unlock_secret';
const kLegacyBioPasswordKey = 'zunia.keystore.bio_password';

/// The old XOR wrap did not verify: wrong password or tampered data.
class LegacyVaultMacMismatch implements Exception {
  const LegacyVaultMacMismatch();
}

/// What sat inside the old wrap once it is removed.
sealed class LegacyInner {
  const LegacyInner();
}

/// A kernel `KeyringEnvelope` JSON: open it with the kernel.
class LegacyKernelEnvelope extends LegacyInner {
  const LegacyKernelEnvelope(this.envelopeJson);
  final String envelopeJson;
}

/// The plaintext phrase, from the old development fallback seal.
class LegacyPlainPhrase extends LegacyInner {
  const LegacyPlainPhrase(this.phrase);
  final String phrase;
}

abstract final class LegacyVault {
  /// Removes the outer XOR wrap and, when the inner layer is the old
  /// fallback seal, that one too. Throws [LegacyVaultMacMismatch] on a wrong
  /// password.
  static LegacyInner open({
    required String wrappedJson,
    required String wrappingKeyB64,
    required String password,
  }) {
    final inner = _xorOpen(
      wrappedJson,
      password,
      base64Decode(wrappingKeyB64),
    );
    Object? decoded;
    try {
      decoded = jsonDecode(inner);
    } catch (_) {
      decoded = null;
    }
    if (decoded is Map && decoded['alg'] == 'local-xor-hmac-sha256') {
      final salt = base64Decode(decoded['salt'] as String);
      return LegacyPlainPhrase(_xorOpen(inner, password, salt));
    }
    return LegacyKernelEnvelope(inner);
  }

  /// `{ct, mac}` under SHA-256^10000(password || salt), as the old code wrote.
  static String _xorOpen(String json, String password, List<int> salt) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    final ct = base64Decode(map['ct'] as String);
    final mac = base64Decode(map['mac'] as String);
    final key = _deriveKey(password, salt);
    final expect = Hmac(sha256, key).convert(ct).bytes;
    if (!_constantTimeEquals(expect, mac)) {
      throw const LegacyVaultMacMismatch();
    }
    final plain = Uint8List(ct.length);
    for (var i = 0; i < ct.length; i++) {
      plain[i] = ct[i] ^ key[i % key.length];
    }
    return utf8.decode(plain);
  }

  static List<int> _deriveKey(String password, List<int> salt) {
    var digest = sha256.convert([...utf8.encode(password), ...salt]).bytes;
    for (var i = 0; i < 10000; i++) {
      digest = sha256.convert(digest).bytes;
    }
    return digest;
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
