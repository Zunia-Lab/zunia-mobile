/// Push registration: the addresses Zunia's server may wake this device for.
///
/// The server (zunia-backend, `POST /v1/devices/subscribe`) keeps this
/// device's Firebase token and, per (chain, address) pair, a salted hash of
/// the address; its indexer watches the address itself. A push it sends says
/// only "New activity in your wallet" and which chain, never an amount or an
/// address. It is what reaches the user while the app is closed, which the
/// notice engine cannot do.
///
/// Rules:
///
/// 1. Opt-in only. Nothing is registered, and no token is even created,
///    until the user has device notifications on, transfers shown, live reads
///    on (the same privacy gate as the chain sockets), and the system allows
///    notifications.
/// 2. Registered while unlocked, kept while locked. The pairs come from the
///    session phrase, so they can only be sent while unlocked; the point is
///    to hear about activity once the app is closed.
/// 3. The server follows the device. A different token or set of pairs first
///    removes the device (and every pair it had), then registers the new set,
///    so an address no longer watched stops waking the phone. An unchanged
///    set is posted again every [pushRefreshInterval], in case the server lost
///    it. Turning notifications off or erasing the wallet removes the device.
/// 4. Only a hash of what was registered is kept here, with the token: the
///    addresses are never stored for this.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How often an unchanged registration is posted again.
const pushRefreshInterval = Duration(days: 7);

const _kRecord = 'zunia.push.registration';

enum PushPlatform { android, ios }

/// The platform this build registers as.
PushPlatform get currentPushPlatform =>
    defaultTargetPlatform == TargetPlatform.iOS
        ? PushPlatform.ios
        : PushPlatform.android;

/// One address the server watches for this device.
@immutable
class PushPair {
  const PushPair(this.chainId, this.address);

  final String chainId;
  final String address;

  String get key => '$chainId|$address';

  @override
  bool operator ==(Object other) =>
      other is PushPair && other.chainId == chainId && other.address == address;

  @override
  int get hashCode => Object.hash(chainId, address);

  @override
  String toString() => 'PushPair($key)';
}

/// What the registrar is told about the app.
@immutable
class PushInputs {
  const PushInputs({
    required this.wanted,
    required this.pairs,
    this.locale = 'en',
  });

  /// Every consent in rule 1 holds.
  final bool wanted;

  /// The active account's watched pairs. Empty while locked.
  final List<PushPair> pairs;

  /// The device language, for the server's wording.
  final String locale;

  String get _key => [
        wanted,
        locale,
        ...[for (final pair in pairs) pair.key]..sort(),
      ].join('\n');
}

/// A request the server refused or never answered.
class PushBackendException implements Exception {
  const PushBackendException(this.message);

  final String message;

  @override
  String toString() => 'PushBackendException: $message';
}

/// The server's device endpoints.
abstract class PushBackend {
  Future<void> subscribe({
    required PushPlatform platform,
    required String token,
    required String locale,
    required PushPair pair,
  });

  /// Removes the device and every pair it had.
  Future<void> unsubscribe({
    required PushPlatform platform,
    required String token,
  });
}

/// The Firebase token, behind an interface so tests need no Firebase.
abstract class PushTokens {
  /// Creates the token when there is none yet. Null when push is unavailable
  /// (no Firebase, no APNs token yet).
  Future<String?> token();

  /// A new token replaced the old one.
  Stream<String> get refreshed;

  /// Drops the token, so nothing can be sent to it again.
  Future<void> delete();
}

/// What was last registered.
@immutable
class PushRecord {
  const PushRecord({
    required this.platform,
    required this.token,
    required this.fingerprint,
    required this.at,
  });

  final PushPlatform platform;
  final String token;

  /// [pushFingerprint] of what the server holds.
  final String fingerprint;
  final DateTime at;

  Map<String, Object> toJson() => {
        'platform': platform.name,
        'token': token,
        'fingerprint': fingerprint,
        'at': at.millisecondsSinceEpoch,
      };

