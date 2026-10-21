/// The lookalike check, with the extension's own cases (lib/origin-risk.ts).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/browser/origin_risk.dart';

void main() {
  test('known dApps and ordinary sites raise nothing', () {
    for (final origin in [
      'https://app.osmosis.zone',
      'https://go.skip.build',
      'https://ibcmap.zunialab.com',
      'https://example.org',
    ]) {
      final risk = assessOrigin(origin);
      expect(risk.level, OriginRiskLevel.none, reason: origin);
      expect(risk.warnings, isEmpty, reason: origin);
    }
  });

  test('a typo of a known domain is named', () {
    final risk = assessOrigin('https://app.osmosls.zone');
    expect(risk.suspicious, isTrue);
    expect(
      risk.warnings,
      ['The address resembles osmosis.zone but is a different site (osmosls.zone). Check it carefully.'],
    );
  });

  test('a brand inside another domain is named', () {
    final risk = assessOrigin('https://osmosis-rewards.claim-now.io');
    expect(risk.suspicious, isTrue);
    expect(risk.warnings.single, contains('resembles osmosis.zone'));
  });

  test('punycode, raw IPs and plain http are each flagged', () {
    expect(assessOrigin('https://xn--osmsis-8ya.zone').warnings,
        contains("The address uses international characters, which can imitate another site's name."));
    expect(assessOrigin('https://\u043esmosis.zone').suspicious, isTrue);
    expect(assessOrigin('https://203.0.113.9').warnings,
        contains('This site is reached by a raw IP address instead of a name.'));
    expect(assessOrigin('http://example.org').warnings, ['The connection to this site is not encrypted.']);
  });

  test('this device is its own level, never suspicious', () {
    for (final origin in ['http://localhost:3000', 'http://127.0.0.1:8080', 'http://[::1]:5173', 'https://app.localhost']) {
      final risk = assessOrigin(origin);
      expect(risk.level, OriginRiskLevel.local, reason: origin);
      expect(risk.warnings, [kLocalSiteWarning]);
    }
  });

  test('an unreadable origin is suspicious', () {
    expect(assessOrigin('not a url').suspicious, isTrue);
  });
}
