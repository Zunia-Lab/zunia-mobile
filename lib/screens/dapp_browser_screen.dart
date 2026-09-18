import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/browser/dapp_browser_store.dart';
import 'package:zunia_mobile/browser/dapp_provider_bridge.dart';
import 'package:zunia_mobile/browser/provider_inject.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/services/deep_link_handler.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Full-screen in-app wallet browser.
///
/// Keys never enter the WebView. The injected `window.zunia` / `window.keplr`
/// provider bridges enable + sign requests to native approval sheets.
class DappBrowserScreen extends ConsumerStatefulWidget {
  const DappBrowserScreen({
    super.key,
    required this.initialUrl,
    this.title,
  });

  final String initialUrl;
  final String? title;

  static Future<void> open(
    BuildContext context, {
    required String url,
    String? title,
  }) {
    final normalized = normalizeBrowserUrl(url);
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        barrierDismissible: false,
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, animation, secondary) {
          return DappBrowserScreen(
            initialUrl: normalized,
            title: title,
          );
        },
        transitionsBuilder: (context, animation, secondary, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(opacity: curved, child: child),
          );
        },
      ),
    );
  }

  @override
  ConsumerState<DappBrowserScreen> createState() => _DappBrowserScreenState();
}

String normalizeBrowserUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return 'https://app.osmosis.zone';
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  if (trimmed.contains(' ') || !trimmed.contains('.')) {
    return 'https://duckduckgo.com/?q=${Uri.encodeComponent(trimmed)}';
  }
  return 'https://$trimmed';
}

/// Unwrap Chrome / Safari / Android intent URLs back to https for in-app load.
String? rewriteExternalBrowserUrl(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'googlechrome' ||
      scheme == 'googlechromes' ||
      scheme == 'chrome' ||
      scheme == 'chromes' ||
      scheme == 'safari-http' ||
      scheme == 'safari-https') {
    final https = scheme.endsWith('s') || scheme.contains('https');
    return Uri(
      scheme: https ? 'https' : 'http',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
      query: uri.hasQuery ? uri.query : null,
      fragment: uri.hasFragment ? uri.fragment : null,
    ).toString();
  }

  if (scheme == 'intent') {
    final raw = uri.toString();
    final fallback = RegExp(r'S\.browser_fallback_url=([^;]+)').firstMatch(raw);
    if (fallback != null) {
      return Uri.decodeComponent(fallback.group(1)!);
    }
    final schemeMatch = RegExp(r'scheme=([a-zA-Z0-9+.-]+)').firstMatch(raw);
    if (schemeMatch != null) {
      final nextScheme = schemeMatch.group(1)!.toLowerCase();
      if (nextScheme == 'http' || nextScheme == 'https') {
        final hostPath = uri.host.isEmpty
            ? raw.replaceFirst(RegExp(r'^intent://'), '')
            : '${uri.host}${uri.path}';
        final cut = hostPath.split('#Intent').first;
        return '$nextScheme://$cut';
      }
    }
  }

  return null;
}

class _DappBrowserScreenState extends ConsumerState<DappBrowserScreen> {
  final _urlController = TextEditingController();
  final _urlFocus = FocusNode();

  InAppWebViewController? _web;
  late final DappProviderBridge _bridge;

  double _progress = 0;
  String _pageTitle = '';
  String _currentUrl = '';
  bool _canBack = false;
  bool _canForward = false;
  bool _secure = true;
  bool _favorite = false;
  bool _loading = true;
  String? _origin;
  UnmodifiableListView<String> _connectedChains = UnmodifiableListView(const []);

