/// The swap form, driven through the real screen in the offline world
/// (`test/support/swap_world.dart`): what it shows, what it refuses and why,
/// and that it holds together at 320dp with large text.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/screens/swap/swap_settings_sheet.dart';
import 'package:zunia_mobile/screens/swap/swap_token_sheet.dart';
import 'package:zunia_mobile/screens/tabs/swap_tab.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/swap/swap_assets.dart';
import 'package:zunia_mobile/swap/xcs_routes.dart';
import 'package:zunia_ui/zunia_ui.dart';

import 'support/swap_world.dart';

late SwapView defaultView;

void main() {
  setUpAll(() async {
    await loadSwapWorld();
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer(overrides: swapOverrides());
    defaultView = await settle(c);
    c.dispose();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(resetWorldClock);

  Future<ProviderContainer> pumpSwap(
    WidgetTester tester, {
    List<Override> extra = const [],
    Map<String, List<HeldToken>>? holdings,
    SwapVenueStatus? venue,
    Size size = const Size(320, 640),
    double textScale = 1,
    List<String> enabled = const ['cosmoshub-4', 'osmosis-1'],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        ...swapOverrides(holdings: holdings, venue: venue, enabled: enabled),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
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
          home: const Scaffold(body: SwapTab(showHeader: false)),
        ),
      ),
    );
    // Let the bundled data, balances, venue and route table resolve.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    return container;
  }

  /// Pick a pair the way the controller does, as the sheet's result would.
  void pick(ProviderContainer c, String from, String to) {
    c.read(swapControllerProvider.notifier)
      ..pickFrom(from)
      ..pickTo(to);
  }

  Future<void> typeAmount(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    // The debounce, then the plan and the price.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  VoidCallback? reviewAction(WidgetTester tester) => tester
      .widget<ZuniaButton>(find.widgetWithText(ZuniaButton, 'Review swap'))
      .onPressed;

  testWidgets(
    'no enabled network: nothing to swap from, and the screen says so',
    (tester) async {
      await pumpSwap(
        tester,
        extra: [chainAccountsProvider.overrideWithValue(const [])],
      );
      expect(find.text('No networks enabled'), findsOneWidget);
      expect(find.widgetWithText(ZuniaButton, 'Review swap'), findsNothing);
    },
  );

  testWidgets(
    'a wallet that holds nothing gets an empty state, not a dead form',
    (tester) async {
      await pumpSwap(tester, holdings: const {});
      expect(find.text('Nothing to swap yet'), findsOneWidget);
      expect(reviewAction(tester), isNull);
      expect(
        find.text('This wallet holds no non-zero balance to swap.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'before an amount: no price, a dash where the estimate goes, and the reason under the button',
    (tester) async {
      final c = await pumpSwap(tester);
      pick(
        c,
        'osmosis-1:uosmo',
        'osmosis-1:${'ibc/794C7D7F3B857713878A3A1927251FA6AC1EEE520424C1F6FAFE9BA26D476138'}',
      );
      await tester.pump();
      expect(find.text('—'), findsOneWidget);
      expect(reviewAction(tester), isNull);
      expect(find.text('Enter an amount to swap.'), findsOneWidget);
    },
  );

  testWidgets(
    'an amount gets a price, the Zunia fee line and a countdown, and Review turns on',
    (tester) async {
      var now = DateTime(2026, 10, 18, 12);
      worldClock = () => now;
      final c = await pumpSwap(tester);
      pick(
        c,
        'osmosis-1:uosmo',
        'osmosis-1:ibc/794C7D7F3B857713878A3A1927251FA6AC1EEE520424C1F6FAFE9BA26D476138',
      );
      await tester.pump();
      await typeAmount(tester, '10');

      expect(find.text('≈ 4.975'), findsOneWidget);
      // Read as one line: "Zunia fee 0.5% · 0.05 OSMO".
      expect(find.text('Zunia fee'), findsOneWidget);
      expect(find.text('0.5% · 0.05 OSMO'), findsOneWidget);
      expect(reviewAction(tester), isNotNull);
      await tester.scrollUntilVisible(
        find.textContaining('Price updates in'),
        120,
        scrollable: find.byType(Scrollable).first,
      );

      // The countdown ticks.
      expect(find.text('Price updates in 20s'), findsOneWidget);
      now = now.add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Price updates in 17s'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a pair the contract cannot swap from another chain offers step 1 of 2, not Review',
    (tester) async {
      final c = await pumpSwap(tester);
      pick(
        c,
        'cosmoshub-4:uatom',
        'osmosis-1:ibc/794C7D7F3B857713878A3A1927251FA6AC1EEE520424C1F6FAFE9BA26D476138',
      );
      await tester.pump();
      await typeAmount(tester, '1');
      expect(
        find.widgetWithText(ZuniaButton, 'Move to Osmosis'),
        findsOneWidget,
      );
      expect(find.widgetWithText(ZuniaButton, 'Review swap'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Two steps, both on Osmosis'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Two steps, both on Osmosis'), findsOneWidget);
    },
  );

  testWidgets(
    'cross-chain swaps that cannot reach the contract say why, and leave the pools alone',
    (tester) async {
      const off = SwapVenueStatus.unavailable(
        'No crosschain-swaps contract this release names exists on Osmosis.',
      );
      final c = await pumpSwap(
        tester,
        venue: off,
        extra: [xcsRouteTableProvider.overrideWith((_) async => null)],
      );
      pick(c, 'cosmoshub-4:uatom', 'osmosis-1:uosmo');
      await tester.pump();
      await typeAmount(tester, '1');
      expect(reviewAction(tester), isNull);
      expect(find.text(off.reason!), findsWidgets);
    },
  );

  testWidgets(
    'renders at 320dp with large text, and in landscape, without overflowing',
    (tester) async {
      final c = await pumpSwap(tester, textScale: 1.3);
      pick(
        c,
        'osmosis-1:uosmo',
        'osmosis-1:ibc/794C7D7F3B857713878A3A1927251FA6AC1EEE520424C1F6FAFE9BA26D476138',
      );
      await tester.pump();
      await typeAmount(tester, '10');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());

      await pumpSwap(tester, size: const Size(640, 320), textScale: 1.3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('every control the user can reach carries a label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpSwap(tester, size: const Size(390, 844));
    expect(
      find.bySemanticsLabel(RegExp('^Swap the two sides')),
      findsOneWidget,
    );
    expect(find.byTooltip('Swap settings'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('^Token to pay with: ATOM on Cosmos Hub')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp('^Token to receive')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Use the maximum')), findsOneWidget);
    handle.dispose();
  });

  testWidgets(
    'the picker lists what can be picked, and shows the rest only to a search, with the reason',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      final view = defaultView;
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: ZuniaTheme.dark(),
          home: Scaffold(
            body: SwapTokenList(
              options: view.destinations,
              selectedKey: view.to?.key,
              onPick: (key) => picked = key,
            ),
          ),
        ),
      );
      expect(find.text('YOUR TOKENS'), findsOneWidget);
      // ATOM on the Hub is the From: not listed until searched.
      expect(find.textContaining(selfReason), findsNothing);
      await tester.enterText(find.byType(TextField), 'atom');
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text(selfReason),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text(selfReason), findsOneWidget);
      await tester.tap(find.text(selfReason));
      expect(picked, isNull);
      await tester.enterText(find.byType(TextField), 'osmo');
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 3000));
      await tester.pump();
      await tester.tap(find.text('OSMO').first);
      expect(picked, 'osmosis-1:uosmo');
    },
  );

  testWidgets(
    'settings: presets, a custom value, a warning above 3% and a refusal above 50%',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      final view = defaultView;
      SwapSettings? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: ZuniaTheme.dark(),
          home: Scaffold(
            body: SwapSettingsForm(
              config: view.data!.config,
              settings: const SwapSettings(),
              onSave: (next) => saved = next,
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('0.5%'), findsOneWidget);
      expect(find.text('1%'), findsOneWidget);
      expect(find.text('3%'), findsOneWidget);
      // Material uppercases the segments; iOS draws them in sentence case.
      await tester.tap(find.text('CUSTOM'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, '5');
      await tester.pump();
      expect(find.textContaining('Wide tolerance'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '60');
      await tester.pump();
      expect(find.textContaining('up to 50%'), findsOneWidget);
      expect(
        tester
            .widget<ZuniaButton>(find.widgetWithText(ZuniaButton, 'Save'))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField).first, '2');
      await tester.pump();
      await tester.tap(find.widgetWithText(ZuniaButton, 'Save'));
      expect(saved?.slippagePercent, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
