/// App-to-app return for zunia.connect.v2 on one phone.
///
/// A site or an app that opens Zunia with a pairing link can add
/// `ret=<url-encoded target>`; once the user approves or rejects, Zunia opens
/// that target so the user lands back where they started. The target is only
/// ever opened right after the user tapped an answer, never on its own.
///
/// Accepted targets:
/// - `https:` URLs with a host;
/// - URLs in another app's own scheme (`myapp://callback`), except schemes
///   that would reach Zunia itself, WalletConnect, script or local content:
///   zunia, zuniamobile, wc, javascript, data, file, blob, about, content,
///   intent (and plain `http:`).
///
/// The whole target must be valid RFC 3986 text and at most 512 characters
/// once decoded. Anything else is ignored: pairing still works, there is just
/// no way back.
library;

final _rfc3986 = RegExp(
  r"^[A-Za-z][A-Za-z0-9+.\-]*:(?:[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=]|%[0-9A-Fa-f]{2})*$",
);

const _refusedSchemes = {
  'zunia',
  'zuniamobile',
  'wc',
  'javascript',
  'data',
  'file',
  'blob',
  'about',
  'content',
  'intent',
  // Only https is accepted for web pages.
  'http',
};

class ReturnTarget {
  const ReturnTarget._(this.url, this.label);

  static const maxLength = 512;

  /// Exactly as the dApp sent it (decoded once from the pairing link).
  final String url;

  /// What "Return to …" names: the host of an https target, the scheme of an
  /// app's own link.
  final String label;

  Uri get uri => Uri.parse(url);

  /// Null for anything that is not an acceptable target.
  static ReturnTarget? parse(String? value) {
    if (value == null || value.isEmpty || value.length > maxLength) return null;
    if (!_rfc3986.hasMatch(value)) return null;
    final Uri uri;
    try {
      uri = Uri.parse(value);
    } on FormatException {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme.isEmpty || _refusedSchemes.contains(scheme)) return null;
    if (scheme == 'https') {
      if (uri.host.isEmpty) return null;
      return ReturnTarget._(value, uri.host.toLowerCase());
    }
    return ReturnTarget._(value, scheme);
  }

  /// `Return to app.example.com`.
  String get prompt => 'Return to $label';

  @override
  bool operator ==(Object other) => other is ReturnTarget && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => url;
}
