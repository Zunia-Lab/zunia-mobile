/// Packet status for a transfer that has already been signed.
///
/// Dart mirror of `tracking.ts`. Nothing here signs and nothing needs the
/// user's key: every read is a public LCD query. The one divergence from the TS
/// twin is [XcsRecovery], which carries the execute body rather than an encoded
/// message — mobile's encoder lives in `crypto/amino_tx.dart` and this layer
/// must not reach into it.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'lcd.dart';
import 'types.dart';

/* -------------------------------------------------------------------------- *
 * JSON narrowing
 * -------------------------------------------------------------------------- */

Map<String, Object?>? _asRecord(Object? value) =>
    value is Map<String, Object?> ? value : null;

List<Object?> _asList(Object? value) => value is List ? value : const [];

String? _asString(Object? value) => value is String ? value : null;

/// A uint64 field as the LCD spells it. Sequences and heights are strings on
/// the wire, but a few proxies re-serialise them as numbers.
String? _asUint(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return RegExp(r'^\d+$').hasMatch(trimmed) ? trimmed : null;
  }
  if (value is int && value >= 0) return '$value';
  return null;
}

/// Plausible event type / attribute key: no spaces, no punctuation soup.
final RegExp _identifier = RegExp(r'^[A-Za-z0-9_.\-/]{1,128}$');

/// Control characters no attribute value legitimately contains.
final RegExp _controlChars = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]');

/// Decode an attribute key that may or may not be base64.
///
/// Cosmos SDK <= 0.46 typed ABCI attribute keys and values as `bytes`, so REST
/// emitted them base64-encoded; 0.47 changed them to `string`. Rather than guess
/// which SDK answered, both spellings are indexed and lookups use the plain
/// name.
String? _decodeKeyCandidate(String raw) {
  if (raw.isEmpty) return null;
  try {
    final decoded = utf8.decode(base64Decode(raw));
    return _identifier.hasMatch(decoded) ? decoded : null;
  } on Object {
    return null;
  }
}

/// Looser than [_decodeKeyCandidate]: values are JSON blobs, bech32 addresses
/// and acknowledgement strings, so only control characters disqualify a decode.
String? _decodeValueCandidate(String raw) {
  if (raw.isEmpty) return '';
  try {
    final decoded = utf8.decode(base64Decode(raw));
    return _controlChars.hasMatch(decoded) ? null : decoded;
  } on Object {
    return null;
  }
}

