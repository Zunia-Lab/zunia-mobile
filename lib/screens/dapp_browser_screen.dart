import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_mobile/browser/approval_queue.dart';
import 'package:zunia_mobile/browser/dapp_browser_store.dart';
import 'package:zunia_mobile/browser/dapp_provider_bridge.dart';
import 'package:zunia_mobile/browser/known_recipients.dart';
import 'package:zunia_mobile/browser/origin_risk.dart';
import 'package:zunia_mobile/browser/provider_errors.dart';
import 'package:zunia_mobile/browser/provider_inject.dart';
import 'package:zunia_mobile/browser/site_grants.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/config/app_identity.dart';
import 'package:zunia_mobile/config/nft_config.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/connected_sites_screen.dart';
import 'package:zunia_mobile/screens/native_request_sheets.dart';
import 'package:zunia_mobile/services/deep_link_handler.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/state/custom_chains.dart';
import 'package:zunia_mobile/state/signing_settings.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Full-screen in-app wallet browser.
///
/// Keys never enter the WebView. The injected `window.zunia` (and, when the
/// user turns it on, `window.keplr`) sends every call to [DappProviderBridge];
/// connection and signature requests open the shared review sheet over the
/// page. The address bar sits at the bottom on iPhone, where Safari keeps it,
/// and at the top on Android, where Chrome does.
class DappBrowserScreen extends ConsumerStatefulWidget {
  const DappBrowserScreen({
    super.key,
    required this.initialUrl,
    this.title,
  });

  final String initialUrl;
  final String? title;

  /// The open page's WebView, for integration tests that drive a real site.
  /// Only set in debug builds.
  @visibleForTesting
  static final debugWebView = ValueNotifier<InAppWebViewController?>(null);

  static Future<void> open(
    BuildContext context, {
    required String url,
    String? title,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DappBrowserScreen(initialUrl: normalizeBrowserUrl(url), title: title),
      ),
    );
  }

  @override
  ConsumerState<DappBrowserScreen> createState() => _DappBrowserScreenState();
}

/// What the address bar loads for [raw]: a URL as typed (https assumed), or a
/// private web search for anything that is not one.
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

/// The app's state as the provider bridge sees it.
class _AppWallet extends ProviderWallet {
  _AppWallet(this.ref);

  final WidgetRef ref;

  @override
  String? get phrase => ref.read(phraseProvider);

  @override
  WalletAccount? get activeAccount => ref.read(walletProvider).active;

  @override
  Future<void> whenUnlocked(Duration timeout) async {
    if (phrase != null) return;
    final unlocked = Completer<void>();
    final sub = ref.listenManual<String?>(phraseProvider, (_, next) {
      if (next != null && !unlocked.isCompleted) unlocked.complete();
    });
    try {
      await unlocked.future.timeout(timeout);
    } on TimeoutException {
      throw const ProviderError(
        ProviderErrorCode.locked,
        'Zunia stayed locked, so the request was cancelled',
      );
    } finally {
      sub.close();
    }
  }

  @override
  ChainEntry? findChain(String chainId) =>
      ChainCatalog.isLoaded ? ChainCatalog.instance.find(chainId) : null;

  @override
  List<ChainEntry> get chains => ChainCatalog.isLoaded ? ChainCatalog.instance.all : const [];

  @override
  bool isRegistryChain(String chainId) =>
      ChainCatalog.isLoaded && ChainCatalog.instance.registryOnly.any((c) => c.chainId == chainId);

  @override
  Future<void> addChain(ChainEntry entry) => ref.read(customChainsProvider.notifier).add(entry);

  @override
  SigningSettings get settings => ref.read(signingSettingsProvider);

  @override
  Future<Set<String>> knownRecipients() async => {
        ...await KnownRecipients.instance.load(),
        for (final entry in ref.read(addressBookProvider)) entry.address,
      };

  @override
  Future<void> rememberRecipients(Iterable<String> addresses) =>
      KnownRecipients.instance.rememberAll(addresses);

  @override
  Set<String> nftBridges(String chainId) => {?kIcs721Bridges[chainId]};
}

class _DappBrowserScreenState extends ConsumerState<DappBrowserScreen> {
  final _urlController = TextEditingController();
  final _urlFocus = FocusNode();
  final _token = newProviderToken();
  final _queue = ApprovalQueue();
  final _subs = <StreamSubscription<Object?>>[];
  late final DappProviderBridge _bridge;
  late final PullToRefreshController? _pullToRefresh;

