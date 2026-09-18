/// Cross-send now plans its route with the engine, and says what is missing.
///
/// The screen used to discover a channel with its own copy of the IBC code,
/// accept whatever came back, and enable the CTA on `check.ok`. It now asks
/// `@zunialab/interchain`'s Dart port for a plan, and when discovery finds
/// nothing — which is the normal outcome on a chain with a slow or partial
/// endpoint — it offers the manual channel field instead of a dead end.
library;

import 'package:bech32/bech32.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/screens/ibc_route_screen.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_ui/zunia_ui.dart';

class _Registry implements ChainRegistry {
  @override
  ChainInfo? get(String chainId) => const {
        'source-1': ChainInfo(
          chainId: 'source-1',
          chainName: 'Source',
          bech32Prefix: 'src',
          coinMinimalDenom: 'usrc',
          rest: 'http://127.0.0.1:1',
        ),
        'dest-1': ChainInfo(
          chainId: 'dest-1',
          chainName: 'Dest',
          bech32Prefix: 'dst',
          coinMinimalDenom: 'udst',
          rest: 'http://127.0.0.1:1',
        ),
      }[chainId];

  @override
  List<ChainInfo> list() => [get('source-1')!, get('dest-1')!];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpRoute(
    WidgetTester tester, {
    Size size = const Size(320, 640),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          interchainRegistryProvider.overrideWithValue(_Registry()),
        ],
        child: const MaterialApp(
          home: IbcRouteScreen(
            chainId: 'source-1',
            denom: 'SRC',
            amount: '1.5',
            fromAddress: 'src1sender',
            sourcePrefix: 'src',
            destChainId: 'dest-1',
            destPrefix: 'dst',
            forceIbc: true,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  VoidCallback? reviewAction(WidgetTester tester) => tester
      .widget<ZuniaButton>(find.widgetWithText(ZuniaButton, 'Review transfer'))
      .onPressed;

  testWidgets('no recipient means no route, and the CTA says which',
      (tester) async {
    await pumpRoute(tester);
    expect(reviewAction(tester), isNull);
    expect(find.text('Enter a recipient address'), findsOneWidget);
  });

  testWidgets('a malformed address is rejected before anything is planned',
      (tester) async {
    await pumpRoute(tester);
    await tester.enterText(find.byType(TextField).first, 'src1someoneelse');
    await tester.pump();
    // Twice on purpose: beside the field, and again under the disabled CTA
    // where a user looking at a dead button looks first.
    expect(find.text('Not a valid bech32 address'), findsWidgets);
    expect(reviewAction(tester), isNull);
  });

  testWidgets('a valid address for the wrong chain is rejected too',
      (tester) async {
    // A real bech32 string with the source chain's prefix: the checksum is
    // fine, the destination is not.
    final wrongChain = const Bech32Codec().encode(
      Bech32('src', List<int>.filled(32, 0)),
    );
    await pumpRoute(tester);
    await tester.enterText(find.byType(TextField).first, wrongChain);
    await tester.pump();
    expect(find.text('Expected a dst… address'), findsWidgets);
    expect(reviewAction(tester), isNull);
  });

  testWidgets('the route panel starts empty with a reason, never a guess',
      (tester) async {
    await pumpRoute(tester);
    expect(find.text('No route yet'), findsOneWidget);
    // Nothing claims a channel until one has been found or typed.
    expect(find.textContaining('channel-'), findsNothing);
  });

  testWidgets('renders at 320dp and in landscape without overflowing',
      (tester) async {
    await pumpRoute(tester);
    expect(tester.takeException(), isNull);
    await pumpRoute(tester, size: const Size(640, 320));
    expect(tester.takeException(), isNull);
  });
}
