/// The CometBFT WebSocket dialect, as pure functions.
///
/// Dart mirror of zunia-extension/lib/realtime-protocol.ts. A Cosmos node
/// exposes a JSON-RPC subscription endpoint at `/websocket` on the host the
/// chain registry lists as `rpc`. Subscribing there is the only way a wallet
/// learns about an incoming transfer the moment it happens; every other path
/// finds out later, by asking again.
///
/// Nothing here touches the network or a clock: the framing and the event
/// parsing are the parts that are easy to get subtly wrong (base64 attributes
/// on CometBFT 0.34, plain strings on 0.37+, multi-coin amounts, the wallet's
/// own transfer coming back as "incoming"), so they are tested on their own.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/notifications/notices.dart';

enum TxDirection { received, sent }

/// One subscription the wallet holds open. [direction] is fixed by the query,
/// so it is known before any frame arrives and cannot be misread afterwards.
@immutable
class Subscription {
  const Subscription({
    required this.id,
    required this.chainId,
    required this.address,
    required this.direction,
    required this.query,
  });

  final String id;
  final String chainId;
  final String address;
  final TxDirection direction;
  final String query;
}

/// `wss://` URL of a node's subscription endpoint, or null when the RPC is not
/// usable. `https` becomes `wss` and `http` becomes `ws` (a local dev node);
/// anything else is refused rather than guessed at, because a wrong scheme
/// shows up as a silent "realtime never connects".
String? websocketUrl(String? rpc) {
  final raw = rpc?.trim() ?? '';
  if (raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return null;
  final String scheme;
  switch (uri.scheme) {
    case 'https':
    case 'wss':
      scheme = 'wss';
    case 'http':
    case 'ws':
      scheme = 'ws';
    default:
      return null;
  }
  // Registry rows disagree about the trailing slash, and `//websocket` 404s on
  // several public nodes.
  final path = '${uri.path.replaceAll(RegExp(r'/+$'), '')}/websocket';
  return Uri(
    scheme: scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path,
  ).toString();
}

/// Bech32 cannot contain a quote, so this only matters for a custom chain
/// whose prefix was typed by hand: an unescaped quote would make the node
/// reject the query, which reads as "realtime is broken here".
String _quoted(String value) => "'${value.replaceAll("'", '')}'";

/// The two queries that together cover everything that moves this address's
/// balance: coins arriving (from a stranger, a relayer, a reward withdrawal)
/// and transactions it signed, including on another device.
List<Subscription> subscriptionsFor(String chainId, String address) {
  final escaped = _quoted(address);
  return [
    Subscription(
      id: '$chainId|$address|in',
      chainId: chainId,
      address: address,
      direction: TxDirection.received,
      query: "tm.event='Tx' AND transfer.recipient=$escaped",
    ),
    Subscription(
      id: '$chainId|$address|out',
      chainId: chainId,
      address: address,
      direction: TxDirection.sent,
      query: "tm.event='Tx' AND message.sender=$escaped",
    ),
  ];
}

String subscribeFrame(Subscription subscription) => jsonEncode({
      'jsonrpc': '2.0',
      'id': subscription.id,
      'method': 'subscribe',
      'params': {'query': subscription.query},
    });

/// A transaction the node told us about, reduced to what the wallet acts on.
@immutable
class TxNotice {
  const TxNotice({
    required this.subscriptionId,
    required this.chainId,
    required this.address,
    required this.direction,
    required this.hash,
    required this.height,
    required this.coins,
    required this.action,
    required this.succeeded,
  });

  final String subscriptionId;
  final String chainId;
  final String address;
  final TxDirection direction;
  final String hash;
  final int height;

  /// Coins credited to (or debited from) [address] in this transaction.
  final List<MovedCoin> coins;

  /// The first `message.action`, when the node reported one.
  final String? action;

  /// False when the transaction was included but failed.
  final bool succeeded;
}

sealed class ParsedFrame {
  const ParsedFrame();
}

final class TxFrame extends ParsedFrame {
  const TxFrame(this.notice);
  final TxNotice notice;
}

final class AckFrame extends ParsedFrame {
  const AckFrame(this.subscriptionId);
  final String subscriptionId;
}

final class ErrorFrame extends ParsedFrame {
  const ErrorFrame(this.subscriptionId, this.message);
  final String? subscriptionId;
  final String message;
}

final class IgnoredFrame extends ParsedFrame {
  const IgnoredFrame();
}

final _base64Re = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');
final _printableRe = RegExp(r'^[\x20-\x7e]*$');

/// CometBFT 0.34 base64-encodes every event attribute; 0.37+ sends plain
/// strings. A decode is only accepted when it round-trips and reads as
/// printable text: `sender` is itself valid base64, and a naive decode would
/// turn readable keys into mojibake on a modern node.
String decodeAttribute(String value) {
  if (value.isEmpty) return value;
  if (!_base64Re.hasMatch(value) || value.length % 4 != 0) return value;
  try {
    final bytes = base64.decode(value);
    final decoded = latin1.decode(bytes);
    if (!_printableRe.hasMatch(decoded)) return value;
    if (base64.encode(bytes) != value) return value;
    return decoded;
  } on FormatException {
    return value;
  }
}

/// Split a bank/ICS20 `amount` attribute (`1000uatom,25ibc/27…`) into coins.
/// The denom starts at the first non-digit; it may itself hold digits and
/// slashes, which is why a `\d+[a-z]+` regex drops every IBC denom.
List<MovedCoin> parseCoins(String amount) {
  final coins = <MovedCoin>[];
  for (final part in amount.split(',')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final split = trimmed.indexOf(RegExp(r'[^0-9]'));
    if (split <= 0) continue;
    coins.add(MovedCoin(trimmed.substring(split), trimmed.substring(0, split)));
  }
  return coins;
}

/// Coins that moved to or from [address], read pairwise from the flattened
/// event map: `transfer.recipient[i]` belongs with `transfer.amount[i]`, so a
/// multi-send or a swap that pays out and takes a fee is read correctly.
List<MovedCoin> coinsForAddress(
  Map<String, List<String>> events,
  String address,
  TxDirection direction,
) {
  final party = direction == TxDirection.received
      ? 'transfer.recipient'
      : 'transfer.sender';
  final parties = events[party] ?? const [];
  final amounts = events['transfer.amount'] ?? const [];
  final totals = <String, BigInt>{};
  for (var i = 0; i < parties.length; i++) {
    if (parties[i] != address || i >= amounts.length) continue;
    for (final coin in parseCoins(amounts[i])) {
      final value = BigInt.tryParse(coin.amount);
      if (value == null) continue;
      totals[coin.denom] = (totals[coin.denom] ?? BigInt.zero) + value;
    }
  }
  return [
    for (final e in totals.entries) MovedCoin(e.key, e.value.toString()),
  ];
}

Map<String, List<String>> _normalizeEvents(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, List<String>>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String || value is! List) continue;
    out[decodeAttribute(key)] = [
      for (final v in value)
        if (v is String) decodeAttribute(v),
    ];
  }
  return out;
}

