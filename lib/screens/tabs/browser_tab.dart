import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/browser/dapp_browser_store.dart';
import 'package:zunia_mobile/screens/dapp_browser_screen.dart';
import 'package:zunia_mobile/screens/dapp_connect_sheet.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/qr_scanner_screen.dart';
import 'package:zunia_mobile/widgets/wallet_header.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Ecosystem catalog + entry into the in-app wallet browser.
class BrowserTab extends ConsumerStatefulWidget {
  const BrowserTab({super.key});

  @override
  ConsumerState<BrowserTab> createState() => _BrowserTabState();
}

class _BrowserTabState extends ConsumerState<BrowserTab> {
  static const _apps = <({
    String name,
    String category,
    String url,
    String meta,
  })>[
    (
      name: 'Osmosis',
      category: 'DeFi',
      url: 'https://app.osmosis.zone',
      meta: 'DEX · osmosis-1',
    ),
    (
      name: 'Astroport',
      category: 'DeFi',
      url: 'https://app.astroport.fi',
      meta: 'DEX · neutron-1',
    ),
    (
      name: 'Mars Protocol',
      category: 'DeFi',
      url: 'https://app.marsprotocol.io',
      meta: 'Lending',
    ),
    (
      name: 'Stride',
      category: 'DeFi',
      url: 'https://app.stride.zone',
      meta: 'Liquid staking',
    ),
    (
      name: 'Skip',
      category: 'Bridge',
      url: 'https://go.skip.build',
      meta: 'IBC bridge',
    ),
    (
      name: 'Mintscan',
      category: 'Tools',
      url: 'https://www.mintscan.io',
      meta: 'Explorer',
    ),
  ];

  static const _categories = ['All', 'DeFi', 'Bridge', 'Tools'];

