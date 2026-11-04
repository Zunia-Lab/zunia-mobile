// Footage for the Connect and Browse films, not a behaviour test. It drives
// the real app on a simulator while `xcrun simctl io recordVideo` records the
// screen, and prints `FILM_MARK <name> <epoch ms> [x y]` (logical px) so the
// edit can line the phone up with the web page and draw the taps.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/film_test.dart -d <sim> --dart-define=FILM=connect
//
// FILM=connect waits for the site's pairing link (written to PAIR_FILE by the
// orchestrator; the simulator has no camera) and hands it to the scanner's own
// routing, then approves the connection and the page's signature request.
// FILM=browse opens sites in the in-app browser and approves what they ask.
//
// The wallet is the public test phrase around the store demo portfolio
// (support/store_demo.dart): balances exist only inside this process.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/main.dart' as app;
import 'package:zunia_mobile/screens/dapp_browser_screen.dart';
import 'package:zunia_mobile/screens/native_request_sheets.dart';
import 'package:zunia_mobile/screens/tabs/home_tab.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

import 'support/store_demo.dart';

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon about';
const _film = String.fromEnvironment('FILM', defaultValue: 'connect');
/// Host file the orchestrator writes the site's pairing link into (FILM=connect).
const _pairFile = String.fromEnvironment('PAIR_FILE');

