/// The Swap page's retry controls: they say they are working, cannot be
/// tapped twice, and say what came of it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/screens/swap/swap_retry.dart';
import 'package:zunia_mobile/screens/tabs/swap_tab.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/swap/one_signature.dart';
import 'package:zunia_mobile/swap/swap_path.dart';
import 'package:zunia_ui/zunia_ui.dart';

import 'support/swap_world.dart';

void main() {
  setUpAll(() async {
    await loadSwapWorld();
    SharedPreferences.setMockInitialValues({});
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(resetWorldClock);

  group('SwapRetry', () {
    Future<void> pump(
      WidgetTester tester, {
      required SwapRetryRun onRetry,
      bool active = true,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: ZuniaTheme.dark(),
        home: Scaffold(
          body: SwapRetry(active: active, onRetry: onRetry),
        ),
      ),
    );

    testWidgets(
      'a tap ticks the haptic, shows Checking… and ignores a second tap',
      (tester) async {
        final haptics = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              haptics.add('${call.arguments}');
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final gate = Completer<bool>();
        var runs = 0;
        await pump(
          tester,
          onRetry: () {
            runs += 1;
            return gate.future;
          },
        );
        await tester.tap(find.text('Try again'));
        await tester.pump();
        expect(find.text('Checking…'), findsOneWidget);
        expect(find.text('Try again'), findsNothing);
        expect(haptics, ['HapticFeedbackType.selectionClick']);

        // The only tappable thing left is disabled.
        await tester.tap(find.text('Checking…'), warnIfMissed: false);
        await tester.pump();
        expect(runs, 1);

        gate.complete(true);
        await tester.pump();
        expect(find.text('Checking…'), findsNothing);
        expect(find.textContaining('Still unavailable'), findsNothing);
      },
    );

    testWidgets('a check that fails again says so, and can be run once more', (
      tester,
    ) async {
      var result = false;
      await pump(tester, onRetry: () async => result);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Still unavailable — checked just now'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      result = true;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Still unavailable'), findsNothing);
    });

    testWidgets(
      'an error that went away takes the control and the old verdict with it',
      (tester) async {
        await pump(tester, onRetry: () async => false);
        await tester.tap(find.text('Try again'));
        await tester.pump();
        await tester.pump();
        expect(find.textContaining('Still unavailable'), findsOneWidget);

        await pump(tester, onRetry: () async => false, active: false);
        expect(find.text('Try again'), findsNothing);
        expect(find.textContaining('Still unavailable'), findsNothing);
      },
    );

    testWidgets(
      'a retry that throws counts as not cleared, and does not leave it stuck',
      (tester) async {
        await pump(tester, onRetry: () async => throw StateError('offline'));
        await tester.tap(find.text('Try again'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Checking…'), findsNothing);
        expect(find.textContaining('Still unavailable'), findsOneWidget);
      },
    );
  });

  group('on the Swap tab', () {
    Future<ProviderContainer> pumpSwap(
      WidgetTester tester, {
      List<Override> extra = const [],
      SwapVenueStatus? venue,
      EntryPointCheck entryPoint = const EntryPointCheck.ready(),
    }) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [
          ...swapOverrides(venue: venue, entryPoint: entryPoint),
          ...extra,
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ZuniaTheme.dark(),
            home: const Scaffold(body: SwapTab(showHeader: false)),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      return container;
    }

    Future<void> settleFrames(WidgetTester tester, [int n = 10]) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    testWidgets(
      'the route\'s Try again is ours: it shows the check, then the outcome',
      (tester) async {
        final flaky = _Flaky();
        final c = await pumpSwap(
          tester,
          extra: [
            swapControllerProvider.overrideWith(
              (ref) => flaky.controller = _FlakyController(ref, flaky),
            ),
          ],
        );
        await c
            .read(swapSettingsProvider.notifier)
            .update(c.read(swapSettingsProvider).copyWith(routeDetails: true));
        c.read(swapControllerProvider.notifier)
          ..pickFrom('osmosis-1:uosmo')
          ..pickTo('cosmoshub-4:uatom');
        await tester.pump();
        await tester.enterText(find.byType(TextField).first, '1');
        await settleFrames(tester);

        expect(c.read(swapViewProvider).path, SwapPath.contract);
        expect(find.text('Could not plan this route'), findsOneWidget);
        // The shared widget's own button is not drawn; ours is.
        expect(find.widgetWithText(TextButton, 'Try again'), findsOneWidget);

        flaky.gate = Completer<void>();
        await tester.tap(find.text('Try again'));
        await tester.pump();
        await settleFrames(tester);
        // Mid-check: disabled, working, no double tap.
        expect(find.text('Checking…'), findsOneWidget);
        expect(find.text('Try again'), findsNothing);

        flaky.gate!.complete();
        await settleFrames(tester);
        expect(
          find.text('Still unavailable — checked just now'),
          findsOneWidget,
        );
        expect(find.text('Could not plan this route'), findsOneWidget);
        expect(flaky.plans, 2);

        // The network is back: the error clears.
        flaky.broken = false;
        await tester.tap(find.text('Try again'));
        await tester.pump();
        await settleFrames(tester);
        expect(find.text('Could not plan this route'), findsNothing);
        expect(find.text('Try again'), findsNothing);
        expect(find.textContaining('Still unavailable'), findsNothing);
      },
    );

    testWidgets(
      'a swap contract that could not be confirmed can be checked again',
      (tester) async {
        var ready = false;
        final c = await pumpSwap(
          tester,
          extra: [
            swapVenueStatusProvider.overrideWith(
              (_) async => ready
                  ? SwapVenueStatus.ready(
                      chainId: 'osmosis-1',
                      contractAddress: xcs,
                      label: 'CrossChainSwaps v1.2',
                    )
                  : const SwapVenueStatus.unavailable(
                      'The contract did not answer.',
                    ),
            ),
          ],
        );
        c.read(swapControllerProvider.notifier)
          ..pickFrom('osmosis-1:uosmo')
          ..pickTo('cosmoshub-4:uatom');
        await settleFrames(tester);
        expect(find.text('Cross-chain swaps are off'), findsOneWidget);

        await tester.tap(find.text('Check again'));
        await tester.pump();
        await settleFrames(tester);
        expect(
          find.text('Still unavailable — checked just now'),
          findsOneWidget,
        );
        // The verdict stays on screen meanwhile; it is never swapped for a gap.
        expect(find.text('Cross-chain swaps are off'), findsOneWidget);

        ready = true;
        await tester.tap(find.text('Check again'));
        await tester.pump();
        await settleFrames(tester);
        expect(find.text('Cross-chain swaps are off'), findsNothing);
        expect(find.text('Check again'), findsNothing);
      },
    );
  });
}

/// What the flaky controller is told to do.
class _Flaky {
  bool broken = true;
  Completer<void>? gate;
  int plans = 0;
  late SwapController controller;
}

/// A controller whose plans fail, on demand, the way an unreachable network
/// makes them fail.
class _FlakyController extends SwapController {
  _FlakyController(super.ref, this.script) : super(restoreIntent: false);

  final _Flaky script;

  @override
  Future<void> plan(SwapView view) async {
    script.plans += 1;
    await script.gate?.future;
    if (!script.broken) return super.plan(view);
    state = state.copyWith(
      contract: ContractPlan(
        key: view.planKey,
        at: DateTime.now(),
        error: 'Could not reach the network: offline',
      ),
    );
  }
}
