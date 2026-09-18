/// The engine's only transport.
///
/// Dart mirror of `lcd.ts`. Every network read in this directory goes through
/// an [LcdClient], so the timeout, retry, failover, cache and the host's
/// live-reads gate have exactly one definition. A module that reached for
/// `HttpClient` directly would have its own timeouts and its own idea of what a
/// failure means, which is how the three implementations this package replaces
/// ended up disagreeing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'types.dart';

/// Per-attempt budget. Matches `lcd.ts`'s 9s default.
const Duration kLcdDefaultTimeout = Duration(seconds: 9);

/// Extra attempts per endpoint after the first.
const int kLcdDefaultRetries = 1;

/// First backoff delay; doubles per attempt.
const Duration kLcdDefaultBackoff = Duration(milliseconds: 250);

/// Cache capacity before the oldest entries are dropped.
const int kLcdMaxCacheEntries = 128;

/// Per-call knobs.
@immutable
class LcdRequestOptions {
  const LcdRequestOptions({this.timeout, this.cacheTtl, this.query});

  final Duration? timeout;

  /// `Duration.zero` bypasses the cache for this call.
  final Duration? cacheTtl;

  /// Query parameters. A null value is dropped, so an optional filter can be
  /// passed unconditionally.
  final Map<String, Object?>? query;

  LcdRequestOptions copyWith({
    Duration? timeout,
    Duration? cacheTtl,
    Map<String, Object?>? query,
  }) =>
      LcdRequestOptions(
        timeout: timeout ?? this.timeout,
        cacheTtl: cacheTtl ?? this.cacheTtl,
        query: query ?? this.query,
      );
}

/// One HTTP answer, as much as this transport cares about.
@immutable
class LcdResponse {
  const LcdResponse(this.status, this.body);

  final int status;
  final String body;
}

/// Pluggable transport, so tests never open a socket.
typedef LcdFetch = Future<LcdResponse> Function(Uri uri, Duration timeout);

/// Read-only JSON access to one chain.
abstract class LcdClient {
  String get chainId;

  /// GET [path] and decode the body.
  ///
  /// Returns the decoded JSON as [Object] (a `Map<String, dynamic>` or a
  /// `List<dynamic>`); callers narrow it themselves, because an LCD is a
  /// stranger's node and a cast that throws in a screen is worse than a null
  /// check in a parser.
  ///
  /// Throws [InterchainError] `readsDisabled` when the host gate is off,
  /// `lcdUnreachable` when every endpoint failed (with [InterchainError
  /// .httpStatus] set when the last failure had one), and `malformedResponse`
  /// when the body is not JSON.
  Future<Object?> getJson(String path, [LcdRequestOptions? options]);
}

/// Builds a read client for a chain.
typedef LcdClientFactory = LcdClient Function(ChainInfo chain);

/// REST base URLs for a chain, trailing slashes trimmed, duplicates dropped.
List<String> lcdEndpointsFromChain(ChainInfo chain) {
  final rest = chain.rest?.trim();
  if (rest == null || rest.isEmpty) return const [];
  return [rest.replaceAll(RegExp(r'/+$'), '')];
}

@immutable
class _CacheEntry {
  const _CacheEntry(this.value, this.expiresAt);

  final Object? value;
  final DateTime expiresAt;
}

/// The default [LcdClient].
class HttpLcdClient implements LcdClient {
  HttpLcdClient({
    required this.chainId,
    required List<String> endpoints,
    this.timeout = kLcdDefaultTimeout,
    this.retries = kLcdDefaultRetries,
    this.cacheTtl = Duration.zero,
    this.backoff = kLcdDefaultBackoff,
    bool Function()? readsAllowed,
    LcdFetch? fetch,
    DateTime Function()? now,
  })  : _endpoints = endpoints,
        _readsAllowed = readsAllowed,
        _fetch = fetch ?? _httpFetch,
        _now = now ?? DateTime.now;

  @override
  final String chainId;