void mark(String name, [Offset? at]) {
  final xy = at == null ? '' : ' ${at.dx.toStringAsFixed(1)} ${at.dy.toStringAsFixed(1)}';
  // ignore: avoid_print
  print('FILM_MARK $name ${DateTime.now().millisecondsSinceEpoch}$xy');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Every frame the app schedules is drawn, so the recording is smooth.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  Future<void> wait(WidgetTester tester, [int ms = 1500]) async {
    for (var t = 0; t < ms; t += 50) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<bool> waitFor(WidgetTester tester, Finder finder, {int seconds = 180}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(end)) {
      if (finder.evaluate().isNotEmpty) return true;
      await tester.pump(const Duration(milliseconds: 50));
    }
    return false;
  }

  Future<bool> tapIf(WidgetTester tester, Finder finder, [int ms = 1500]) async {
    if (finder.evaluate().isEmpty) return false;
    try {
      await tester.ensureVisible(finder.first);
      await tester.pump();
      if (finder.evaluate().isEmpty) return false;
      await tester.tap(finder.first, warnIfMissed: false);
    } on StateError {
      return false;
    }
    await wait(tester, ms);
    return true;
  }

  Future<void> tapText(WidgetTester tester, String text, [int ms = 1500]) async {
    if (!await tapIf(tester, find.text(text), ms)) {
      throw TestFailure('No "$text" on screen');
    }
  }

  /// A tap the film shows: marked with its position first.
  Future<void> filmTap(WidgetTester tester, String name, Finder finder, [int ms = 1500]) async {
    final at = tester.getCenter(finder);
    mark(name, at);
    await tester.tap(finder, warnIfMissed: false);
    await wait(tester, ms);
  }

  ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));

  Future<void> onboard(WidgetTester tester) async {
    await wait(tester, 6000);
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
    await tester.enterText(fields.at(1), 'film-password-1');
    await tester.enterText(fields.at(2), 'film-password-1');
    await wait(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await wait(tester, 1500);
    await tapIf(tester, find.text('Continue'));
    await wait(tester, 4000);
    await tester.tap(find.textContaining('Continue ·').first);
    await wait(tester, 2000);
    await tapIf(tester, find.text('Skip for now'));
    await tapIf(tester, find.text('Not now'));
    await wait(tester, 4000);
    await tapIf(tester, find.text('Not now'));
    final c = container(tester);
    final account = c.read(walletProvider).active!;
    await c.read(walletProvider.notifier).setBackupVerified(account.phraseId, true);
    await wait(tester, 12000);
    await tapIf(tester, find.text('Not now'));
    await wait(tester, 2000);
  }

  /// Runs `script` in the in-app browser's page and returns its result.
  Future<Object?> js(String script) async {
    final view = DappBrowserScreen.debugWebView.value;
    if (view == null) return null;
    return view.evaluateJavascript(source: script);
  }

  testWidgets('film footage', (tester) async {
    final catalog = await ChainCatalog.load();
    final hub = catalog.find('cosmoshub-4')!;
    final me = WalletKernel.instance.deriveAddress(phrase: _phrase, chain: hub).address;
    StoreDemo(me).install();

    app.main();
    await onboard(tester);
    mark('READY');

    if (_film == 'connect') {
      // What the camera would read from the site's QR code.
      final file = File(_pairFile);
      final end = DateTime.now().add(const Duration(minutes: 5));
      while (!file.existsSync() && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final link = file.readAsStringSync().trim();
      mark('SCANNED');
      final home = tester.element(find.byType(HomeTab));
      unawaited(handleScannedCode(home, home as WidgetRef, link));
      if (!await waitFor(tester, find.text('CONNECTION REQUEST'))) {
        throw TestFailure('No connection request');
      }
      mark('CONNECT_SHEET');
      await wait(tester, 4500);
      await filmTap(tester, 'CONNECT_TAP', find.text('Connect').last, 300);
      await waitFor(tester, find.textContaining('Connected to'), seconds: 20);
      mark('CONNECTED');
      if (!await waitFor(tester, find.text('SIGNATURE REQUEST'))) {
        throw TestFailure('No signature request');
      }
      mark('SIGN_SHEET');
      await wait(tester, 5000);
      await filmTap(tester, 'SIGN_TAP', find.text('Sign').last, 300);
      mark('SIGNED');
      await wait(tester, 5000);
      mark('DONE');
      return;
    }

    // Browse: the Browser tab, the dashboard (built with Zunia), then a page
    // written only for Keplr (KEPLR_URL, served from the Mac).
    final semantics = tester.ensureSemantics();
    final webView = find.byType(InAppWebView);
    // Centre of a page element in screen points, or null.
    Future<Offset?> rectOf(String findJs) async {
      final r = await js('''(() => { const e = ($findJs); if (!e) return null;
        const b = e.getBoundingClientRect(); return [b.left + b.width / 2, b.top + b.height / 2]; })()''');
      if (r is! List || webView.evaluate().isEmpty) return null;
      final origin = tester.getTopLeft(webView.first);
      return origin + Offset((r[0] as num).toDouble(), (r[1] as num).toDouble());
    }
    Future<bool> pageTap(String name, String findJs) async {
      final at = await rectOf(findJs);
      if (at == null) return false;
      mark(name, at);
      await js('''(() => { const e = ($findJs); e && e.click(); })()''');
      return true;
    }
    Future<void> approveAll(String name) async {
      for (var i = 0; i < 5; i++) {
        final next = find.text('Connect').evaluate().isNotEmpty
            ? 'Connect'
            : find.text('Add network').evaluate().isNotEmpty
                ? 'Add network'
                : null;
        if (next == null) return;
        await filmTap(tester, '$name${i == 0 ? '' : '_$i'}', find.text(next).last, 2200);
      }
    }

    await wait(tester, 2500);
    await filmTap(tester, 'TAB_BROWSER', find.text('Browser').last, 3500);

    // 1. The featured app: Safrochain Hub, written for Keplr.
    await filmTap(tester, 'HUB_OPEN', find.text('Safrochain Hub').first, 9000);
    mark('HUB_LOADED');
    await pageTap('HUB_CONNECT', '''[...document.querySelectorAll('button, a')].find((e) => /Connect wallet/i.test(e.innerText) && e.offsetParent !== null)''');
    await wait(tester, 3200);
    mark('HUB_OPTIONS');
    await pageTap('HUB_KEPLR', '''(() => { const all = [...document.querySelectorAll('button, a, [role=button], li, div')].filter((e) => /^\\s*Keplr/.test(e.innerText || '') && e.offsetParent !== null); all.sort((a, b) => a.innerText.length - b.innerText.length); return all.find((e) => e.matches('button, a, [role=button]')) || all[0]; })()''');
    if (await waitFor(tester, find.byWidgetPredicate((w) => w is Text && (w.data == 'CONNECTION REQUEST' || w.data == 'ADD NETWORK REQUEST')), seconds: 30)) {
      mark('HUB_SHEET');
      await wait(tester, 4000);
      await approveAll('HUB_APPROVE');
    }
    await wait(tester, 7000);
    mark('HUB_CONNECTED');
    await wait(tester, 2500);

    // 2. A site built with Zunia, typed in the Browser tab.
    await filmTap(tester, 'DONE_HUB', find.text('Done').first, 2500);
    final field = find.byWidgetPredicate(
      (w) => w is TextField && (w.decoration?.hintText ?? '').contains('Search dApps'),
    );
    await filmTap(tester, 'FIELD', field.first, 700);
    mark('TYPE');
    const typed = 'app.zunialab.com';
    for (var i = 1; i <= typed.length; i++) {
      await tester.enterText(field.first, typed.substring(0, i));
      await tester.pump(const Duration(milliseconds: 75));
    }
    await wait(tester, 700);
    mark('GO');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await wait(tester, 10000);
    mark('DASH_LOADED');
    await pageTap('DASH_CONNECT', '''[...document.querySelectorAll('button, a')].find((e) => /^Connect( wallet)?\$/.test(e.innerText.trim()) && e.offsetParent !== null)''');
    await wait(tester, 3200);
    mark('DASH_OPTIONS');
    await pageTap('DASH_ZUNIA', '''(() => { const d = document.querySelector('[role=dialog]'); return d && [...d.querySelectorAll('button, a')].find((e) => /Zunia/.test(e.innerText) && !/Mobile/.test(e.innerText) && e.offsetParent !== null); })()''');
    if (await waitFor(tester, find.text('CONNECTION REQUEST'), seconds: 30)) {
      mark('DASH_SHEET');
      await wait(tester, 4000);
      await approveAll('DASH_APPROVE');
    }
    await wait(tester, 7000);
    mark('DASH_CONNECTED');
    await wait(tester, 2500);

    final chip = find.bySemanticsLabel(RegExp(r'^Connected on \d+ network'));
    if (chip.evaluate().isNotEmpty) {
      await filmTap(tester, 'CHIP', chip.first, 4000);
    }
    semantics.dispose();
    mark('DONE');
    await wait(tester, 2000);
  });
}
