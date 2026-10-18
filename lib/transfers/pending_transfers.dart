/// In-flight transfers, remembered across app restarts, and followed until
/// they land.
///
/// Port of `zunia-extension/lib/pending-transfers.ts` and the outcome half of
/// `packet-tracking.ts` / `transfer-watch.ts`. A cross-chain transfer takes a
/// minute or several; closing the app must not lose the only place the wallet
/// reports where the funds are. The record is exactly what `trackRoute`
/// needs: no key material and no balances, and it is dropped once the route
/// settles.
///
/// Every read is a public query, so following works while the wallet is
/// locked. An app cannot poll from the background the way the extension's
/// alarm does, so the watcher runs while the app is open and picks every
/// record back up at the next launch.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/tracking.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

/// Keep the list short: a resume aid, not a history.
const int maxPendingTransfers = 5;

/// Records older than this are dropped on read: far longer than any timeout
/// this wallet sets (10 minutes per hop).
const Duration pendingTransferMaxAge = Duration(hours: 24);

const String _pendingKey = 'zunia.transfers.pending';

/// One signed route the wallet is still following.
@immutable
class PendingTransfer {
  const PendingTransfer({
    required this.kind,
    required this.txHash,
    required this.chainId,
    required this.plan,
    required this.amountBaseUnits,
    required this.label,
    required this.startedAt,
    this.swapContract,
    this.recoveryAddress,
  });

  /// `transfer` or `swap`.
  final String kind;

  /// The transaction the user signed. Unique per record.
  final String txHash;

  /// Chain it was signed on.
  final String chainId;
  final RoutePlan plan;

  /// Base units moved, so a batched relayer transaction can be told apart.
  final String amountBaseUnits;

  /// `10 USDC.n (Osmosis) → Noble`.
  final String label;
  final DateTime startedAt;
  final String? swapContract;
  final String? recoveryAddress;

  Map<String, Object?> toJson() => {
        'kind': kind,
        'txHash': txHash,
        'chainId': chainId,
        'plan': routePlanToJson(plan),
        'amountBaseUnits': amountBaseUnits,
        'label': label,
        'startedAt': startedAt.millisecondsSinceEpoch,
        if (swapContract != null) 'swapContract': swapContract,
        if (recoveryAddress != null) 'recoveryAddress': recoveryAddress,
      };

  static PendingTransfer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final txHash = raw['txHash'];
    final chainId = raw['chainId'];
    final amount = raw['amountBaseUnits'];
    final plan = routePlanFromJson(raw['plan']);
    final started = raw['startedAt'];
    if (txHash is! String || txHash.isEmpty || chainId is! String || amount is! String) return null;
    if (plan == null || started is! num) return null;
    return PendingTransfer(
      kind: raw['kind'] == 'swap' ? 'swap' : 'transfer',
      txHash: txHash,
      chainId: chainId,
      plan: plan,
      amountBaseUnits: amount,
      label: raw['label'] is String ? raw['label'] as String : '',
      startedAt: DateTime.fromMillisecondsSinceEpoch(started.toInt()),
      swapContract: raw['swapContract'] as String?,
      recoveryAddress: raw['recoveryAddress'] as String?,
    );
  }
}

Map<String, Object?> routePlanToJson(RoutePlan plan) => {
      'sourceChainId': plan.sourceChainId,
      'destChainId': plan.destChainId,
      'inputDenom': plan.inputDenom,
      'outputDenom': plan.outputDenom,
      'hops': [
        for (final hop in plan.hops)
          {
            'chainId': hop.chainId,
            'channelId': hop.channelId,
            'port': hop.port,
            'counterpartyChainId': hop.counterpartyChainId,
            'kind': hop.kind.name,
          },
      ],
      'memo': plan.memo,
      'warnings': plan.warnings,
      'estimatedDurationSeconds': plan.estimatedDurationSeconds,
      'requiresPfm': plan.requiresPfm,
      'requiresIbcHooks': plan.requiresIbcHooks,
    };

RoutePlan? routePlanFromJson(Object? raw) {
  if (raw is! Map || raw['hops'] is! List) return null;
  final hops = <RouteHop>[];
  for (final item in raw['hops'] as List) {
    if (item is! Map || item['chainId'] is! String) return null;
    hops.add(RouteHop(
      chainId: item['chainId'] as String,
      channelId: item['channelId'] as String? ?? '',
      port: item['port'] as String? ?? transferPort,
      counterpartyChainId: item['counterpartyChainId'] as String?,
      kind: RouteHopKind.values.firstWhere(
        (kind) => kind.name == item['kind'],
        orElse: () => RouteHopKind.transfer,
      ),
    ));
  }
  if (hops.isEmpty) return null;
  return RoutePlan(
    sourceChainId: raw['sourceChainId'] as String? ?? hops.first.chainId,
    destChainId: raw['destChainId'] as String? ?? '',
    inputDenom: raw['inputDenom'] as String? ?? '',
    outputDenom: raw['outputDenom'] as String? ?? '',
    hops: hops,
    memo: raw['memo'] as String? ?? '',
    warnings: [
      if (raw['warnings'] is List)
        for (final warning in raw['warnings'] as List)
          if (warning is String) warning,
    ],
    estimatedDurationSeconds: (raw['estimatedDurationSeconds'] as num?)?.toInt() ?? 0,
    requiresPfm: raw['requiresPfm'] == true,
    requiresIbcHooks: raw['requiresIbcHooks'] == true,
  );
}

