/// Swap balances stay current without a pull: read again when the tab is
/// shown, and followed after a swap until the money has moved.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/screens/tabs/swap_tab.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/swap_balances.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/tx/tx_inclusion.dart';
import 'package:zunia_ui/zunia_ui.dart';

import 'support/swap_fixtures.dart';
import 'support/swap_world.dart';

/// Bank balances that a test moves between reads, and every read counted.
class Bank {
  final Map<String, String> uatom = {'cosmoshub-4': '10000000'};
  final Map<String, String> uosmo = {'osmosis-1': '50000000'};
  final Map<String, int> reads = {};
  final Set<String> down = {};

  /// While set, every balance read waits for it.
  Completer<void>? gate;

  LcdClientFactory get factory =>
      (c) => ScriptedLcd(c.chainId, (path, q) async {
        if (path.startsWith('/cosmos/bank/v1beta1/balances/')) {
          reads[c.chainId] = (reads[c.chainId] ?? 0) + 1;
          await gate?.future;
          if (down.contains(c.chainId)) throw notFound(c.chainId, path);
          return {
            'balances': [
              if (uatom.containsKey(c.chainId))
                {'denom': 'uatom', 'amount': uatom[c.chainId]},
              if (uosmo.containsKey(c.chainId))
                {'denom': 'uosmo', 'amount': uosmo[c.chainId]},
            ],
          };
        }
        return chainAnswer(c.chainId, path, q);
      });
}

