// The in-app browser as a web dApp sees it, on a simulator or device:
//
// 1. A page served by this test checks what Zunia puts in it before any of
//    its own scripts run (`window.zunia`, the `window.keplr` alias, the
//    `getOfflineSigner` globals) and connects the way a Keplr dApp does.
// 2. The live dashboard (app.zunialab.com) is opened in the same browser and
//    connected through its Zunia wallet option, as on a desktop with the
//    extension.
//
// Nothing is signed or broadcast.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/browser_check_test.dart -d <device>
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zunia_mobile/main.dart' as app;
import 'package:zunia_mobile/screens/dapp_browser_screen.dart';

const _phrase = 'abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon about';
const _hubAddress = 'cosmos19rl4cm2hmr8afy4kldpxz3fka4jguq0auqdal4';

/// What a dApp looks for before it offers "Connect", then Keplr's connect
/// calls. The result goes in the title, which the browser's top bar shows.
const _detectPage = r'''<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ZD:loading</title></head>
<body style="font:15px -apple-system,sans-serif;padding:20px;background:#15110f;color:#eee">
<h2>Zunia detection check</h2><pre id="out" style="white-space:pre-wrap"></pre>
<script>
var r = { atStart: { zunia: typeof window.zunia, keplr: typeof window.keplr } };
function show(prefix) {
  document.title = prefix + ' ' + JSON.stringify(r);
  document.getElementById('out').textContent = JSON.stringify(r, null, 2);
}
async function run() {
  if (document.readyState !== 'complete') await new Promise(function (ok) { window.addEventListener('load', ok); });
  var z = window.zunia, k = window.keplr;
  r.isZunia = !!(z && z.isZunia);
  r.mode = z && z.mode;
  r.version = z && z.version;
  r.appVersion = z && z.appVersion;
  r.features = z && z.features ? z.features.length : 0;
  r.keplrIsZunia = !!(k && k.isZunia);
  r.globals = [typeof window.getOfflineSigner, typeof window.getOfflineSignerOnlyAmino, typeof window.getOfflineSignerAuto];
  show('ZD:detected');
  try {
    await k.enable('cosmoshub-4');
    var key = await k.getKey('cosmoshub-4');
    r.address = key.bech32Address;
    var accounts = await window.getOfflineSigner('cosmoshub-4').getAccounts();
    r.signerAddress = accounts[0] && accounts[0].address;
    r.connected = await z.getConnectedChains();
  } catch (e) {
    r.error = String((e && e.message) || e);
  }
  show('ZD:done');
}
run();
</script></body></html>''';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wait(WidgetTester tester, [int ms = 1500]) async {
    for (var t = 0; t < ms; t += 100) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> waitFor(WidgetTester tester, Finder finder, {int seconds = 30}) async {
    for (var t = 0; t < seconds * 10; t++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    fail('Nothing matched $finder after $seconds s');
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    final finder = find.text(text);
    await tester.ensureVisible(finder.first);
    await tester.tap(finder.first);
    await wait(tester);
  }

  /// Runs [script] in the open page and returns what it evaluates to.
  Future<String> page(String script) async {
    final web = DappBrowserScreen.debugWebView.value;
    if (web == null) fail('No page is open');
    return '${await web.evaluateJavascript(source: script)}';
  }

  testWidgets('web dApps find Zunia in the in-app browser', (tester) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.html
        ..write(_detectPage)
        ..close();
    });

    app.main();
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
    await tester.enterText(fields.at(1), 'browser-check-1');
    await tester.enterText(fields.at(2), 'browser-check-1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tapText(tester, 'Continue');
    await wait(tester, 4000);
    await tester.tap(find.textContaining('Continue ·').first);
    await wait(tester, 2000);
    if (find.text('Skip for now').evaluate().isNotEmpty) await tapText(tester, 'Skip for now');
    if (find.text('Not now').evaluate().isNotEmpty) await tapText(tester, 'Not now');
    await wait(tester, 8000);
    if (find.text('Turn on').evaluate().isNotEmpty) await tapText(tester, 'Not now');

    // 1. Typed in the Browser tab's address field, as a person would.
    await tester.tap(find.text('Browser').last);
    await wait(tester, 2000);
    await tester.enterText(find.byType(TextField).first, 'http://localhost:${server.port}/detect');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await waitFor(tester, find.text('Connect'));
    await wait(tester, 800);
    await binding.takeScreenshot('b1-local-connect-sheet');
    await tester.tap(find.text('Connect').last);
    await waitFor(tester, find.textContaining('ZD:done'));
    await wait(tester, 800);
    await binding.takeScreenshot('b2-local-detected');

    final title = tester.widget<Text>(find.textContaining('ZD:done').first).data!;
    final r = jsonDecode(title.substring('ZD:done '.length)) as Map<String, dynamic>;
    // ignore: avoid_print
    print('BROWSER_DETECT $r');
    expect(r['error'], isNull);
    expect(r['atStart'], {'zunia': 'object', 'keplr': 'object'});
    expect(r['isZunia'], isTrue);
    expect(r['keplrIsZunia'], isTrue);
    expect(r['mode'], 'mobile');
    expect(r['features'], 6);
    expect(r['globals'], ['function', 'function', 'function']);
    expect(r['address'], _hubAddress);
    expect(r['signerAddress'], _hubAddress);
    expect(r['connected'], contains('cosmoshub-4'));

    // 2. The live dashboard, in the same browser.
    await DappBrowserScreen.debugWebView.value!
        .loadUrl(urlRequest: URLRequest(url: WebUri('https://app.zunialab.com')));
    await wait(tester, 12000);
    final opened = await page('''(() => {
      const b = [...document.querySelectorAll('button, a')].find((e) => /^Connect( wallet)?\$/.test(e.innerText.trim()) && e.offsetParent !== null);
      if (!b) return 'no connect button';
      b.click();
      return 'clicked ' + b.innerText.trim();
    })()''');
    await wait(tester, 2500);
    final options = await page("document.querySelector('[role=dialog]')?.innerText ?? 'no dialog'");
    // ignore: avoid_print
    print('DASHBOARD_OPEN $opened\nDASHBOARD_OPTIONS ${options.replaceAll('\n', ' | ')}');
    await binding.takeScreenshot('b3-dashboard-options');

    final chose = await page('''(() => {
      const d = document.querySelector('[role=dialog]');
      const b = d && [...d.querySelectorAll('button, a')].find((e) => /Zunia/.test(e.innerText) && !/Mobile/.test(e.innerText) && e.offsetParent !== null);
      if (!b) return 'no zunia option';
      b.click();
      return 'clicked ' + b.innerText.trim().replace(/\\s+/g, ' ');
    })()''');
    // ignore: avoid_print
    print('DASHBOARD_CHOSE $chose');
    await waitFor(tester, find.text('Connect'), seconds: 20);
    await wait(tester, 800);
    await binding.takeScreenshot('b4-dashboard-connect-sheet');
    await tester.tap(find.text('Connect').last);
    // Safrochain and the others may each ask once more (a network to add).
    for (var i = 0; i < 4; i++) {
      await wait(tester, 2500);
      final again = find.text('Connect').evaluate().isNotEmpty
          ? 'Connect'
          : find.text('Add network').evaluate().isNotEmpty
              ? 'Add network'
              : null;
      if (again == null) break;
      await tester.tap(find.text(again).last);
    }
    await wait(tester, 8000);
    final shown = await page('document.body.innerText');
    final connected = RegExp('dal4|v259|3mq6x0|5m7df8').hasMatch(shown);
    // ignore: avoid_print
    print('DASHBOARD_CONNECTED $connected');
    await binding.takeScreenshot('b5-dashboard-connected');
    expect(connected, isTrue, reason: 'the dashboard should show the wallet once connected');
  });
}
