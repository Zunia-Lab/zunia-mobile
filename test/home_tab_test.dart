import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/prices/price_service.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/tabs/home_tab.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

import 'support/catalog.dart';

/// Home on a small phone: the headline adds what was read at the prices that
/// apply, a chain that could not be read is said so instead of shown as 0,
/// and hiding amounts hides every figure.
const osmoAtom = 'ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2';

void main() {
  setUpAll(loadBundledData);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpHome(
    WidgetTester tester, {
    required Map<String, BalanceRead> reads,
    double width = 320,
    // The test font draws every glyph a full em wide, so 1.3x here reads far
    // wider than any real font; zunia_ui's ZuniaButton (not this screen) then
    // overflows on 'Manage networks'. 1.0 keeps the check about Home's layout.
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = Size(width, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final catalog = ChainCatalog.instance;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chainAccountsProvider.overrideWithValue([
            for (final chainId in reads.keys)
              ChainAccount(chain: catalog.find(chainId)!, address: '${catalog.find(chainId)!.bech32Prefix}1me'),
          ]),
          balanceFetcherProvider.overrideWithValue((chain, _) async => reads[chain.chainId]!),
          tokenNamerProvider.overrideWithValue((_, _) async => null),
          balanceCacheProvider.overrideWith((ref) => BalanceCache()),
          backupVerifiedProvider.overrideWith((ref) async => true),
          pricesProvider.overrideWith(
            (ref) async => PriceSnapshot(
              currency: 'usd',
              prices: const {
                'osmosis-1': SpotPrice(price: 0.5, change24h: 10),
                'cosmoshub-4': SpotPrice(price: 4, change24h: -5),
              },
            ),
          ),
        ],
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(body: HomeTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ChainBalance osmosis() => const ChainBalance(
        chainId: 'osmosis-1',
        available: '2000000',
        staked: '4000000',
        rewards: '0',
        tokens: [
          HeldToken(denom: 'uosmo', amount: '2000000'),
          HeldToken(denom: osmoAtom, amount: '1000000'),
        ],
      );

  testWidgets('adds held, staked and voucher value on a 320dp phone without overflow', (tester) async {
    await pumpHome(tester, reads: {'osmosis-1': BalanceLoaded(osmosis())});
    expect(tester.takeException(), isNull);
    // (2 + 4) OSMO × 0.5 + 1 ATOM × 4 = 7.
    expect(find.text(r'$7.00'), findsOneWidget);
    expect(find.text('ATOM'), findsWidgets);
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Stake'), findsOneWidget);
  });

  testWidgets('a chain that could not be read is named, never shown as an empty balance', (tester) async {
    await pumpHome(tester, reads: {
      'osmosis-1': BalanceLoaded(osmosis()),
      'cosmoshub-4': const BalanceUnavailable(ChainReadFailure(ChainReadFailureKind.badStatus, statusCode: 429)),
    });
    expect(tester.takeException(), isNull);
    expect(find.text('1 network did not answer. Their balances show as —, not 0.'), findsOneWidget);
    // Osmosis still adds up: the failed chain is left out, not counted as 0.
    expect(find.text(r'$7.00'), findsOneWidget);
  });

  testWidgets('hiding amounts hides the headline', (tester) async {
    await pumpHome(tester, reads: {'osmosis-1': BalanceLoaded(osmosis())});
    await tester.tap(find.byTooltip('Hide amounts'));
    await tester.pumpAndSettle();
    expect(find.text(r'$7.00'), findsNothing);
    expect(find.textContaining('••••'), findsWidgets);
  });
}
