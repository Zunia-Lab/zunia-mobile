/// Which `ret` targets a pairing link may name. The JS SDK validates with
/// the same table (zunia-sdk), so a dApp learns before it ships that a
/// target would be ignored.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/connect/app_return.dart';
import 'package:zunia_mobile/connect/pairing_uri.dart';

void main() {
  group('accepted', () {
    const table = <String, String>{
      'https://app.example.com': 'app.example.com',
      'https://app.example.com/back?session=1#done': 'app.example.com',
      'https://APP.Example.com/x': 'app.example.com',
      'https://app.example.com:8443/cb': 'app.example.com',
      'https://user@app.example.com/cb': 'app.example.com',
      'myapp://callback': 'myapp',
      'myapp://': 'myapp',
      'MyApp://Callback?x=%20y': 'myapp',
      'com.example.game:/oauth': 'com.example.game',
      'my-app+v2.beta://done': 'my-app+v2.beta',
      'tg://resolve?domain=zunia': 'tg',
    };
    for (final MapEntry(key: url, value: label) in table.entries) {
      test(url, () {
        final target = ReturnTarget.parse(url);
        expect(target, isNotNull);
        expect(target!.url, url);
        expect(target.label, label);
        expect(target.prompt, 'Return to $label');
      });
    }

    test('exactly 512 characters', () {
      final url =
          'https://a.example/${'p' * (512 - 'https://a.example/'.length)}';
      expect(url.length, 512);
      expect(ReturnTarget.parse(url), isNotNull);
    });
  });

  group('refused', () {
    const table = <String, String>{
      '': 'empty',
      'http://app.example.com': 'not https',
      'HTTP://app.example.com': 'not https, any case',
      'https:///nohost': 'https without a host',
      'https:nohost': 'https without a host',
      'zunia://connect?v=2': 'Zunia itself',
      'ZUNIA://connect': 'Zunia itself, any case',
      'zuniamobile://wc': 'Zunia itself',
      'wc:abc@2?relay-protocol=irn': 'WalletConnect',
      'javascript:alert(1)': 'script',
      'JavaScript://%0aalert(1)': 'script, any case',
      'data:text/html,<b>x</b>': 'data',
      'file:///etc/passwd': 'local file',
      'blob:https://app.example.com/1': 'blob',
      'about:blank': 'about',
      'content://com.android.contacts/1': 'Android content provider',
      'intent://scan/#Intent;scheme=zxing;end': 'Android intent',
      'app.example.com/back': 'no scheme',
      '/relative/path': 'no scheme',
      '1app://x': 'scheme must start with a letter',
      'my_app://x': 'underscore is not a scheme character',
      'myapp://has space': 'space',
      'myapp://x"y': 'quote',
      'myapp://x<y>': 'angle brackets',
      'myapp://x\\y': 'backslash',
      'myapp://bad%zzescape': 'broken percent escape',
      'myapp://x\ny': 'control character',
      'myapp://café': 'non-ASCII',
    };
    for (final MapEntry(key: url, value: why) in table.entries) {
      test('${url.isEmpty ? '(empty)' : url}: $why', () {
        expect(ReturnTarget.parse(url), isNull);
      });
    }

    test('null', () => expect(ReturnTarget.parse(null), isNull));

    test('over 512 characters', () {
      final url =
          'https://a.example/${'p' * (513 - 'https://a.example/'.length)}';
      expect(url.length, 513);
      expect(ReturnTarget.parse(url), isNull);
    });
  });

  group('in a pairing link', () {
    const base =
        'zunia://connect?v=2&sid=AAAAAAAAAAAAAAAAAAAAAA'
        '&t=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
        '&pk=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'
        '&r=wss%3A%2F%2Fapi.zunialab.com';

    test('is read URL-decoded', () {
      final uri = parsePairingUri(
        '$base&ret=${Uri.encodeComponent('https://app.example.com/back?a=1&b=2')}',
      )!;
      expect(uri.returnTarget!.url, 'https://app.example.com/back?a=1&b=2');
    });

    test('an unusable one is ignored and the link still pairs', () {
      final uri = parsePairingUri(
        '$base&ret=${Uri.encodeComponent('javascript:alert(1)')}',
      );
      expect(uri, isNotNull);
      expect(uri!.returnTarget, isNull);
    });

    test('is optional', () {
      expect(parsePairingUri(base)!.returnTarget, isNull);
    });

    test('the https form carries it too', () {
      final link = base.replaceFirst(
        'zunia://connect',
        'https://zunialab.com/connect',
      );
      final uri = parsePairingUri('$link&ret=myapp%3A%2F%2Fdone')!;
      expect(uri.returnTarget!.label, 'myapp');
    });
  });
}
