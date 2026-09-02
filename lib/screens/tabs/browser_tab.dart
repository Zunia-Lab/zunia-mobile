import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/dapp_connect_sheet.dart';
import 'package:zunia_mobile/screens/qr_scanner_screen.dart';
import 'package:zunia_mobile/widgets/wallet_header.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// dApp launcher. Sites open in the system browser and pair back over
/// WalletConnect, so no in-app webview ever sees the keys.
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
      name: 'Mintscan',
      category: 'Tools',
      url: 'https://www.mintscan.io',
      meta: 'Explorer',
    ),
    (
      name: 'IBC transfer',
      category: 'Bridge',
      url: 'https://go.skip.build',
      meta: 'Bridge',
    ),
  ];

  static const _categories = ['All', 'DeFi', 'Bridge', 'Tools'];

  final _search = TextEditingController();
  String _query = '';
  String _category = 'All';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _launch(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }

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
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
              children: [
                Row(
                  children: [
                    Text(
                      'Ecosystem',
                      style: zuniaSans(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.3,
                        color: s.fg,
                      ),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 148,
                      child: ZuniaSearchField(
                        controller: _search,
                        hintText: 'Search',
                        onChanged: (v) => setState(() => _query = v),
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
                        'FEATURED PROJECT',
                        style: zuniaMono(
                          fontSize: 9.5,
                          letterSpacing: 1.3,
                          color: s.fgMuted,
                        ),
                      ),
                      const SizedBox(height: 10),
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
                              onTap: () => _launch(featured.url),
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
                              gradient: _category == cat
                                  ? s.accentGradient
                                  : null,
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
                const SizedBox(height: 14),
                if (_query.startsWith('http'))
                  _AppRow(
                    name: _query,
                    meta: 'Open in browser',
                    onTap: () => _launch(_query),
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
                        onTap: () => _launch(app.url),
                      ),
                const SizedBox(height: 12),
                const ZuniaCallout(
                  tone: ZuniaCalloutTone.info,
                  title: 'Sites open outside the wallet',
                  body:
                      'Zunia has no in-app webview. dApps run in your system '
                      'browser and request signatures over WalletConnect, which '
                      'you approve here.',
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
  });

  final String name;
  final String meta;
  final VoidCallback onTap;
  final bool raised;

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
              gradient: raised ? s.surfaceRaisedGradient : null,
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
                    child: Text(
                      name.characters.first.toUpperCase(),
                      style: zuniaMono(fontSize: 11, color: s.fg),
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
                    'Open',
                    style: zuniaMono(fontSize: 9.5, color: s.fgMuted),
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
