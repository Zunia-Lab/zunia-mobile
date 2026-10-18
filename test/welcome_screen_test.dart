import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/onboarding_screen.dart';
import 'package:zunia_mobile/screens/welcome_screen.dart';
import 'package:zunia_mobile/security/seed_safety_copy.dart';
import 'package:zunia_ui/zunia_ui.dart';

import 'support/brand_fonts.dart';
import 'support/kernel.dart';

/// iOS and Android, each with its own idiom (TargetPlatformVariant sets
/// debugDefaultTargetPlatformOverride, which the theme and ZuniaPlatform read).
final _platforms = TargetPlatformVariant(const {TargetPlatform.iOS, TargetPlatform.android});

Widget _app({ThemeMode mode = ThemeMode.dark}) => ProviderScope(
      child: MaterialApp(
        theme: ZuniaTheme.light(),
        darkTheme: ZuniaTheme.dark(),
        themeMode: mode,
        home: const WelcomeScreen(),
      ),
    );

/// The welcome screen loops a slow ambient animation, so it never settles:
/// pump past a transition instead.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

Future<void> _acceptSafetyAcks(WidgetTester tester) async {
  expect(find.text(SeedSafetyCopy.title), findsOneWidget);
  await tester.tap(find.text(SeedSafetyCopy.ackUnderstand));
  await tester.pump();
  await tester.tap(find.text(SeedSafetyCopy.ackBackup));
  await tester.pump();
  await tester.tap(find.text('Continue'));
  await _settle(tester);
}

void main() {
  setUpAll(loadBrandFonts);

  testWidgets(
    'every page and the safety sheet fit a 320dp phone at 1.3x text',
    (tester) async {
      tester.view.physicalSize = const Size(640, 1136);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        await tester.pumpWidget(_app(mode: mode));
        await _settle(tester);
        expect(tester.takeException(), isNull);

        for (var page = 0; page < 3; page++) {
          expect(find.bySemanticsLabel('Page ${page + 1} of 3'), findsOneWidget);
          expect(tester.takeException(), isNull, reason: 'page $page, $mode');
          if (page < 2) {
            await tester.drag(find.byType(PageView), const Offset(-280, 0));
            await _settle(tester);
          }
        }

        expect(find.text('Create a new wallet'), findsOneWidget);
        expect(find.text('I already have a wallet'), findsOneWidget);

        await tester.tap(find.text('I already have a wallet'));
        await _settle(tester);
        expect(find.text(SeedSafetyCopy.ackBackup), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'safety sheet, $mode');

        // Unmount between themes so each run starts on page one.
        await tester.pumpWidget(const SizedBox());
      }
    },
    variant: _platforms,
  );

  testWidgets('changing page plays a selection haptic', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(_app());
    await _settle(tester);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await _settle(tester);

    expect(find.bySemanticsLabel('Page 2 of 3'), findsOneWidget);
    expect(
      calls.where(
        (c) => c.method == 'HapticFeedback.vibrate' && c.arguments == 'HapticFeedbackType.selectionClick',
      ),
      hasLength(1),
    );
  }, variant: _platforms);

  testWidgets(
    'create asks the safety acknowledgements once, then opens onboarding in create mode',
    (tester) async {
      await tester.pumpWidget(_app());
      await _settle(tester);

      await tester.tap(find.text('Create a new wallet'));
      await _settle(tester);
      // Continue stays off until both are ticked.
      await tester.tap(find.text('Continue'));
      await _settle(tester);
      expect(find.byType(OnboardingScreen), findsNothing);

      await _acceptSafetyAcks(tester);
      final onboarding = tester.widget<OnboardingScreen>(find.byType(OnboardingScreen));
      expect(onboarding.initialMode, OnboardingMode.create);
      // Straight into the flow: its own welcome step, and the acknowledgements
      // just given, are not shown again.
      expect(find.text(SeedSafetyCopy.ackUnderstand), findsNothing);
      expect(find.text('Create a new wallet'), findsNothing);

      // Back from the first step returns to the welcome screen...
      await tester.tap(find.text('Back'));
      await _settle(tester);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(WelcomeScreen), findsOneWidget);

      // ...which remembers the acknowledgements.
      await tester.tap(find.text('I already have a wallet'));
      await _settle(tester);
      expect(find.text(SeedSafetyCopy.title), findsNothing);
      expect(
        tester.widget<OnboardingScreen>(find.byType(OnboardingScreen)).initialMode,
        OnboardingMode.import,
      );
    },
    variant: _platforms,
    skip: kernelSkip != false,
  );

  testWidgets(
    'restore opens onboarding in import mode',
    (tester) async {
      await tester.pumpWidget(_app(mode: ThemeMode.light));
      await _settle(tester);
      await tester.tap(find.text('I already have a wallet'));
      await _settle(tester);
      await _acceptSafetyAcks(tester);

      expect(
        tester.widget<OnboardingScreen>(find.byType(OnboardingScreen)).initialMode,
        OnboardingMode.import,
      );
      expect(find.text('Restore wallet'), findsWidgets);
    },
    variant: _platforms,
    skip: kernelSkip != false,
  );

  testWidgets(
    'a session opened from onboarding takes its route away',
    (tester) async {
      await tester.pumpWidget(_app());
      await _settle(tester);
      await tester.tap(find.text('Create a new wallet'));
      await _settle(tester);
      await _acceptSafetyAcks(tester);
      expect(find.byType(OnboardingScreen), findsOneWidget);

      // What OnboardingScreen does once the vault is sealed; the app gate then
      // swaps the welcome screen for the wallet underneath.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WelcomeScreen, skipOffstage: false)),
      );
      container.read(sessionProvider.notifier).state =
          UnlockedVault(envelopeJson: '{}', sessionToken: 'test');
      await _settle(tester);

      expect(find.byType(OnboardingScreen), findsNothing);
    },
    skip: kernelSkip != false,
  );
}
