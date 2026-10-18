/// The confirm card, driven through the real screen with a review the real
/// controller prepared in the offline world: what it shows, and that the Sign
/// button refuses anything that moved, expired or was not reviewed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_core/zunia_core.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/swap_review_screen.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/swap/swap_fee.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';
import 'package:zunia_ui/zunia_ui.dart';

import 'support/swap_fixtures.dart';
import 'support/swap_world.dart';

const usdcInj =
    'ibc/794C7D7F3B857713878A3A1927251FA6AC1EEE520424C1F6FAFE9BA26D476138';

TxQuote quoteFor(PreparedSwap prepared, {List<TxMsg>? msgs}) => TxQuote(
  chain: prepared.chain,
  signer: prepared.review.signer,
  msgs: msgs ?? prepared.msgs,
  memo: prepared.memo,
  accountNumber: 7,
  sequence: 3,
  fee: ZuniaFee(
    amount: [ZuniaCoin(denom: prepared.chain.feeMinimalDenom, amount: '5250')],
    gasLimit: 210000,
  ),
  speed: FeeSpeed.average,
  gasAdjustment: defaultGasAdjustment,
  preview: ZuniaSigningPreview(
    chainId: prepared.chain.chainId,
    mode: ZuniaSignMode.direct,
    summaries: const [
      'Swap 9950000 uosmo for at least 4925250 USDC through 2 routes',
      'Send 50000 uosmo',
    ],
    msgs: const [],
    fee: const [],
    gasLimit: 210000,
    memo: prepared.memo,
    spendsFunds: true,
    counterparties: const [],
    signBytesHash: '00',
  ),
  publicKeyHex: '',
);

void main() {
  setUpAll(loadSwapWorld);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(resetWorldClock);

  Future<({ProviderContainer container, PreparedSwap prepared})> pumpReview(
    WidgetTester tester, {
    required String from,
    required String to,
    String amount = '10',
    List<TxMsg> Function(PreparedSwap prepared)? msgs,
    Size size = const Size(320, 640),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(overrides: swapOverrides());
    addTearDown(container.dispose);
    late PreparedSwap prepared;
    await tester.runAsync(() async {
      final view = await plan(container, from: from, to: to, amount: amount);
      prepared = await container
          .read(swapControllerProvider.notifier)
          .prepareReview(view);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: SwapReviewScreen(
            prepared: prepared,
            quote: quoteFor(prepared, msgs: msgs?.call(prepared)),
          ),
        ),
      ),
    );
    await tester.pump();
    return (container: container, prepared: prepared);
  }

  VoidCallback? sign(WidgetTester tester, String label) => tester
      .widget<ZuniaButton>(find.widgetWithText(ZuniaButton, label))
      .onPressed;

  testWidgets(
    'one card: what is paid, what comes back, the minimum, the rate, both fees and the clock',
    (tester) async {
      var now = DateTime(2026, 10, 18, 12);
      worldClock = () => now;
      await pumpReview(
        tester,
        from: 'osmosis-1:uosmo',
        to: 'osmosis-1:$usdcInj',
        size: const Size(390, 1000),
      );
      expect(find.text('YOU PAY'), findsOneWidget);
      expect(find.text('10 OSMO'), findsOneWidget);
      expect(find.text('YOU RECEIVE'), findsOneWidget);
      expect(find.text('≈ 4.975 USDC.inj'), findsOneWidget);
      expect(find.text('Minimum received'), findsOneWidget);
      expect(find.text('4.92525 USDC.inj'), findsOneWidget);
      expect(find.text('Rate'), findsOneWidget);
      expect(find.text('1 OSMO ≈ 0.500000 USDC.inj'), findsOneWidget);
      expect(find.text('Zunia fee (0.5%)'), findsOneWidget);
      expect(find.text('0.05 OSMO'), findsOneWidget);
      expect(find.text('Network fee'), findsOneWidget);
      expect(find.text('0.00525 OSMO'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Price valid for 20s'), findsOneWidget);
      expect(
        find.text(
          'The swap and the fee are one transaction: if the swap fails, no fee is taken.',
        ),
        findsOneWidget,
      );
      expect(sign(tester, 'Sign'), isNotNull);

      // Past the quote's twenty seconds the price no longer signs.
      now = now.add(const Duration(seconds: 21));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Price expired. Refresh it to sign.'), findsOneWidget);
      expect(sign(tester, 'Price expired'), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a cross-chain swap says the fee is not refunded if the swap fails on Osmosis',
    (tester) async {
      await pumpReview(
        tester,
        from: 'cosmoshub-4:uatom',
        to: 'osmosis-1:uosmo',
        amount: '1',
        size: const Size(390, 1000),
      );
      expect(
        find.text(
          'If the swap fails on Osmosis, the amount swapped comes back to you, but the 0.5% Zunia fee does not.',
        ),
        findsOneWidget,
      );
      expect(find.text('Zunia fee (0.5%)'), findsOneWidget);
      expect(find.text('0.005 ATOM'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the Sign button reads Out of date as soon as the form moves under the review',
    (tester) async {
      final h = await pumpReview(
        tester,
        from: 'osmosis-1:uosmo',
        to: 'osmosis-1:$usdcInj',
        size: const Size(390, 1000),
      );
      expect(sign(tester, 'Sign'), isNotNull);
      final view = h.container.read(swapViewProvider);
      h.container
          .read(swapControllerProvider.notifier)
          .setAmount('11', view.from!);
      // The review was prepared in a real zone (runAsync); Riverpod's refresh
      // is scheduled there too, so let that zone run once before the frame.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      expect(sign(tester, 'Out of date'), isNull);
      expect(find.text('This review is out of date'), findsOneWidget);
      expect(find.textContaining('no longer 10 OSMO'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a transaction paying a fee the review did not show is refused, in red',
    (tester) async {
      await pumpReview(
        tester,
        from: 'osmosis-1:uosmo',
        to: 'osmosis-1:$usdcInj',
        size: const Size(390, 1000),
        msgs: (prepared) => [
          prepared.msgs.first,
          buildSwapFeeMsg(
            sender: prepared.review.signer,
            recipient: bech('osmo', 9),
            denom: 'uosmo',
            amount: BigInt.from(50000),
          ),
        ],
      );
      expect(find.text('Zunia will not sign this'), findsOneWidget);
      expect(find.textContaining("not Zunia's fee address"), findsOneWidget);
      expect(sign(tester, 'Cannot sign'), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the network fee speed is changed from a native sheet', (
    tester,
  ) async {
    await pumpReview(
      tester,
      from: 'osmosis-1:uosmo',
      to: 'osmosis-1:$usdcInj',
      size: const Size(390, 1000),
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Network fee speed'), findsOneWidget);
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    // Material: a bottom sheet, dismissed by tapping outside it.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('Network fee speed'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('fits at 320dp with large text', (tester) async {
    await pumpReview(
      tester,
      from: 'cosmoshub-4:uatom',
      to: 'osmosis-1:uosmo',
      amount: '1',
      textScale: 1.3,
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('the card names the chain the fee is paid on', () {
    expect(ChainCatalog.instance.find('osmosis-1')?.feeDenom, 'OSMO');
  });
}
