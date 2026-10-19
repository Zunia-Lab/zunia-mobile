// App Store and Google Play screenshots of the real build, around a demo
// portfolio (see support/store_demo.dart). Run it on a simulator:
//
//   ZUNIA_SHOTS=build/store/ios flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/store_shots_test.dart -d <device>
//
// Add --dart-define=STORE_PLATFORM=android for the Material version of every
// screen (the same Flutter widgets an Android phone draws).
//
// It never signs or broadcasts: the phrase is the public test phrase and the
// balances exist only inside this process.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/main.dart' as app;
import 'package:zunia_mobile/state/wallet_state.dart';

import 'support/store_demo.dart';

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon about';
const _platform = String.fromEnvironment('STORE_PLATFORM', defaultValue: 'ios');
const _only = String.fromEnvironment('STORE_ONLY');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wait(WidgetTester tester, [int ms = 1500]) async {
    for (var t = 0; t < ms; t += 100) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (_only.isNotEmpty && !_only.split(',').contains(name)) return;
    await wait(tester, 800);
    await binding.takeScreenshot('$_platform-$name');
  }

  Future<bool> tapIf(
    WidgetTester tester,
    Finder finder, [
    int ms = 1500,
  ]) async {
    if (finder.evaluate().isEmpty) return false;
    try {
      await tester.ensureVisible(finder.first);
      await tester.pump();
      if (finder.evaluate().isEmpty) return false;
      await tester.tap(finder.first, warnIfMissed: false);
    } on StateError {
      // It went away while scrolling into view (a form submitted on Done).
      return false;
    }
    await wait(tester, ms);
    return true;
  }

  Future<void> tapText(
    WidgetTester tester,
    String text, [
    int ms = 1500,
  ]) async {
    if (!await tapIf(tester, find.text(text), ms)) {
      throw TestFailure('No "$text" on screen');
    }
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await wait(tester, 1500);
  }

  ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));

  testWidgets('store screenshots', (tester) async {
    if (_platform == 'android') {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    }
    final catalog = await ChainCatalog.load();
    final hub = catalog.find('cosmoshub-4')!;
    final me = WalletKernel.instance
        .deriveAddress(phrase: _phrase, chain: hub)
        .address;
    StoreDemo(me).install();

    app.main();
    if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
    await wait(tester, 6000);
    await shot(tester, '00-welcome');

    // Restore the demo phrase.
    await tapText(tester, 'I already have a wallet');
    await tapText(tester, 'I will never share my recovery phrase with anyone.');
    await tapText(
      tester,
      'I accept that Zunia cannot recover a lost phrase, and I will keep an offline backup.',
    );
    await tapText(tester, 'Continue');
    await tester.enterText(find.byType(TextField).first, _phrase);
    await wait(tester);
    await tapText(tester, 'Continue');
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), 'store-password-1');
    await tester.enterText(fields.at(2), 'store-password-1');
    await wait(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await wait(tester, 1500);
    await tapIf(tester, find.text('Continue'));
    await wait(tester, 4000);

    // Networks: the three defaults (Safrochain, Cosmos Hub, Osmosis).
    await tester.tap(find.textContaining('Continue ·').first);
    await wait(tester, 2000);
    await tapIf(tester, find.text('Skip for now'));
    await tapIf(tester, find.text('Not now'));
    await wait(tester, 4000);
    await tapIf(tester, find.text('Not now'));

    // The phrase was restored, so the app asks to verify the backup; the
    // demo is not a wallet anyone funds.
    final c = container(tester);
    final wallet = c.read(walletProvider);
    final account = wallet.active!;
    await c
        .read(walletProvider.notifier)
        .setBackupVerified(account.phraseId, true);
    await wait(tester, 12000);
    await tapIf(tester, find.text('Not now'));

    await shot(tester, '01-home');

    // An asset: ATOM with its staked and claimable parts.
    if (await tapIf(tester, find.text('ATOM'), 4000)) {
      await shot(tester, '02-asset');
      await back(tester);
    }

    // Swap OSMO for ATOM on Osmosis.
    await tester.tap(find.text('Swap').last);
    await wait(tester, 5000);
    if (await tapIf(
      tester,
      find.bySemanticsLabel(RegExp('^Token to pay with')),
      2500,
    )) {
      await tapIf(
        tester,
        find.bySemanticsLabel(RegExp(r'^OSMO on Osmosis')),
        2500,
      );
    }
    if (await tapIf(
      tester,
      find.bySemanticsLabel(RegExp('^Token to receive')),
      2500,
    )) {
      await tapIf(
        tester,
        find.bySemanticsLabel(RegExp(r'^ATOM on Osmosis')),
        2500,
      );
    }
    final amount = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == '0' &&
          (w.enabled ?? true),
    );
    if (amount.evaluate().isNotEmpty) {
      await tester.enterText(amount.first, '250');
      await wait(tester, 7000);
      FocusManager.instance.primaryFocus?.unfocus();
      await wait(tester, 1500);
    }
    await shot(tester, '03-swap');

    // Earn on Cosmos Hub.
    await tester.tap(find.text('Earn').last);
    await wait(tester, 4000);
    if (await tapIf(tester, find.text('Safrochain'), 2000)) {
      await tapIf(tester, find.text('Cosmos Hub').last, 5000);
    }
    await wait(tester, 4000);
    await shot(tester, '04-earn');

    // Governance, filtered to Osmosis.
    await tester.tap(find.text('Gov').last);
    await wait(tester, 6000);
    if (await tapIf(tester, find.text('All networks'), 2000)) {
      await tapIf(tester, find.text('Osmosis').last, 7000);
    }
    await shot(tester, '05-gov');

    // The in-app browser on the Zunia dashboard.
    await tester.tap(find.text('Browser').last);
    await wait(tester, 4000);
    final address = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          (w.decoration?.hintText ?? '').contains('Search dApps'),
    );
    if (address.evaluate().isNotEmpty) {
      await tester.enterText(address.first, 'app.zunialab.com');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await wait(tester, 14000);
      await shot(tester, '06-browser');
      await back(tester);
      await wait(tester, 2000);
    }

    await tester.tap(find.text('Wallet').last);
    await wait(tester, 2000);
    await tester.tap(find.byTooltip('Activity').first);
    await wait(tester, 7000);
    await shot(tester, '07-activity');
    if (await tapIf(tester, find.textContaining('Swap').first, 5000)) {
      await shot(tester, '08-tx-detail');
      await back(tester);
    }
    await back(tester);

    await tapIf(tester, find.text('Receive'), 3000);
    await tapIf(tester, find.text('Cosmos Hub').last, 3000);
    await shot(tester, '09-receive');
    await back(tester);
    await back(tester);

    await tester.tap(find.byTooltip('Menu').first);
    await wait(tester, 1500);
    await tapText(tester, 'Settings & security');
    await wait(tester, 2000);
    await tapIf(tester, find.text('Security').last, 3000);
    await shot(tester, '10-security');
  });
}
