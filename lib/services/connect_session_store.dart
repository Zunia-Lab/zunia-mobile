/// Where approved zunia.connect.v2 sessions survive an app restart.
///
/// A saved session holds its resume token and both encryption keys, so it
/// lives in the Keychain / Keystore, never in plain preferences.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zunia_mobile/crypto/keystore.dart';

/// Layout of a saved session row (`v`).
///
/// - 1: the first release.
/// - 2: adds `sameDevice` (paired from a link opened on this phone),
///   `returnUrl` (the `ret` target of that link), `pairedAt` (ms) and
///   `requestedChains` (what the site asked for, which the user can narrow
///   and widen again).
const int kConnectSessionSchema = 2;

/// Brings a saved row up to [kConnectSessionSchema]. Null for a row from a
/// newer app or one that is not a session at all; such rows are dropped.
Map<String, dynamic>? upgradeConnectSessionRow(Map<String, dynamic> row) {
  final version = row['v'];
  if (version == kConnectSessionSchema) return row;
  if (version == 1) {
    final chains = row['chains'];
    return {
      ...row,
      'v': kConnectSessionSchema,
      // Sessions from 0.1.0 builds were all paired by scanning.
      'sameDevice': false,
      'returnUrl': null,
      'pairedAt': null,
      'requestedChains': chains is List ? List<Object?>.of(chains) : const [],
    };
  }
  return null;
}

abstract class ConnectSessionStore {
  Future<List<Map<String, dynamic>>> load();

  Future<void> save(List<Map<String, dynamic>> sessions);
}

class SecureConnectSessionStore implements ConnectSessionStore {
  SecureConnectSessionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? createSecureStorage();

  static const _key = 'zunia.connect.v2.sessions';

  final FlutterSecureStorage _storage;

  @override
  Future<List<Map<String, dynamic>>> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [
        for (final entry in jsonDecode(raw) as List)
          if (entry is Map) Map<String, dynamic>.from(entry),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> save(List<Map<String, dynamic>> sessions) async {
    if (sessions.isEmpty) {
      await _storage.delete(key: _key);
    } else {
      await _storage.write(key: _key, value: jsonEncode(sessions));
    }
  }
}

/// What Zunia keeps about each WalletConnect session next to WalletKit's own
/// storage: which wallet account and keys it shares (so `cosmos_getAccounts`
/// is answered without unlocking), the chains it asked for and whether it was
/// opened on this phone. Keyed by session topic.
abstract class WcSessionMetaStore {
  Future<Map<String, Map<String, dynamic>>> load();

  Future<void> save(Map<String, Map<String, dynamic>> sessions);
}

class SecureWcSessionMetaStore implements WcSessionMetaStore {
  SecureWcSessionMetaStore({FlutterSecureStorage? storage})
      : _storage = storage ?? createSecureStorage();

  static const _key = 'zunia.walletconnect.sessions';

  final FlutterSecureStorage _storage;

  @override
  Future<Map<String, Map<String, dynamic>>> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map;
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is Map)
            entry.key as String: Map<String, dynamic>.from(entry.value as Map),
      };
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> save(Map<String, Map<String, dynamic>> sessions) async {
    if (sessions.isEmpty) {
      await _storage.delete(key: _key);
    } else {
      await _storage.write(key: _key, value: jsonEncode(sessions));
    }
  }
}

class MemoryWcSessionMetaStore implements WcSessionMetaStore {
  Map<String, Map<String, dynamic>> saved = {};

  @override
  Future<Map<String, Map<String, dynamic>>> load() async => {
        for (final entry in saved.entries)
          entry.key: Map<String, dynamic>.from(entry.value),
      };

  @override
  Future<void> save(Map<String, Map<String, dynamic>> sessions) async {
    saved = {
      for (final entry in (jsonDecode(jsonEncode(sessions)) as Map).entries)
        entry.key as String: Map<String, dynamic>.from(entry.value as Map),
    };
  }
}

class MemoryConnectSessionStore implements ConnectSessionStore {
  List<Map<String, dynamic>> saved = [];

  @override
  Future<List<Map<String, dynamic>>> load() async =>
      [for (final s in saved) Map<String, dynamic>.from(s)];

  @override
  Future<void> save(List<Map<String, dynamic>> sessions) async {
    saved = [
      for (final s in jsonDecode(jsonEncode(sessions)) as List)
        Map<String, dynamic>.from(s as Map),
    ];
  }
}