  static PushRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    final platform = PushPlatform.values
        .where((p) => p.name == value['platform'])
        .firstOrNull;
    final token = value['token'];
    final fingerprint = value['fingerprint'];
    final at = value['at'];
    if (platform == null ||
        token is! String ||
        token.isEmpty ||
        fingerprint is! String ||
        at is! int) {
      return null;
    }
    return PushRecord(
      platform: platform,
      token: token,
      fingerprint: fingerprint,
      at: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

abstract class PushRecordStore {
  Future<PushRecord?> read();
  Future<void> write(PushRecord record);
  Future<void> clear();
}

/// Kept under `zunia.`, so removing the wallet clears it with the rest.
class PrefsPushRecordStore implements PushRecordStore {
  @override
  Future<PushRecord?> read() async {
    final raw = (await SharedPreferences.getInstance()).getString(_kRecord);
    if (raw == null) return null;
    try {
      return PushRecord.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(PushRecord record) async {
    final store = await SharedPreferences.getInstance();
    await store.setString(_kRecord, jsonEncode(record.toJson()));
  }

  @override
  Future<void> clear() async {
    await (await SharedPreferences.getInstance()).remove(_kRecord);
  }
}

class MemoryPushRecordStore implements PushRecordStore {
  PushRecord? record;

  @override
  Future<PushRecord?> read() async => record;

  @override
  Future<void> write(PushRecord record) async => this.record = record;

  @override
  Future<void> clear() async => record = null;
}

/// A hash of what the server holds for this device: the platform, the token,
/// the locale and the sorted pairs.
String pushFingerprint(
  PushPlatform platform,
  String token,
  String locale,
  Iterable<PushPair> pairs,
) {
  final keys = [for (final pair in pairs) pair.key]..sort();
  final canonical = [platform.name, token, locale, ...keys].join('\n');
  return sha256.convert(utf8.encode(canonical)).toString();
}

/// Keeps the server's registration in step with [PushInputs].
class PushRegistrar {
  PushRegistrar({
    required this.backend,
    required this.tokens,
    required this.store,
    PushPlatform? platform,
    DateTime Function()? clock,
  })  : platform = platform ?? currentPushPlatform,
        _clock = clock ?? DateTime.now {
    _refreshSub = tokens.refreshed.listen((_) {
      final latest = _latest;
      if (latest != null) unawaited(sync(latest, force: true));
    });
  }

  final PushBackend backend;
  final PushTokens tokens;
  final PushRecordStore store;
  final PushPlatform platform;
  final DateTime Function() _clock;

  StreamSubscription<String>? _refreshSub;
  PushInputs? _latest;
  Future<void>? _running;
  bool _again = false;
  bool _againForced = false;

  /// The inputs of the last sync that left the server up to date, and when.
  String? _settledKey;
  DateTime? _settledAt;

  /// Bring the server in line with [inputs]. Calls never overlap: one made
  /// while another runs is folded into a single further run with the latest
  /// inputs. Never throws; what failed is retried on the next call.
  Future<void> sync(PushInputs inputs, {bool force = false}) {
    _latest = inputs;
    final running = _running;
    if (running != null) {
      _again = true;
      _againForced = _againForced || force;
      return running;
    }
    final run = _drain(force);
    _running = run;
    return run.whenComplete(() => _running = null);
  }

  Future<void> _drain(bool force) async {
    var forced = force;
    do {
      _again = false;
      final inputs = _latest!;
      try {
        await _syncOnce(inputs, forced);
      } on Object catch (e) {
        debugPrint('push registration: $e');
      }
      forced = _againForced;
      _againForced = false;
    } while (_again);
  }

  Future<void> _syncOnce(PushInputs inputs, bool force) async {
    final now = _clock();
    final settledAt = _settledAt;
    if (!force &&
        _settledKey == inputs._key &&
        settledAt != null &&
        now.difference(settledAt) < pushRefreshInterval) {
      return;
    }
    if (!inputs.wanted) {
      await _remove(deleteToken: true);
      _settle(inputs, now);
      return;
    }
    // Locked: nothing to send, and what the server holds stays.
    if (inputs.pairs.isEmpty) return;

    final token = await tokens.token();
    if (token == null || token.isEmpty) return;
    final record = await store.read();
    final fingerprint =
        pushFingerprint(platform, token, inputs.locale, inputs.pairs);
    if (record != null &&
        record.fingerprint == fingerprint &&
        now.difference(record.at) < pushRefreshInterval) {
      _settle(inputs, now);
      return;
    }
    if (record != null && record.fingerprint != fingerprint) {
      // Another token or set: clear the old device first, so a pair no
      // longer watched stops waking this phone.
      await backend.unsubscribe(platform: record.platform, token: record.token);
      await store.clear();
    }
    for (final pair in inputs.pairs) {
      await backend.subscribe(
        platform: platform,
        token: token,
        locale: inputs.locale,
        pair: pair,
      );
    }
    await store.write(
      PushRecord(
        platform: platform,
        token: token,
        fingerprint: fingerprint,
        at: now,
      ),
    );
    _settle(inputs, now);
  }

  void _settle(PushInputs inputs, DateTime at) {
    _settledKey = inputs._key;
    _settledAt = at;
  }

  /// Removes the device from the server, when it was ever registered.
  /// Without a record nothing is sent: a device that never opted in must not
  /// reach the server at all.
  Future<void> _remove({required bool deleteToken}) async {
    final record = await store.read();
    if (record == null) return;
    await backend.unsubscribe(platform: record.platform, token: record.token);
    await store.clear();
    if (deleteToken) await tokens.delete();
  }

  /// The wallet is being erased: take the device off the server now, before
  /// the stored record goes with the rest of the wallet's preferences.
  Future<void> forget() async {
    _latest = null;
    _settledKey = null;
    _settledAt = null;
    try {
      await _running;
      await _remove(deleteToken: true);
    } on Object catch (e) {
      debugPrint('push registration (erase): $e');
    }
  }

  Future<void> dispose() async {
    await _refreshSub?.cancel();
  }
}

/// [PushBackend] over HTTPS (zunia-backend's `/v1/devices/...`).
class HttpPushBackend implements PushBackend {
  HttpPushBackend(this.base, {this.timeout = const Duration(seconds: 15)});

  /// The server's origin, `https://api.zunialab.com`.
  final Uri base;
  final Duration timeout;

  @override
  Future<void> subscribe({
    required PushPlatform platform,
    required String token,
    required String locale,
    required PushPair pair,
  }) =>
      _send('POST', '/v1/devices/subscribe', {
        'platform': platform.name,
        'pushToken': token,
        'locale': locale,
        'prefs': const <String, Object>{},
        'chainId': pair.chainId,
        'address': pair.address,
      });

  @override
  Future<void> unsubscribe({
    required PushPlatform platform,
    required String token,
  }) =>
      _send('DELETE', '/v1/devices/unsubscribe', {
        'platform': platform.name,
        'pushToken': token,
      });

  Future<void> _send(String method, String path, Map<String, Object> body) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request =
          await client.openUrl(method, base.resolve(path)).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PushBackendException('$method $path: HTTP ${response.statusCode}');
      }
    } on PushBackendException {
      rethrow;
    } on Object catch (e) {
      throw PushBackendException('$method $path: $e');
    } finally {
      client.close(force: true);
    }
  }
}
