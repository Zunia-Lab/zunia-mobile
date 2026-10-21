import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/send_screen.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

import 'support/catalog.dart';

/// The send step is where a failed balance read used to become a claim about
/// the user's money: a rate-limited endpoint produced '0', the screen printed
/// "More than…" under a valid amount, and the step could not be passed until
/// the endpoint recovered. These tests drive the real screen and pin the
/// difference between a balance that was read, one still being read, and one
/// that could not be read.
void main() {
  const chainId = 'testchain-1';
  const address = 'test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq';
  // A valid bech32 recipient on the same prefix.
  const recipient = 'test1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5nm3q2g';
  const overBalanceClaim = 'More than the TEST available';

  final chain = ChainEntry(
    chainId: chainId,
    chainName: 'Testchain',
    bech32Prefix: 'test',
    coinType: 118,
    network: 'testnet',
    coinDenom: 'TEST',
    coinMinimalDenom: 'utest',
    coinDecimals: 6,
    feeDenom: 'TEST',
    feeMinimalDenom: 'utest',
    feeDecimals: 6,
    rest: 'http://127.0.0.1:1',
  );

  ChainBalance balanceOf(String available, {List<String> otherDenoms = const []}) => ChainBalance(
        chainId: chainId,
        available: available,
        staked: '0',
        rewards: '0',
        otherDenoms: otherDenoms,
        tokens: [if (available != '0') HeldToken(denom: 'utest', amount: available)],
      );

  setUpAll(loadBundledData);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChainCatalog.instance.setCustom([chain]);
  });

  tearDown(() => ChainCatalog.instance.setCustom(const []));

  /// Pumps the real SendScreen with [read] standing in for the LCD.
  Future<void> pumpSend(
    WidgetTester tester,
    FutureOr<BalanceRead> Function() read, {
    String? initialRecipient,
  }) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chainAccountsProvider.overrideWithValue([ChainAccount(chain: chain, address: address)]),
          balanceFetcherProvider.overrideWithValue((_, _) async => read()),
          tokenNamerProvider.overrideWithValue((_, _) async => null),
          balanceCacheProvider.overrideWith((ref) => BalanceCache()),
        ],
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
          home: SendScreen(initialChainId: chainId, initialRecipient: initialRecipient ?? recipient),
        ),
      ),
    );
  }

  Finder amountField() => find.byWidgetPredicate(
        (widget) => widget is TextField && widget.decoration?.hintText == '0',
      );

  VoidCallback? reviewAction(WidgetTester tester) =>
      tester.widget<ZuniaButton>(find.widgetWithText(ZuniaButton, 'Review')).onPressed;

  VoidCallback? maxAction(WidgetTester tester) => tester
      .widget<InkWell>(find.ancestor(of: find.text('MAX'), matching: find.byType(InkWell)))
      .onTap;

  testWidgets('a balance that was read still blocks an amount above it', (tester) async {
    await pumpSend(tester, () => BalanceLoaded(balanceOf('500000000')));
    await tester.pumpAndSettle();

    await tester.enterText(amountField(), '600');
    await tester.pumpAndSettle();

    // The claim is true here: the endpoint answered with 500 TEST.
    expect(find.text(overBalanceClaim), findsWidgets);
    expect(reviewAction(tester), isNull);
  });

  testWidgets('Max keeps the fee back when the token pays the fee', (tester) async {
    await pumpSend(tester, () => BalanceLoaded(balanceOf('500000000')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('MAX'));
    await tester.pumpAndSettle();

    // 300000 gas × 1.4 at the default 0.025 price is 10500 base units kept back.
    expect(tester.widget<TextField>(amountField()).controller!.text, '499.9895');
    expect(find.textContaining('back for the network fee'), findsOneWidget);
    expect(reviewAction(tester), isNotNull);
  });

  testWidgets('an account read as empty still blocks', (tester) async {
    await pumpSend(tester, () => BalanceLoaded(balanceOf('0')));
    await tester.pumpAndSettle();

    await tester.enterText(amountField(), '1');
    await tester.pumpAndSettle();

    expect(find.text(overBalanceClaim), findsWidgets);
    expect(reviewAction(tester), isNull);
  });

  testWidgets('a rate-limited read never claims the amount is over balance', (tester) async {
    await pumpSend(
      tester,
      () => const BalanceUnavailable(ChainReadFailure(ChainReadFailureKind.badStatus, statusCode: 429)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(amountField(), '600');
    await tester.pumpAndSettle();

    expect(find.text(overBalanceClaim), findsNothing);
    expect(find.textContaining('answered HTTP 429'), findsOneWidget);
    expect(find.text('Balance not available'), findsOneWidget);
    // The step can still be passed, with the caveat stated.
    expect(reviewAction(tester), isNotNull);
    expect(find.textContaining('could not be read, so this amount has not been'), findsOneWidget);
  });

  testWidgets('a timed-out read disables the percentage shortcuts', (tester) async {
    await pumpSend(
      tester,
      () => const BalanceUnavailable(ChainReadFailure(ChainReadFailureKind.timedOut)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('did not answer in time'), findsOneWidget);
    // MAX of an unknown balance is not a number the wallet has.
    expect(maxAction(tester), isNull);
  });

  testWidgets('a read still in flight says so rather than showing a zero', (tester) async {
    final pending = Completer<BalanceRead>();
    await pumpSend(tester, () => pending.future);
    await tester.pump();

    await tester.enterText(amountField(), '600');
    await tester.pump();

    expect(find.text(overBalanceClaim), findsNothing);
    expect(find.text('Reading balance…'), findsWidgets);
    expect(maxAction(tester), isNull);
    expect(find.textContaining('still being read'), findsOneWidget);

    pending.complete(BalanceLoaded(balanceOf('500000000')));
    await tester.pumpAndSettle();

    // Once the number arrives the claim is allowed again.
    expect(find.text(overBalanceClaim), findsWidgets);
    expect(maxAction(tester), isNotNull);
  });

  testWidgets('retry re-runs the read', (tester) async {
    var reads = 0;
    await pumpSend(tester, () {
      reads++;
      return const BalanceUnavailable(ChainReadFailure(ChainReadFailureKind.unreachable));
    });
    await tester.pumpAndSettle();
    expect(reads, 1);

    await tester.tap(find.text('Retry balance read'));
    await tester.pumpAndSettle();

    expect(reads, 2);
  });

  testWidgets('reads switched off explain themselves and offer no dead retry', (tester) async {
    await pumpSend(
      tester,
      () => const BalanceUnavailable(ChainReadFailure(ChainReadFailureKind.readsDisabled)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Live reads are off'), findsOneWidget);
    expect(find.text('Retry balance read'), findsNothing);
    expect(maxAction(tester), isNull);
  });

  testWidgets('a zero under a denom the account does not use is explained', (tester) async {
    await pumpSend(
      tester,
      () => BalanceLoaded(balanceOf('0', otherDenoms: const ['uosmo', 'ibc/ABC'])),
    );
    await tester.pumpAndSettle();

    expect(find.text('No TEST in this account'), findsOneWidget);
    expect(find.textContaining('2 other denominations'), findsOneWidget);
  });

  testWidgets('a recipient on another prefix is refused with the expected one', (tester) async {
    await pumpSend(
      tester,
      () => BalanceLoaded(balanceOf('500000000')),
      initialRecipient: 'cosmos1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7xu',
    );
    await tester.pumpAndSettle();
    await tester.enterText(amountField(), '1');
    await tester.pumpAndSettle();

    expect(find.text('Expected a test1… address'), findsWidgets);
    expect(reviewAction(tester), isNull);
  });

  testWidgets('renders at 320dp with large text without overflowing', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chainAccountsProvider.overrideWithValue([ChainAccount(chain: chain, address: address)]),
          balanceFetcherProvider.overrideWithValue((_, _) async => BalanceLoaded(balanceOf('500000000'))),
          tokenNamerProvider.overrideWithValue((_, _) async => null),
          balanceCacheProvider.overrideWith((ref) => BalanceCache()),
        ],
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: const SendScreen(initialChainId: chainId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
