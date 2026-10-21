import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/splash_screen.dart';
import 'package:zunia_mobile/ui/zunia_mark.dart';
import 'package:zunia_tokens/zunia_tokens.dart';

import 'support/brand_fonts.dart';

/// The splash takes over from the native launch screen, so its first frame
/// has to be that screen: same background for the system appearance, the
/// mark at 96 x 120 in the centre of the whole display.
void main() {
  setUpAll(loadBrandFonts);

  Widget host(Widget child, {Brightness platform = Brightness.dark, bool still = false}) {
    return MediaQuery(
      data: MediaQueryData(
        size: const Size(393, 852),
        padding: const EdgeInsets.only(top: 59, bottom: 34),
        platformBrightness: platform,
        disableAnimations: still,
      ),
      child: MaterialApp(
        // The app's own theme does not decide the splash colours.
        theme: ThemeData.dark(),
        home: child,
      ),
    );
  }

  Rect markRect(WidgetTester tester) => tester.getRect(find.byType(ZuniaMark));

  Color background(WidgetTester tester) => tester
      .widget<Material>(
        find.descendant(of: find.byType(SplashScreen), matching: find.byType(Material)).first,
      )
      .color!;

  Color hex(String rgb) => Color(int.parse('FF$rgb', radix: 16));

  test('native launch colours are the splash colours', () {
    final ios = jsonDecode(
      File('ios/Runner/Assets.xcassets/LaunchBackground.colorset/Contents.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    Color iosColor(bool dark) {
      final entry = (ios['colors'] as List).cast<Map<String, dynamic>>().firstWhere(
            (c) => (c['appearances'] != null) == dark,
          );
      final comps = (entry['color'] as Map)['components'] as Map;
      String byte(String k) => (comps[k] as String).substring(2);
      return hex('${byte('red')}${byte('green')}${byte('blue')}');
    }

    Color androidColor(String folder) {
      final xml = File('android/app/src/main/res/$folder/colors.xml').readAsStringSync();
      return hex(RegExp(r'name="zunia_splash_bg">#([0-9A-Fa-f]{6})<').firstMatch(xml)!.group(1)!);
    }

    expect(iosColor(false), ZuniaSemantic.light.bg);
    expect(iosColor(true), ZuniaSemantic.dark.bg);
    expect(androidColor('values'), ZuniaSemantic.light.bg);
    expect(androidColor('values-night'), ZuniaSemantic.dark.bg);
  });

  for (final platform in Brightness.values) {
    testWidgets('first frame matches the launch screen (${platform.name} appearance)', (tester) async {
      for (final size in const [Size(393, 852), Size(320, 568), Size(430, 932), Size(820, 1180)]) {
        tester.view.physicalSize = size * 3;
        tester.view.devicePixelRatio = 3;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(size: size, platformBrightness: platform),
            child: MaterialApp(
              theme: ThemeData.dark(),
              home: const SplashScreen(),
            ),
          ),
        );
        expect(markRect(tester), Rect.fromCenter(center: size.center(Offset.zero), width: 96, height: 120));
        expect(
          background(tester),
          platform == Brightness.dark ? ZuniaSemantic.dark.bg : ZuniaSemantic.light.bg,
        );
        expect(find.text('zunia'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
      tester.view.reset();
    });
  }

  testWidgets('the mark holds while iOS fades its launch view, then rises into the lockup', (tester) async {
    await tester.pumpWidget(host(const SplashScreen()));
    final start = markRect(tester);

    await tester.pump(SplashScreen.holdDuration - const Duration(milliseconds: 10));
    expect(markRect(tester), start);

    await tester.pump(SplashScreen.introDuration);
    expect(markRect(tester), start.shift(const Offset(0, -SplashScreen.rise)));
    expect(find.text('zunia'), findsOneWidget);
  });

  testWidgets('with reduced motion the mark never moves', (tester) async {
    await tester.pumpWidget(host(const SplashScreen(), still: true));
    final start = markRect(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(markRect(tester), start);
    expect(find.text('zunia'), findsNothing);
  });

  testWidgets('a startup error shows under the mark', (tester) async {
    await tester.pumpWidget(host(const SplashScreen(message: 'Startup error: boom')));
    await tester.pump(SplashScreen.introDuration);
    expect(find.text('Startup error: boom'), findsOneWidget);
  });

  group('SplashGate', () {
    Widget gated(Future<AppGate> Function() gate, {bool still = false}) => ProviderScope(
          overrides: [appGateProvider.overrideWith((ref) => gate())],
          child: host(const SplashGate(child: Text('first route')), still: still),
        );

    bool splashShown() => find.byType(SplashScreen).evaluate().isNotEmpty;

    /// Frames every 16 ms from the first one, as on a phone: an animation
    /// starts on the frame after it is asked to.
    Future<void> runFor(WidgetTester tester, Duration total) async {
      for (var t = 0; t < total.inMilliseconds; t += 16) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets('keeps a ready app for the intro and the dissolve only, under 900 ms', (tester) async {
      await tester.pumpWidget(gated(() async => AppGate.onboarding));
      expect(splashShown(), isTrue);

      await runFor(tester, SplashScreen.introDuration - const Duration(milliseconds: 40));
      expect(splashShown(), isTrue);

      await runFor(tester, const Duration(milliseconds: 900) - SplashScreen.introDuration + const Duration(milliseconds: 40));
      expect(splashShown(), isFalse);
      expect(find.text('first route'), findsOneWidget);
    });

    testWidgets('waits for a slow gate, then dissolves', (tester) async {
      final gate = Completer<AppGate>();
      await tester.pumpWidget(gated(() => gate.future));
      await tester.pump(const Duration(seconds: 3));
      expect(splashShown(), isTrue);

      gate.complete(AppGate.unlock);
      await runFor(tester, SplashScreen.exitDuration + const Duration(milliseconds: 40));
      expect(splashShown(), isFalse);
    });

    testWidgets('with reduced motion a ready app shows after the dissolve alone', (tester) async {
      await tester.pumpWidget(gated(() async => AppGate.onboarding, still: true));
      await runFor(tester, SplashScreen.exitDuration + const Duration(milliseconds: 40));
      expect(splashShown(), isFalse);
    });

    testWidgets('the route underneath cannot be tapped through the splash', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appGateProvider.overrideWith((ref) => Completer<AppGate>().future)],
          child: host(
            SplashGate(
              child: Center(
                child: TextButton(onPressed: () => taps++, child: const Text('under')),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('under'), warnIfMissed: false);
      expect(taps, 0);
    });
  });
}
