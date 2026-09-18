/// The tracking screen tells the user where their money is.
///
/// A progress bar cannot distinguish "moving", "stuck but safe", "failed and
/// refunded" and "sitting in a contract until you claim it", and the user's next
/// action differs in all four. These tests pin the two states a client can get
/// wrong on its own: a chain it cannot read, and a route it has not read yet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/screens/packet_status_screen.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/tracking.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_ui/zunia_ui.dart';

class _FakeLcd implements LcdClient {
  _FakeLcd(this.chainId);

  @override
  final String chainId;

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    // Everything 404s: a node that has not indexed the transaction yet, which
    // is the normal state for the first few seconds after a broadcast.
    throw InterchainError(
      InterchainErrorCode.lcdUnreachable,
      'not indexed',
      chainId: chainId,
      httpStatus: 404,
    );
  }
}

const _plan = RoutePlan(
  sourceChainId: 'source-1',
  destChainId: 'dest-1',
  inputDenom: 'usrc',
  outputDenom: 'udst',
  hops: [
    RouteHop(
      chainId: 'source-1',
      channelId: 'channel-3',
      port: 'transfer',
      counterpartyChainId: 'osmosis-1',
      kind: RouteHopKind.transfer,
    ),
    RouteHop(
      chainId: 'osmosis-1',
      channelId: '',
      port: '',
      counterpartyChainId: 'osmosis-1',
      kind: RouteHopKind.swap,
    ),
    RouteHop(
      chainId: 'osmosis-1',
      channelId: 'channel-42',
      port: 'transfer',
      counterpartyChainId: 'dest-1',
      kind: RouteHopKind.forward,
    ),
  ],
  memo: '{"wasm":{}}',
  warnings: [],
  estimatedDurationSeconds: 140,
  requiresPfm: false,
  requiresIbcHooks: true,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpTracker(
    WidgetTester tester, {
    required LcdResolver resolver,
    String? swapContract,
    String? recoveryAddress,
    Size size = const Size(320, 640),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [lcdResolverProvider.overrideWithValue(resolver)],
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
          home: PacketStatusScreen(
            plan: _plan,
            sourceTxHash: 'AA11BB22',
            swapContract: swapContract,
            recoveryAddress: recoveryAddress,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('a chain with no endpoint is an error with the reason, not a '
      'blank tracker', (tester) async {
    await pumpTracker(tester, resolver: (_) => null);
    expect(find.textContaining('No REST endpoint for source-1'), findsOneWidget);
  });

  testWidgets('an unindexed transaction reads as still in flight, not failed',
      (tester) async {
    await pumpTracker(tester, resolver: (chainId) => _FakeLcd(chainId));
    // The packet has not been seen yet; nothing here may claim it failed.
    expect(find.textContaining('failed'), findsNothing);
    expect(find.textContaining('refunded'), findsNothing);
    expect(find.byType(ZuniaPacketTracker), findsOneWidget);
  });

  testWidgets('the planned hops are shown before the first read', (tester) async {
    await pumpTracker(tester, resolver: (chainId) => _FakeLcd(chainId));
    expect(find.textContaining('channel-3'), findsWidgets);
  });

  testWidgets('renders at 320dp and in landscape without overflowing',
      (tester) async {
    await pumpTracker(tester, resolver: (chainId) => _FakeLcd(chainId));
    expect(tester.takeException(), isNull);

    await pumpTracker(
      tester,
      resolver: (chainId) => _FakeLcd(chainId),
      size: const Size(640, 320),
    );
    expect(tester.takeException(), isNull);
  });
}
