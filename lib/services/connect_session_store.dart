/// Where approved zunia.connect.v2 sessions survive an app restart.
///
/// A saved session holds its resume token and both encryption keys, so it
/// lives in the Keychain / Keystore, never in plain preferences.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zunia_mobile/crypto/keystore.dart';

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
