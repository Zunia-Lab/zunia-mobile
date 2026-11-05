/// What the page is given: the provider's identity and the script's guards.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/browser/provider_inject.dart';
import 'package:zunia_mobile/config/app_identity.dart';

void main() {
  test('identity matches the extension contract with mode mobile', () {
    expect(providerIdentity(), {
      'version': '0.1.0',
      'isZunia': true,
      'mode': 'mobile',
      'appVersion': '0.1.0',
      'features': providerFeatures,
    });
    expect(providerFeatures, contains('sign-amino:escaped'));
  });

  test('the script carries the token, the identity and the alias switch', () {
    final token = newProviderToken();
    expect(token, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(newProviderToken(), isNot(token));
    final off = buildProviderScript(token: token, exposeKeplrAlias: false);
    expect(off, contains(jsonEncode(token)));
    expect(off, contains('"mode":"mobile"'));
    expect(off, contains('applyKeplrAlias(false)'));
    expect(off, isNot(contains('__ZUNIA_')));
    expect(buildProviderScript(token: token, exposeKeplrAlias: true), contains('applyKeplrAlias(true)'));
  });

  test('the script installs in the top secure document only, once', () {
    final script = buildProviderScript(token: 't', exposeKeplrAlias: false);
    expect(script, contains('window.top !== window.self'));
    expect(script, contains("loc.protocol === 'https:'"));
    expect(script, contains('__zuniaProviderInstalled'));
    // Keplr's globals and initialization event exist only behind the alias
    // switch, and are never assigned unconditionally.
    expect(script, isNot(contains('window.getOfflineSigner =')));
    expect(script, contains('function applyKeplrAlias(enabled)'));
    expect(script, contains("'keplr#initialized'"));
    // Window events the extension dispatches.
    for (final name in ['zunia_locked', 'zunia_chainchanged', "'zunia_' + name", "'keplr_' + name"]) {
      expect(script, contains(name));
    }
  });

  test('native events and settings reach the page through one frozen hook', () {
    expect(
      providerEventScript('disconnect', {'chainIds': ['osmosis-1']}),
      'window.__zuniaNative && window.__zuniaNative.event("disconnect", {"chainIds":["osmosis-1"]});',
    );
    expect(
      providerSettingsScript(exposeKeplrAlias: true),
      'window.__zuniaNative && window.__zuniaNative.settings({"exposeKeplrAlias":true});',
    );
  });
}