  InAppWebViewController? _web;
  Timer? _expiryTimer;
  bool _showingApproval = false;

  double _progress = 0;
  String _pageTitle = '';
  String _currentUrl = '';
  String? _origin;
  bool _canBack = false;
  bool _canForward = false;
  bool _bookmarked = false;
  bool _loading = true;
  List<String> _connectedChains = const [];

  SiteGrantStore get _grants => ref.read(siteGrantStoreProvider);

  @override
  void initState() {
    super.initState();
    _bridge = DappProviderBridge(wallet: _AppWallet(ref), grants: _grants, approvals: _queue);
    _currentUrl = widget.initialUrl;
    _urlController.text = widget.initialUrl;
    _pageTitle = widget.title ?? '';
    _origin = _originOf(widget.initialUrl);
    _pullToRefresh = defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android
        ? PullToRefreshController(
            // The brand red of the primary button; the theme is not readable yet here.
            settings: PullToRefreshSettings(color: const Color(0xFFB42218)),
            onRefresh: () => _web?.reload(),
          )
        : null;
    _subs
      ..add(_queue.changes.listen((_) => _showNextApproval()))
      ..add(_grants.events.listen(_onSiteEvent))
      ..add(_grants.changes.listen((_) => _refreshConnection()));

    // The page hears an account switch and the wallet locking, as a connected
    // site in the extension does.
    ref.listenManual<String?>(walletProvider.select((w) => w.active?.id), (previous, next) {
      if (previous != null && next != null && previous != next) {
        _notifyConnected(ProviderEventName.accountsChanged);
      }
    });
    ref.listenManual<String?>(phraseProvider, (previous, next) {
      if (previous != null && next == null) {
        _queue.rejectWhere((_) => true, reason: 'Wallet locked', code: ProviderErrorCode.locked);
        _notifyConnected(ProviderEventName.locked);
      } else if (previous == null && next != null) {
        _notifyConnected(ProviderEventName.accountsChanged);
      }
    });
    ref.listenManual<bool>(signingSettingsProvider.select((s) => s.exposeKeplrAlias), (_, on) {
      unawaited(_applyKeplrAlias(on));
    });
    _refreshBookmark();
    _refreshConnection();
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _expiryTimer?.cancel();
    _queue.dispose();
    _urlController.dispose();
    _urlFocus.dispose();
    if (DappBrowserScreen.debugWebView.value == _web) DappBrowserScreen.debugWebView.value = null;
    super.dispose();
  }