  final List<String> _endpoints;
  final Duration timeout;
  final int retries;
  final Duration cacheTtl;
  final Duration backoff;
  final bool Function()? _readsAllowed;
  final LcdFetch _fetch;
  final DateTime Function() _now;

  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  static Future<LcdResponse> _httpFetch(Uri uri, Duration timeout) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);
      return LcdResponse(response.statusCode, body);
    } finally {
      client.close(force: true);
    }
  }

  Uri _uri(String base, String path, Map<String, Object?>? query) {
    final uri = Uri.parse('$base$path');
    if (query == null || query.isEmpty) return uri;
    final merged = <String, String>{...uri.queryParameters};
    for (final entry in query.entries) {
      final value = entry.value;
      if (value == null) continue;
      merged[entry.key] = '$value';
    }
    return uri.replace(queryParameters: merged.isEmpty ? null : merged);
  }

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    final allowed = _readsAllowed?.call() ?? true;
    if (!allowed) {
      throw InterchainError(
        InterchainErrorCode.readsDisabled,
        '$chainId: live reads are off',
        chainId: chainId,
      );
    }
    if (_endpoints.isEmpty) {
      throw InterchainError(
        InterchainErrorCode.unsupportedChain,
        'No REST endpoint for $chainId',
        chainId: chainId,
      );
    }

    final ttl = options?.cacheTtl ?? cacheTtl;
    final key = _uri(_endpoints.first, path, options?.query).toString();
    if (ttl > Duration.zero) {
      final hit = _cache[key];
      if (hit != null && hit.expiresAt.isAfter(_now())) return hit.value;
    }

    final budget = options?.timeout ?? timeout;
    InterchainError? last;

    for (final base in _endpoints) {
      final uri = _uri(base, path, options?.query);
      for (var attempt = 0; attempt <= retries; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(backoff * (1 << (attempt - 1)));
        }
        try {
          final response = await _fetch(uri, budget);
          if (response.status < 200 || response.status >= 300) {
            last = InterchainError(
              InterchainErrorCode.lcdUnreachable,
              '$chainId: $base answered HTTP ${response.status}',
              chainId: chainId,
              endpoint: base,
              httpStatus: response.status,
            );
            // 4xx is the node's considered answer: the route does not exist or
            // the id is unknown. Retrying cannot change it, and callers read
            // the status to tell "not found" from "unreachable".
            if (response.status >= 400 && response.status < 500) break;
            continue;
          }
          final Object? decoded;
          try {
            decoded = jsonDecode(response.body.isEmpty ? 'null' : response.body);
          } on FormatException catch (error) {
            throw InterchainError(
              InterchainErrorCode.malformedResponse,
              '$chainId: $base answered with something that is not JSON',
              chainId: chainId,
              endpoint: base,
              cause: error,
            );
          }
          if (ttl > Duration.zero) _remember(key, decoded, ttl);
          return decoded;
        } on InterchainError {
          rethrow;
        } on TimeoutException catch (error) {
          last = InterchainError(
            InterchainErrorCode.lcdUnreachable,
            '$chainId: $base did not answer within ${budget.inSeconds}s',
            chainId: chainId,
            endpoint: base,
            cause: error,
          );
        } on IOException catch (error) {
          last = InterchainError(
            InterchainErrorCode.lcdUnreachable,
            '$chainId: could not reach $base',
            chainId: chainId,
            endpoint: base,
            cause: error,
          );
        }
      }
    }

    throw last ??
        InterchainError(
          InterchainErrorCode.lcdUnreachable,
          '$chainId: every REST endpoint failed',
          chainId: chainId,
        );
  }

  void _remember(String key, Object? value, Duration ttl) {
    if (_cache.length >= kLcdMaxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = _CacheEntry(value, _now().add(ttl));
  }
}

/// Build a factory that turns a chain into a client.
///
/// A chain with no REST endpoint yields a client that throws
/// `unsupportedChain` on first use rather than a null: callers already handle
/// that code as the UI state "no endpoint for this chain", and a nullable
/// factory would make every call site invent its own message.
LcdClientFactory createLcdClientFactory({
  bool Function()? readsAllowed,
  Duration timeout = kLcdDefaultTimeout,
  Duration cacheTtl = Duration.zero,
  LcdFetch? fetch,
}) {
  final cache = <String, LcdClient>{};
  return (ChainInfo chain) => cache.putIfAbsent(
        chain.chainId,
        () => HttpLcdClient(
          chainId: chain.chainId,
          endpoints: lcdEndpointsFromChain(chain),
          timeout: timeout,
          cacheTtl: cacheTtl,
          readsAllowed: readsAllowed,
          fetch: fetch,
        ),
      );
}
