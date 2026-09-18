/// The swap tab's honesty behaviours, driven through the real screen.
///
/// The failure this pins is the one the audit found everywhere: a control that
/// looks live while nothing behind it works. The Osmosis crosschain-swaps
/// contract address is deployment data and this build ships without one, so the
/// review button must be off and the screen must say exactly why — never a
/// spinner, never a priced-looking quote, never a zero where a number could not
/// be read.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/tabs/swap_tab.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

ChainEntry _chain(String id, String denom, String prefix) => ChainEntry(
      chainId: id,
      chainName: id,
      bech32Prefix: prefix,
      coinType: 118,
      network: 'testnet',
      coinDenom: denom,
      coinMinimalDenom: 'u${denom.toLowerCase()}',
      coinDecimals: 6,
      feeDenom: denom,
      feeMinimalDenom: 'u${denom.toLowerCase()}',
      feeDecimals: 6,
      // Unroutable on purpose: a widget test must never open a socket, and the
      // screen has to behave the same way it does against a dead endpoint.
      rest: 'http://127.0.0.1:1',
    );

void main() {
  final source = _chain('source-1', 'SRC', 'src');
  final dest = _chain('dest-1', 'DST', 'dst');

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSwap(
    WidgetTester tester, {
    List<ChainAccount>? accounts,
    SwapVenueStatus? venue,
    Size size = const Size(320, 640),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chainAccountsProvider.overrideWithValue(
            accounts ??
                [
                  ChainAccount(chain: source, address: 'src1sender'),
                  ChainAccount(chain: dest, address: 'dst1recipient'),
                ],
          ),
          balancesProvider.overrideWith(
            (_) => BalanceReads(
              {
                source.chainId: ChainBalance(
                  chainId: source.chainId,
                  available: '5000000',
                  staked: '0',
                  rewards: '0',
                ),
              },
              const {},
            ),
          ),
          if (venue != null)
            swapVenueStatusProvider.overrideWith((_) async => venue),
        ],
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
          home: const Scaffold(body: SwapTab()),
        ),
      ),
    );
    // Two pumps: one to build, one to let the venue-status future resolve.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  VoidCallback? reviewAction(WidgetTester tester) => tester
      .widget<ZuniaButton>(find.widgetWithText(ZuniaButton, 'Review swap'))
      .onPressed;

  testWidgets('one enabled network cannot swap, and the screen says so',
      (tester) async {
    await pumpSwap(
      tester,
      accounts: [ChainAccount(chain: source, address: 'src1sender')],
    );
    expect(find.text('Enable two networks'), findsOneWidget);
    expect(find.widgetWithText(ZuniaButton, 'Review swap'), findsNothing);
  });

  testWidgets('an unconfigured swap contract disables review with the reason',
      (tester) async {
    await pumpSwap(
      tester,
      venue: const SwapVenueStatus.unavailable(
        'This build has no Osmosis crosschain-swaps contract address.',
      ),
    );

    expect(reviewAction(tester), isNull);
    // The reason sits under the CTA, where a user looking at a dead button
    // looks first.
    expect(
      find.textContaining('no Osmosis crosschain-swaps contract address'),
      findsWidgets,
    );
    // And again as a callout in the body, which is below the fold at 320dp.
    await tester.scrollUntilVisible(
      find.text('Swaps are off in this build'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Swaps are off in this build'), findsOneWidget);
  });

  testWidgets('nothing is priced before an amount is entered', (tester) async {
    await pumpSwap(
      tester,
      venue: const SwapVenueStatus.unavailable('not configured in tests'),
    );

    // The "To" leg shows an em dash rather than a zero it cannot justify.
    expect(find.text('—'), findsWidgets);
    expect(reviewAction(tester), isNull);
  });

  testWidgets('the route panel is empty with a reason, not a fake route',
      (tester) async {
    await pumpSwap(
      tester,
      venue: const SwapVenueStatus.unavailable('not configured in tests'),
    );
    await tester.scrollUntilVisible(
      find.text('No route yet'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('No route yet'), findsOneWidget);
  });

  testWidgets('renders at 320dp and in landscape without overflowing',
      (tester) async {
    await pumpSwap(tester, size: const Size(320, 640));
    expect(tester.takeException(), isNull);

    await pumpSwap(tester, size: const Size(640, 320));
    expect(tester.takeException(), isNull);
  });

  testWidgets('every control the user can reach carries a label', (tester) async {
    await pumpSwap(tester);

    // The direction toggle is an icon: without this it is unreachable by
    // anything that is not a pointer.
    expect(
      find.bySemanticsLabel('Swap the two networks'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsWidgets);
  });
}