  static String? _originOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    return browserOriginOf(uri);
  }

  String get _host => Uri.tryParse(_currentUrl)?.host ?? '';

  /* ---------------------------------------------------------------------- */

  Future<String?> _mainFrameOrigin() async {
    final url = await _web?.getUrl();
    return url == null ? null : _originOf(url.toString());
  }

  Future<Object?> _onProviderCall(List<dynamic> args) async {
    final payload = args.isNotEmpty && args.first is Map ? Map<String, dynamic>.from(args.first as Map) : null;
    // Only the script this browser injected knows the token, and it installs
    // itself in the top document only: a frame inside the page cannot speak
    // for the site.
    if (payload == null || payload['token'] != _token) {
      return const ProviderError(
        ProviderErrorCode.originMismatch,
        'This frame cannot use Zunia',
      ).toWire();
    }
    final origin = await _mainFrameOrigin();
    if (origin == null || payload['origin'] != origin) {
      return const ProviderError(
        ProviderErrorCode.originMismatch,
        'The request does not come from the page on screen',
      ).toWire();
    }
    final method = payload['method'] is String ? payload['method'] as String : '';
    final callArgs = payload['args'] is List ? payload['args'] as List<dynamic> : const <dynamic>[];
    if (ref.read(phraseProvider) == null &&
        const {'enable', 'getKey', 'getAccounts', 'signAmino', 'signDirect', 'signArbitrary'}.contains(method) &&
        mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Unlock Zunia to answer ${webHostOf(origin)}')),
      );
    }
    final response = await _bridge.handle(origin: origin, method: method, args: callArgs);
    unawaited(_refreshConnection());
    return response;
  }

  static String webHostOf(String origin) => Uri.tryParse(origin)?.host ?? origin;

  Future<void> _showNextApproval() async {
    if (_showingApproval || !mounted) return;
    final next = _queue.current;
    if (next == null) return;
    _showingApproval = true;
    try {
      _urlFocus.unfocus();
      final account = ref.read(walletProvider).active;
      await showBrowserApprovalSheet(
        context,
        request: next,
        queue: _queue,
        accountName: account?.name ?? 'Wallet',
        accountAddress: _addressOn(next.chainIds.isEmpty ? null : next.chainIds.first),
      );
    } finally {
      _showingApproval = false;
    }
    if (mounted) unawaited(_showNextApproval());
  }

  /// The active account's address on [chainId], for a connection prompt.
  String? _addressOn(String? chainId) {
    final phrase = ref.read(phraseProvider);
    final account = ref.read(walletProvider).active;
    final chain = chainId == null || !ChainCatalog.isLoaded ? null : ChainCatalog.instance.find(chainId);
    if (phrase == null || account == null || chain == null) return null;
    try {
      return CosmosSigningKey(phrase: phrase, chain: chain, accountIndex: account.index).address();
    } catch (_) {
      return null;
    }
  }

  void _onSiteEvent(SiteEvent event) {
    if (event.origin != _origin) return;
    unawaited(_emit(event.event.name, event.data));
  }

  /// An event that is not a grant change, for the open page if it is connected.
  Future<void> _notifyConnected(ProviderEventName event) async {
    final origin = _origin;
    if (origin == null || (await _grants.connectedChains(origin)).isEmpty) return;
    await _emit(event.name, null);
  }

  Future<void> _emit(String event, Object? data) async {
    try {
      await _web?.evaluateJavascript(source: providerEventScript(event, data));
    } catch (e) {
      debugPrint('provider event: $e');
    }
  }

  Future<void> _applyKeplrAlias(bool on) async {
    final web = _web;
    if (web == null) return;
    try {
      await web.removeAllUserScripts();
      await web.addUserScript(userScript: _providerScript(on));
      await web.evaluateJavascript(source: providerSettingsScript(exposeKeplrAlias: on));
    } catch (e) {
      debugPrint('keplr alias: $e');
    }
  }

  UserScript _providerScript(bool keplrAlias) => UserScript(
        source: buildProviderScript(token: _token, exposeKeplrAlias: keplrAlias),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      );

  Future<void> _refreshConnection() async {
    final origin = _origin;
    final chains = origin == null ? const <String>[] : await _grants.connectedChains(origin);
    if (!mounted) return;
    if (!listEquals(chains, _connectedChains)) setState(() => _connectedChains = chains);
    // Tell the page the moment one of its chains lapses, not on its next call.
    _expiryTimer?.cancel();
    final next = await _grants.nextExpiry();
    if (next == null || !mounted) return;
    final wait = next.difference(_grants.now);
    _expiryTimer = Timer(wait.isNegative ? Duration.zero : wait + const Duration(seconds: 1), () {
      unawaited(_grants.sweep());
    });
  }

  Future<void> _refreshBookmark() async {
    final saved = await DappBrowserStore.instance.isBookmarked(_currentUrl);
    if (mounted && saved != _bookmarked) setState(() => _bookmarked = saved);
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

  /* ---------------------------------------------------------------------- */

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
    if (scheme == 'http' || scheme == 'https' || scheme == 'about' || scheme == 'data' || scheme == 'blob') {
      return NavigationActionPolicy.ALLOW;
    }

    final raw = uri.toString();

    // Keep WalletConnect pairings inside Zunia instead of bouncing out.
    if (scheme == 'wc' || raw.contains('wc:')) {
      try {
        await ref.read(deepLinkHandlerProvider).handleUri(Uri.parse(raw));
      } catch (e) {
        _toast('WalletConnect failed: $e');
      }
      return NavigationActionPolicy.CANCEL;
    }

    // zunia://dapp?url=https://… → load that page in this WebView.
    final dappUrl = DeepLinkHandler.parseDappUrl(uri);
    if (dappUrl != null) {
      await _submitUrl(normalizeBrowserUrl(dappUrl));
      return NavigationActionPolicy.CANCEL;
    }

    // Zunia Connect and other recognized Zunia schemes stay in-process.
    final deep = ref.read(deepLinkHandlerProvider);
    if (deep.isRecognized(uri)) {
      try {
        await deep.handleUri(uri);
      } catch (e) {
        _toast('Link failed: $e');
      }
      return NavigationActionPolicy.CANCEL;
    }

    // Chrome / Safari / Android intent wrappers → unwrap to https and stay here.
    final rewritten = rewriteExternalBrowserUrl(uri);
    if (rewritten != null) {
      await _submitUrl(rewritten);
      return NavigationActionPolicy.CANCEL;
    }

    // Never hand off to another wallet app from a page: it could be anything.
    _toast('Kept in Zunia. Unsupported ${uri.scheme.isEmpty ? 'link' : '${uri.scheme}://'} link.');
    return NavigationActionPolicy.CANCEL;
  }

  Future<bool> _onCreateWindow(InAppWebViewController controller, CreateWindowAction action) async {
    final url = action.request.url;
    if (url == null) return true;
    final scheme = url.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      await controller.loadUrl(urlRequest: URLRequest(url: url));
      return true;
    }
    final rewritten = rewriteExternalBrowserUrl(url);
    if (rewritten != null) await _submitUrl(rewritten);
    // Swallow popups that would otherwise open the system browser.
    return true;
  }

  void _onLoadStart(WebUri? url) {
    final next = url?.toString() ?? _currentUrl;
    final origin = _originOf(next);
    if (origin != _origin) {
      // A request from a page the user has left is not one to answer.
      final left = _origin;
      if (left != null) _queue.rejectWhere((r) => r.origin == left);
    }
    setState(() {
      _loading = true;
      _currentUrl = next;
      _origin = origin;
      if (!_urlFocus.hasFocus) _urlController.text = next;
    });
    unawaited(_refreshNav());
    unawaited(_refreshConnection());
    unawaited(_refreshBookmark());
  }

  Future<void> _onLoadStop(InAppWebViewController controller, WebUri? url) async {
    final next = url?.toString() ?? _currentUrl;
    await _pullToRefresh?.endRefreshing();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _progress = 1;
      _currentUrl = next;
      if (!_urlFocus.hasFocus) _urlController.text = next;
    });
    await _refreshNav();
    await DappBrowserStore.instance.touchRecent(
      url: next,
      title: _pageTitle.isEmpty ? (Uri.tryParse(next)?.host ?? next) : _pageTitle,
    );
    await _refreshBookmark();
    // A page whose document-start script did not run (an old Android WebView)
    // still gets the provider; the script refuses to install twice.
    final keplr = ref.read(signingSettingsProvider).exposeKeplrAlias;
    await controller.evaluateJavascript(
      source: buildProviderScript(token: _token, exposeKeplrAlias: keplr),
    );
    await controller.evaluateJavascript(source: providerSettingsScript(exposeKeplrAlias: keplr));
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  /* ---------------------------------------------------------------------- */

  Future<void> _share() async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        uri: Uri.tryParse(_currentUrl),
        subject: _pageTitle.isEmpty ? null : _pageTitle,
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  Future<void> _openInSystemBrowser() async {
    final uri = Uri.tryParse(_currentUrl);
    if (uri == null || !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _toast('No browser could open this page');
    }
  }

  Future<void> _toggleBookmark() async {
    final saved = await DappBrowserStore.instance.toggleBookmark(
      url: _currentUrl,
      title: _pageTitle.isEmpty ? _host : _pageTitle,
    );
    unawaited(ZuniaHaptics.light());
    if (!mounted) return;
    setState(() => _bookmarked = saved);
    _toast(saved ? 'Bookmarked' : 'Bookmark removed');
  }

  Future<void> _showMore() async {
    final cupertino = ZuniaPlatform.isCupertino(context);
    final connected = _connectedChains.isNotEmpty;
    final choice = await showZuniaActionSheet<String>(
      context,
      title: _host.isEmpty ? null : _host,
      actions: [
        ZuniaAlertAction(label: _bookmarked ? 'Remove bookmark' : 'Add bookmark', value: 'bookmark'),
        const ZuniaAlertAction(label: 'Bookmarks and history', value: 'history'),
        const ZuniaAlertAction(label: 'Copy link', value: 'copy'),
        const ZuniaAlertAction(label: 'Share…', value: 'share'),
        ZuniaAlertAction(label: cupertino ? 'Open in Safari' : 'Open in browser', value: 'external'),
        const ZuniaAlertAction(label: 'Connected sites', value: 'sites'),
        if (connected)
          const ZuniaAlertAction(label: 'Disconnect this site', value: 'disconnect', destructive: true),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'bookmark':
        await _toggleBookmark();
      case 'history':
        await _showBookmarks();
      case 'copy':
        await Clipboard.setData(ClipboardData(text: _currentUrl));
        _toast('Link copied');
      case 'share':
        await _share();
      case 'external':
        await _openInSystemBrowser();
      case 'sites':
        await ConnectedSitesScreen.open(context);
        unawaited(_refreshConnection());
      case 'disconnect':
        await _disconnectSite();
    }
  }

  Future<void> _disconnectSite() async {
    final origin = _origin;
    if (origin == null) return;
    await _grants.revokeSite(origin);
    unawaited(ZuniaHaptics.success());
    _toast('${webHostOf(origin)} disconnected');
  }

  Future<void> _showConnection() async {
    final origin = _origin;
    if (origin == null) return;
    await showZuniaSheet<void>(
      context,
      title: webHostOf(origin),
      builder: (ctx) => _ConnectionSheet(
        origin: origin,
        onDisconnectSite: () async {
          Navigator.of(ctx).pop();
          await _disconnectSite();
        },
        onManage: () {
          Navigator.of(ctx).pop();
          ConnectedSitesScreen.open(context);
        },
      ),
    );
  }

  Future<void> _showBookmarks() async {
    final url = await showZuniaSheet<String>(
      context,
      title: 'Bookmarks and history',
      builder: (_) => const _BookmarksSheet(),
    );
    if (url != null && mounted) await _submitUrl(url);
    unawaited(_refreshBookmark());
  }

  void _showSiteInfo() {
    final origin = _origin;
    if (origin == null) return;
    final risk = assessOrigin(origin);
    final secure = Uri.tryParse(_currentUrl)?.scheme == 'https';
    showZuniaAlert<void>(
      context,
      title: webHostOf(origin),
      message: [
        secure ? 'The connection to this site is encrypted.' : 'The connection to this site is not encrypted.',
        ...risk.warnings.where((w) => w != 'The connection to this site is not encrypted.'),
        if (_connectedChains.isNotEmpty)
          'Connected on ${_connectedChains.length} network${_connectedChains.length == 1 ? '' : 's'}.',
      ].join('\n\n'),
      actions: const [ZuniaAlertAction(label: 'OK', isDefault: true)],
    );
  }

  /* ---------------------------------------------------------------------- */

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    final risk = _origin == null ? null : assessOrigin(_origin!);
    final secure = Uri.tryParse(_currentUrl)?.scheme == 'https';
    final keplr = ref.read(signingSettingsProvider).exposeKeplrAlias;

    final addressBar = _AddressBar(
      controller: _urlController,
      focus: _urlFocus,
      host: _host,
      title: _pageTitle,
      secure: secure,
      suspicious: risk?.suspicious ?? false,
      local: risk?.level == OriginRiskLevel.local,
      loading: _loading,
      connectedChains: _connectedChains,
      onSubmit: _submitUrl,
      onReload: () => _loading ? _web?.stopLoading() : _web?.reload(),
      onSiteInfo: _showSiteInfo,
      onConnection: _showConnection,
    );
    final progress = SizedBox(
      height: 2,
      child: _loading && _progress > 0 && _progress < 1
          ? LinearProgressIndicator(
              value: _progress,
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: s.accent,
              semanticsLabel: 'Loading page',
            )
          : null,
    );
    final toolbar = _Toolbar(
      canBack: _canBack,
      canForward: _canForward,
      bookmarked: _bookmarked,
      onBack: () => _web?.goBack(),
      onForward: () => _web?.goForward(),
      onShare: _share,
      onBookmarks: _showBookmarks,
      onMore: _showMore,
    );

    final webView = InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
      pullToRefreshController: _pullToRefresh,
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        // Web inspector in debug builds only: a release build is not a page
        // anyone can attach to and read.
        isInspectable: kDebugMode,
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
        allowsLinkPreview: false,
        isFraudulentWebsiteWarningEnabled: true,
        safeBrowsingEnabled: true,
        preferredContentMode: UserPreferredContentMode.MOBILE,
        // The platform's own WebView user agent, with Zunia named at the end:
        // Safari's on iPhone, Chrome's on Android, never one faking the other.
        applicationNameForUserAgent: 'Zunia/$appVersion Mobile',
      ),
      initialUserScripts: UnmodifiableListView([_providerScript(keplr)]),
      onWebViewCreated: (controller) {
        _web = controller;
        assert(() {
          DappBrowserScreen.debugWebView.value = controller;
          return true;
        }());
        controller.addJavaScriptHandler(handlerName: kProviderHandlerName, callback: _onProviderCall);
      },
      shouldOverrideUrlLoading: (controller, action) => _onNav(action),
      onCreateWindow: _onCreateWindow,
      onLoadStart: (controller, url) => _onLoadStart(url),
      onProgressChanged: (controller, progress) {
        setState(() => _progress = progress / 100);
        if (progress == 100) _pullToRefresh?.endRefreshing();
      },
      onTitleChanged: (controller, title) => setState(() => _pageTitle = title ?? ''),
      onUpdateVisitedHistory: (controller, url, isReload) {
        if (url == null) return;
        setState(() {
          _currentUrl = url.toString();
          if (!_urlFocus.hasFocus) _urlController.text = _currentUrl;
        });
        unawaited(_refreshNav());
      },
      onLoadStop: _onLoadStop,
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame == true) {
          _pullToRefresh?.endRefreshing();
          setState(() => _loading = false);
        }
      },
    );

    final topBar = _TopBar(
      title: _pageTitle,
      host: _host,
      cupertino: cupertino,
      onClose: () => Navigator.of(context).pop(),
      trailing: cupertino
          ? (_connectedChains.isEmpty
              ? null
              : _ConnectionChip(count: _connectedChains.length, onTap: _showConnection))
          : null,
    );

    return Scaffold(
      backgroundColor: s.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (cupertino) ...[topBar, progress] else ...[
              Material(
                color: s.surface,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Close browser',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(Icons.close_rounded, color: s.fg),
                      ),
                      Expanded(child: addressBar),
                    ],
                  ),
                ),
              ),
              progress,
            ],
            Expanded(child: webView),
            Material(
              color: s.surface,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Divider(height: 0.5, thickness: 0.5, color: s.line),
                    if (cupertino)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: addressBar,
                      ),
                    toolbar,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.host,
    required this.cupertino,
    required this.onClose,
    this.trailing,
  });

  final String title;
  final String host;
  final bool cupertino;
  final VoidCallback onClose;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Material(
      color: s.surface,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            TextButton(
              onPressed: onClose,
              child: Text('Done', style: zuniaSans(fontSize: 16, fontWeight: FontWeight.w600, color: s.accent)),
            ),
            Expanded(
              child: Text(
                title.isEmpty ? host : title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: zuniaSans(fontSize: 13.5, fontWeight: FontWeight.w500, color: s.fg),
              ),
            ),
            SizedBox(
              width: 72,
              child: Align(alignment: Alignment.centerRight, child: trailing ?? const SizedBox()),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _AddressBar extends StatelessWidget {
  const _AddressBar({
    required this.controller,
    required this.focus,
    required this.host,
    required this.title,
    required this.secure,
    required this.suspicious,
    required this.local,
    required this.loading,
    required this.connectedChains,
    required this.onSubmit,
    required this.onReload,
    required this.onSiteInfo,
    required this.onConnection,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final String host;
  final String title;
  final bool secure;
  final bool suspicious;
  final bool local;
  final bool loading;
  final List<String> connectedChains;
  final ValueChanged<String> onSubmit;
  final VoidCallback onReload;
  final VoidCallback onSiteInfo;
  final VoidCallback onConnection;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    final (icon, color, label) = suspicious
        ? (Icons.gpp_maybe_rounded, s.danger, 'Lookalike site warning')
        : local
            ? (Icons.developer_mode_rounded, s.info, 'Site on this device')
            : secure
                ? (Icons.lock_rounded, s.fgMuted, 'Secure connection')
                : (Icons.lock_open_rounded, s.warning, 'Connection not secure');
    return AnimatedBuilder(
      animation: focus,
      builder: (context, _) {
        final editing = focus.hasFocus;
        return Container(
          height: 44,
          padding: const EdgeInsets.only(left: 2, right: 2),
          decoration: BoxDecoration(
            color: s.glass2,
            borderRadius: BorderRadius.circular(cupertino ? 12 : 22),
            border: Border.all(color: editing ? s.accent : (suspicious ? s.dangerLine : Colors.transparent)),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: label,
                visualDensity: VisualDensity.compact,
                onPressed: onSiteInfo,
                icon: Icon(icon, size: 16, color: color),
              ),
              Expanded(
                child: editing
                    ? TextField(
                        controller: controller,
                        focusNode: focus,
                        autofocus: true,
                        style: zuniaMono(fontSize: 13.5, color: s.fg),
                        cursorColor: s.accent,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.go,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          filled: false,
                          hintText: 'Search or enter address',
                          hintStyle: zuniaSans(fontSize: 13.5, color: s.fgDim),
                        ),
                        onTap: () => controller.selection =
                            TextSelection(baseOffset: 0, extentOffset: controller.text.length),
                        onSubmitted: onSubmit,
                      )
                    : Semantics(
                        button: true,
                        label: 'Address: $host. Tap to edit.',
                        excludeSemantics: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            focus.requestFocus();
                            controller.selection =
                                TextSelection(baseOffset: 0, extentOffset: controller.text.length);
                          },
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment:
                                cupertino ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                            children: [
                              Text(
                                host.isEmpty ? 'Search or enter address' : host,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: zuniaSans(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: suspicious ? s.dangerFg : s.fg,
                                ),
                              ),
                              if (!cupertino && title.isNotEmpty)
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: zuniaSans(fontSize: 11, color: s.fgDim),
                                ),
                            ],
                          ),
                        ),
                      ),
              ),
              if (!editing && !cupertino && connectedChains.isNotEmpty)
                _ConnectionChip(count: connectedChains.length, onTap: onConnection),
              if (!editing)
                IconButton(
                  tooltip: loading ? 'Stop loading' : 'Reload',
                  visualDensity: VisualDensity.compact,
                  onPressed: onReload,
                  icon: Icon(loading ? Icons.close_rounded : Icons.refresh_rounded, size: 19, color: s.fg),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      button: true,
      label: 'Connected on $count network${count == 1 ? '' : 's'}. Manage connection.',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: s.successFill,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: s.successLine),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: s.success)),
              const SizedBox(width: 5),
              Text('$count', style: zuniaMono(fontSize: 11, color: s.successFg)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.canBack,
    required this.canForward,
    required this.bookmarked,
    required this.onBack,
    required this.onForward,
    required this.onShare,
    required this.onBookmarks,
    required this.onMore,
  });

  final bool canBack;
  final bool canForward;
  final bool bookmarked;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onShare;
  final VoidCallback onBookmarks;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    Widget button(IconData icon, String label, VoidCallback? onTap) => IconButton(
          tooltip: label,
          onPressed: onTap,
          icon: Icon(icon, size: 24, color: onTap == null ? s.fgFaint : s.accent),
        );
    return SizedBox(
      height: 48,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          button(cupertino ? Icons.arrow_back_ios_new_rounded : Icons.arrow_back_rounded, 'Back',
              canBack ? onBack : null),
          button(cupertino ? Icons.arrow_forward_ios_rounded : Icons.arrow_forward_rounded, 'Forward',
              canForward ? onForward : null),
          button(cupertino ? Icons.ios_share_rounded : Icons.share_outlined, 'Share', onShare),
          button(bookmarked ? Icons.bookmark_rounded : Icons.bookmark_border_rounded, 'Bookmarks and history',
              onBookmarks),
          button(cupertino ? Icons.more_horiz_rounded : Icons.more_vert_rounded, 'More', onMore),
        ],
      ),
    );
  }
}

