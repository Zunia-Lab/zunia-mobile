import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/config/connect_config.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/connect_links.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';

/// Where links come from: app_links in the app, a stream in tests.
abstract interface class LinkSource {
  Future<Uri?> initial();
  Stream<Uri> get links;
}

class AppLinksSource implements LinkSource {
  AppLinksSource([AppLinks? appLinks]) : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;

  @override
  Future<Uri?> initial() => _appLinks.getInitialLink();

  @override
  Stream<Uri> get links => _appLinks.uriLinkStream;
}

/// Routes links other apps, sites and the camera open Zunia with
/// ([classifyLink] lists them).
///
/// Nothing a link asks for happens behind the lock screen: links that arrive
/// while the wallet is locked wait until the unlocked UI [attach]es, then run
/// in order. The one exception is a wake link, which only brings an existing
/// session's socket up so its request is there by the time the user unlocks.
class DeepLinkHandler {
  DeepLinkHandler({
    LinkSource? source,
    WalletConnectService? walletConnect,
    NativeConnectService? nativeConnect,
  }) : _source = source,
       _nativeConnect = nativeConnect ?? NativeConnectService(),
       _walletConnect = walletConnect ?? StubWalletConnectService();

  LinkSource? _source;
  final WalletConnectService _walletConnect;
  final NativeConnectService _nativeConnect;
  StreamSubscription<Uri>? _sub;
  final _controller = StreamController<Uri>.broadcast();
  final _dapps = StreamController<Uri>.broadcast();
  final List<(Uri, bool)> _held = [];
  bool _attached = false;

  static const _maxHeld = 8;

  /// Every recognised link, as it arrives.
  Stream<Uri> get links => _controller.stream;

  /// Sites to open in the in-app browser, once the user confirmed the URL.
  Stream<Uri> get dappRequests => _dapps.stream;

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
    final source = _source ??= AppLinksSource();
    try {
      final initial = await source.initial();
      if (initial != null) await _receive(initial, fromOutside: true);
    } catch (e) {
      debugPrint('DeepLinkHandler initial link error: $e');
    }
    _sub = source.links.listen(
      (uri) => unawaited(_receive(uri, fromOutside: true)),
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
    await _dapps.close();
  }

  /// The unlocked UI is up: run what waited behind the lock screen.
  Future<void> attach() async {
    _attached = true;
    final held = List.of(_held);
    _held.clear();
    for (final (uri, fromOutside) in held) {
      await _route(uri, fromOutside: fromOutside);
    }
  }

  /// The wallet locked: hold links until [attach].
  void detach() => _attached = false;

  /// Routes a link found inside Zunia (the in-app browser). Such a link was
  /// not opened by another app, so it never sends the user anywhere after.
  Future<void> handleUri(Uri uri) => _receive(uri, fromOutside: false);

  bool isRecognized(Uri uri) => classifyLink(uri.toString()) != null;

  /// `zunia://dapp?url=https://...` → the https URL, or null.
  static String? parseDappUrl(Uri uri) =>
      switch (classifyLink(uri.toString())) {
        DappLink(:final url) => url.toString(),
        _ => null,
      };

  Future<void> _receive(Uri uri, {required bool fromOutside}) async {
    final link = classifyLink(uri.toString());
    if (link == null) return;
    if (!_controller.isClosed) _controller.add(uri);
    // Waking only reconnects a session this phone already has.
    if (link is WakeLink) {
      _nativeConnect.wake(link.sessionId);
      return;
    }
    if (!_attached) {
      if (_held.length >= _maxHeld) _held.removeAt(0);
      _held.add((uri, fromOutside));
      return;
    }
    await _route(uri, fromOutside: fromOutside);
  }

  Future<void> _route(Uri uri, {required bool fromOutside}) async {
    final link = classifyLink(uri.toString());
    switch (link) {
      case null:
        return;
      case WakeLink(:final sessionId):
        _nativeConnect.wake(sessionId);
      case PairLink(link: final raw):
        // Completes when the site's request arrives, which the inbox shows on
        // its own; later links need not wait for that.
        unawaited(
          _nativeConnect
              .pair(raw, sameDevice: fromOutside)
              .then<void>((_) {}, onError: _nativeConnect.reportError),
        );
      case WalletConnectPairLink(uri: final wcUri):
        try {
          if (!_walletConnect.isReady && kWalletConnectProjectId.isNotEmpty) {
            await _walletConnect.init();
          }
          await _walletConnect.pair(wcUri, sameDevice: fromOutside);
        } catch (e) {
          _nativeConnect.reportError(e);
        }
      case WalletConnectWakeLink(:final topic):
        try {
          await _walletConnect.wake(topic: fromOutside ? topic : null);
        } catch (e) {
          debugPrint('DeepLinkHandler WC wake error: $e');
        }
      case DappLink(:final url):
        if (!_dapps.isClosed) _dapps.add(url);
      case AddressLink():
        // Only the scanner acts on addresses.
        return;
      case UnsupportedLink(:final reason):
        _nativeConnect.reportError(ConnectException('UNSUPPORTED', reason));
    }
  }
}
