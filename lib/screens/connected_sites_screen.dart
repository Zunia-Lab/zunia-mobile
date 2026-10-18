/// Sites the in-app browser connected, per site and per chain
/// (extension 0.1.5's Connected dApps screen): when each was last used, the
/// address each chain handed over, when each chain lapses, and a lookalike flag
/// for a site whose address imitates a well-known one. Disconnect a chain, a
/// site or all of them; an open page is told at once and has to ask again.
///
/// [ConnectedSitesView] is the list alone, for Settings or the Connected apps
/// screen to embed; [SigningSettingsSection] holds the two signing switches.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/browser/origin_risk.dart';
import 'package:zunia_mobile/browser/site_grants.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/sign_in.dart';
import 'package:zunia_mobile/state/signing_settings.dart';
import 'package:zunia_ui/zunia_ui.dart';

class ConnectedSitesScreen extends ConsumerWidget {
  const ConnectedSitesScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ConnectedSitesScreen()),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ZuniaLargeTitleScaffold(
      title: 'Connected sites',
      onRefresh: () async => ref.invalidate(siteGrantsProvider),
      slivers: const [
        SliverToBoxAdapter(child: ConnectedSitesView()),
        SliverToBoxAdapter(child: SigningSettingsSection()),
      ],
    );
  }
}

String _hostOf(String origin) => webHost(origin) ?? origin.replaceFirst(RegExp(r'^[a-z]+://'), '');

String _chainName(String chainId) =>
    (ChainCatalog.isLoaded ? ChainCatalog.instance.find(chainId)?.chainName : null) ?? chainId;

String _short(String address) =>
    address.length <= 18 ? address : '${address.substring(0, 10)}…${address.substring(address.length - 6)}';

/// "5 min ago", "3 h ago", "2 days ago".
String relativeTime(DateTime at, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(at);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes} min ago';
  if (diff.inDays < 1) return '${diff.inHours} h ago';
  return diff.inDays == 1 ? 'yesterday' : '${diff.inDays} days ago';
}

/// "in 6 days", "in 3 h", "in 12 min".
String timeUntil(DateTime at, {DateTime? now}) {
  final diff = at.difference(now ?? DateTime.now());
  if (diff.inMinutes < 1) return 'in less than a minute';
  if (diff.inHours < 1) return 'in ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'in ${diff.inHours} h';
  // Rounded: a grant made a moment ago lasts "7 days", not "6 days".
  final days = (diff.inMinutes / (24 * 60)).round();
  return days == 1 ? 'in 1 day' : 'in $days days';
}

/// The live grants as cards, with search and "Disconnect all".
class ConnectedSitesView extends ConsumerStatefulWidget {
  const ConnectedSitesView({super.key, this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 8)});

  final EdgeInsets padding;

  @override
  ConsumerState<ConnectedSitesView> createState() => _ConnectedSitesViewState();
}