/// The current site's connection: its chains, each removable, and the site.
class _ConnectionSheet extends ConsumerWidget {
  const _ConnectionSheet({
    required this.origin,
    required this.onDisconnectSite,
    required this.onManage,
  });

  final String origin;
  final VoidCallback onDisconnectSite;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final grants = ref.watch(siteGrantsProvider);
    final grant = grants.valueOrNull?.where((g) => g.origin == origin).firstOrNull;
    final now = DateTime.now();
    final chains = grant?.activeChainIds(now) ?? const <String>[];
    String name(String id) => (ChainCatalog.isLoaded ? ChainCatalog.instance.find(id)?.chainName : null) ?? id;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          chains.isEmpty
              ? 'This site is not connected.'
              : 'This site can see your address on these networks.',
          style: zuniaSans(fontSize: 13, height: 1.45, color: s.fgMuted),
        ),
        const SizedBox(height: 10),
        for (final id in chains)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name(id), style: zuniaSans(fontSize: 14, color: s.fg)),
                      if (grant!.chains[id]?.address != null)
                        Text(
                          grant.chains[id]!.address!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaMono(fontSize: 10.5, color: s.fgDim),
                        ),
                    ],
                  ),
                ),
                Text('expires ${timeUntil(grant.chains[id]!.expiresAt)}',
                    style: zuniaSans(fontSize: 11, color: s.fgDim)),
                IconButton(
                  tooltip: 'Disconnect ${name(id)}',
                  onPressed: () => ref.read(siteGrantStoreProvider).revokeChain(origin, id),
                  icon: Icon(Icons.link_off_rounded, size: 19, color: s.fgMuted),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        ZuniaListSection(
          children: [
            ZuniaListTile(
              leading: Icons.tune_rounded,
              title: 'Connected sites',
              navigates: true,
              onTap: onManage,
            ),
            if (chains.isNotEmpty)
              ZuniaListTile(
                leading: Icons.link_off_rounded,
                title: 'Disconnect this site',
                destructive: true,
                onTap: onDisconnectSite,
              ),
          ],
        ),
      ],
    );
  }
}