void main() {
  setUpAll(() async {
    await loadSwapWorld();
    SharedPreferences.setMockInitialValues({});
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(resetWorldClock);

  ProviderContainer make(
    Bank bank, {
    Duration pollEvery = const Duration(milliseconds: 20),
    Duration window = const Duration(seconds: 2),
    InclusionWaiter? waitForTx,
  }) {
    final c = ProviderContainer(
      overrides: [
        ...swapOverrides(),
        lcdFactoryProvider.overrideWithValue(bank.factory),
        swapBalancesProvider.overrideWith(
          (ref) => SwapBalanceController(
            ref,
            pollEvery: pollEvery,
            window: window,
            waitForTx: waitForTx ?? (_, _) async => const Included('1'),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('re-reading', () {
    test(
      'the fresh read replaces the cached one that MAX and the balance check use',
      () async {
        final bank = Bank();
        final c = make(bank);
        await settle(c);
        c.read(swapControllerProvider.notifier)
          ..pickFrom('cosmoshub-4:uatom')
          ..pickTo('osmosis-1:uosmo');
        expect(c.read(swapViewProvider).available, BigInt.from(10000000));

        // Funds arrive; nothing is pulled.
        bank.uatom['cosmoshub-4'] = '25000000';
        expect(
          await c.read(swapBalancesProvider.notifier).refresh(['cosmoshub-4']),
          isTrue,
        );

        final view = c.read(swapViewProvider);
        expect(view.available, BigInt.from(25000000));
        c.read(swapControllerProvider.notifier).applyMax(view);
        final max = c.read(swapViewProvider);
        expect(max.overBalance, isFalse);
        expect(max.amountUnits, isNotNull);
        expect(max.amountUnits! > BigInt.from(10000000), isTrue);
        // Only the chain asked for was read.
        expect(bank.reads['osmosis-1'], isNull);
      },
    );

    test('the cached numbers stay while a read is in flight', () async {
      final bank = Bank();
      final c = make(bank);
      await settle(c);
      bank.gate = Completer<void>();
      final reading = c.read(swapBalancesProvider.notifier).refresh([
        'cosmoshub-4',
      ]);
      // Mid-read: busy, and the base number is still the one shown.
      expect(c.read(swapBalancesProvider).busy, isTrue);
      expect(
        c.read(swapBalancesNowProvider)['cosmoshub-4']!.single.amount,
        '10000000',
      );
      bank.gate!.complete();
      await reading;
      expect(c.read(swapBalancesProvider).busy, isFalse);
      expect(
        c.read(swapBalancesNowProvider)['cosmoshub-4']!.single.amount,
        '10000000',
      );
    });

    test(
      'a chain that does not answer is reported, and the old number stays',
      () async {
        final bank = Bank();
        final c = make(bank);
        await settle(c);
        bank.down.add('cosmoshub-4');
        expect(
          await c.read(swapBalancesProvider.notifier).refresh(['cosmoshub-4']),
          isFalse,
        );
        expect(c.read(swapBalancesProvider).failed, {'cosmoshub-4'});
        expect(c.read(swapBalanceGapsProvider).map((e) => e.chainId), [
          'cosmoshub-4',
        ]);
        expect(
          c.read(swapBalancesNowProvider)['cosmoshub-4']!.single.amount,
          '10000000',
        );

        bank.down.clear();
        expect(
          await c.read(swapBalancesProvider.notifier).refresh(['cosmoshub-4']),
          isTrue,
        );
        expect(c.read(swapBalanceGapsProvider), isEmpty);
      },
    );

    test('chains read a moment ago are not read again', () async {
      final bank = Bank();
      final c = make(bank);
      await settle(c);
      final balances = c.read(swapBalancesProvider.notifier);
      await balances.refresh([
        'cosmoshub-4',
      ], minAge: const Duration(seconds: 5));
      await balances.refresh([
        'cosmoshub-4',
      ], minAge: const Duration(seconds: 5));
      expect(bank.reads['cosmoshub-4'], 1);
    });
  });

  group('after a swap', () {
    test(
      'the source is read once the tx is in a block; the destination until it changes',
      () async {
        final bank = Bank();
        final c = make(bank);
        await settle(c);
        var destReads = 0;
        c.listen(swapBalancesProvider, (_, next) {
          destReads = bank.reads['osmosis-1'] ?? 0;
          // The packet lands on the third look at Osmosis.
          if (destReads == 4) bank.uosmo['osmosis-1'] = '60000000';
        });
        c
            .read(swapBalancesProvider.notifier)
            .followSwap(
              source: chain('cosmoshub-4'),
              txHash: 'AAA',
              destinationChainId: 'osmosis-1',
            );
        await _until(
          () =>
              c.read(swapBalancesNowProvider)['osmosis-1']!.single.amount ==
              '60000000',
        );
        expect(bank.reads['cosmoshub-4'], greaterThanOrEqualTo(1));
        final settled = bank.reads['osmosis-1']!;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        // Stopped: only the closing read of both ends came after the change.
        expect(bank.reads['osmosis-1']! - settled, lessThanOrEqualTo(1));
      },
    );

    test(
      'the packet tracker finishing stops the polling and reads both ends again',
      () async {
        final bank = Bank();
        final c = make(bank, pollEvery: const Duration(seconds: 30));
        await settle(c);
        c
            .read(swapBalancesProvider.notifier)
            .followSwap(
              source: chain('cosmoshub-4'),
              txHash: 'BBB',
              destinationChainId: 'osmosis-1',
            );
        await _until(() => (bank.reads['cosmoshub-4'] ?? 0) >= 1);
        final before = bank.reads['cosmoshub-4']!;
        // A refund: the source gets its tokens back.
        bank.uatom['cosmoshub-4'] = '10500000';
        c.read(swapBalancesProvider.notifier).finishSwap('BBB');
        await _until(
          () =>
              c.read(swapBalancesNowProvider)['cosmoshub-4']!.single.amount ==
              '10500000',
        );
        expect(bank.reads['cosmoshub-4']! > before, isTrue);
      },
    );

    test(
      'a swap refused in its block refreshes the source and does not wait on the destination',
      () async {
        final bank = Bank();
        final c = make(
          bank,
          waitForTx: (_, _) async =>
              const FailedInBlock(5, 'insufficient funds'),
        );
        await settle(c);
        bank.uatom['cosmoshub-4'] = '9990000'; // the fee left
        c
            .read(swapBalancesProvider.notifier)
            .followSwap(
              source: chain('cosmoshub-4'),
              txHash: 'CCC',
              destinationChainId: 'osmosis-1',
            );
        await _until(
          () =>
              c.read(swapBalancesNowProvider)['cosmoshub-4']!.single.amount ==
              '9990000',
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        // The destination was read once, for the baseline, and never polled.
        expect(bank.reads['osmosis-1'], 1);
      },
    );

    test('with no change it gives up when the window is over', () async {
      final bank = Bank();
      final c = make(bank, window: const Duration(milliseconds: 120));
      await settle(c);
      c
          .read(swapBalancesProvider.notifier)
          .followSwap(
            source: chain('cosmoshub-4'),
            txHash: 'DDD',
            destinationChainId: 'osmosis-1',
          );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final after = bank.reads['osmosis-1']!;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(bank.reads['osmosis-1'], after);
      expect(after, greaterThan(2));
    });

    test(
      'a destination that did not answer before the swap takes its first answer as the baseline',
      () async {
        final bank = Bank();
        final c = make(bank);
        await settle(c);
        bank.down.add('osmosis-1');
        c
            .read(swapBalancesProvider.notifier)
            .followSwap(
              source: chain('cosmoshub-4'),
              txHash: 'EEE',
              destinationChainId: 'osmosis-1',
            );
        await _until(() => (bank.reads['osmosis-1'] ?? 0) >= 1);
        bank.down.clear();
        // The balance it then reads is unchanged: the watch keeps reading
        // instead of taking that first answer for the swap's arrival.
        await _until(() => (bank.reads['osmosis-1'] ?? 0) >= 4);
        final watching = bank.reads['osmosis-1']!;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(bank.reads['osmosis-1']!, greaterThan(watching));

        bank.uosmo['osmosis-1'] = '60000000';
        await _until(
          () =>
              c.read(swapBalancesNowProvider)['osmosis-1']!.single.amount ==
              '60000000',
        );
        final arrived = bank.reads['osmosis-1']!;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        // Stopped: at most the closing read of both ends came after it.
        expect(bank.reads['osmosis-1']! - arrived, lessThanOrEqualTo(1));
      },
    );
  });

  group('showing the tab', () {
    Future<(ProviderContainer, ValueNotifier<bool>)> pumpTab(
      WidgetTester tester,
      Bank bank, {
      required bool shown,
    }) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = make(bank);
      final visible = ValueNotifier(shown);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ZuniaTheme.dark(),
            home: ValueListenableBuilder<bool>(
              valueListenable: visible,
              // The shell keeps the tab built under the others; only its
              // tickers go quiet.
              builder: (_, on, _) => TickerMode(
                enabled: on,
                child: const Scaffold(body: SwapTab(showHeader: false)),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      return (container, visible);
    }

    testWidgets(
      'switching to it reads the balances again, and says so while it does',
      (tester) async {
        final bank = Bank();
        final (c, visible) = await pumpTab(tester, bank, shown: false);
        expect(bank.reads, isEmpty);

        bank.uatom['cosmoshub-4'] = '12345678';
        bank.gate = Completer<void>();
        visible.value = true;
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('Updating balances…'), findsOneWidget);
        // The old number is still what the form holds meanwhile.
        expect(
          c.read(swapBalancesNowProvider)['cosmoshub-4']!.single.amount,
          '10000000',
        );
        bank.gate!.complete();
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(find.text('Updating balances…'), findsNothing);
        expect(bank.reads['cosmoshub-4'], 1);
        expect(
          c.read(swapBalancesNowProvider)['cosmoshub-4']!.single.amount,
          '12345678',
        );

        // Away and straight back: not read again for nothing.
        visible.value = false;
        await tester.pump();
        visible.value = true;
        await tester.pump(const Duration(milliseconds: 50));
        expect(bank.reads['cosmoshub-4'], 1);
      },
    );

    testWidgets('returning to the app with the tab shown reads them again', (
      tester,
    ) async {
      final bank = Bank();
      final (c, _) = await pumpTab(tester, bank, shown: true);
      expect(bank.reads['cosmoshub-4'], isNull);

      bank.uatom['cosmoshub-4'] = '777';
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(
        c.read(swapBalancesNowProvider)['cosmoshub-4']!.single.amount,
        '777',
      );
    });

    testWidgets(
      'a chain that would not answer offers a retry that shows its work and its result',
      (tester) async {
        final bank = Bank()..down.add('cosmoshub-4');
        final (c, visible) = await pumpTab(tester, bank, shown: false);
        visible.value = true;
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.textContaining("Couldn't read your balance on"),
          findsOneWidget,
        );

        // Still down: the button works, says so, and the verdict stays up.
        bank.gate = Completer<void>();
        await tester.tap(find.text('Try again'));
        await tester.pump();
        expect(find.text('Checking…'), findsOneWidget);
        // Mid-check the button is gone: a second tap has nothing to land on.
        expect(find.text('Try again'), findsNothing);
        bank.gate!.complete();
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(
          find.textContaining('Still unavailable — checked just now'),
          findsOneWidget,
        );

        // Back up: the error clears.
        bank.down.clear();
        bank.gate = null;
        await tester.tap(find.text('Try again'));
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(
          find.textContaining("Couldn't read your balance on"),
          findsNothing,
        );
        expect(find.text('Try again'), findsNothing);
        expect(c.read(swapBalanceGapsProvider), isEmpty);
      },
    );
  });
}

Future<void> _until(bool Function() done) async {
  final stop = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(stop)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