  @override
  void initState() {
    super.initState();
    _bridge = DappProviderBridge(ref);
    _currentUrl = widget.initialUrl;
    _urlController.text = widget.initialUrl;
    _pageTitle = widget.title ?? '';
    _refreshFavorite();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  Future<void> _refreshFavorite() async {
    final fav = await DappBrowserStore.instance.isFavorite(_currentUrl);
    if (mounted) setState(() => _favorite = fav);
  }

  Future<void> _refreshNav() async {
    final web = _web;
    if (web == null) return;
    final back = await web.canGoBack();
    final forward = await web.canGoForward();
    if (!mounted) return;
    setState(() {
      _canBack = back;
      _canForward = forward;
    });
  }

  Future<void> _refreshPermissions(String? origin) async {
    if (origin == null) {
      setState(() {
        _origin = null;
        _connectedChains = UnmodifiableListView(const []);
      });
      return;
    }
    final perms = await DappBrowserStore.instance.permissions();
    final chains = perms[origin] ?? const <String>[];
    if (!mounted) return;
    setState(() {
      _origin = origin;
      _connectedChains = UnmodifiableListView(chains);
    });
  }

  Future<void> _submitUrl(String raw) async {
    final url = normalizeBrowserUrl(raw);
    _urlFocus.unfocus();
    setState(() {
      _currentUrl = url;
      _urlController.text = url;
      _loading = true;
    });
    await _web?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<NavigationActionPolicy> _onNav(NavigationAction action) async {
    final uri = action.request.url;
    if (uri == null) return NavigationActionPolicy.ALLOW;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' ||
        scheme == 'https' ||
        scheme == 'about' ||
        scheme == 'data' ||
        scheme == 'blob') {
      return NavigationActionPolicy.ALLOW;
    }

    final raw = uri.toString();

    // Keep WalletConnect pairings inside Zunia instead of bouncing out.
    if (scheme == 'wc' || raw.contains('wc:')) {
      try {
        final deep = ref.read(deepLinkHandlerProvider);
        await deep.handleUri(Uri.parse(raw));
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('WalletConnect failed: $e')),
          );
        }
      }
      return NavigationActionPolicy.CANCEL;
    }

    // zunia://dapp?url=https://… → load that page in this WebView.
    final dappUrl = DeepLinkHandler.parseDappUrl(uri);
    if (dappUrl != null) {
      await _submitUrl(normalizeBrowserUrl(dappUrl));
      return NavigationActionPolicy.CANCEL;
    }

    // Native connect / other recognized Zunia schemes stay in-process.
    final deep = ref.read(deepLinkHandlerProvider);
    if (deep.isRecognized(uri)) {
      try {
        await deep.handleUri(uri);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Link failed: $e')),
          );
        }
      }
      return NavigationActionPolicy.CANCEL;
    }

    // Chrome / Safari / Android intent wrappers → unwrap to https and stay here.
    final rewritten = rewriteExternalBrowserUrl(uri);
    if (rewritten != null) {
      await _submitUrl(rewritten);
      return NavigationActionPolicy.CANCEL;
    }

    // Never hand off to Safari / Chrome / another wallet app from the browser.
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Kept in Zunia. Unsupported ${uri.scheme.isEmpty ? "link" : "${uri.scheme}://"} link.',
          ),
        ),
      );
    }
    return NavigationActionPolicy.CANCEL;
  }

  Future<bool> _onCreateWindow(
    InAppWebViewController controller,
    CreateWindowAction createWindowAction,
  ) async {
    final url = createWindowAction.request.url;
    if (url == null) return true;
    final scheme = url.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      await controller.loadUrl(urlRequest: URLRequest(url: url));
      return true;
    }
    final rewritten = rewriteExternalBrowserUrl(url);
    if (rewritten != null) {
      await _submitUrl(rewritten);
      return true;
    }
    // Swallow popups that would otherwise open the system browser.
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final host = Uri.tryParse(_currentUrl)?.host ?? '';

    return Scaffold(
      backgroundColor: s.bg,
      // Stay inside the Flutter app surface — never hand off to Safari/Chrome.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _BrowserChrome(
              urlController: _urlController,
              urlFocus: _urlFocus,
              displayUrl: _currentUrl,
              pageTitle: _pageTitle,
              progress: _progress,
              loading: _loading,
              secure: _secure,
              canBack: _canBack,
              canForward: _canForward,
              favorite: _favorite,
              connected: _connectedChains.isNotEmpty,
              connectedLabel: _connectedChains.isEmpty
                  ? null
                  : '${_connectedChains.length} chain${_connectedChains.length == 1 ? '' : 's'}',
              onBack: _canBack ? () => _web?.goBack() : null,
              onForward: _canForward ? () => _web?.goForward() : null,
              onReload: () => _web?.reload(),
              onClose: () => Navigator.of(context).pop(),
              onSubmit: _submitUrl,
              onToggleFavorite: () async {
                await DappBrowserStore.instance.toggleFavorite(
                  url: _currentUrl,
                  title: _pageTitle.isEmpty ? host : _pageTitle,
                );
                await _refreshFavorite();
              },
              onMore: _showMore,
            ),
            Expanded(
              child: Stack(
                children: [
                  ColoredBox(
                    color: s.bg,
                    child: const SizedBox.expand(),
                  ),
                  InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      domStorageEnabled: true,
                      databaseEnabled: true,
                      isInspectable: true,
                      mediaPlaybackRequiresUserGesture: true,
                      allowsInlineMediaPlayback: true,
                      allowsBackForwardNavigationGestures: true,
                      sharedCookiesEnabled: true,
                      useShouldOverrideUrlLoading: true,
                      supportZoom: true,
                      transparentBackground: false,
                      // Keep window.open / target=_blank inside this WebView.
                      supportMultipleWindows: true,
                      javaScriptCanOpenWindowsAutomatically: true,
                      // iOS: block Safari link previews / external handoff.
                      allowsLinkPreview: false,
                      isFraudulentWebsiteWarningEnabled: true,
                      preferredContentMode: UserPreferredContentMode.MOBILE,
                      userAgent:
                          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                          'AppleWebKit/605.1.15 (KHTML, like Gecko) '
                          'Version/17.0 Mobile/15E148 Safari/604.1 ZuniaWallet/0.1',
                    ),
                    onWebViewCreated: (controller) async {
                      _web = controller;
                      controller.addJavaScriptHandler(
                        handlerName: 'zunia',
                        callback: (args) async {
                          final payload = args.isEmpty
                              ? <String, dynamic>{}
                              : Map<String, dynamic>.from(args.first as Map);
                          final method = payload['method']?.toString() ?? '';
                          final reqArgs = (payload['args'] as List<dynamic>?) ??
                              const <dynamic>[];
                          final origin = _origin ??
                              browserOriginOf(
                                Uri.tryParse(_currentUrl) ?? Uri(),
                              );
                          if (!mounted) {
                            return {'error': 'Browser closed'};
                          }
                          final response = await _bridge.handle(
                            context: context,
                            origin: origin,
                            method: method,
                            args: reqArgs,
                          );
                          await _refreshPermissions(origin);
                          return response;
                        },
                      );
                    },
                    initialUserScripts: UnmodifiableListView([
                      UserScript(
                        source: kZuniaProviderInjectScript,
                        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                      ),
                    ]),
                    shouldOverrideUrlLoading: (controller, action) => _onNav(action),
                    onCreateWindow: _onCreateWindow,
                    onLoadStart: (controller, url) {
                      final next = url?.toString() ?? _currentUrl;
                      setState(() {
                        _loading = true;
                        _currentUrl = next;
                        if (!_urlFocus.hasFocus) {
                          _urlController.text = next;
                        }
                        _secure = (url?.scheme ?? 'https') == 'https';
                      });
                      _refreshNav();
                      _refreshPermissions(
                        url == null ? null : browserOriginOf(url),
                      );
                    },
                    onProgressChanged: (controller, progress) {
                      setState(() => _progress = progress / 100);
                    },
                    onTitleChanged: (controller, title) {
                      setState(() => _pageTitle = title ?? '');
                    },
                    onLoadStop: (controller, url) async {
                      final next = url?.toString() ?? _currentUrl;
                      setState(() {
                        _loading = false;
                        _progress = 1;
                        _currentUrl = next;
                        if (!_urlFocus.hasFocus) {
                          _urlController.text = next;
                        }
                      });
                      await _refreshNav();
                      await DappBrowserStore.instance.touchRecent(
                        url: next,
                        title: _pageTitle.isEmpty
                            ? (Uri.tryParse(next)?.host ?? next)
                            : _pageTitle,
                      );
                      await _refreshFavorite();
                      // Re-inject if a SPA wiped scripts (belt and braces).
                      await controller.evaluateJavascript(
                        source: kZuniaProviderInjectScript,
                      );
                    },
                    onReceivedError: (controller, request, error) {
                      if (request.isForMainFrame == true) {
                        setState(() => _loading = false);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMore() async {
    final s = ZuniaSemanticsExt.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Material(
              color: s.surfaceRaised,
              borderRadius: BorderRadius.circular(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: Icon(Icons.copy_rounded, color: s.fg),
                    title: Text('Copy link', style: zuniaSans(color: s.fg)),
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: _currentUrl));
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Link copied')),
                        );
                      }
                    },
                  ),
                  if (_origin != null)
                    ListTile(
                      leading: Icon(Icons.link_off_rounded, color: s.danger),
                      title: Text(
                        'Disconnect this site',
                        style: zuniaSans(color: s.danger),
                      ),
                      onTap: () async {
                        await DappBrowserStore.instance.revoke(_origin!);
                        await _refreshPermissions(_origin);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BrowserChrome extends StatelessWidget {
  const _BrowserChrome({
    required this.urlController,
    required this.urlFocus,
    required this.displayUrl,
    required this.pageTitle,
    required this.progress,
    required this.loading,
    required this.secure,
    required this.canBack,
    required this.canForward,
    required this.favorite,
    required this.connected,
    required this.connectedLabel,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onClose,
    required this.onSubmit,
    required this.onToggleFavorite,
    required this.onMore,
  });

  final TextEditingController urlController;
  final FocusNode urlFocus;
  final String displayUrl;
  final String pageTitle;
  final double progress;
  final bool loading;
  final bool secure;
  final bool canBack;
  final bool canForward;
  final bool favorite;
  final bool connected;
  final String? connectedLabel;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final VoidCallback onReload;
  final VoidCallback onClose;
  final ValueChanged<String> onSubmit;
  final VoidCallback onToggleFavorite;
  final VoidCallback onMore;

  String get _hostLabel {
    final host = Uri.tryParse(displayUrl)?.host;
    if (host != null && host.isNotEmpty) return host;
    if (pageTitle.trim().isNotEmpty) return pageTitle.trim();
    return 'Zunia browser';
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Material(
      color: s.surface,
      elevation: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Row(
              children: [
                Text(
                  'ZUNIA',
                  style: zuniaMono(
                    fontSize: 9.5,
                    letterSpacing: 1.4,
                    color: s.fgDim,
                  ),
                ),
                const Spacer(),
                Text(
                  'In-app browser',
                  style: zuniaMono(fontSize: 9.5, color: s.fgDim),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Row(
              children: [
                _ChromeIcon(
                  icon: Icons.close_rounded,
                  onTap: onClose,
                ),
                _ChromeIcon(
                  icon: Icons.chevron_left_rounded,
                  onTap: onBack,
                  enabled: canBack,
                ),
                _ChromeIcon(
                  icon: Icons.chevron_right_rounded,
                  onTap: onForward,
                  enabled: canForward,
                ),
                Expanded(
                  child: AnimatedBuilder(
                    animation: urlFocus,
                    builder: (context, _) {
                      final editing = urlFocus.hasFocus;
                      return Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: s.glass,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: editing ? s.accent : s.line,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              secure
                                  ? Icons.lock_rounded
                                  : Icons.lock_open_rounded,
                              size: 14,
                              color: secure ? s.success : s.warning,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: editing
                                  ? TextField(
                                      controller: urlController,
                                      focusNode: urlFocus,
                                      style: zuniaMono(
                                        fontSize: 13,
                                        color: s.fg,
                                      ),
                                      cursorColor: s.accent,
                                      keyboardType: TextInputType.url,
                                      textInputAction: TextInputAction.go,
                                      autocorrect: false,
                                      enableSuggestions: false,
                                      decoration: InputDecoration(
                                        isDense: true,
                                        border: InputBorder.none,
                                        hintText: 'Search or enter dApp URL',
                                        hintStyle: zuniaSans(
                                          fontSize: 13,
                                          color: s.fgDim,
                                        ),
                                      ),
                                      onSubmitted: onSubmit,
                                    )
                                  : GestureDetector(
                                      onTap: urlFocus.requestFocus,
                                      behavior: HitTestBehavior.opaque,
                                      child: Text(
                                        _hostLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: zuniaMono(
                                          fontSize: 13,
                                          color: s.fg,
                                        ),
                                      ),
                                    ),
                            ),
                            if (!editing &&
                                connected &&
                                connectedLabel != null)
                              Container(
                                margin: const EdgeInsets.only(left: 4),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: s.accent.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  connectedLabel!,
                                  style: zuniaMono(
                                    fontSize: 9.5,
                                    color: s.accent,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                _ChromeIcon(
                  icon: loading ? Icons.close_rounded : Icons.refresh_rounded,
                  onTap: onReload,
                ),
                _ChromeIcon(
                  icon: favorite
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  onTap: onToggleFavorite,
                  color: favorite ? s.accent : null,
                ),
                _ChromeIcon(
                  icon: Icons.more_horiz_rounded,
                  onTap: onMore,
                ),
              ],
            ),
          ),
          if (loading && progress > 0 && progress < 0.98)
            LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: s.accent,
            ),
        ],
      ),
    );
  }
}

class _ChromeIcon extends StatelessWidget {
  const _ChromeIcon({
    required this.icon,
    required this.onTap,
    this.enabled = true,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool enabled;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      onPressed: enabled ? onTap : null,
      icon: Icon(
        icon,
        size: 22,
        color: !enabled
            ? s.fgDim.withValues(alpha: 0.35)
            : (color ?? s.fg),
      ),
    );
  }
}
