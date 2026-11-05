/// Read-only REST access for the staking, governance and notification reads.
///
/// A thin layer over [HttpLcdClient], so the timeout, retry and live-reads
/// gate are the interchain engine's, and so a test can hand in a fake fetch
/// instead of opening a socket. Unlike the older `ChainClient`, a failed read
/// throws [ChainReadError] rather than coming back as an empty list: "this
/// account has no delegations" and "the endpoint did not answer" are different
/// facts, and the Earn and Governance screens say which one they have.
library;

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

enum ChainReadErrorKind {
  /// Live reads are off.
  disabled,

  /// The chain has no REST endpoint.
  noEndpoint,

  /// The endpoint answered 4xx: the route or the id does not exist there.
  notFound,

  /// Timeout, socket error or 5xx.
  unreachable,

  /// The answer was not the schema asked for.
  malformed,
}

class ChainReadError implements Exception {
  const ChainReadError(this.kind, this.message, {this.status});

  final ChainReadErrorKind kind;

  /// Developer-facing detail.
  final String message;
  final int? status;

  /// One sentence for a screen.
  String get userMessage => switch (kind) {
        ChainReadErrorKind.disabled =>
          'Live reads are off, so nothing was asked of this network.',
        ChainReadErrorKind.noEndpoint =>
          'This network has no REST endpoint configured.',
        ChainReadErrorKind.notFound =>
          'This network\'s endpoint does not offer this information.',
        ChainReadErrorKind.unreachable =>
          'This network\'s endpoint did not answer. Try again in a moment.',
        ChainReadErrorKind.malformed =>
          'This network\'s endpoint answered with something unexpected.',
      };

  @override
  String toString() => message;
}

class ChainReader {
  ChainReader({
    required bool Function() readsAllowed,
    LcdFetch? fetch,
    Duration timeout = kLcdDefaultTimeout,
  })  : _readsAllowed = readsAllowed,
        _fetch = fetch,
        _timeout = timeout;

  final bool Function() _readsAllowed;
  final LcdFetch? _fetch;
  final Duration _timeout;
  final Map<String, HttpLcdClient> _clients = {};

  bool get enabled => _readsAllowed();

  HttpLcdClient? _clientFor(ChainEntry chain) {
    final rest = chain.rest?.trim().replaceAll(RegExp(r'/+$'), '');
    if (rest == null || rest.isEmpty) return null;
    return _clients.putIfAbsent(
      '${chain.chainId}|$rest',
      () => HttpLcdClient(
        chainId: chain.chainId,
        endpoints: [rest],
        timeout: _timeout,
        readsAllowed: _readsAllowed,
        fetch: _fetch,
      ),
    );
  }

  /// GET [path] and return the decoded object.
  Future<Map<String, dynamic>> get(
    ChainEntry chain,
    String path, {
    Map<String, Object?>? query,
  }) async {
    final client = _clientFor(chain);
    if (client == null) {
      throw ChainReadError(
        ChainReadErrorKind.noEndpoint,
        '${chain.chainId}: no REST endpoint',
      );
    }
    final Object? body;
    try {
      body = await client.getJson(path, LcdRequestOptions(query: query));
    } on InterchainError catch (e) {
      final status = e.httpStatus;
      final kind = switch (e.code) {
        InterchainErrorCode.readsDisabled => ChainReadErrorKind.disabled,
        InterchainErrorCode.unsupportedChain => ChainReadErrorKind.noEndpoint,
        InterchainErrorCode.malformedResponse => ChainReadErrorKind.malformed,
        _ when status != null && status >= 400 && status < 500 =>
          ChainReadErrorKind.notFound,
        // gRPC-gateway answers an unregistered route with 501.
        _ when status == 501 => ChainReadErrorKind.notFound,
        _ => ChainReadErrorKind.unreachable,
      };
      throw ChainReadError(kind, e.message, status: status);
    }
    if (body is! Map) {
      throw ChainReadError(
        ChainReadErrorKind.malformed,
        '${chain.chainId}$path: top level is not an object',
      );
    }
    return body.cast<String, dynamic>();
  }
}

/* -------------------------------------------------------------------------- *
 * Small readers for LCD JSON, which is a stranger's node: nothing is cast
 * without a check.
 * -------------------------------------------------------------------------- */

Map<String, dynamic> asMap(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

List<Object?> asList(Object? value) => value is List ? value : const [];

String asString(Object? value, [String fallback = '']) =>
    value is String ? value : (value is num ? '$value' : fallback);

/// An LCD integer amount. Distribution totals carry a decimal tail
/// (`1234.5000…`); the tail is dropped, since the chain never pays out more
/// than the integer part. Null for anything that is not a number.
BigInt? asBaseUnits(Object? value) {
  if (value == null) return null;
  final text = asString(value).trim();
  if (text.isEmpty) return null;
  return BigInt.tryParse(text.split('.').first);
}

/// An LCD `sdk.Dec` (`"0.050000000000000000"`) as a double, for display of
/// rates and shares only, never for amounts.
double? asDecimal(Object? value) {
  final text = asString(value).trim();
  if (text.isEmpty) return null;
  final parsed = double.tryParse(text);
  return parsed != null && parsed.isFinite ? parsed : null;
}

/// The amount of [denom] in a coin list, or zero.
BigInt sumDenom(Object? rows, String denom) {
  var total = BigInt.zero;
  for (final row in asList(rows)) {
    final map = asMap(row);
    if (map['denom'] != denom) continue;
    total += asBaseUnits(map['amount']) ?? BigInt.zero;
  }
  return total;
}
