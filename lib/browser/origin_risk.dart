/// Warnings about the site asking to connect or sign, computed from its origin
/// alone (zunia-extension/lib/origin-risk.ts, the same lists and sentences).
///
/// There is no remote blocklist behind this: it catches the lookalike patterns
/// a phishing page relies on (a well-known dApp's name inside a different
/// domain, a one-letter typo, punycode, a bare IP) and says so in the prompt.
/// It never blocks on its own; the user decides with the warning in front of
/// them.
library;

/// Registrable domains of dApps people are commonly tricked into
/// "reconnecting" to.
const kKnownDappDomains = <String>[
  'osmosis.zone',
  'keplr.app',
  'leapwallet.io',
  'cosmostation.io',
  'mintscan.io',
  'astroport.fi',
  'stargaze.zone',
  'daodao.zone',
  'stride.zone',
  'neutron.org',
  'celestia.org',
  'injective.com',
  'injective.network',
  'kujira.network',
  'levana.finance',
  'dydx.exchange',
  'skip.build',
  'restake.app',
  'zunialab.com',
];

/// Brand tokens long enough that finding one inside another domain means
/// something.
final List<String> _brandTokens = [
  for (final domain in kKnownDappDomains)
    if (domain.split('.').first.length >= 5) domain.split('.').first,
];

/// `suspicious` when any pattern matched, `local` for a page served from this
/// device, `none` otherwise.
enum OriginRiskLevel { none, local, suspicious }

class OriginRisk {
  const OriginRisk(this.level, this.warnings);

  final OriginRiskLevel level;
  final List<String> warnings;

  bool get suspicious => level == OriginRiskLevel.suspicious;
}

/// The sentence the prompt shows for a site running on this device.
const kLocalSiteWarning = 'This is a site running on your own computer.';

String _registrableDomain(String host) {
  final labels = host.split('.');
  return labels.length <= 2 ? host : labels.sublist(labels.length - 2).join('.');
}

int _editDistance(String a, String b) {
  if ((a.length - b.length).abs() > 2) return 3;
  final row = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    var prev = row[0];
    row[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final temp = row[j];
      final substitution = prev + (a[i - 1] == b[j - 1] ? 0 : 1);
      var best = row[j] + 1;
      if (row[j - 1] + 1 < best) best = row[j - 1] + 1;
      if (substitution < best) best = substitution;
      row[j] = best;
      prev = temp;
    }
  }
  return row[b.length];
}

bool _isLocalHost(String host) =>
    host == 'localhost' ||
    host == '127.0.0.1' ||
    host == '[::1]' ||
    host == '::1' ||
    host.endsWith('.localhost');

bool _isIpAddress(String host) =>
    RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$').hasMatch(host) ||
    host.startsWith('[') ||
    host.contains(':');

OriginRisk assessOrigin(String origin) {
  final url = Uri.tryParse(origin);
  if (url == null || !url.hasScheme || url.host.isEmpty) {
    return const OriginRisk(
      OriginRiskLevel.suspicious,
      ["Zunia could not read this site's address."],
    );
  }
  final host = url.host.toLowerCase();
  final warnings = <String>[];

  if (_isLocalHost(host)) {
    return const OriginRisk(OriginRiskLevel.local, [kLocalSiteWarning]);
  }
  if (url.scheme != 'https') {
    warnings.add('The connection to this site is not encrypted.');
  }
  if (_isIpAddress(host)) {
    warnings.add('This site is reached by a raw IP address instead of a name.');
  }
  // A browser hands over the punycode form; a Dart Uri keeps the Unicode one,
  // or percent-encodes it, which is the same lookalike.
  if (host.split('.').any((label) => label.startsWith('xn--')) ||
      host.contains('%') ||
      RegExp(r'[^\x00-\x7f]').hasMatch(host)) {
    warnings.add(
      "The address uses international characters, which can imitate another site's name.",
    );
  }

  final domain = _registrableDomain(host);
  if (!kKnownDappDomains.contains(domain)) {
    String? typo;
    for (final known in kKnownDappDomains) {
      if (known.length >= 6 && _editDistance(domain, known) <= 2) {
        typo = known;
        break;
      }
    }
    String? imitated = typo;
    if (imitated == null) {
      for (final token in _brandTokens) {
        if (host.contains(token)) {
          imitated = kKnownDappDomains.firstWhere((d) => d.startsWith(token));
          break;
        }
      }
    }
    if (imitated != null) {
      warnings.add(
        'The address resembles $imitated but is a different site ($domain). Check it carefully.',
      );
    }
  }

  return OriginRisk(
    warnings.isEmpty ? OriginRiskLevel.none : OriginRiskLevel.suspicious,
    warnings,
  );
}
