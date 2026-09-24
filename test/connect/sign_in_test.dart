import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/sign_in.dart';

/// The vectors the extension and `@zunialab/sdk-core` run: a message the site
/// builds must read the same here, and a request the extension refuses must be
/// refused here too.
void main() {
  final vectors = jsonDecode(
    File('test/fixtures/sign-in-vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  String text(Map<String, dynamic> v) => (v['lines'] as List).cast<String>().join('\n');

  group('valid messages', () {
    for (final v in (vectors['valid'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'], () {
        final message = parseSignInMessage(text(v));
        expect(message.toJson(), v['fields']);
        expect(looksLikeSignIn(text(v)), isTrue);
      });
    }
  });

  group('invalid messages', () {
    for (final v in (vectors['invalid'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'], () {
        expect(
          () => parseSignInMessage(text(v)),
          throwsA(isA<ConnectException>().having((e) => e.code, 'code', 'INVALID_PARAMS')),
        );
      });
    }
  });

  group('binding', () {
    for (final v in (vectors['binding'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'], () {
        final message = parseSignInMessage(text(v));
        void check() => checkSignInBinding(
              message,
              origin: v['origin'],
              chainId: v['chainId'],
              signer: v['signer'],
              now: DateTime.parse(v['now']),
            );
        if (v['expect'] == 'ok') {
          check();
        } else {
          expect(
            check,
            throwsA(isA<ConnectException>().having((e) => e.code, 'code', v['expect'])),
          );
        }
      });
    }
  });

  test('refuses impossible dates the regex alone would let through', () {
    final base = (vectors['valid'] as List).first as Map<String, dynamic>;
    final lines = (base['lines'] as List).cast<String>().toList();
    final at = lines.indexWhere((l) => l.startsWith('Issued At: '));
    for (final date in ['2026-02-30T10:00:00Z', '2026-09-24T25:00:00Z', '2026-13-01T00:00:00Z']) {
      lines[at] = 'Issued At: $date';
      expect(() => parseSignInMessage(lines.join('\n')), throwsA(isA<ConnectException>()), reason: date);
    }
  });

  test('reads origins the way a browser does', () {
    expect(webOrigin('https://App.Example.com:443/login?x=1'), 'https://app.example.com');
    expect(webOrigin('http://localhost:3000/'), 'http://localhost:3000');
    expect(webOrigin('ipfs://bafy'), isNull);
    expect(webHost('http://[::1]:5173'), '[::1]:5173');
    expect(looksLikeSignIn('Example WANTS YOU TO SIGN IN WITH YOUR Ethereum account'), isTrue);
    expect(looksLikeSignIn('Please sign this message'), isFalse);
  });
}
