/// zunia.connect.v2 pairing links, as the dApp SDK builds them:
///
/// ```text
/// zunia://connect?v=2&sid=<22>&t=<43>&pk=<43>&r=<relay ws base>
/// ```
///
/// An `https://.../connect?...` link carries the same query. The parser accepts
/// exactly what `parsePairingUri` in `@zunialab/sdk-core` accepts; whether the
/// relay is one the wallet trusts is a separate decision ([RelayPolicy]).
///
/// An optional `ret` names where to send the user back when the link was
/// opened on this phone ([ReturnTarget]); an unusable `ret` is ignored and
/// the link still pairs.
library;

import 'package:zunia_mobile/connect/app_return.dart';

final _sessionId = RegExp(r'^[A-Za-z0-9_-]{22}$');
final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// A 22-character zunia.connect.v2 session id.
bool isConnectSessionId(String value) => _sessionId.hasMatch(value);

class PairingUri {
  const PairingUri({
    required this.sessionId,
    required this.joinToken,
    required this.dappPublicKey,
    required this.relay,
    this.returnTarget,
  });

  final String sessionId;

  /// Single-use token the relay exchanges for a resume token.
  final String joinToken;

  /// The dApp's X25519 public key, unpadded base64url.
  final String dappPublicKey;

  /// WebSocket base of the relay, for example `wss://api.zunialab.com`.
  final String relay;

  /// Where to go back after answering, when the link was opened on this phone.
  final ReturnTarget? returnTarget;

  Uri get relayUri => Uri.parse(relay);
}

String? _first(Uri uri, String key) {
  final values = uri.queryParametersAll[key];
  return values == null || values.isEmpty ? null : values.first;
}

/// Reads a v2 pairing link. Returns null for anything else, including v1 links.
PairingUri? parsePairingUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return null;
  final isScheme = uri.scheme == 'zunia' &&
      (uri.host == 'connect' ||
          uri.path.replaceFirst(RegExp(r'^/+'), '') == 'connect');
  final isLink = uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.path.replaceFirst(RegExp(r'/$'), '') == '/connect';
  if (!isScheme && !isLink) return null;
  final sessionId = _first(uri, 'sid') ?? '';
  final joinToken = _first(uri, 't') ?? '';
  final dappPublicKey = _first(uri, 'pk') ?? '';
  final relay = _first(uri, 'r') ?? '';
  if (_first(uri, 'v') != '2' ||
      !_sessionId.hasMatch(sessionId) ||
      !_token.hasMatch(joinToken) ||
      !_token.hasMatch(dappPublicKey)) {
    return null;
  }
  final relayUri = Uri.tryParse(relay);
  if (relayUri == null ||
      (relayUri.scheme != 'wss' && relayUri.scheme != 'ws') ||
      relayUri.host.isEmpty) {
    return null;
  }
  return PairingUri(
    sessionId: sessionId,
    joinToken: joinToken,
    dappPublicKey: dappPublicKey,
    relay: relay,
    returnTarget: ReturnTarget.parse(_first(uri, 'ret')),
  );
}

/// Which relays the wallet talks to.
///
/// The relay reports the origin of the page that created the session (its
/// `Origin` header). The wallet shows that origin as verified and binds
/// sign-in requests to it, so it only pairs through relays it trusts to
/// report it honestly: a relay run by the site itself could claim any origin.
class RelayPolicy {
  const RelayPolicy({required this.trusted, this.allowLocal = false});

  /// WebSocket bases, for example `wss://api.zunialab.com`.
  final List<String> trusted;

  /// Also accept relays on this machine or the local network: loopback, the
  /// Android emulator host (10.0.2.2) and private IPv4 ranges. Debug builds only.
  final bool allowLocal;

  bool trusts(String relay) {
    final uri = Uri.tryParse(relay);
    if (uri == null || (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      return false;
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return false;
    }
    for (final entry in trusted) {
      final allowed = Uri.tryParse(entry.trim());
      if (allowed == null) continue;
      if (allowed.scheme == uri.scheme &&
          allowed.host.toLowerCase() == uri.host.toLowerCase() &&
          _port(allowed) == _port(uri) &&
          _trimSlash(allowed.path) == _trimSlash(uri.path)) {
        return true;
      }
    }
    return allowLocal && isLocalHost(uri.host);
  }

  static int _port(Uri uri) =>
      uri.hasPort ? uri.port : (uri.scheme == 'wss' ? 443 : 80);

  static String _trimSlash(String path) => path.replaceFirst(RegExp(r'/+$'), '');

  static bool isLocalHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '::1' || h == '10.0.2.2') return true;
    final parts = h.split('.');
    if (parts.length != 4) return false;
    final octets = parts.map(int.tryParse).toList();
    if (octets.any((o) => o == null || o < 0 || o > 255)) return false;
    final a = octets[0]!;
    final b = octets[1]!;
    return a == 127 ||
        a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }
}

/// `ws(s)://host/base` to the socket URL the wallet opens.
Uri relaySocketUri(String relay, String sessionId) {
  final base = Uri.parse(relay);
  return base.replace(
    path: '${RelayPolicy._trimSlash(base.path)}/v1/connect/ws',
    queryParameters: {'sid': sessionId, 'role': 'wallet'},
  );
}

/// `ws(s)://host/base` to the HTTP URL of the session, for DELETE.
Uri relaySessionUri(String relay, String sessionId) {
  final base = Uri.parse(relay);
  return base.replace(
    scheme: base.scheme == 'wss' ? 'https' : 'http',
    path: '${RelayPolicy._trimSlash(base.path)}/v1/connect/sessions/$sessionId',
  );
}