/// Everything still being followed, newest first. Unreadable rows dropped.
List<PendingTransfer> decodePendingTransfers(String? raw, {DateTime? now}) {
  if (raw == null) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];
  final cutoff = (now ?? DateTime.now()).subtract(pendingTransferMaxAge);
  final rows = [
    for (final item in decoded)
      if (PendingTransfer.fromJson(item) case final row?)
        if (row.startedAt.isAfter(cutoff)) row,
  ]..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  return rows.take(maxPendingTransfers).toList();
}

class PendingTransferStore {
  const PendingTransferStore();

  Future<List<PendingTransfer>> list() async {
    final store = await SharedPreferences.getInstance();
    return decodePendingTransfers(store.getString(_pendingKey));
  }

  /// Remember a route that was just broadcast. Replaces any with the same hash.
  Future<List<PendingTransfer>> save(PendingTransfer record) async {
    final existing = await list();
    final next = [
      record,
      ...existing.where((row) => row.txHash != record.txHash),
    ].take(maxPendingTransfers).toList();
    await _write(next);
    return next;
  }

  /// Forget a route: it landed, or failed with nothing to claim.
  Future<List<PendingTransfer>> remove(String txHash) async {
    final next = [for (final row in await list()) if (row.txHash != txHash) row];
    await _write(next);
    return next;
  }

  Future<void> _write(List<PendingTransfer> rows) async {
    final store = await SharedPreferences.getInstance();
    await store.setString(_pendingKey, jsonEncode([for (final row in rows) row.toJson()]));
  }
}

/* -------------------------------------------------------------------------- *
 * Outcomes
 * -------------------------------------------------------------------------- */

enum RouteOutcome { delivered, refunded, recoverable, failed }

/// The last hop has delivered: the funds are on the destination chain.
bool hasArrived(RouteTrace trace) {
  if (trace.failure != null && trace.failure != PacketFailureKind.stalled) return false;
  if (trace.hops.isEmpty) return false;
  final last = trace.hops.last.status;
  return last == PacketStatus.received || last == PacketStatus.acknowledged;
}

/// Nothing more will change without the user.
bool isSettled(RouteTrace trace) =>
    (trace.failure != null && trace.failure != PacketFailureKind.stalled) ||
    (isTerminalPacketStatus(trace.status) && trace.status != PacketStatus.unknown);

/// What a route means for the funds, or null while it can still move. A
/// timeout and an error acknowledgement both return the escrow; a swap whose
/// output could not be delivered waits in the contract to be recovered.
RouteOutcome? routeOutcome(RouteTrace trace) {
  if (hasArrived(trace)) return RouteOutcome.delivered;
  if (!isSettled(trace)) return null;
  return trace.failure == PacketFailureKind.swapDeliveryFailed
      ? RouteOutcome.recoverable
      : RouteOutcome.refunded;
}

/// One poll of a pending route: the signed transaction first (a transaction
/// the chain rejected sent nothing), then the packets.
@immutable
class TrackedTransfer {
  const TrackedTransfer({
    required this.record,
    this.trace,
    this.outcome,
    this.sourceError,
    this.error,
    this.updatedAt,
  });

  final PendingTransfer record;
  final RouteTrace? trace;
  final RouteOutcome? outcome;

  /// The chain's words when it rejected the signed transaction.
  final String? sourceError;

  /// Why this poll learned nothing (reads off, endpoint down).
  final String? error;
  final DateTime? updatedAt;

  bool get finished =>
      outcome == RouteOutcome.delivered ||
      outcome == RouteOutcome.refunded ||
      outcome == RouteOutcome.failed;
}

/// Read the signed transaction's result: null while not indexed, else its
/// code and raw log.
Future<({int code, String rawLog})?> readSourceResult(LcdClient lcd, String txHash) async {
  try {
    final body = await lcd.getJson(
      '/cosmos/tx/v1beta1/txs/${Uri.encodeComponent(normalizeTxHash(txHash))}',
      const LcdRequestOptions(cacheTtl: Duration.zero),
    );
    final response = body is Map ? body['tx_response'] : null;
    if (response is! Map) return null;
    final code = response['code'];
    return (
      code: code is num ? code.toInt() : 0,
      rawLog: response['raw_log'] is String ? response['raw_log'] as String : '',
    );
  } on InterchainError catch (error) {
    if (error.code == InterchainErrorCode.readsDisabled || error.code == InterchainErrorCode.aborted) {
      rethrow;
    }
    if (error.httpStatus == 404 || error.httpStatus == 400) return null;
    rethrow;
  }
}

/// Follow one record once.
Future<TrackedTransfer> pollTransfer(PendingTransfer record, LcdResolver resolve) async {
  final now = DateTime.now();
  try {
    final lcd = resolve(record.chainId);
    if (lcd != null) {
      final source = await readSourceResult(lcd, record.txHash);
      if (source != null && source.code != 0) {
        return TrackedTransfer(
          record: record,
          outcome: RouteOutcome.failed,
          sourceError: source.rawLog.isEmpty
              ? 'The chain rejected it with code ${source.code}.'
              : source.rawLog,
          updatedAt: now,
        );
      }
    }
    final trace = await trackRoute(
      record.plan,
      record.txHash,
      resolve,
      expectedAmount: record.amountBaseUnits,
      swapContract: record.swapContract,
      recoveryAddress: record.recoveryAddress,
    );
    return TrackedTransfer(record: record, trace: trace, outcome: routeOutcome(trace), updatedAt: now);
  } on InterchainError catch (error) {
    return TrackedTransfer(
      record: record,
      error: error.code == InterchainErrorCode.readsDisabled
          ? 'Live reads are off, so Zunia cannot follow this transfer. The transfer itself is unaffected.'
          : 'Could not read where this transfer is: ${error.message}',
      updatedAt: now,
    );
  }
}
