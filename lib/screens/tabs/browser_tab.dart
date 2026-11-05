import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/browser/browser_favicon.dart';
import 'package:zunia_mobile/browser/curated_dapps.dart';
import 'package:zunia_mobile/browser/dapp_browser_store.dart';
import 'package:zunia_mobile/browser/site_grants.dart';
import 'package:zunia_mobile/screens/connected_sites_screen.dart';
import 'package:zunia_mobile/screens/dapp_browser_screen.dart';
import 'package:zunia_mobile/screens/native_request_sheets.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/qr_scanner_screen.dart';
import 'package:zunia_mobile/widgets/wallet_header.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Browser home: an address field, the user's favorites, the default dApps as
/// square tiles, and recent pages. Defaults come from `assets/browser/dapps.json`.
class BrowserTab extends ConsumerStatefulWidget {
  const BrowserTab({super.key, this.asPage = false});

  /// Opened from the menu as a page: a back control and a title instead of
  /// the account header the root tabs carry.
  final bool asPage;

  @override
  ConsumerState<BrowserTab> createState() => _BrowserTabState();
}

class _BrowserTabState extends ConsumerState<BrowserTab> {
  final _search = TextEditingController();
  String _query = '';
  List<BrowserBookmark> _recents = const [];
  List<BrowserBookmark> _bookmarks = const [];

  @override
  void initState() {
    super.initState();
    _loadLists();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadLists() async {
    final recents = await DappBrowserStore.instance.recents();
    final bookmarks = await DappBrowserStore.instance.bookmarks();
    if (!mounted) return;
    setState(() {
      _recents = recents;
      _bookmarks = bookmarks;
    });
  }

  Future<void> _refresh() async {
    ref.invalidate(curatedDappsProvider);
    ref.invalidate(siteGrantsProvider);
    await _loadLists();
  }

  Future<void> _open(String url, {String? title}) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    FocusScope.of(context).unfocus();
    await DappBrowserScreen.open(context, url: trimmed, title: title);
    if (mounted) await _loadLists();
  }

  bool get _looksLikeAddress {
    final q = _query.trim();
    return q.startsWith('http://') || q.startsWith('https://') || (q.contains('.') && !q.contains(' '));
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (!mounted || code == null || code.isEmpty) return;
    await handleScannedCode(context, ref, code);
  }

  /// Host plus path, so https://x.com and https://x.com/ count as one site.
  String _key(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return url;
    final path = u.path == '/' ? '' : u.path;
    return '${u.host.toLowerCase()}$path';
  }