class _ConnectedSitesViewState extends ConsumerState<ConnectedSitesView> {
  final _search = TextEditingController();
  String _query = '';
  String? _busy;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _run(String key, Future<void> Function() task, String done) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = key);
    try {
      await task();
      ZuniaHaptics.success();
      messenger?.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      ZuniaHaptics.error();
      messenger?.showSnackBar(SnackBar(content: Text('Could not disconnect: $e')));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _revokeAll(int count) async {
    final ok = await showZuniaConfirm(
      context,
      title: 'Disconnect all $count site${count == 1 ? '' : 's'}?',
      message: 'Each one has to ask again before it can see an address.',
      confirmLabel: 'Disconnect all',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final store = ref.read(siteGrantStoreProvider);
    await _run('all', () => store.revokeAll(), 'Every site disconnected');
  }

  bool _matches(SiteGrant grant, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return grant.origin.toLowerCase().contains(q) ||
        grant.chains.values.any(
          (c) =>
              c.chainId.toLowerCase().contains(q) ||
              _chainName(c.chainId).toLowerCase().contains(q) ||
              (c.address?.contains(q) ?? false),
        );
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final grants = ref.watch(siteGrantsProvider);
    final store = ref.read(siteGrantStoreProvider);

    return Padding(
      padding: widget.padding,
      child: grants.when(
        loading: () => Column(
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ZuniaCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      ZuniaSkeleton(width: 140, height: 12),
                      SizedBox(height: 10),
                      ZuniaSkeleton(width: 200),
                      SizedBox(height: 8),
                      ZuniaSkeleton(width: 90),
                    ],
                  ),
                ),
              ),
          ],
        ),
        error: (e, _) => ZuniaEmptyState(
          title: 'Connected sites could not be read',
          description: '$e',
        ),
        data: (list) {
          final shown = list.where((g) => _matches(g, _query)).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Each site sees only the networks it asked for and the address shown next to '
                'each, for 7 days after you approved it. Disconnect a network or the whole site '
                'anytime; an open page is told at once and has to ask again.',
                style: zuniaSans(fontSize: 13, height: 1.5, color: s.fgMuted),
              ),
              const SizedBox(height: 14),
              if (list.length > 1) ...[
                ZuniaSearchField(
                  controller: _search,
                  hintText: 'Search sites, networks or addresses',
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 12),
              ],
              if (list.isEmpty)
                const ZuniaEmptyState(
                  title: 'No connected sites',
                  description: 'Sites you connect in the Discover browser are listed here with the '
                      'networks they can see.',
                )
              else if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'No site matches "${_query.trim()}".',
                    textAlign: TextAlign.center,
                    style: zuniaSans(fontSize: 13, color: s.fgMuted),
                  ),
                )
              else
                for (final grant in shown) ...[
                  _SiteCard(
                    grant: grant,
                    busy: _busy,
                    onRevokeSite: () => _run(
                      grant.origin,
                      () => store.revokeSite(grant.origin),
                      '${_hostOf(grant.origin)} disconnected',
                    ),
                    onRevokeChain: (chainId) => _run(
                      '${grant.origin}|$chainId',
                      () => store.revokeChain(grant.origin, chainId),
                      '${_chainName(chainId)} removed from ${_hostOf(grant.origin)}',
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              if (list.isNotEmpty)
                ZuniaListSection(
                  children: [
                    ZuniaListTile(
                      leading: Icons.link_off_rounded,
                      title: 'Disconnect all sites',
                      destructive: true,
                      trailing: _busy == 'all' ? const ZuniaActivityIndicator(size: 16) : null,
                      onTap: _busy != null ? null : () => _revokeAll(list.length),
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SiteCard extends StatelessWidget {
  const _SiteCard({
    required this.grant,
    required this.busy,
    required this.onRevokeSite,
    required this.onRevokeChain,
  });

  final SiteGrant grant;
  final String? busy;
  final VoidCallback onRevokeSite;
  final ValueChanged<String> onRevokeChain;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final host = _hostOf(grant.origin);
    final risk = assessOrigin(grant.origin);
    final now = DateTime.now();
    final chains = [
      for (final id in grant.activeChainIds(now)) grant.chains[id]!,
    ];
    final used = grant.lastUsedAt == null ? 'Not used yet' : 'Used ${relativeTime(grant.lastUsedAt!)}';
    final expires = grant.expiresAt == null ? 'no expiry' : 'expires ${timeUntil(grant.expiresAt!)}';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: s.surfaceRaisedGradient,
        border: Border.all(color: risk.suspicious ? s.dangerLine : s.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: risk.suspicious ? s.dangerLine : s.line),
                ),
                child: Icon(
                  risk.suspicious ? Icons.gpp_maybe_rounded : Icons.language_rounded,
                  size: 18,
                  color: risk.suspicious ? s.danger : s.fgMuted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      host,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaSans(fontSize: 14.5, fontWeight: FontWeight.w500, color: s.fg),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      grant.origin,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaMono(fontSize: 10.5, color: risk.suspicious ? s.dangerFg : s.fgDim),
                    ),
                    const SizedBox(height: 2),
                    Text('$used · $expires', style: zuniaSans(fontSize: 12, color: s.fgMuted)),
                  ],
                ),
              ),
              TextButton(
                onPressed: busy != null ? null : onRevokeSite,
                child: busy == grant.origin
                    ? const ZuniaActivityIndicator(size: 16)
                    : Text('Disconnect', style: zuniaSans(fontSize: 13, color: s.danger)),
              ),
            ],
          ),
          if (risk.suspicious) ...[
            const SizedBox(height: 10),
            ZuniaCallout(
              tone: ZuniaCalloutTone.danger,
              title: 'Lookalike address',
              body: risk.warnings.join('\n'),
            ),
          ],
          const SizedBox(height: 8),
          Divider(height: 1, thickness: 0.5, color: s.line),
          for (final chain in chains)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _chainName(chain.chainId),
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(fontSize: 13, color: s.fg),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          chain.address == null ? 'Address not read yet' : _short(chain.address!),
                          semanticsLabel: chain.address ?? 'Address not read yet',
                          style: zuniaMono(fontSize: 10.5, color: s.fgDim),
                        ),
                        Text(
                          'expires ${timeUntil(chain.expiresAt)}',
                          style: zuniaSans(fontSize: 11, color: s.fgDim),
                        ),
                      ],
                    ),
                  ),
                  if (chains.length > 1)
                    IconButton(
                      tooltip: 'Remove ${_chainName(chain.chainId)} from $host',
                      onPressed: busy != null ? null : () => onRevokeChain(chain.chainId),
                      icon: Icon(Icons.close_rounded, size: 18, color: s.fgDim),
                    )
                  else
                    const SizedBox(width: 12),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Blind signing and the Keplr alias: off by default, as in the extension.
class SigningSettingsSection extends ConsumerWidget {
  const SigningSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(signingSettingsProvider);
    final controller = ref.read(signingSettingsProvider.notifier);
    return ZuniaListSection(
      header: 'dApp signing',
      footer: 'With blind signing off, Zunia refuses any request holding a message it cannot '
          'read, and tells the site why.',
      children: [
        ZuniaListTile(
          leading: Icons.visibility_off_outlined,
          title: 'Blind signing',
          subtitle: 'Approve messages Zunia cannot decode',
          trailing: ZuniaAdaptiveSwitch(
            value: settings.blindSigning,
            onChanged: (on) async {
              if (on) {
                final ok = await showZuniaConfirm(
                  context,
                  title: 'Turn on blind signing?',
                  message: 'You will be able to approve transactions Zunia cannot read. Only '
                      'do this for a dApp you trust: the prompt cannot tell you what they do.',
                  confirmLabel: 'Turn on',
                  destructive: true,
                );
                if (!ok) return;
              }
              await controller.setBlindSigning(on);
            },
          ),
        ),
        ZuniaListTile(
          leading: Icons.extension_outlined,
          title: 'Keplr compatibility',
          subtitle: 'Also answer as window.keplr in the browser',
          trailing: ZuniaAdaptiveSwitch(
            value: settings.exposeKeplrAlias,
            onChanged: controller.setExposeKeplrAlias,
          ),
        ),
      ],
    );
  }
}
