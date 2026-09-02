import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/config/connect_config.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';

/// Registers deep / universal links from [connect_config] and routes WC URIs.
class DeepLinkHandler {
  DeepLinkHandler({
    AppLinks? appLinks,
    WalletConnectService? walletConnect,
  })  : _appLinks = appLinks ?? AppLinks(),
        _walletConnect = walletConnect ?? createWalletConnectService();

  final AppLinks _appLinks;
  final WalletConnectService _walletConnect;
  StreamSubscription<Uri>? _sub;
  final _controller = StreamController<Uri>.broadcast();

  Stream<Uri> get links => _controller.stream;

  Future<void> start() async {
    await _sub?.cancel();
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

  Future<void> _handle(Uri uri) async {
    if (!isRecognized(uri)) return;
    if (!_controller.isClosed) {
      _controller.add(uri);
    }
    final wcUri = _extractWalletConnectUri(uri);
    if (wcUri != null && _walletConnect.isReady) {
      try {
        await _walletConnect.pair(wcUri);
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
