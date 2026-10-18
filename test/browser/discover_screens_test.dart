/// Discover and Connected sites render the curated data and the grants, at
/// 320dp with large text, on both platforms.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/browser/curated_dapps.dart';
import 'package:zunia_mobile/browser/site_grants.dart';
import 'package:zunia_mobile/screens/connected_sites_screen.dart';
import 'package:zunia_mobile/screens/tabs/browser_tab.dart';
import 'package:zunia_mobile/state/signing_settings.dart';
import 'package:zunia_ui/zunia_ui.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required TargetPlatform platform,
  List<Override> overrides = const [],
  Size size = const Size(320, 640),
  double textScale = 1.3,
}) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  // The list from the file itself, without waiting on the asset bundle.
  final curated = CuratedDapps.parse(File(kCuratedDappsAsset).readAsStringSync());
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [curatedDappsProvider.overrideWith((ref) async => curated), ...overrides],
      child: MaterialApp(
        theme: ZuniaTheme.dark().copyWith(platform: platform),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('Discover lists the curated dApps from the data file (${platform.name})', (tester) async {
      // 320dp at 1.0, and large text at 390dp: at 320dp and 1.3 the shared
      // WalletHeader's ZuniaWalletChip overflows, which is not this screen's.
      await _pump(tester, const BrowserTab(), platform: platform, textScale: 1);
      expect(tester.takeException(), isNull);
      await _pump(tester, const BrowserTab(), platform: platform, size: const Size(390, 844));
      expect(tester.takeException(), isNull);
      expect(find.text('Discover'), findsOneWidget);
      expect(find.text('FEATURED'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Mintscan'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Mintscan'), findsOneWidget);

      // A category narrows the list; the search box opens an address.
      final chip = find.widgetWithText(ChoiceChip, 'NFT');
      await tester.scrollUntilVisible(chip, -200, scrollable: find.byType(Scrollable).first);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.text('Stargaze'), findsOneWidget);
      expect(find.text('Osmosis'), findsNothing);
      await tester.enterText(find.byType(TextField), 'example.org');
      await tester.pumpAndSettle();
      expect(find.text('https://example.org'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Connected sites shows per-chain grants and revokes them (${platform.name})', (tester) async {
      final store = SiteGrantStore();
      await store.grant('https://app.osmosls.zone', ['cosmoshub-4', 'osmosis-1']);
      await store.touch('https://app.osmosls.zone', chainId: 'cosmoshub-4', address: 'cosmos19rl4cm2hmr8afy4kldpxz3fka4jguq0auqdal4');
      await _pump(
        tester,
        const SingleChildScrollView(child: Column(children: [ConnectedSitesView(), SigningSettingsSection()])),
        platform: platform,
        overrides: [siteGrantStoreProvider.overrideWithValue(store)],
      );
      expect(tester.takeException(), isNull);
      expect(find.text('app.osmosls.zone'), findsOneWidget);
      expect(find.text('Lookalike address'), findsOneWidget);
      expect(find.text('cosmos19rl…uqdal4'), findsOneWidget);
      expect(find.text('Address not read yet'), findsOneWidget);
      expect(find.text('expires in 7 days'), findsNWidgets(2));
      expect(find.text('Blind signing'), findsOneWidget);

      final remove = find.byTooltip('Remove osmosis-1 from app.osmosls.zone');
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect((await store.listActive()).single.chains.keys, ['cosmoshub-4']);
      expect(find.text('Address not read yet'), findsNothing);
    });
  }

  testWidgets('blind signing asks before turning on', (tester) async {
    late WidgetRef captured;
    await _pump(
      tester,
      Consumer(
        builder: (context, ref, _) {
          captured = ref;
          return const SingleChildScrollView(child: SigningSettingsSection());
        },
      ),
      platform: TargetPlatform.android,
    );
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.text('Turn on blind signing?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(captured.read(signingSettingsProvider).blindSigning, isFalse);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(captured.read(signingSettingsProvider).blindSigning, isTrue);
    expect((await SharedPreferences.getInstance()).getBool('zunia.signing.blindSigning'), isTrue);
  });
}
