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

/// The send step is where a failed balance read used to become a claim about
/// the user's money: a rate-limited endpoint produced '0', the screen printed
/// "More than your TEST balance" in red under a valid amount, and the step
/// could not be passed until the endpoint recovered. These tests drive the
/// real screen and pin the difference between a balance that was read, one
/// that is still being read, and one that could not be read.
void main() {
  const chainId = 'testchain-1';
  const address = 'test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq';
  const overBalanceClaim = 'More than your TEST balance';

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

  ChainBalance balanceOf(String available, {List<String> otherDenoms = const []}) =>
      ChainBalance(
        chainId: chainId,
        available: available,
        staked: '0',
        rewards: '0',
        otherDenoms: otherDenoms,
      );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Pumps the real SendScreen with [reads] standing in for the LCD round trip.
  Future<void> pumpSend(
    WidgetTester tester,
    FutureOr<Map<String, ChainBalance>> Function(Ref ref) reads,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chainAccountsProvider.overrideWithValue([
            ChainAccount(chain: chain, address: address),
          ]),
          balancesProvider.overrideWith(reads),
        ],
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
          home: const SendScreen(chainId: chainId),
        ),
      ),
    );
  }

  VoidCallback? ctaAction(WidgetTester tester) => tester
      .widget<ZuniaButton>(
        find.widgetWithText(ZuniaButton, 'Choose recipient'),
      )
      .onPressed;

  VoidCallback? maxAction(WidgetTester tester) => tester
      .widget<InkWell>(
        find.ancestor(of: find.text('MAX'), matching: find.byType(InkWell)),
      )
      .onTap;

  testWidgets('a balance that was read still blocks an amount above it',
      (tester) async {
    await pumpSend(
      tester,
      (_) => BalanceReads({chainId: balanceOf('500000000')}, const {}),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '600');
    await tester.pumpAndSettle();

    // The claim is true here: the endpoint answered with 500 TEST.
    expect(find.text(overBalanceClaim), findsNWidgets(2));
    expect(ctaAction(tester), isNull);
  });

  testWidgets('an account read as empty still blocks', (tester) async {
    await pumpSend(
      tester,
      (_) => BalanceReads({chainId: balanceOf('0')}, const {}),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '1');
    await tester.pumpAndSettle();

    expect(find.text(overBalanceClaim), findsWidgets);
    expect(ctaAction(tester), isNull);
  });

  testWidgets('a rate-limited read never claims the amount is over balance',
      (tester) async {
    await pumpSend(
      tester,
      (_) => BalanceReads(const {}, {
        chainId: const ChainReadFailure(
          ChainReadFailureKind.badStatus,
          statusCode: 429,
        ),
      }),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '600');
    await tester.pumpAndSettle();

    // The regression: a transient failure printed as a fact about holdings.
    expect(find.text(overBalanceClaim), findsNothing);
    // The reason is on screen, naming the cause.
    expect(find.textContaining('answered HTTP 429'), findsOneWidget);
    expect(find.text('Balance not available'), findsOneWidget);
    // And the step can still be passed, with the caveat stated.
    expect(ctaAction(tester), isNotNull);
    expect(
      find.textContaining('could not be read, so this amount has not been'),
      findsOneWidget,
    );
  });

  testWidgets('a timed-out read disables the percentage shortcuts with a reason',
      (tester) async {
    await pumpSend(
      tester,
      (_) => BalanceReads(const {}, {
        chainId: const ChainReadFailure(ChainReadFailureKind.timedOut),
      }),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('did not answer in time'), findsOneWidget);
    // MAX of an unknown balance is not a number the wallet has.
    expect(maxAction(tester), isNull);
    await tester.tap(find.text('MAX'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('0.00'), findsOneWidget, reason: 'field hint, so empty');
    expect(find.textContaining('Balance unavailable'), findsWidgets);
  });

  testWidgets('a malformed body is reported as unreadable, not as zero',
      (tester) async {
    await pumpSend(
      tester,
      (_) => BalanceReads(const {}, {
        chainId: const ChainReadFailure(ChainReadFailureKind.malformedBody),
      }),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '600');
    await tester.pumpAndSettle();

    expect(find.text(overBalanceClaim), findsNothing);
    expect(
      find.textContaining('something that is not a balance'),
      findsOneWidget,
    );
    expect(ctaAction(tester), isNotNull);
  });

  testWidgets('a read still in flight says so rather than showing a zero',
      (tester) async {
    final pending = Completer<Map<String, ChainBalance>>();
    await pumpSend(tester, (_) => pending.future);
    await tester.pump();

    await tester.enterText(find.byType(TextField), '600');
    await tester.pump();

    expect(find.text(overBalanceClaim), findsNothing);
    expect(find.textContaining('Checking your TEST balance'), findsOneWidget);
    expect(maxAction(tester), isNull);
    expect(ctaAction(tester), isNotNull);
    expect(
      find.textContaining('still being read'),
      findsOneWidget,
    );

    pending.complete(BalanceReads({chainId: balanceOf('500000000')}, const {}));
    await tester.pumpAndSettle();

    // Once the number arrives the claim is allowed again.
    expect(find.text(overBalanceClaim), findsNWidgets(2));
    expect(maxAction(tester), isNotNull);
  });

  testWidgets('retry re-runs the read', (tester) async {
    var reads = 0;
    await pumpSend(tester, (_) {
      reads++;
      return BalanceReads(const {}, {
        chainId: const ChainReadFailure(
          ChainReadFailureKind.unreachable,
        ),
      });
    });
    await tester.pumpAndSettle();
    expect(reads, 1);

    await tester.tap(find.text('Retry balance read'));
    await tester.pumpAndSettle();

    expect(reads, 2);
  });

  testWidgets('reads switched off explain themselves and offer no dead retry',
      (tester) async {
    await pumpSend(
      tester,
      (_) => BalanceReads(const {}, {
        chainId: const ChainReadFailure(ChainReadFailureKind.readsDisabled),
      }),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Live reads are off'), findsOneWidget);
    // Retrying cannot help while the preference is off, so it is not offered.
    expect(find.text('Retry balance read'), findsNothing);
    expect(maxAction(tester), isNull);
  });

  testWidgets('a zero under a denom the account does not use is explained',
      (tester) async {
    await pumpSend(
      tester,
      (_) => BalanceReads(
        {
          chainId: balanceOf('0', otherDenoms: const ['uosmo', 'ibc/ABC']),
        },
        const {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No TEST in this account'), findsOneWidget);
    expect(find.textContaining('2 other denominations'), findsOneWidget);
    expect(find.textContaining('utest'), findsOneWidget);
  });
}