  Future<void> _toggleFavorite({required String url, required String title, String? iconUrl}) async {
    ZuniaHaptics.selection();
    final existing = _bookmarks.where((b) => _key(b.url) == _key(url)).firstOrNull;
    if (existing != null) {
      await DappBrowserStore.instance.removeBookmark(existing.url);
    } else {
      await DappBrowserStore.instance.toggleBookmark(url: url, title: title, iconUrl: iconUrl);
    }
    await _loadLists();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final curated = ref.watch(curatedDappsProvider);
    final connected = ref.watch(siteGrantsProvider).valueOrNull?.length ?? 0;
    final defaults = curated.valueOrNull?.dapps ?? const <CuratedDapp>[];
    final defaultKeys = {for (final d in defaults) _key(d.url)};
    final q = _query.trim().toLowerCase();
    bool hit(String title, String host) =>
        q.isEmpty || title.toLowerCase().contains(q) || host.toLowerCase().contains(q);

    final favorites = [
      for (final b in _bookmarks)
        if (!defaultKeys.contains(_key(b.url)) && hit(b.title, b.host)) b,
    ];
    final tiles = <Widget>[
      for (final d in defaults)
        if (d.matches(_query))
          _Tile(
            title: d.name,
            host: d.host,
            asset: d.icon,
            starred: _bookmarks.any((b) => _key(b.url) == _key(d.url)),
            onTap: () => _open(d.url, title: d.name),
            onLongPress: () => _toggleFavorite(url: d.url, title: d.name),
          ),
    ];
    final recents = [
      for (final b in _recents.take(12))
        if (hit(b.title, b.host)) b,
    ];

    final page = ZuniaBackdrop(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.asPage)
            const _PageHeader(title: 'Browser')
          else
            WalletHeader(
              onOpenNetworks: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NetworksScreen()),
              ),
            ),
          Expanded(
            child: ZuniaRefresh(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      'Browser',
                      style: zuniaSans(fontSize: 22, fontWeight: FontWeight.w500, letterSpacing: -0.5, color: s.fg),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ZuniaSearchField(
                    controller: _search,
                    hintText: 'Search or enter an address',
                    textInputAction: TextInputAction.go,
                    onChanged: (v) => setState(() => _query = v),
                    onSubmitted: (v) => _open(v),
                  ),
                  if (_query.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _OpenRow(
                      icon: _looksLikeAddress ? Icons.language_rounded : Icons.search_rounded,
                      title: _looksLikeAddress ? normalizeBrowserUrl(_query) : 'Search the web for "${_query.trim()}"',
                      onTap: () => _open(_query),
                    ),
                  ],
                  if (favorites.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    const _SectionTitle('Favorites'),
                    _Grid(children: [
                      for (final b in favorites)
                        _Tile(
                          title: b.title,
                          host: b.host,
                          iconUrl: b.iconUrl,
                          starred: true,
                          onTap: () => _open(b.url, title: b.title),
                          onLongPress: () => _toggleFavorite(url: b.url, title: b.title),
                        ),
                    ]),
                  ],
                  if (tiles.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    _Grid(children: tiles),
                  ] else if (curated.isLoading) ...[
                    const SizedBox(height: 22),
                    _Grid(children: [
                      for (var i = 0; i < 4; i++) const ZuniaSkeleton(width: 60, height: 60),
                    ]),
                  ],
                  if (recents.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    _SectionTitle(
                      'Recent',
                      action: q.isNotEmpty
                          ? null
                          : TextButton(
                              onPressed: () async {
                                await DappBrowserStore.instance.clearRecents();
                                await _loadLists();
                              },
                              child: Text('Clear', style: zuniaSans(fontSize: 13, color: s.fgMuted)),
                            ),
                    ),
                    for (final b in recents)
                      _RecentRow(
                        entry: b,
                        starred: _bookmarks.any((f) => _key(f.url) == _key(b.url)),
                        onTap: () => _open(b.url, title: b.title),
                        onToggleStar: () => _toggleFavorite(url: b.url, title: b.title, iconUrl: b.iconUrl),
                      ),
                  ],
                  const SizedBox(height: 22),
                  ZuniaListSection(
                    children: [
                      ZuniaListTile(
                        leading: Icons.link_rounded,
                        title: 'Connected sites',
                        value: connected == 0 ? 'None' : '$connected',
                        navigates: true,
                        onTap: () => ConnectedSitesScreen.open(context),
                      ),
                      ZuniaListTile(
                        leading: Icons.qr_code_scanner_rounded,
                        title: 'Scan a connect code',
                        navigates: true,
                        onTap: _scan,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (!widget.asPage) return page;
    return Scaffold(
      backgroundColor: zuniaGroundTop(context),
      body: SafeArea(bottom: false, child: page),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(text, style: zuniaSans(fontSize: 15, fontWeight: FontWeight.w500, color: s.fg)),
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

/// Four equal columns of square tiles.
class _Grid extends StatelessWidget {
  const _Grid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 12.0;
        final w = (c.maxWidth - gap * 3) / 4;
        return Wrap(
          spacing: gap,
          runSpacing: 16,
          children: [for (final child in children) SizedBox(width: w, child: child)],
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.title,
    required this.host,
    required this.onTap,
    required this.onLongPress,
    this.asset,
    this.iconUrl,
    this.starred = false,
  });

  final String title;
  final String host;
  final String? asset;
  final String? iconUrl;
  final bool starred;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      button: true,
      label: '$title. ${starred ? 'Favorite. ' : ''}Long press to ${starred ? 'remove from' : 'add to'} favorites.',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: () {
          ZuniaHaptics.light();
          onLongPress();
        },
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LayoutBuilder(
              builder: (context, c) => Stack(
                clipBehavior: Clip.none,
                children: [
                  BrowserFavicon(host: host, asset: asset, iconUrl: iconUrl, size: c.maxWidth, radius: c.maxWidth * 0.28),
                  if (starred)
                    Positioned(
                      right: -3,
                      top: -3,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(shape: BoxShape.circle, color: s.surfaceRaised, border: Border.all(color: s.line)),
                        child: Icon(Icons.star_rounded, size: 12, color: s.accent),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: zuniaSans(fontSize: 12, color: s.fg),
            ),
          ],
        ),
      ),
    );
  }
}

class _OpenRow extends StatelessWidget {
  const _OpenRow({required this.icon, required this.title, required this.onTap});

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      button: true,
      label: title,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: s.glass,
              border: Border.all(color: s.accent.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: s.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: zuniaSans(fontSize: 14, fontWeight: FontWeight.w500, color: s.fg)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.entry, required this.starred, required this.onTap, required this.onToggleStar});

  final BrowserBookmark entry;
  final bool starred;
  final VoidCallback onTap;
  final VoidCallback onToggleStar;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: s.glass,
              border: Border.all(color: s.line),
            ),
            child: Row(
              children: [
                BrowserFavicon(host: entry.host, iconUrl: entry.iconUrl, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: zuniaSans(fontSize: 14, fontWeight: FontWeight.w500, color: s.fg)),
                      const SizedBox(height: 2),
                      Text(entry.host, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: zuniaMono(fontSize: 11, color: s.fgDim)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: starred ? 'Remove from favorites' : 'Add to favorites',
                  onPressed: onToggleStar,
                  icon: Icon(starred ? Icons.star_rounded : Icons.star_border_rounded,
                      size: 22, color: starred ? s.accent : s.fgMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A pushed page's header: the platform's back control and a title.
class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 16, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(
              cupertino ? Icons.arrow_back_ios_new_rounded : Icons.arrow_back,
              size: cupertino ? 20 : 22,
              color: s.fg,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              title,
              style: zuniaSans(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.4,
                color: s.fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
