import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/config/connect_config.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';

/// Registers deep / universal links and routes WC + native connect URIs.
class DeepLinkHandler {
  DeepLinkHandler({
    AppLinks? appLinks,
    WalletConnectService? walletConnect,
    NativeConnectService? nativeConnect,
  })  : _appLinks = appLinks ?? AppLinks(),
        _walletConnect = walletConnect ?? createWalletConnectService(),
        _nativeConnect = nativeConnect ?? NativeConnectService();

  final AppLinks _appLinks;
  final WalletConnectService _walletConnect;
  final NativeConnectService _nativeConnect;
  StreamSubscription<Uri>? _sub;
  final _controller = StreamController<Uri>.broadcast();

  Stream<Uri> get links => _controller.stream;

  WalletConnectService get walletConnect => _walletConnect;
  NativeConnectService get nativeConnect => _nativeConnect;

  Future<void> start() async {
    await _sub?.cancel();
    try {
      if (!_walletConnect.isReady && kWalletConnectProjectId.isNotEmpty) {
        await _walletConnect.init();
      }
    } catch (e) {
      debugPrint('DeepLinkHandler WC init error: $e');
    }
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        await _handle(initial);
      }
    } catch (e) {
      debugPrint('DeepLinkHandler initial link error: $e');
    }
    _sub = _appLinks.uriLinkStream.listen(
      _handle,
      onError: (Object e) => debugPrint('DeepLinkHandler stream error: $e'),
    );
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  /// Route a URI as if it arrived via deep link (e.g. `wc:` from the browser).
  Future<void> handleUri(Uri uri) => _handle(uri);

  bool isRecognized(Uri uri) {
    if (uri.scheme == 'wc') return true;
    if (kCustomUrlSchemes.contains(uri.scheme)) return true;
    if (uri.scheme == 'https' &&
        kUniversalLinkHosts.contains(uri.host) &&
        kUniversalLinkPaths.any((p) => uri.path.startsWith(p))) {
      return true;
    }
    return false;
  }

  /// Open-in-browser deep links: `zunia://dapp?url=https://...`
  static String? parseDappUrl(Uri uri) {
    if (!kCustomUrlSchemes.contains(uri.scheme)) return null;
    final host = uri.host.toLowerCase();
    final isDappPath = uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first.toLowerCase() == 'dapp';
    if (host != 'dapp' && !isDappPath) return null;
    final url = uri.queryParameters['url'] ?? uri.queryParameters['u'];
    if (url == null || url.isEmpty) return null;
    return url;
  }

  Future<void> _handle(Uri uri) async {
    if (!isRecognized(uri)) return;
    if (!_controller.isClosed) {
      _controller.add(uri);
    }

    // Browser deep links are surfaced on [links] for the UI to open.
    if (parseDappUrl(uri) != null) return;

    final nativeCreds = NativeConnectService.parseConnectLink(uri);
    if (nativeCreds != null) {
      try {
        await _nativeConnect.connect(
          sessionId: nativeCreds.sessionId,
          pairingSecret: nativeCreds.pairingSecret,
        );
      } catch (e) {
        debugPrint('DeepLinkHandler native connect error: $e');
      }
      return;
    }

    final wcUri = _extractWalletConnectUri(uri);
    if (wcUri != null) {
      try {
        if (!_walletConnect.isReady && kWalletConnectProjectId.isNotEmpty) {
          await _walletConnect.init();
        }
        if (_walletConnect.isReady) {
          await _walletConnect.pair(wcUri);
        }
      } catch (e) {
        debugPrint('DeepLinkHandler WC pair error: $e');
      }
    }
  }

  String? _extractWalletConnectUri(Uri uri) {
    if (uri.scheme == 'wc') return uri.toString();
    final uriParam = uri.queryParameters['uri'];
    if (uriParam != null && uriParam.startsWith('wc:')) return uriParam;
    if (uri.pathSegments.contains('wc') || uri.host == 'wc') {
      return uriParam;
    }
    return null;
  }
}
