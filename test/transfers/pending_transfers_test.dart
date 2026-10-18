import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/tracking.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/transfers/pending_transfers.dart';

/// Transfers the app is still following (extension lib/pending-transfers.ts
/// and the outcome half of transfer-watch.ts): kept across restarts, short,
/// and settled from what the chains say.
const plan = RoutePlan(
  sourceChainId: 'osmosis-1',
  destChainId: 'cosmoshub-4',
  inputDenom: 'ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2',
  outputDenom: 'uatom',
  hops: [
    RouteHop(
      chainId: 'osmosis-1',
      channelId: 'channel-0',
      port: 'transfer',
      counterpartyChainId: 'cosmoshub-4',
      kind: RouteHopKind.transfer,
    ),
  ],
  memo: '',
  warnings: ['A note'],
  estimatedDurationSeconds: 60,
  requiresPfm: false,
  requiresIbcHooks: false,
);

PendingTransfer record(String hash, DateTime startedAt) => PendingTransfer(
      kind: 'transfer',
      txHash: hash,
      chainId: 'osmosis-1',
      plan: plan,
      amountBaseUnits: '1000000',
      label: '1 ATOM (Osmosis) → Cosmos Hub',
      startedAt: startedAt,
    );

RouteTrace trace(List<PacketStatus> hops, {PacketStatus? status, PacketFailureKind? failure}) => RouteTrace(
      sourceChainId: 'osmosis-1',
      destChainId: 'cosmoshub-4',
      sourceTxHash: 'AB',
      hops: [
        for (final (index, hop) in hops.indexed)
          RouteHopTrace(
            index: index,
            chainId: 'osmosis-1',
            channelId: 'channel-0',
            port: 'transfer',
            counterpartyChainId: 'cosmoshub-4',
            kind: RouteHopKind.transfer,
            status: hop,
            expectedSeconds: 60,
          ),
      ],
      status: status ?? hops.last,
      failure: failure,
      recovery: null,
      stalled: failure == PacketFailureKind.stalled,
      currentHopIndex: 0,
      elapsedSeconds: null,
      estimatedDurationSeconds: 60,
      notes: const [],
      updatedAt: DateTime(2026),
    );

class TxLcd implements LcdClient {
  TxLcd(this.answer);
  final Object? Function() answer;

  @override
  String get chainId => 'osmosis-1';

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async => answer();
}

void main() {
  final now = DateTime(2026, 10, 18, 12);

  group('records', () {
    test('round-trip through storage with their route', () {
      final original = record('AB12', now).toJson();
      final decoded = decodePendingTransfers(jsonEncode([original]), now: now).single;
      expect(decoded.toJson(), original);
      expect(decoded.plan.hops.single.channelId, 'channel-0');
      expect(decoded.plan.warnings, ['A note']);
    });

    test('keep the newest five, drop anything older than a day, and survive garbage', () {
      final rows = [
        for (var i = 0; i < 7; i++) record('H$i', now.subtract(Duration(minutes: i))).toJson(),
        record('OLD', now.subtract(const Duration(hours: 25))).toJson(),
        {'txHash': 'broken'},
        'not a row',
      ];
      final decoded = decodePendingTransfers(jsonEncode(rows), now: now);
      expect([for (final row in decoded) row.txHash], ['H0', 'H1', 'H2', 'H3', 'H4']);
      expect(decodePendingTransfers('{nope', now: now), isEmpty);
      expect(decodePendingTransfers(null, now: now), isEmpty);
    });

    test('are saved once per hash and forgotten by hash', () async {
      SharedPreferences.setMockInitialValues({});
      const store = PendingTransferStore();
      final started = DateTime.now();
      await store.save(record('AA', started));
      await store.save(record('BB', started.add(const Duration(seconds: 1))));
      final saved = await store.save(record('AA', started.add(const Duration(seconds: 2))));
      expect([for (final row in saved) row.txHash], ['AA', 'BB']);
      expect([for (final row in await store.remove('AA')) row.txHash], ['BB']);
      expect([for (final row in await store.list()) row.txHash], ['BB']);
    });
  });

  group('outcomes', () {
    test('delivered once the last hop is received or acknowledged', () {
      expect(routeOutcome(trace([PacketStatus.received], status: PacketStatus.received)), RouteOutcome.delivered);
      expect(routeOutcome(trace([PacketStatus.acknowledged])), RouteOutcome.delivered);
      // A stalled route that arrived still arrived.
      expect(routeOutcome(trace([PacketStatus.received], failure: PacketFailureKind.stalled)),
          RouteOutcome.delivered);
    });

    test('nothing yet while a packet can still move', () {
      expect(routeOutcome(trace([PacketStatus.pending])), isNull);
      expect(routeOutcome(trace([PacketStatus.relayed], failure: PacketFailureKind.stalled)), isNull);
      expect(routeOutcome(trace([PacketStatus.unknown])), isNull);
    });

    test('refunded after a timeout or an error acknowledgement; recoverable after a failed swap delivery', () {
      expect(routeOutcome(trace([PacketStatus.timeout], failure: PacketFailureKind.timeout)), RouteOutcome.refunded);
      expect(routeOutcome(trace([PacketStatus.failed], failure: PacketFailureKind.ackError)), RouteOutcome.refunded);
      expect(
        routeOutcome(trace([PacketStatus.acknowledged, PacketStatus.failed],
            status: PacketStatus.failed, failure: PacketFailureKind.swapDeliveryFailed)),
        RouteOutcome.recoverable,
      );
    });
  });

  group('the signed transaction', () {
    test("is read first: the chain's refusal settles the record as failed", () async {
      final failed = await pollTransfer(
        record('AB', now),
        (_) => TxLcd(() => {
              'tx_response': {'code': 5, 'raw_log': 'insufficient funds'},
            }),
      );
      expect(failed.outcome, RouteOutcome.failed);
      expect(failed.sourceError, 'insufficient funds');
      expect(failed.finished, isTrue);
    });

    test('not indexed yet reads as nothing, never as a failure', () async {
      final read = await readSourceResult(
        TxLcd(() => throw InterchainError(InterchainErrorCode.lcdUnreachable, 'HTTP 404', httpStatus: 404)),
        'AB',
      );
      expect(read, isNull);
    });

    test('says plainly when live reads are off', () async {
      final polled = await pollTransfer(
        record('AB', now),
        (_) => TxLcd(() => throw InterchainError(InterchainErrorCode.readsDisabled, 'off')),
      );
      expect(polled.outcome, isNull);
      expect(polled.error, contains('Live reads are off'));
      expect(polled.finished, isFalse);
    });
  });
}
