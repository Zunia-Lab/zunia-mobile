import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

/// Discover: the curated dApps, the user's bookmarks and recent pages, and the
/// way into the in-app browser. The list comes from `assets/browser/dapps.json`.
class BrowserTab extends ConsumerStatefulWidget {
  const BrowserTab({super.key});

  @override
  ConsumerState<BrowserTab> createState() => _BrowserTabState();
}

class _BrowserTabState extends ConsumerState<BrowserTab> {
  static const _all = 'All';

  final _search = TextEditingController();
  String _query = '';
  String _category = _all;
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

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final curated = ref.watch(curatedDappsProvider);
    final connected = ref.watch(siteGrantsProvider).valueOrNull?.length ?? 0;

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
            child: ZuniaRefresh(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      'Discover',
                      style: zuniaSans(fontSize: 22, fontWeight: FontWeight.w500, letterSpacing: -0.5, color: s.fg),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ZuniaSearchField(
                    controller: _search,
                    hintText: 'Search dApps or enter an address',
                    textInputAction: TextInputAction.go,
                    onChanged: (v) => setState(() => _query = v),
                    onSubmitted: (v) => _open(v),
                  ),
                  if (_query.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _Row(
                      icon: _looksLikeAddress ? Icons.language_rounded : Icons.search_rounded,
                      title: _looksLikeAddress ? normalizeBrowserUrl(_query) : 'Search the web for "${_query.trim()}"',
                      subtitle: 'Opens inside Zunia',
                      accent: true,
                      onTap: () => _open(_query),
                    ),
                  ],
                  const SizedBox(height: 14),
                  ...curated.when(
                    loading: () => [for (var i = 0; i < 4; i++) const _RowSkeleton()],
                    error: (e, _) => [
                      const ZuniaEmptyState(
                        title: 'The dApp list could not be read',
                        description: 'Type an address above to open a site.',
                      ),
                    ],
                    data: (data) => _curated(context, data),
                  ),
                  if (_bookmarks.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _SectionTitle('Bookmarks'),
                    for (final b in _bookmarks.take(6))
                      _Row(
                        icon: Icons.bookmark_outline_rounded,
                        title: b.title,
                        subtitle: b.host,
                        onTap: () => _open(b.url, title: b.title),
                      ),
                  ],
                  if (_recents.isNotEmpty && _query.isEmpty) ...[
                    const SizedBox(height: 18),
                    _SectionTitle(
                      'Recent',
                      action: TextButton(
                        onPressed: () async {
                          await DappBrowserStore.instance.clearRecents();
                          await _loadLists();
                        },
                        child: Text('Clear', style: zuniaSans(fontSize: 13, color: s.fgMuted)),
                      ),
                    ),
                    for (final b in _recents.take(5))
                      _Row(
                        icon: Icons.history_rounded,
                        title: b.title,
                        subtitle: b.host,
                        onTap: () => _open(b.url, title: b.title),
                      ),
                  ],
                  const SizedBox(height: 18),
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
                        subtitle: 'Zunia Connect or WalletConnect',
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
  }

  List<Widget> _curated(BuildContext context, CuratedDapps data) {
    final s = ZuniaSemanticsExt.of(context);
    final featured = data.featured;
    final categories = [_all, ...data.usedCategories];
    final rows = data.dapps
        .where((d) => (_category == _all || d.category == _category) && d.matches(_query))
        .toList();
    return [
      if (featured != null && _query.isEmpty && _category == _all) ...[
        _FeaturedCard(dapp: featured, onOpen: () => _open(featured.url, title: featured.name)),
        const SizedBox(height: 14),
      ],
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final category in categories)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(category),
                  selected: _category == category,
                  showCheckmark: false,
                  labelStyle: zuniaSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _category == category ? s.accentFg : s.fgMuted,
                  ),
                  selectedColor: s.accent,
                  backgroundColor: s.glass,
                  side: BorderSide(color: _category == category ? s.accent : s.line),
                  onSelected: (_) {
                    ZuniaHaptics.selection();
                    setState(() => _category = category);
                  },
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'No dApp in the list matches. Open the address directly above.',
            style: zuniaSans(fontSize: 13, color: s.fgMuted),
          ),
        )
      else
        for (final dapp in rows)
          _Row(
            icon: Icons.apps_rounded,
            title: dapp.name,
            subtitle: '${dapp.description} · ${dapp.host}',
            trailing: dapp.category,
            onTap: () => _open(dapp.url, title: dapp.name),
          ),
    ];
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
      padding: const EdgeInsets.only(bottom: 4),
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
    );
  }
}

class _FeaturedCard extends StatelessWidget {
  const _FeaturedCard({required this.dapp, required this.onOpen});

  final CuratedDapp dapp;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      button: true,
      label: 'Featured: ${dapp.name}. ${dapp.description}. Open.',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(18),
          child: Ink(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: s.heroGradient,
              border: Border.all(color: s.infoLine),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('FEATURED', style: zuniaMono(fontSize: 9.5, letterSpacing: 1.4, color: s.fgMuted)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _Monogram(name: dapp.name, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(dapp.name, style: zuniaSans(fontSize: 16, fontWeight: FontWeight.w500, color: s.fg)),
                          const SizedBox(height: 2),
                          Text(
                            dapp.description,
                            style: zuniaSans(fontSize: 12.5, height: 1.35, color: s.fgMuted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.arrow_forward_rounded, color: s.fg),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Opens inside Zunia. Sites see your address only after you connect, and keys never leave the wallet.',
                  style: zuniaSans(fontSize: 12, height: 1.4, color: s.fgMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Monogram extends StatelessWidget {
  const _Monogram({required this.name, this.size = 34});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(size * 0.3), gradient: s.accentGradient),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: zuniaMono(fontSize: size * 0.36, color: s.accentFg),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.accent = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? trailing;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        button: true,
        label: '$title. $subtitle',
        excludeSemantics: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: s.glass,
                border: Border.all(color: accent ? s.accent.withValues(alpha: 0.5) : s.line),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: s.glass2),
                    child: Icon(icon, size: 18, color: accent ? s.accent : s.fg),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(fontSize: 14, fontWeight: FontWeight.w500, color: s.fg),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(fontSize: 12, height: 1.3, color: s.fgMuted),
                        ),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    Text(trailing!, style: zuniaMono(fontSize: 10, color: s.fgDim)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RowSkeleton extends StatelessWidget {
  const _RowSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          ZuniaSkeleton(width: 34, height: 34),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [ZuniaSkeleton(width: 120, height: 11), SizedBox(height: 8), ZuniaSkeleton(width: 180)],
            ),
          ),
        ],
      ),
    );
  }
}