  final _search = TextEditingController();
  String _query = '';
  String _category = 'All';
  List<BrowserBookmark> _recents = const [];
  List<BrowserBookmark> _favorites = const [];

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
    final favorites = await DappBrowserStore.instance.favorites();
    if (!mounted) return;
    setState(() {
      _recents = recents;
      _favorites = favorites;
    });
  }

  Future<void> _open(String url, {String? title}) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    await DappBrowserScreen.open(context, url: trimmed, title: title);
    if (mounted) await _loadLists();
  }

  Future<void> _openQuery() => _open(_query);

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final rows = _apps
        .where((a) {
          final catOk = _category == 'All' || a.category == _category;
          final q = _query.toLowerCase();
          final queryOk = q.isEmpty ||
              a.name.toLowerCase().contains(q) ||
              a.category.toLowerCase().contains(q) ||
              a.meta.toLowerCase().contains(q);
          return catOk && queryOk;
        })
        .toList();
    final featured = _apps.first;
    final showUrlHint = _query.contains('.') || _query.startsWith('http');

    return DecoratedBox(
      decoration: BoxDecoration(gradient: s.screenGradient),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WalletHeader(
            onOpenNetworks: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NetworksScreen()),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
              children: [
                Row(
                  children: [
                    Text(
                      'Browser',
                      style: zuniaSans(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.3,
                        color: s.fg,
                      ),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 168,
                      child: ZuniaSearchField(
                        controller: _search,
                        hintText: 'Search or URL',
                        textInputAction: TextInputAction.go,
                        onChanged: (v) => setState(() => _query = v),
                        onSubmitted: (_) => _openQuery(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        s.accent.withValues(alpha: 0.4),
                        s.info.withValues(alpha: 0.22),
                        s.glass,
                      ],
                      stops: const [0, 0.58, 1],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'WALLET BROWSER',
                        style: zuniaMono(
                          fontSize: 9.5,
                          letterSpacing: 1.3,
                          color: s.fgMuted,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Open a dApp inside Zunia. Connect with one tap. Keys never leave the wallet.',
                        style: zuniaSans(
                          fontSize: 13.5,
                          height: 1.35,
                          color: s.fg,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(11),
                              gradient: s.accentGradient,
                            ),
                            child: Text(
                              featured.name.characters.first.toUpperCase(),
                              style: zuniaMono(
                                fontSize: 12,
                                color: s.accentFg,
                              ),
                            ),
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  featured.name,
                                  style: zuniaSans(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: s.fg,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  featured.meta,
                                  style: zuniaMono(
                                    fontSize: 10,
                                    color: s.fgMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => _open(
                                featured.url,
                                title: featured.name,
                              ),
                              borderRadius: BorderRadius.circular(999),
                              child: Ink(
                                decoration: BoxDecoration(
                                  gradient: s.accentGradient,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 9,
                                ),
                                child: Text(
                                  'Open',
                                  style: zuniaMono(
                                    fontSize: 10.5,
                                    color: s.accentFg,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final cat in _categories) ...[
                        GestureDetector(
                          onTap: () => setState(() => _category = cat),
                          child: Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              gradient:
                                  _category == cat ? s.accentGradient : null,
                              color: _category == cat ? null : s.glass,
                            ),
                            child: Text(
                              cat.toUpperCase(),
                              style: zuniaMono(
                                fontSize: 10,
                                color: _category == cat
                                    ? s.accentFg
                                    : s.fgMuted,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                ZuniaButton(
                  label: 'Pair with WalletConnect',
                  variant: ZuniaButtonVariant.secondary,
                  leading: const Icon(Icons.qr_code_scanner),
                  onPressed: () async {
                    final uri = await Navigator.of(context).push<String>(
                      MaterialPageRoute(
                        builder: (_) => const QrScannerScreen(),
                      ),
                    );
                    if (!context.mounted || uri == null || uri.isEmpty) return;
                    await showDappConnectSheet(context, uri: uri);
                  },
                ),
                if (_favorites.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    'Favorites',
                    style: zuniaSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: s.fgMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final b in _favorites.take(6))
                    _AppRow(
                      name: b.title,
                      meta: Uri.tryParse(b.url)?.host ?? b.url,
                      onTap: () => _open(b.url, title: b.title),
                    ),
                ],
                if (_recents.isNotEmpty && _query.isEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    'Recent',
                    style: zuniaSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: s.fgMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final b in _recents.take(5))
                    _AppRow(
                      name: b.title,
                      meta: Uri.tryParse(b.url)?.host ?? b.url,
                      onTap: () => _open(b.url, title: b.title),
                    ),
                ],
                const SizedBox(height: 14),
                if (showUrlHint)
                  _AppRow(
                    name: normalizeBrowserUrl(_query.trim()),
                    meta: 'Opens inside Zunia',
                    accentAction: true,
                    onTap: _openQuery,
                  )
                else
                  for (final app in rows)
                    if (!(app.name == featured.name &&
                        _category == 'All' &&
                        _query.isEmpty))
                      _AppRow(
                        name: app.name,
                        meta: '${app.meta} · ${app.category}',
                        raised: app.name == featured.name,
                        onTap: () => _open(app.url, title: app.name),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.name,
    required this.meta,
    required this.onTap,
    this.raised = false,
    this.accentAction = false,
  });

  final String name;
  final String meta;
  final VoidCallback onTap;
  final bool raised;
  final bool accentAction;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(13),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              gradient: raised || accentAction ? s.surfaceRaisedGradient : null,
              border: accentAction
                  ? Border.all(color: s.accent.withValues(alpha: 0.45))
                  : null,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: s.glass2,
                    ),
                    child: Icon(
                      accentAction
                          ? Icons.language_rounded
                          : Icons.apps_rounded,
                      size: 15,
                      color: accentAction ? s.accent : s.fg,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: s.fg,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          meta,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaMono(fontSize: 9.5, color: s.fgMuted),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    accentAction ? 'Open' : 'Open',
                    style: zuniaMono(
                      fontSize: 9.5,
                      color: accentAction ? s.accent : s.fgMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
