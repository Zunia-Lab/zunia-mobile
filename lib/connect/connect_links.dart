/// Every link and code that can reach the wallet from outside: opened by
/// another app, a site or the camera app, or scanned and pasted in Zunia.
///
/// | Link | Meaning |
/// | --- | --- |
/// | `zunia://connect?v=2&sid&t&pk&r[&ret]`, `https://<host>/connect?...` | Pair over Zunia Connect |
/// | `zunia://connect/wake?sid=<22>`, `https://zunialab.com/connect/wake?sid=`, `https://link.zunialab.com/connect/wake?sid=` | Bring a paired session up and show what waits |
/// | `wc:<topic>@2?...`, `zunia://wc?uri=`, `zuniamobile://wc?uri=`, `https://zunialab.com/wc?uri=`, `https://link.zunialab.com/wc?uri=` | Pair over WalletConnect v2 |
/// | `zunia://wc`, `zunia://wc?requestId=&sessionTopic=`, `zunia://` | A WalletConnect dApp bringing the wallet up for a request |
/// | `zunia://dapp?url=https://...` | Open a site in the in-app browser (after the user confirms) |
/// | a bech32 address, `cosmos:<address>`, `{"address": ...}` | Scanned only: someone to pay |
///
/// A wake link carries no secret: it can only bring up a session this phone
/// already has, and an unknown session id is ignored.
library;

import 'package:zunia_mobile/config/connect_config.dart';
import 'package:zunia_mobile/connect/pairing_uri.dart';
import 'package:zunia_mobile/util/address_payload.dart';

sealed class ConnectLink {
  const ConnectLink();
}

/// A zunia.connect.v2 pairing code.
final class PairLink extends ConnectLink {
  const PairLink(this.link, this.uri);

  final String link;
  final PairingUri uri;
}

/// `zunia://connect/wake?sid=...`.
final class WakeLink extends ConnectLink {
  const WakeLink(this.sessionId);

  final String sessionId;
}

/// A WalletConnect v2 pairing URI (`wc:...@2?...`).
final class WalletConnectPairLink extends ConnectLink {
  const WalletConnectPairLink(this.uri);

  final String uri;
}

/// A WalletConnect dApp opening the wallet for a request it just sent, or
/// just bringing it to the front.
final class WalletConnectWakeLink extends ConnectLink {
  const WalletConnectWakeLink({this.topic, this.requestId});

  final String? topic;
  final int? requestId;
}

/// `zunia://dapp?url=...`: only ever opened after the user confirms the URL.
final class DappLink extends ConnectLink {
  const DappLink(this.url);

  final Uri url;
}

/// A scanned payment address.
final class AddressLink extends ConnectLink {
  const AddressLink(this.address);

  final String address;
}

/// Something that looks like WalletConnect v1 or a damaged code: worth a
/// message instead of silence when it was scanned.
final class UnsupportedLink extends ConnectLink {
  const UnsupportedLink(this.reason);

  final String reason;
}

String _trimPath(String path) => path.replaceFirst(RegExp(r'/+$'), '');

bool _isOwnScheme(Uri uri) =>
    kCustomUrlSchemes.contains(uri.scheme.toLowerCase());

bool _isOwnHost(Uri uri) =>
    uri.scheme == 'https' &&
    kUniversalLinkHosts.contains(uri.host.toLowerCase());

/// The session id of a wake link, or null when [uri] is not one.
String? wakeSessionId(Uri uri) {
  final path = _trimPath(uri.path);
  final isScheme =
      uri.scheme.toLowerCase() == 'zunia' &&
      ((uri.host == 'connect' && path == '/wake') ||
          (uri.host.isEmpty &&
              path.replaceFirst(RegExp(r'^/+'), '') == 'connect/wake'));
  final isLink = _isOwnHost(uri) && path == '/connect/wake';
  if (!isScheme && !isLink) return null;
  final values = uri.queryParametersAll['sid'];
  final sid = values == null || values.isEmpty ? '' : values.first;
  return isConnectSessionId(sid) ? sid : null;
}

bool _isWalletConnectUri(String value) {
  if (!value.startsWith('wc:')) return false;
  final at = value.indexOf('@');
  if (at < 0) return false;
  final version = value.substring(at + 1).split(RegExp(r'[?/]')).first;
  return version == '2';
}

/// Reads [raw]. [scanned] also accepts payment addresses, which only make
/// sense from the camera or the clipboard.
ConnectLink? classifyLink(String raw, {bool scanned = false}) {
  final value = raw.trim();
  if (value.isEmpty) return null;

  if (value.startsWith('wc:')) {
    return _isWalletConnectUri(value)
        ? WalletConnectPairLink(value)
        : const UnsupportedLink(
            'This WalletConnect code is for an older version Zunia does not support',
          );
  }

  final uri = Uri.tryParse(value);
  if (uri != null && uri.hasScheme) {
    final sid = wakeSessionId(uri);
    if (sid != null) return WakeLink(sid);
    if (_isOwnHost(uri) && _trimPath(uri.path) == '/connect/wake') {
      return const UnsupportedLink('This link names no session');
    }

    final pairing = parsePairingUri(value);
    if (pairing != null) return PairLink(value, pairing);

    final own = _isOwnScheme(uri);
    final firstSegment = uri.pathSegments.isEmpty
        ? ''
        : uri.pathSegments.first.toLowerCase();
    final isWcPath =
        (own &&
            (uri.host.toLowerCase() == 'wc' ||
                (uri.host.isEmpty && firstSegment == 'wc'))) ||
        (_isOwnHost(uri) && _trimPath(uri.path) == '/wc');
    if (isWcPath) {
      final inner = uri.queryParameters['uri'];
      if (inner != null && inner.isNotEmpty) {
        return _isWalletConnectUri(inner)
            ? WalletConnectPairLink(inner)
            : const UnsupportedLink(
                'This WalletConnect code is for an older version Zunia does not support',
              );
      }
      return WalletConnectWakeLink(
        topic: uri.queryParameters['sessionTopic'],
        requestId: int.tryParse(uri.queryParameters['requestId'] ?? ''),
      );
    }

    if (own &&
        (uri.host.toLowerCase() == 'dapp' ||
            (uri.host.isEmpty && firstSegment == 'dapp'))) {
      final target = uri.queryParameters['url'] ?? uri.queryParameters['u'];
      final parsed = target == null ? null : Uri.tryParse(target.trim());
      if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty) {
        return const UnsupportedLink('Zunia only opens https sites from links');
      }
      return DappLink(parsed);
    }

    // `zunia://` alone: a WalletConnect dApp's redirect back to the wallet.
    if (own && uri.host.isEmpty && uri.path.isEmpty && !uri.hasQuery) {
      return const WalletConnectWakeLink();
    }

    if (own && uri.host.toLowerCase() == 'connect') {
      return const UnsupportedLink(
        'This Zunia Connect code is damaged or from an older version. Ask the site for a new one.',
      );
    }
  }

  if (scanned) {
    final address = addressFromMaybeJson(value);
    if (address != null) return AddressLink(address);
  }
  return null;
}
