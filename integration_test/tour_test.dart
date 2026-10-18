// A walk through the app on a simulator or device, for screenshots and a
// smoke test of the real build: restore the public test phrase, open every
// tab and the main screens. It never signs or broadcasts anything.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/tour_test.dart -d <device>
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zunia_mobile/main.dart' as app;

const _phrase = 'abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon about';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wait(WidgetTester tester, [int ms = 1500]) async {
    // Some screens animate forever (the welcome scene), so no pumpAndSettle.
    for (var t = 0; t < ms; t += 100) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await wait(tester, 600);
    await binding.takeScreenshot(name);
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    final finder = find.text(text);
    await tester.ensureVisible(finder.first);
    await tester.tap(finder.first);
    await wait(tester);
  }

  testWidgets('tour', (tester) async {
    app.main();
    // Android renders to a texture the screenshot call cannot read until it
    // is switched to an image surface.
    if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
    await wait(tester, 6000);
    await shot(tester, '01-welcome');

    await tapText(tester, 'I already have a wallet');
    await shot(tester, '02-restore');
    await tester.enterText(find.byType(TextField).first, _phrase);
    await wait(tester);
    await tapText(tester, 'I will never share my recovery phrase with anyone.');
    await tapText(
      tester,
      'I accept that Zunia cannot recover a lost phrase, and I will keep an offline backup.',
    );
    await shot(tester, '03-restore-filled');
    await tapText(tester, 'Continue');

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), 'tour-password-1');
    await tester.enterText(fields.at(2), 'tour-password-1');
    await wait(tester);
    await shot(tester, '04-password');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tapText(tester, 'Continue');
    await wait(tester, 4000);
    await shot(tester, '05-networks');
    await tester.tap(find.textContaining('Continue ·').first);
    await wait(tester, 2000);
    if (find.text('Skip for now').evaluate().isNotEmpty) {
      await tapText(tester, 'Skip for now');
    }
    if (find.text('Not now').evaluate().isNotEmpty) {
      await tapText(tester, 'Not now');
    }
    await wait(tester, 12000);
    await shot(tester, '06-home');

    for (final (tab, name) in [
      ('Swap', '07-swap'),
      ('Earn', '08-earn'),
      ('Discover', '09-discover'),
      ('Activity', '10-activity'),
    ]) {
      await tester.tap(find.text(tab).last);
      await wait(tester, 6000);
      await shot(tester, name);
    }

    await tester.tap(find.text('Wallet').last);
    await wait(tester, 2000);
    await tester.tap(find.byTooltip('Menu').first);
    await wait(tester, 1500);
    await shot(tester, '11-drawer');
    await tapText(tester, 'Settings & security');
    await wait(tester, 2000);
    await shot(tester, '12-settings');
  });
}