/// Turn one frame off the socket into something the caller can act on.
/// Anything unrecognised is ignored, never thrown: a node adding a field must
/// not drop a live subscription.
ParsedFrame parseFrame(String raw, String chainId) {
  Object? message;
  try {
    message = jsonDecode(raw);
  } on FormatException {
    return const IgnoredFrame();
  }
  if (message is! Map) return const IgnoredFrame();
  final id = message['id'] is String ? message['id'] as String : null;

  final error = message['error'];
  if (error is Map) {
    final data = error['data'] is String ? error['data'] as String : null;
    final text = error['message'] is String
        ? error['message'] as String
        : 'RPC error';
    return ErrorFrame(id, data == null ? text : '$text: $data');
  }

  final result = message['result'];
  if (result is! Map) return const IgnoredFrame();
  // A subscribe call is answered with an empty result before events flow.
  if (result.isEmpty) {
    return id == null ? const IgnoredFrame() : AckFrame(id);
  }

  final events = _normalizeEvents(result['events']);
  final hashes = events['tx.hash'];
  if (id == null || hashes == null || hashes.isEmpty) {
    return const IgnoredFrame();
  }
  final parts = id.split('|');
  if (parts.length < 3) return const IgnoredFrame();
  final address = parts[1];
  final direction =
      parts[2] == 'out' ? TxDirection.sent : TxDirection.received;

  final data = result['data'];
  final value = data is Map ? data['value'] : null;
  final txResult = value is Map ? value['TxResult'] : null;
  final inner = txResult is Map ? txResult['result'] : null;
  final heights = events['tx.height'];
  final height = int.tryParse(
        heights != null && heights.isNotEmpty
            ? heights.first
            : (txResult is Map && txResult['height'] is String
                ? txResult['height'] as String
                : '0'),
      ) ??
      0;
  final code = inner is Map ? inner['code'] : null;
  final actions = events['message.action'];

  return TxFrame(
    TxNotice(
      subscriptionId: id,
      chainId: chainId,
      address: address,
      direction: direction,
      hash: hashes.first,
      height: height,
      coins: coinsForAddress(events, address, direction),
      action: actions != null && actions.isNotEmpty ? actions.first : null,
      succeeded: code == null || code == 0,
    ),
  );
}

/// An incoming transfer in the shape the feed takes; outgoing and failed
/// transactions are not arrivals.
ArrivalNotice? arrivalFrom(TxNotice notice, int at) {
  if (notice.direction != TxDirection.received || !notice.succeeded) {
    return null;
  }
  if (notice.coins.isEmpty) return null;
  return ArrivalNotice(
    chainId: notice.chainId,
    hash: notice.hash,
    coins: notice.coins,
    at: at,
  );
}

/// Backoff ceiling. Past this a node is down, not busy, and polling covers it.
const maxBackoff = Duration(seconds: 60);
const _baseBackoffMs = 1000;

/// Delay before retry [attempt] (0-based), with full jitter, so every install
/// watching the same public node does not reconnect on the same schedule.
Duration backoffDelay(int attempt, [Random? random]) {
  final r = random ?? Random();
  final ceiling = min(
    maxBackoff.inMilliseconds,
    _baseBackoffMs * pow(2, max(0, min(attempt, 16))).toInt(),
  );
  return Duration(
    milliseconds:
        (_baseBackoffMs + r.nextDouble() * max(0, ceiling - _baseBackoffMs))
            .round(),
  );
}