/// Saved pages and recent ones; picking one pops with its URL.
class _BookmarksSheet extends StatefulWidget {
  const _BookmarksSheet();

  @override
  State<_BookmarksSheet> createState() => _BookmarksSheetState();
}

class _BookmarksSheetState extends State<_BookmarksSheet> {
  String _tab = 'bookmarks';
  List<BrowserBookmark>? _bookmarks;
  List<BrowserBookmark>? _recents;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bookmarks = await DappBrowserStore.instance.bookmarks();
    final recents = await DappBrowserStore.instance.recents();
    if (!mounted) return;
    setState(() {
      _bookmarks = bookmarks;
      _recents = recents;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final rows = _tab == 'bookmarks' ? _bookmarks : _recents;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZuniaSegmented<String>(
          options: const {'bookmarks': 'Bookmarks', 'history': 'History'},
          value: _tab,
          onChanged: (v) => setState(() => _tab = v),
        ),
        const SizedBox(height: 10),
        if (rows == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Column(children: [ZuniaSkeleton(width: 220), SizedBox(height: 12), ZuniaSkeleton(width: 160)]),
          )
        else if (rows.isEmpty)
          ZuniaEmptyState(
            title: _tab == 'bookmarks' ? 'No bookmarks yet' : 'No history yet',
            description: _tab == 'bookmarks'
                ? 'Save a page from the browser menu to find it here.'
                : 'Secure pages you open in Zunia appear here. They stay on this device.',
          )
        else
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final row in rows)
                  Dismissible(
                    key: ValueKey('${_tab}_${row.url}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 16),
                      color: s.dangerFill,
                      child: Icon(Icons.delete_outline_rounded, color: s.danger),
                    ),
                    onDismissed: (_) async {
                      if (_tab == 'bookmarks') {
                        await DappBrowserStore.instance.removeBookmark(row.url);
                      } else {
                        await DappBrowserStore.instance.removeRecent(row.url);
                      }
                      await _load();
                    },
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        _tab == 'bookmarks' ? Icons.bookmark_outline_rounded : Icons.history_rounded,
                        color: s.fgMuted,
                      ),
                      title: Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: zuniaSans(fontSize: 14, color: s.fg)),
                      subtitle: Text(row.host, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: zuniaMono(fontSize: 11, color: s.fgDim)),
                      onTap: () => Navigator.of(context).pop(row.url),
                    ),
                  ),
              ],
            ),
          ),
        if (_tab == 'history' && (rows?.isNotEmpty ?? false))
          TextButton(
            onPressed: () async {
              await DappBrowserStore.instance.clearRecents();
              await _load();
            },
            child: Text('Clear history', style: zuniaSans(fontSize: 13, color: s.danger)),
          ),
      ],
    );
  }
}