/// Decode a hex string to text. ibc-go emits `packet_data_hex` alongside (and on
/// some versions instead of) `packet_data`.
String? _hexToText(String raw) {
  final hex = raw.startsWith('0x') || raw.startsWith('0X') ? raw.substring(2) : raw;
  if (hex.isEmpty || hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
    return null;
  }
  final bytes = <int>[
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/* -------------------------------------------------------------------------- *
 * Events
 * -------------------------------------------------------------------------- */

/// One transaction event, with its attributes flattened and decoded.
@immutable
class DecodedTxEvent {
  const DecodedTxEvent({
    required this.type,
    required this.types,
    required this.attributes,
    required this.msgIndex,
  });

  final String type;

  /// Every spelling seen for the type, so a match can accept either.
  final List<String> types;

  final Map<String, String> attributes;

  /// Index of the message that emitted this event, when the node reports it.
  final int? msgIndex;

  String? attr(String key) {
    final value = attributes[key];
    return value == null || value.isEmpty ? null : value;
  }

  bool isType(String type) => types.contains(type);
}

DecodedTxEvent? _decodeEvent(Object? raw) {
  final row = _asRecord(raw);
  if (row == null) return null;
  final rawType = _asString(row['type']);
  if (rawType == null || rawType.isEmpty) return null;

  final decodedType = _decodeKeyCandidate(rawType);
  final types = decodedType == null || decodedType == rawType
      ? <String>[rawType]
      : <String>[rawType, decodedType];

  final attributes = <String, String>{};
  for (final entry in _asList(row['attributes'])) {
    final pair = _asRecord(entry);
    if (pair == null) continue;
    final key = _asString(pair['key']);
    if (key == null || key.isEmpty) continue;
    final value = _asString(pair['value']) ?? '';
    attributes.putIfAbsent(key, () => value);
    final plainKey = _decodeKeyCandidate(key);
    if (plainKey != null && plainKey != key) {
      attributes.putIfAbsent(
          plainKey, () => _decodeValueCandidate(value) ?? value);
    }
  }

  final msgIndexAttr = attributes['msg_index'];
  final msgIndex = row['msg_index'] is int
      ? row['msg_index'] as int
      : (msgIndexAttr != null && RegExp(r'^\d+$').hasMatch(msgIndexAttr)
          ? int.parse(msgIndexAttr)
          : null);

  return DecodedTxEvent(
    type: decodedType ?? rawType,
    types: types,
    attributes: attributes,
    msgIndex: msgIndex,
  );
}

@immutable
class _EventGroup {
  const _EventGroup(this.msgIndex, this.events);

  final int? msgIndex;
  final List<DecodedTxEvent> events;
}

/// Unwrap `{"tx_response": …}` or accept a bare `tx_response` row.
Map<String, Object?>? _txResponseOf(Object? body) {
  final row = _asRecord(body);
  if (row == null) return null;
  return _asRecord(row['tx_response']) ?? row;
}

List<_EventGroup> _eventGroupsOf(Map<String, Object?> txResponse) {
  final groups = <_EventGroup>[];

  // SDK <= 0.47 shape: `logs[].events`, already grouped by message.
  for (final log in _asList(txResponse['logs'])) {
    final row = _asRecord(log);
    if (row == null) continue;
    final events = _asList(row['events'])
        .map(_decodeEvent)
        .whereType<DecodedTxEvent>()
        .toList();
    if (events.isEmpty) continue;
    groups.add(_EventGroup(
        row['msg_index'] is int ? row['msg_index'] as int : null, events));
  }

  // Flat shape: base64 attributes on <= 0.46, plain plus a `msg_index` attribute
  // on >= 0.47, and the only shape at all on >= 0.50 where `logs` is empty for
  // successful transactions.
  final flat = _asList(txResponse['events'])
      .map(_decodeEvent)
      .whereType<DecodedTxEvent>()
      .toList();
  if (flat.isNotEmpty) {
    final byIndex = <int?, List<DecodedTxEvent>>{};
    for (final event in flat) {
      byIndex.putIfAbsent(event.msgIndex, () => <DecodedTxEvent>[]).add(event);
    }
    byIndex.forEach((msgIndex, events) {
      groups.add(_EventGroup(msgIndex, events));
    });
  }

  return groups;
}

/// Every event in a transaction response, from whichever shape it uses.
List<DecodedTxEvent> decodeTxEvents(Object? body) {
  final txResponse = _txResponseOf(body);
  if (txResponse == null) return const [];
  return [for (final group in _eventGroupsOf(txResponse)) ...group.events];
}

/* -------------------------------------------------------------------------- *
 * Packet extraction
 * -------------------------------------------------------------------------- */

/// ICS20 packet data. Every field is nullable: the shape is not in the verified
/// spec, and ICS20 v2 moved the denom and amount into a `tokens` array.
@immutable
class Ics20PacketData {
  const Ics20PacketData({
    this.denom,
    this.amount,
    this.sender,
    this.receiver,
    this.memo,
  });

  final String? denom;
  final String? amount;
  final String? sender;
  final String? receiver;

  /// The memo that drives packet-forward-middleware and ibc-hooks.
  final String? memo;
}

/// The `ibc_transfer` event, when the source transaction emitted one.
@immutable
class IbcTransferSummary {
  const IbcTransferSummary({
    this.sender,
    this.receiver,
    this.denom,
    this.amount,
    this.memo,
  });

  final String? sender;
  final String? receiver;
  final String? denom;
  final String? amount;
  final String? memo;
}

/// A packet identity: everything needed to look it up on either chain.
@immutable
class ExtractedPacket {
  const ExtractedPacket({
    required this.sequence,
    required this.sourcePort,
    required this.sourceChannelId,
    required this.destPort,
    required this.destChannelId,
    this.timeoutHeight,
    this.timeoutTimestamp,
    this.connectionId,
    this.data,
    this.rawData,
    this.transfer,
    this.txHash,
    this.height,
    this.timestamp,
  });

  final String sequence;
  final String sourcePort;
  final String sourceChannelId;
  final String destPort;

  /// May be `''` when the node did not report it; lookups then drop the filter.
  final String destChannelId;

  final String? timeoutHeight;

  /// Unix nanoseconds as a decimal string; `"0"` means no timestamp timeout.
  final String? timeoutTimestamp;

  final String? connectionId;

  /// Parsed ICS20 payload, null when the packet is not ICS20 or was not indexed.
  final Ics20PacketData? data;

  /// The raw `packet_data` JSON, for diagnostics.
  final String? rawData;

  final IbcTransferSummary? transfer;
  final String? txHash;
  final String? height;

  /// Block time, RFC 3339.
  final String? timestamp;
}

/// Parse an ICS20 packet payload.
///
/// Null when the payload is not a JSON object. A JSON object missing every known
/// field still returns a record of nulls, because a partially understood packet
/// is more useful than none.
Ics20PacketData? parseIcs20PacketData(String raw) {
  Object? parsed;
  try {
    parsed = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  final row = _asRecord(parsed);
  if (row == null) return null;

  // ICS20 v2 nests the token: {tokens:[{denom:{base,trace},amount}]}.
  var denom = _asString(row['denom']);
  var amount = _asUint(row['amount']) ?? _asString(row['amount']);
  if (denom == null || amount == null) {
    final tokens = _asList(row['tokens']);
    final token = tokens.isEmpty ? null : _asRecord(tokens.first);
    if (token != null) {
      amount ??= _asUint(token['amount']) ?? _asString(token['amount']);
      final nested = _asRecord(token['denom']);
      denom ??= _asString(token['denom']) ??
          (nested == null ? null : _asString(nested['base']));
    }
  }

  return Ics20PacketData(
    denom: denom,
    amount: amount,
    sender: _asString(row['sender']),
    receiver: _asString(row['receiver']),
    memo: _asString(row['memo']),
  );
}

String? _packetDataOf(DecodedTxEvent event) {
  final direct = event.attr('packet_data');
  if (direct != null) return direct;
  final hex = event.attr('packet_data_hex');
  return hex == null ? null : _hexToText(hex);
}

IbcTransferSummary _transferSummaryOf(DecodedTxEvent event) =>
    IbcTransferSummary(
      sender: event.attr('sender'),
      receiver: event.attr('receiver'),
      denom: event.attr('denom'),
      amount: event.attr('amount'),
      memo: event.attr('memo'),
    );

/// Every outgoing packet in a transaction, in emission order.
///
/// Accepts the `/cosmos/tx/v1beta1/txs/{hash}` envelope or a bare `tx_response`
/// row, and reads both the `logs[].events` and flat `events` shapes with either
/// base64 or plain attribute encoding.
///
/// Packets without a sequence or a source channel are dropped: they cannot be
/// looked up later, so reporting them would only produce a permanently
/// `unknown` hop.
List<ExtractedPacket> extractPacketsFromTx(Object? body) {
  final txResponse = _txResponseOf(body);
  if (txResponse == null) return const [];

  final txHash = _asString(txResponse['txhash']);
  final height = _asUint(txResponse['height']);
  final timestamp = _asString(txResponse['timestamp']);

  final order = <String>[];
  final found = <String, ExtractedPacket>{};

  for (final group in _eventGroupsOf(txResponse)) {
    // `ibc_transfer` carries the human-readable sender/receiver/amount and sits
    // in the same message as the `send_packet` it describes.
    final transfers =
        group.events.where((event) => event.isType('ibc_transfer')).toList();
    var sendIndex = 0;

    for (final event in group.events) {
      if (!event.isType('send_packet')) continue;
      final sequence = _asUint(event.attr('packet_sequence'));
      final sourceChannelId = event.attr('packet_src_channel');
      final ordinal = sendIndex;
      sendIndex += 1;
      if (sequence == null || sourceChannelId == null) continue;

      final rawData = _packetDataOf(event);
      final transferEvent = ordinal < transfers.length
          ? transfers[ordinal]
          : (transfers.length == 1 ? transfers.first : null);
      final packet = ExtractedPacket(
        sequence: sequence,
        sourcePort: event.attr('packet_src_port') ?? transferPort,
        sourceChannelId: sourceChannelId,
        destPort: event.attr('packet_dst_port') ?? transferPort,
        destChannelId: event.attr('packet_dst_channel') ?? '',
        timeoutHeight: event.attr('packet_timeout_height'),
        timeoutTimestamp: _asUint(event.attr('packet_timeout_timestamp')),
        connectionId:
            event.attr('packet_connection') ?? event.attr('connection_id'),
        data: rawData == null ? null : parseIcs20PacketData(rawData),
        rawData: rawData,
        transfer:
            transferEvent == null ? null : _transferSummaryOf(transferEvent),
        txHash: txHash,
        height: height,
        timestamp: timestamp,
      );

      final key = '${packet.sourcePort}/${packet.sourceChannelId}/'
          '${packet.sequence}';
      final existing = found[key];
      if (existing == null) {
        found[key] = packet;
        order.add(key);
      } else {
        // Fill nulls from the second sighting; the first keeps precedence.
        found[key] = ExtractedPacket(
          sequence: existing.sequence,
          sourcePort: existing.sourcePort,
          sourceChannelId: existing.sourceChannelId,
          destPort:
              existing.destPort.isEmpty ? packet.destPort : existing.destPort,
          destChannelId: existing.destChannelId.isEmpty
              ? packet.destChannelId
              : existing.destChannelId,
          timeoutHeight: existing.timeoutHeight ?? packet.timeoutHeight,
          timeoutTimestamp:
              existing.timeoutTimestamp ?? packet.timeoutTimestamp,
          connectionId: existing.connectionId ?? packet.connectionId,
          data: existing.data ?? packet.data,
          rawData: existing.rawData ?? packet.rawData,
          transfer: existing.transfer ?? packet.transfer,
          txHash: existing.txHash ?? packet.txHash,
          height: existing.height ?? packet.height,
          timestamp: existing.timestamp ?? packet.timestamp,
        );
      }
    }
  }

  return [for (final key in order) found[key]!];
}

/* -------------------------------------------------------------------------- *
 * Acknowledgements
 * -------------------------------------------------------------------------- */

/// A parsed ICS04 acknowledgement.
@immutable
class PacketAck {
  const PacketAck({required this.ok, this.error, this.result});

  /// True for `{"result": …}`, false for `{"error": …}`.
  final bool ok;

  /// Error text, developer-facing. Null on success.
  final String? error;

  /// Base64 result payload, null on failure.
  final String? result;
}

/// Parse an acknowledgement string.
///
/// The ICS04 envelope is `{"result":"<base64>"}` or `{"error":"<text>"}`. Not in
/// the verified spec, so an unrecognised shape returns null and the caller keeps
/// the status it had rather than inventing a failure.
PacketAck? parsePacketAcknowledgement(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  Object? parsed;
  try {
    parsed = jsonDecode(trimmed);
  } on FormatException {
    // Some nodes hand back the base64 of the JSON rather than the JSON.
    final decoded = _decodeValueCandidate(trimmed);
    if (decoded == null || decoded == trimmed) return null;
    return parsePacketAcknowledgement(decoded);
  }
  final row = _asRecord(parsed);
  if (row == null) return null;
  final error = _asString(row['error']);
  if (error != null && error.isNotEmpty) {
    return PacketAck(ok: false, error: error);
  }
  if (row.containsKey('result')) {
    return PacketAck(ok: true, result: _asString(row['result']));
  }
  return null;
}

/// Decide whether a delivery succeeded from the events of one transaction.
PacketAck? _readAckOutcome(List<DecodedTxEvent> events) {
  for (final event in events) {
    if (!event.isType('write_acknowledgement')) continue;
    final hex = event.attr('packet_ack_hex');
    final raw =
        event.attr('packet_ack') ?? (hex == null ? null : _hexToText(hex));
    if (raw != null) {
      final parsed = parsePacketAcknowledgement(raw);
      if (parsed != null) return parsed;
    }
  }
  for (final event in events) {
    if (!event.isType('fungible_token_packet')) continue;
    final error = event.attr('error');
    if (error != null) return PacketAck(ok: false, error: error);
    final raw = event.attr('acknowledgement');
    if (raw != null) {
      final parsed = parsePacketAcknowledgement(raw);
      if (parsed != null) return parsed;
    }
    final success = event.attr('success');
    if (success != null) return PacketAck(ok: success != 'false');
  }
  return null;
}

/* -------------------------------------------------------------------------- *
 * Timing
 * -------------------------------------------------------------------------- */

/// How long each kind of hop should take, and when to call it stuck.
///
/// Relayers normally land a packet inside a block or two. The defaults are
/// deliberately generous: a false "stalled" badge costs more user trust than a
/// spinner that runs a minute longer than it should.
@immutable
class HopTimingProfile {
  const HopTimingProfile({
    this.transferSeconds = 60,
    this.forwardSeconds = 60,
    this.swapSeconds = 20,
    this.stalledFactor = 4,
    this.minStalledSeconds = 300,
  });

  final int transferSeconds;
  final int forwardSeconds;
  final int swapSeconds;

  /// A hop is stalled once it runs this many times over its estimate.
  final int stalledFactor;

  /// Floor for the stall threshold, so a fast hop does not alarm early.
  final int minStalledSeconds;
}

const HopTimingProfile kDefaultHopTiming = HopTimingProfile();

/// Expected duration of one hop, in seconds.
int estimateHopSeconds(RouteHopKind kind,
    [HopTimingProfile timing = kDefaultHopTiming]) {
  switch (kind) {
    case RouteHopKind.forward:
      return timing.forwardSeconds;
    case RouteHopKind.swap:
      return timing.swapSeconds;
    case RouteHopKind.transfer:
      return timing.transferSeconds;
  }
}

/// Expected end-to-end duration of a plan, in seconds.
int estimateRouteSeconds(List<RouteHop> hops,
    [HopTimingProfile timing = kDefaultHopTiming]) {
  var total = 0;
  for (final hop in hops) {
    total += estimateHopSeconds(hop.kind, timing);
  }
  return total;
}

/// Age at which a hop stops being slow and starts being stuck, in seconds.
int hopStallThresholdSeconds(RouteHopKind kind,
    [HopTimingProfile timing = kDefaultHopTiming]) {
  final expected = estimateHopSeconds(kind, timing) * timing.stalledFactor;
  return expected > timing.minStalledSeconds
      ? expected
      : timing.minStalledSeconds;
}

/// Whether a hop has been waiting long enough to escalate.
///
/// Only in-flight hops can stall. `received` is excluded on purpose: the funds
/// have landed on the destination and a late acknowledgement changes nothing the
/// user can act on, so flagging it would send them chasing a non-problem.
bool isHopStalled({
  required PacketStatus status,
  required RouteHopKind kind,
  required int? elapsedSeconds,
  HopTimingProfile timing = kDefaultHopTiming,
  int? stalledAfterSeconds,
}) {
  if (elapsedSeconds == null) return false;
  if (status != PacketStatus.pending &&
      status != PacketStatus.relayed &&
      status != PacketStatus.unknown) {
    return false;
  }
  final threshold =
      stalledAfterSeconds ?? hopStallThresholdSeconds(kind, timing);
  return elapsedSeconds > threshold;
}

/* -------------------------------------------------------------------------- *
 * Status
 * -------------------------------------------------------------------------- */

/// Why a transfer stopped, when it did.
///
/// - `timeout` — the packet expired before a relayer delivered it. The escrow is
///   released on the source chain. Nothing to do.
/// - `ackError` — the destination rejected the packet (a bad ibc-hooks memo, a
///   missing receiver). Refunded on the source chain. Nothing to do.
/// - `stalled` — no relayer has touched it. The funds are safe and the packet is
///   still live; the user waits or asks for a relayer.
/// - `swapDeliveryFailed` — a crosschain swap executed but the outbound transfer
///   did not land. The output sits in the Osmosis contract and only the
///   `local_recovery_addr` can pull it out with `{"recover":{}}`.
enum PacketFailureKind { timeout, ackError, stalled, swapDeliveryFailed }

/// Terminal statuses: nothing further will happen to this packet.
bool isTerminalPacketStatus(PacketStatus status) =>
    status == PacketStatus.acknowledged ||
    status == PacketStatus.timeout ||
    status == PacketStatus.failed;

/// What the chains say about one packet.
@immutable
class PacketStatusReport {
  const PacketStatusReport({
    required this.status,
    required this.failure,
    required this.receiveTxHash,
    required this.ackTxHash,
    required this.timeoutTxHash,
    required this.receivedAt,
    required this.completedAt,
    required this.error,
    required this.fundsRefunded,
    required this.onwardPackets,
    required this.notes,
  });

  final PacketStatus status;
  final PacketFailureKind? failure;
  final String? receiveTxHash;
  final String? ackTxHash;
  final String? timeoutTxHash;
  final String? receivedAt;
  final String? completedAt;

  /// Error acknowledgement text. Developer-facing; never rendered raw.
  final String? error;

  final bool fundsRefunded;

  /// Packets the receiving transaction sent onward, which is how a forward or
  /// crosschain-swap hop is found.
  final List<ExtractedPacket> onwardPackets;

  /// Which probes could not run. Diagnostics only.
  final List<String> notes;
}

const int _defaultSearchLimit = 10;

/// Re-throw the errors that must never be swallowed.
///
/// `aborted` is the caller cancelling and `readsDisabled` is a settings prompt;
/// turning either into "status unknown" would lie about the chain. Every other
/// failure means this endpoint could not answer, which is what an unindexed
/// public LCD looks like, so tracking degrades instead of failing.
void _rethrowFatal(Object error) {
  if (error is InterchainError &&
      (error.code == InterchainErrorCode.aborted ||
          error.code == InterchainErrorCode.readsDisabled)) {
    throw error;
  }
}

String _quote(String value) {
  // Tendermint's query grammar has no escape for a single quote, and channel ids
  // and sequences cannot contain one. Reject rather than build a query that
  // would silently match the wrong packet.
  if (value.contains("'")) {
    throw InterchainError(
      InterchainErrorCode.malformedResponse,
      'Refusing to search for a value containing a quote: $value',
    );
  }
  return "'$value'";
}

@immutable
class _PacketHit {
  const _PacketHit(this.txHash, this.timestamp, this.events, this.row);

  final String? txHash;
  final String? timestamp;
  final List<DecodedTxEvent> events;
  final Object? row;
}

/// Run one transaction search, tolerating both LCD spellings.
///
/// Returns null when neither spelling worked — which is a node without a
/// transaction index, not a missing packet.
Future<List<Object?>?> _searchTxs(
  LcdClient lcd,
  List<String> conditions,
  int limit,
  List<String> notes,
) async {
  try {
    final body = await lcd.getJson(
      '/cosmos/tx/v1beta1/txs',
      LcdRequestOptions(query: {
        'query': conditions.join(' AND '),
        'order_by': 'ORDER_BY_DESC',
        'limit': limit,
      }),
    );
    final rows = _asRecord(body)?['tx_responses'];
    return rows is List ? rows : null;
  } on Object catch (error) {
    _rethrowFatal(error);
  }

  // SDK <= 0.46 wants one `events` parameter per condition. A repeated key
  // cannot be expressed through the query map, so this is the one place that
  // hand-builds a query string.
  try {
    final repeated = conditions
        .map((c) => 'events=${Uri.encodeQueryComponent(c)}')
        .join('&');
    final body = await lcd.getJson(
      '/cosmos/tx/v1beta1/txs?$repeated',
      LcdRequestOptions(query: {'order_by': 'ORDER_BY_DESC', 'limit': limit}),
    );
    final rows = _asRecord(body)?['tx_responses'];
    return rows is List ? rows : null;
  } on Object catch (error) {
    _rethrowFatal(error);
    notes.add('${lcd.chainId}: tx search unavailable '
        '(${conditions.isEmpty ? '' : conditions.first})');
    return null;
  }
}

bool _matchesPacket(DecodedTxEvent event, ExtractedPacket ref) {
  if (_asUint(event.attr('packet_sequence')) != ref.sequence) return false;
  final src = event.attr('packet_src_channel');
  if (src != null && src != ref.sourceChannelId) return false;
  final dst = event.attr('packet_dst_channel');
  if (dst != null && ref.destChannelId.isNotEmpty && dst != ref.destChannelId) {
    return false;
  }
  return true;
}

/// The first returned transaction that really contains our packet.
///
/// The search filters are re-checked here: some indexers match attributes across
/// different events in the same transaction, so a relayer batch can come back
/// for a packet that is not ours.
_PacketHit? _findPacketHit(
  List<Object?>? rows,
  String eventType,
  ExtractedPacket ref,
) {
  if (rows == null) return null;
  for (final row in rows) {
    final txResponse = _txResponseOf(row);
    if (txResponse == null) continue;
    final events = [
      for (final group in _eventGroupsOf(txResponse)) ...group.events,
    ];
    final hit = events
        .any((event) => event.isType(eventType) && _matchesPacket(event, ref));
    if (!hit) continue;
    return _PacketHit(
      _asString(txResponse['txhash']),
      _asString(txResponse['timestamp']),
      events,
      row,
    );
  }
  return null;
}

/// Whether the packet's timeout can already have fired.
///
/// Skipping the timeout search while the deadline is in the future halves the
/// request count for the common in-flight poll.
bool _timeoutMayHaveFired(ExtractedPacket ref, DateTime now) {
  final nanos = ref.timeoutTimestamp;
  if (nanos == null || nanos.isEmpty || nanos == '0') return true;
  final deadline = BigInt.tryParse(nanos);
  if (deadline == null) return true;
  return BigInt.from(now.millisecondsSinceEpoch) * BigInt.from(1000000) >=
      deadline;
}

/// Ask both chains where one packet is.
///
/// The source chain is asked first for a terminal answer — `acknowledge_packet`,
/// then `timeout_packet` if the deadline has passed — because those are the only
/// states that end the user's wait. The destination chain is asked for
/// `write_acknowledgement` (which carries the acknowledgement itself) and falls
/// back to `recv_packet`, which also yields the transaction that forwarded the
/// packet onward.
///
/// Never throws for a chain that cannot answer: a public LCD with transaction
/// indexing off reports `unknown`, and the caller keeps polling.
Future<PacketStatusReport> getPacketStatus(
  ExtractedPacket packet,
  LcdClient source, {
  LcdClient? destination,
  int limit = _defaultSearchLimit,
  bool probeDestination = true,
  DateTime Function()? now,
}) async {
  final notes = <String>[];
  final clock = now ?? DateTime.now;

  final seq = _quote(packet.sequence);
  final src = _quote(packet.sourceChannelId);
  final dst = packet.destChannelId.isEmpty ? null : _quote(packet.destChannelId);

  List<String> conditions(String prefix, bool withDest) => [
        '$prefix.packet_sequence=$seq',
        '$prefix.packet_src_channel=$src',
        if (withDest && dst != null) '$prefix.packet_dst_channel=$dst',
      ];

  var probesRan = 0;

  Future<({_PacketHit? ack, _PacketHit? timeout})> probeSource() async {
    final ackRows = await _searchTxs(
        source, conditions('acknowledge_packet', true), limit, notes);
    if (ackRows != null) probesRan += 1;
    final ack = _findPacketHit(ackRows, 'acknowledge_packet', packet);
    if (ack != null) return (ack: ack, timeout: null);

    if (!_timeoutMayHaveFired(packet, clock())) {
      return (ack: null, timeout: null);
    }
    final timeoutRows = await _searchTxs(
        source, conditions('timeout_packet', true), limit, notes);
    if (timeoutRows != null) probesRan += 1;
    return (
      ack: null,
      timeout: _findPacketHit(timeoutRows, 'timeout_packet', packet)
    );
  }

  Future<({_PacketHit? write, _PacketHit? recv})> probeDest() async {
    if (destination == null || !probeDestination) {
      return (write: null, recv: null);
    }
    final writeRows = await _searchTxs(
        destination, conditions('write_acknowledgement', true), limit, notes);
    if (writeRows != null) probesRan += 1;
    final write = _findPacketHit(writeRows, 'write_acknowledgement', packet);
    if (write != null) return (write: write, recv: null);

    final recvRows = await _searchTxs(
        destination, conditions('recv_packet', true), limit, notes);
    if (recvRows != null) probesRan += 1;
    return (write: null, recv: _findPacketHit(recvRows, 'recv_packet', packet));
  }

  final sourceProbe = await probeSource();
  final destProbe = await probeDest();

  final delivery = destProbe.write ?? destProbe.recv;
  final onwardPackets = delivery == null
      ? <ExtractedPacket>[]
      : extractPacketsFromTx(delivery.row);
  final receiveTxHash = delivery?.txHash;
  final receivedAt = delivery?.timestamp;

  // The acknowledgement text is best read on the destination, where
  // `write_acknowledgement` carries it verbatim; the source chain's
  // `fungible_token_packet` is the fallback when the destination was not probed.
  final destAck =
      destProbe.write == null ? null : _readAckOutcome(destProbe.write!.events);
  final sourceAck =
      sourceProbe.ack == null ? null : _readAckOutcome(sourceProbe.ack!.events);
  final outcome = destAck ?? sourceAck;

  if (sourceProbe.timeout != null) {
    return PacketStatusReport(
      status: PacketStatus.timeout,
      failure: PacketFailureKind.timeout,
      receiveTxHash: receiveTxHash,
      ackTxHash: null,
      timeoutTxHash: sourceProbe.timeout!.txHash,
      receivedAt: receivedAt,
      completedAt: sourceProbe.timeout!.timestamp,
      error: null,
      fundsRefunded: true,
      onwardPackets: onwardPackets,
      notes: notes,
    );
  }

  if (sourceProbe.ack != null) {
    final failed = outcome != null && !outcome.ok;
    return PacketStatusReport(
      status: failed ? PacketStatus.failed : PacketStatus.acknowledged,
      failure: failed ? PacketFailureKind.ackError : null,
      receiveTxHash: receiveTxHash,
      ackTxHash: sourceProbe.ack!.txHash,
      timeoutTxHash: null,
      receivedAt: receivedAt,
      completedAt: sourceProbe.ack!.timestamp,
      error: failed
          ? (outcome.error ?? 'packet acknowledgement reported an error')
          : null,
      fundsRefunded: failed,
      onwardPackets: onwardPackets,
      notes: notes,
    );
  }

  if (destProbe.write != null) {
    // An error acknowledgement is already decided on the destination; the refund
    // only lands once the relayer brings it home, so say so now rather than
    // showing "received" for a packet that has failed.
    if (destAck != null && !destAck.ok) {
      return PacketStatusReport(
        status: PacketStatus.failed,
        failure: PacketFailureKind.ackError,
        receiveTxHash: receiveTxHash,
        ackTxHash: null,
        timeoutTxHash: null,
        receivedAt: receivedAt,
        completedAt: null,
        error: destAck.error,
        fundsRefunded: false,
        onwardPackets: onwardPackets,
        notes: notes,
      );
    }
    return PacketStatusReport(
      status: PacketStatus.received,
      failure: null,
      receiveTxHash: receiveTxHash,
      ackTxHash: null,
      timeoutTxHash: null,
      receivedAt: receivedAt,
      completedAt: null,
      error: null,
      fundsRefunded: false,
      onwardPackets: onwardPackets,
      notes: notes,
    );
  }

  if (destProbe.recv != null) {
    return PacketStatusReport(
      status: PacketStatus.relayed,
      failure: null,
      receiveTxHash: receiveTxHash,
      ackTxHash: null,
      timeoutTxHash: null,
      receivedAt: receivedAt,
      completedAt: null,
      error: null,
      fundsRefunded: false,
      onwardPackets: onwardPackets,
      notes: notes,
    );
  }

  return PacketStatusReport(
    status: probesRan == 0 ? PacketStatus.unknown : PacketStatus.pending,
    failure: null,
    receiveTxHash: null,
    ackTxHash: null,
    timeoutTxHash: null,
    receivedAt: null,
    completedAt: null,
    error: null,
    fundsRefunded: false,
    onwardPackets: const [],
    notes: notes,
  );
}

/* -------------------------------------------------------------------------- *
 * Crosschain-swap recovery
 * -------------------------------------------------------------------------- */

/// The crosschain-swaps recovery call, `{"recover":{}}`.
///
/// Verified in INTERCHAIN-SPEC.md section 3: when a swap succeeds but the
/// outbound delivery fails, the output is held for the `local_recovery_addr` the
/// swap was built with, and that address calls this to withdraw it.
const Map<String, Object?> xcsRecoverExecuteMsg = {
  'recover': <String, Object?>{},
};

/// Everything the UI needs to offer "recover my funds".
///
/// Divergence from `tracking.ts`: that returns an encoded `BuiltMsg`, because
/// the TS package owns a message builder. Here the encoder is the app's
/// `crypto/amino_tx.dart`, so this carries the execute body and the two
/// addresses and the screen encodes them. [ready] is the same fail-closed signal
/// the TS `msg != null` is.
@immutable
class XcsRecovery {
  const XcsRecovery({
    required this.chainId,
    required this.contractAddress,
    required this.recoveryAddress,
    this.executeMsg = xcsRecoverExecuteMsg,
  });

  /// Chain the contract lives on, and where the recovery must be broadcast.
  final String chainId;

  /// The crosschain-swaps contract, when the host configured one.
  final String? contractAddress;

  /// The address allowed to recover, from `on_failed_delivery`.
  final String? recoveryAddress;

  /// The execute body, for display.
  final Map<String, Object?> executeMsg;

  /// True when a recover message can actually be built. False means the
  /// contract address is not in host config, and the UI must say so rather than
  /// offer a dead button: that address is deployment data, never a constant.
  bool get ready =>
      (contractAddress?.isNotEmpty ?? false) &&
      (recoveryAddress?.isNotEmpty ?? false);
}

/// One hop of a [RouteTrace].
@immutable
class RouteHopTrace {
  const RouteHopTrace({
    required this.index,
    required this.chainId,
    required this.channelId,
    required this.port,
    required this.counterpartyChainId,
    required this.kind,
    required this.status,
    required this.expectedSeconds,
    this.sequence,
    this.sendTxHash,
    this.receiveTxHash,
    this.ackTxHash,
    this.timeoutTxHash,
    this.error,
    this.failure,
    this.startedAt,
    this.completedAt,
    this.elapsedSeconds,
    this.stalled = false,
    this.fundsRefunded = false,
  });

  final int index;
  final String chainId;
  final String channelId;
  final String port;
  final String? counterpartyChainId;
  final RouteHopKind kind;
  final PacketStatus status;
  final String? sequence;
  final String? sendTxHash;
  final String? receiveTxHash;
  final String? ackTxHash;
  final String? timeoutTxHash;
  final String? error;
  final PacketFailureKind? failure;
  final String? startedAt;
  final String? completedAt;
  final int? elapsedSeconds;
  final int expectedSeconds;

  /// True once [isHopStalled] says the wait is abnormal.
  final bool stalled;

  /// True when the source chain has already returned the escrow.
  final bool fundsRefunded;

  RouteHopTrace copyWith({
    String? receiveTxHash,
    String? startedAt,
  }) =>
      RouteHopTrace(
        index: index,
        chainId: chainId,
        channelId: channelId,
        port: port,
        counterpartyChainId: counterpartyChainId,
        kind: kind,
        status: status,
        expectedSeconds: expectedSeconds,
        sequence: sequence,
        sendTxHash: sendTxHash,
        receiveTxHash: receiveTxHash ?? this.receiveTxHash,
        ackTxHash: ackTxHash,
        timeoutTxHash: timeoutTxHash,
        error: error,
        failure: failure,
        startedAt: startedAt ?? this.startedAt,
        completedAt: completedAt,
        elapsedSeconds: elapsedSeconds,
        stalled: stalled,
        fundsRefunded: fundsRefunded,
      );
}

/// Where a whole route has got to.
@immutable
class RouteTrace {
  const RouteTrace({
    required this.sourceChainId,
    required this.destChainId,
    required this.sourceTxHash,
    required this.hops,
    required this.status,
    required this.failure,
    required this.recovery,
    required this.stalled,
    required this.currentHopIndex,
    required this.elapsedSeconds,
    required this.estimatedDurationSeconds,
    required this.notes,
    required this.updatedAt,
  });

  final String sourceChainId;
  final String destChainId;
  final String sourceTxHash;
  final List<RouteHopTrace> hops;
  final PacketStatus status;

  /// The one thing that went wrong, or null while the route is healthy.
  final PacketFailureKind? failure;

  /// Set only for `swapDeliveryFailed`: how to get the money back.
  final XcsRecovery? recovery;

  /// True when any in-flight hop has passed its stall threshold.
  final bool stalled;

  /// Index of the hop the user is waiting on, for "hop 2 of 3".
  final int currentHopIndex;

  final int? elapsedSeconds;
  final int estimatedDurationSeconds;

  /// Diagnostics: probes that could not run, ambiguous forwards. Never raw copy.
  final List<String> notes;

  final DateTime updatedAt;
}

/// Finds the LCD for a chain id, or null when the host cannot read it.
///
/// Returning null rather than throwing keeps a route trackable through a chain
/// with no public REST endpoint: those hops report `unknown` and the hops around
/// them still resolve.
typedef LcdResolver = LcdClient? Function(String chainId);

int? _parseTime(String? value) {
  if (value == null) return null;
  return DateTime.tryParse(value)?.millisecondsSinceEpoch;
}

int? _secondsBetween(int? fromMs, int? toMs) {
  if (fromMs == null || toMs == null) return null;
  final delta = ((toMs - fromMs) / 1000).round();
  return delta < 0 ? 0 : delta;
}

/// Pick the packet this route forwarded out of everything the relayer's
/// transaction sent.
///
/// Channel and port narrow it; the amount settles a batch. When the amount does
/// not settle it either, the first match is used and the caller is told, because
/// a slightly wrong hop trace is better than no trace and the ambiguity must not
/// be silent.
ExtractedPacket? _pickOnwardPacket(
  List<ExtractedPacket> packets,
  String channelId,
  String port,
  String? expectedAmount,
  List<String> notes,
) {
  final onChannel = packets
      .where((packet) =>
          packet.sourceChannelId == channelId &&
          (port.isEmpty || packet.sourcePort == port))
      .toList();
  if (onChannel.isEmpty) return null;
  if (onChannel.length == 1) return onChannel.first;

  if (expectedAmount != null) {
    final byAmount =
        onChannel.where((p) => p.data?.amount == expectedAmount).toList();
    if (byAmount.length == 1) return byAmount.first;
  }
  notes.add('Several packets left on $channelId in the same transaction; '
      'followed the first');
  return onChannel.first;
}

/// Fetch one transaction by hash.
///
/// Null when the node has not indexed it, which is normal for the first few
/// seconds after a broadcast and must never read as a failure.
Future<Object?> _fetchTx(LcdClient lcd, String txHash) async {
  try {
    return await lcd
        .getJson('/cosmos/tx/v1beta1/txs/${Uri.encodeComponent(txHash)}');
  } on InterchainError catch (error) {
    _rethrowFatal(error);
    if (error.httpStatus == 404) return null;
    rethrow;
  }
}

/// Normalise a user-pasted hash: uppercase hex, no `0x`.
String normalizeTxHash(String raw) {
  final trimmed = raw.trim();
  final body = trimmed.startsWith('0x') || trimmed.startsWith('0X')
      ? trimmed.substring(2)
      : trimmed;
  return body.toUpperCase();
}

/// Follow a signed route across every hop.
///
/// Starts from the transaction the user signed, reads its `send_packet` events,
/// and walks forward: each hop's receive transaction on the intermediate chain
/// contains the packet that packet-forward-middleware or the crosschain-swaps
/// contract sent onward, which becomes the next hop's packet. The walk stops at
/// the first hop that has not moved, so a poll costs a bounded number of reads.
Future<RouteTrace> trackRoute(
  RoutePlan plan,
  String sourceTxHash,
  LcdResolver resolve, {
  void Function(RouteTrace trace)? onUpdate,
  HopTimingProfile timing = kDefaultHopTiming,
  int? stalledAfterSeconds,
  int limit = _defaultSearchLimit,
  bool probeDestination = true,
  String? sourcePacketSequence,
  String? expectedAmount,
  String? swapContract,
  String? recoveryAddress,
  DateTime Function()? now,
}) async {
  final hops = plan.hops;
  if (hops.isEmpty) {
    throw InterchainError(
      InterchainErrorCode.noRoute,
      'Cannot track a plan with no hops',
      chainId: plan.sourceChainId,
    );
  }

  final clock = now ?? DateTime.now;
  final notes = <String>[];
  final txHash = normalizeTxHash(sourceTxHash);
  final estimatedDurationSeconds = estimateRouteSeconds(hops, timing);

  final sourceLcd = resolve(plan.sourceChainId);
  if (sourceLcd == null) {
    throw InterchainError(
      InterchainErrorCode.unsupportedChain,
      'No REST endpoint for ${plan.sourceChainId}',
      chainId: plan.sourceChainId,
    );
  }

  final traces = <RouteHopTrace>[];
  PacketFailureKind? failure;
  XcsRecovery? recovery;
  String? sourceStartedAt;

  RouteHopTrace emptyHop(int index, PacketStatus status) {
    final hop = index < hops.length ? hops[index] : null;
    return RouteHopTrace(
      index: index,
      chainId: hop?.chainId ?? plan.sourceChainId,
      channelId: hop?.channelId ?? '',
      port: hop?.port ?? transferPort,
      counterpartyChainId: hop?.counterpartyChainId,
      kind: hop?.kind ?? RouteHopKind.transfer,
      status: status,
      expectedSeconds:
          estimateHopSeconds(hop?.kind ?? RouteHopKind.transfer, timing),
    );
  }

  RouteTrace assemble() {
    final padded = [...traces];
    // Hops the walk never reached: `pending` while the route is alive, and
    // `unknown` after a failure, because they will now never happen and calling
    // them pending would promise an arrival that is not coming.
    final filler = failure == null || failure == PacketFailureKind.stalled
        ? PacketStatus.pending
        : PacketStatus.unknown;
    for (var i = padded.length; i < hops.length; i++) {
      padded.add(emptyHop(i, filler));
    }

    final firstOpen =
        padded.indexWhere((hop) => !isTerminalPacketStatus(hop.status));
    final currentHopIndex = firstOpen == -1 ? padded.length - 1 : firstOpen;
    RouteHopTrace? broken;
    for (final hop in padded) {
      if (hop.status == PacketStatus.timeout ||
          hop.status == PacketStatus.failed) {
        broken = hop;
        break;
      }
    }
    final open = firstOpen == -1 ? null : padded[firstOpen];
    // A failure anywhere wins: a later hop sitting at `pending` describes a
    // packet that was never sent.
    final status = broken?.status ??
        open?.status ??
        (padded.isEmpty ? PacketStatus.unknown : padded.last.status);

    return RouteTrace(
      sourceChainId: plan.sourceChainId,
      destChainId: plan.destChainId,
      sourceTxHash: txHash,
      hops: padded,
      status: status,
      failure: failure,
      recovery: recovery,
      stalled: padded.any((hop) => hop.stalled),
      currentHopIndex: currentHopIndex,
      elapsedSeconds: _secondsBetween(
          _parseTime(sourceStartedAt), clock().millisecondsSinceEpoch),
      estimatedDurationSeconds: estimatedDurationSeconds,
      notes: notes,
      updatedAt: clock(),
    );
  }

  RouteTrace publish() {
    final trace = assemble();
    if (onUpdate != null) {
      try {
        onUpdate(trace);
      } on Object {
        // A rendering bug in the host must not abort tracking.
      }
    }
    return trace;
  }

  final sourceTx = await _fetchTx(sourceLcd, txHash);
  if (sourceTx == null) {
    notes.add('${plan.sourceChainId}: transaction not indexed yet');
    return publish();
  }

  sourceStartedAt = _asString(_txResponseOf(sourceTx)?['timestamp']);
  final sourcePackets = extractPacketsFromTx(sourceTx);
  final firstHop = hops.first;
  ExtractedPacket? packet;
  if (sourcePacketSequence != null) {
    for (final candidate in sourcePackets) {
      if (candidate.sequence == sourcePacketSequence) {
        packet = candidate;
        break;
      }
    }
  }
  packet ??= _pickOnwardPacket(
        sourcePackets,
        firstHop.channelId,
        firstHop.port,
        expectedAmount,
        notes,
      ) ??
      (sourcePackets.isEmpty ? null : sourcePackets.first);

  if (packet == null) {
    notes.add('${plan.sourceChainId}: no IBC packet found in $txHash');
    return publish();
  }

  String? hopStartedAt = sourceStartedAt ?? packet.timestamp;
  String? previousReceiveTxHash;
  var stop = false;

  for (var index = 0; index < hops.length && !stop; index++) {
    final hop = hops[index];

    // A hop with no channel is a contract call inside packet processing — an
    // ibc-hooks swap. It sends no packet of its own, so its state is the state
    // of the delivery that triggered it.
    if (hop.channelId.isEmpty) {
      final previous = index == 0 || traces.isEmpty ? null : traces.last;
      final derived = index == 0
          ? PacketStatus.pending
          : previous == null
              ? PacketStatus.unknown
              : (previous.status == PacketStatus.acknowledged ||
                      previous.status == PacketStatus.received)
                  ? PacketStatus.received
                  : previous.status;
      traces.add(emptyHop(index, derived).copyWith(
        receiveTxHash: previousReceiveTxHash,
        startedAt: hopStartedAt,
      ));
      publish();
      continue;
    }

    if (packet == null) {
      // The previous hop has not forwarded anything yet, so this hop has no
      // packet to look up. Report it as waiting and stop: nothing beyond it can
      // be known this round.
      traces.add(
          emptyHop(index, PacketStatus.pending).copyWith(startedAt: hopStartedAt));
      publish();
      stop = true;
      continue;
    }
    final current = packet;

    final destChainId = index + 1 < hops.length
        ? hops[index + 1].chainId
        : hop.counterpartyChainId;
    final destination = destChainId == null ? null : resolve(destChainId);
    if (destination == null && destChainId != null) {
      notes.add('$destChainId: no REST endpoint, hop $index tracked from the '
          'source only');
    }

    final report = await getPacketStatus(
      current,
      resolve(hop.chainId) ?? sourceLcd,
      destination: destination,
      limit: limit,
      probeDestination: probeDestination,
      now: clock,
    );
    notes.addAll(report.notes);

    final startedMs = _parseTime(hopStartedAt);
    final endedMs = _parseTime(report.completedAt ?? report.receivedAt);
    final elapsedSeconds =
        _secondsBetween(startedMs, endedMs ?? clock().millisecondsSinceEpoch);
    final stalled = isHopStalled(
      status: report.status,
      kind: hop.kind,
      elapsedSeconds: endedMs == null ? elapsedSeconds : null,
      timing: timing,
      stalledAfterSeconds: stalledAfterSeconds,
    );

    traces.add(RouteHopTrace(
      index: index,
      chainId: hop.chainId,
      channelId: hop.channelId,
      port: hop.port,
      counterpartyChainId: hop.counterpartyChainId ?? destChainId,
      kind: hop.kind,
      status: report.status,
      expectedSeconds: estimateHopSeconds(hop.kind, timing),
      sequence: current.sequence,
      sendTxHash:
          index == 0 ? txHash : (current.txHash ?? previousReceiveTxHash),
      receiveTxHash: report.receiveTxHash,
      ackTxHash: report.ackTxHash,
      timeoutTxHash: report.timeoutTxHash,
      error: report.error,
      failure: report.failure,
      startedAt: hopStartedAt,
      completedAt: report.completedAt ?? report.receivedAt,
      elapsedSeconds: elapsedSeconds,
      stalled: stalled,
      fundsRefunded: report.fundsRefunded,
    ));

    if (report.failure != null) {
      failure = report.failure;
      // Funds only sit in the crosschain-swaps contract when the swap itself
      // worked and the hop *leaving* the swap chain failed. A failure before the
      // swap refunds on the source chain and needs no recovery.
      final swapIndex = hops.indexWhere((c) => c.kind == RouteHopKind.swap);
      if (swapIndex != -1 && index > swapIndex) {
        failure = PacketFailureKind.swapDeliveryFailed;
        recovery = XcsRecovery(
          chainId: hops[swapIndex].chainId,
          contractAddress: swapContract,
          recoveryAddress: recoveryAddress,
        );
        if (!recovery.ready) {
          notes.add('Swap output is stuck in the contract but no recovery '
              'address or contract is configured');
        }
      }
      stop = true;
    } else if (stalled) {
      failure = PacketFailureKind.stalled;
    }

    publish();
    if (stop) break;

    // Chain to the next hop: the forwarded packet lives in the transaction that
    // delivered this one. A swap hop moves no packet of its own, so look past it
    // to the hop that does — the crosschain-swaps contract sends the outbound
    // transfer from inside the same delivery.
    previousReceiveTxHash = report.receiveTxHash;
    hopStartedAt = report.receivedAt ?? hopStartedAt;
    var nextIndex = index + 1;
    while (nextIndex < hops.length && hops[nextIndex].channelId.isEmpty) {
      nextIndex += 1;
    }
    // Null here is not a failure: the packet may simply not have been forwarded
    // yet, or the destination chain was not probed.
    packet = nextIndex < hops.length
        ? _pickOnwardPacket(
            report.onwardPackets,
            hops[nextIndex].channelId,
            hops[nextIndex].port,
            expectedAmount ?? current.data?.amount,
            notes,
          )
        : null;
  }

  return publish();
}
