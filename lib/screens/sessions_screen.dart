/// Connected apps: every site and app paired over Zunia Connect or
/// WalletConnect, what each can see, and the controls to narrow or end it.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/sign_in.dart';
import 'package:zunia_mobile/connect/wallet_signer.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/pair_device.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// One connected app, whichever protocol it came over.
class ConnectedApp {
  const ConnectedApp({
    required this.id,
    required this.transport,
    required this.name,
    required this.host,
    required this.icons,
    required this.chains,
    required this.requestedChains,
    required this.requiredChains,
    required this.accounts,
    this.description,
    this.verifiedOrigin,
    this.originMismatch = false,
    this.online,
    this.pairedAt,
    this.expiresAt,
    this.sameDevice = false,
    this.returnLabel,
  });

  factory ConnectedApp.native(NativeActiveSession s) => ConnectedApp(
    id: s.sessionId,
    transport: ConnectTransport.zuniaConnect,
    name: s.name,
    host: s.dapp.host,
    icons: s.icons,
    description: s.dapp.metadata.description,
    verifiedOrigin: s.dapp.verifiedOrigin,
    originMismatch: s.dapp.originMismatch,
    chains: s.chains,
    requestedChains: s.requestedChains,
    requiredChains: const [],
    accounts: s.accounts,
    online: s.online,
    pairedAt: s.pairedAt,
    expiresAt: s.expiresAt.millisecondsSinceEpoch == 0 ? null : s.expiresAt,
    sameDevice: s.sameDevice,
    returnLabel: s.returnTarget?.label,
  );

  factory ConnectedApp.walletConnect(WcActiveSession s) {
    final declared = webOrigin(s.url);
    return ConnectedApp(
      id: s.topic,
      transport: ConnectTransport.walletConnect,
      name: s.name,
      host: webHost(s.verifiedOrigin ?? s.url) ?? s.name,
      icons: s.icons,
      description: s.description,
      verifiedOrigin: s.verifiedOrigin,
      originMismatch:
          s.verifiedOrigin != null &&
          declared != null &&
          declared != s.verifiedOrigin,
      chains: s.chains,
      requestedChains: s.requestedChains,
      requiredChains: s.requiredChains,
      accounts: s.accounts,
      pairedAt: s.pairedAt,
      expiresAt: s.expiresAt,
    );
  }

  final String id;
  final ConnectTransport transport;
  final String name;
  final String host;
  final List<String> icons;
  final String? description;
  final String? verifiedOrigin;
  final bool originMismatch;
  final List<String> chains;
  final List<String> requestedChains;
  final List<String> requiredChains;
  final List<NativeConnectAccount> accounts;

  /// The site's side is connected right now (Zunia Connect only).
  final bool? online;
  final DateTime? pairedAt;
  final DateTime? expiresAt;
  final bool sameDevice;
  final String? returnLabel;
}

/// zunia_ui's Cupertino title styles inherit from the text theme while the
/// back label's does not, and the large-title flight between two of these
/// pages asserts on that mismatch. These pages use self-contained styles so
/// the flight can interpolate them.
Widget _flightSafe(BuildContext context, Widget child) {
  final base = CupertinoTheme.of(context);
  final text = base.textTheme;
  return CupertinoTheme(
    data: base.copyWith(
      textTheme: text.copyWith(
        navLargeTitleTextStyle: text.navLargeTitleTextStyle.copyWith(
          inherit: false,
        ),
        navTitleTextStyle: text.navTitleTextStyle.copyWith(inherit: false),
      ),
    ),
    child: child,
  );
}

/// "in 23 h", "in 12 min", "expired".
String expiresIn(DateTime at, DateTime now) {
  final left = at.difference(now);
  if (left.isNegative) return 'expired';
  if (left.inDays >= 2) return 'in ${left.inDays} days';
  if (left.inHours >= 1) return 'in ${left.inHours} h';
  if (left.inMinutes >= 1) return 'in ${left.inMinutes} min';
  return 'in under a minute';
}

String _date(DateTime at) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = at.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${local.day} ${months[local.month - 1]}, $hh:$mm';
}

/// Rebuilds whenever either protocol's sessions change, and every half
/// minute so "expires in" stays true.
mixin _LiveSessions<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  final _subs = <StreamSubscription<void>>[];
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    void refresh(void _) {
      if (mounted) setState(() {});
    }

    _subs
      ..add(ref.read(nativeConnectProvider).changes.listen(refresh))
      ..add(ref.read(walletConnectProvider).changes.listen(refresh));
    _clock = Timer.periodic(const Duration(seconds: 30), (_) => refresh(null));
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _clock?.cancel();
    super.dispose();
  }

  List<ConnectedApp> get apps => [
    for (final s in ref.read(nativeConnectProvider).activeSessions)
      ConnectedApp.native(s),
    for (final s in ref.read(walletConnectProvider).activeSessions)
      ConnectedApp.walletConnect(s),
  ];
}

class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({super.key});

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen>
    with _LiveSessions<SessionsScreen> {
  Future<void> _disconnectAll(int count) async {
    final ok = await showZuniaConfirm(
      context,
      title: 'Disconnect all apps?',
      message:
          'The $count connected app${count == 1 ? '' : 's'} will no longer '
          'see your addresses or ask you to sign. You can pair again any time.',
      confirmLabel: 'Disconnect all',
      destructive: true,
    );
    if (!ok) return;
    unawaited(ZuniaHaptics.warning());
    await ref.read(walletConnectProvider).disconnectAll();
    await ref.read(nativeConnectProvider).disconnectAll();
    if (mounted) setState(() {});
  }

  void _openApp(ConnectedApp app) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ConnectedAppScreen(id: app.id, transport: app.transport),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _flightSafe(context, _list(context));

  Widget _list(BuildContext context) {
    final all = apps;
    final now = DateTime.now();
    final native = [
      for (final a in all)
        if (a.transport == ConnectTransport.zuniaConnect) a,
    ];
    final wc = [
      for (final a in all)
        if (a.transport == ConnectTransport.walletConnect) a,
    ];
    final cupertino = ZuniaPlatform.isCupertino(context);

    return ZuniaLargeTitleScaffold(
      title: 'Connected apps',
      actions: [
        IconButton(
          tooltip: 'Pair a device',
          onPressed: () => unawaited(openPairDevice(context, ref)),
          icon: Icon(
            cupertino
                ? CupertinoIcons.qrcode_viewfinder
                : Icons.qr_code_scanner,
          ),
        ),
      ],
      slivers: [
        if (all.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: ZuniaEmptyState(
                title: 'No connected apps',
                description:
                    'Scan a site’s or an app’s Zunia Connect or '
                    'WalletConnect code to use your wallet with it, even on '
                    'a computer without the extension.',
                action: ZuniaButton(
                  label: 'Pair a device',
                  onPressed: () => unawaited(openPairDevice(context, ref)),
                ),
              ),
            ),
          )
        else ...[
          if (native.isNotEmpty)
            SliverToBoxAdapter(
              child: ZuniaListSection(
                header: 'Zunia Connect',
                children: [
                  for (final app in native)
                    _AppRow(app: app, now: now, onTap: () => _openApp(app)),
                ],
              ),
            ),
          if (wc.isNotEmpty)
            SliverToBoxAdapter(
              child: ZuniaListSection(
                header: 'WalletConnect',
                children: [
                  for (final app in wc)
                    _AppRow(app: app, now: now, onTap: () => _openApp(app)),
                ],
              ),
            ),
          SliverToBoxAdapter(
            child: ZuniaListSection(
              footer:
                  'Connected apps see the addresses listed for them and '
                  'can ask you to sign. Nothing is signed without your '
                  'approval.',
              children: [
                ZuniaListTile(
                  title: 'Disconnect all',
                  leading: Icons.link_off,
                  destructive: true,
                  onTap: () => _disconnectAll(all.length),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.app, required this.now, required this.onTap});

  final ConnectedApp app;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    final expires = app.expiresAt;
    final status = [
      app.host,
      if (app.online != null) app.online! ? 'online' : 'offline',
      if (expires != null) 'expires ${expiresIn(expires, now)}',
    ].join(' · ');
    final row = Padding(
      padding: cupertino
          ? const EdgeInsets.fromLTRB(16, 10, 14, 10)
          : const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: ExcludeSemantics(
        child: Row(
          children: [
            AppIcon(
              name: app.name,
              icons: app.icons,
              size: cupertino ? 32 : 40,
            ),
            SizedBox(width: cupertino ? 12 : 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(
                            fontSize: 16,
                            fontWeight: cupertino
                                ? FontWeight.w400
                                : FontWeight.w500,
                            color: s.fg,
                          ),
                        ),
                      ),
                      if (app.online == true) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: s.success,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: zuniaSans(
                      fontSize: 13,
                      height: 1.3,
                      color: s.fgMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (app.originMismatch)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: s.danger,
                ),
              ),
            if (cupertino)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                  CupertinoIcons.chevron_forward,
                  size: 16,
                  color: s.fgFaint,
                ),
              ),
          ],
        ),
      ),
    );
    return Semantics(
      button: true,
      label: '${app.name}, $status',
      child: cupertino
          ? _PressHighlight(onTap: onTap, child: row)
          : Material(
              type: MaterialType.transparency,
              child: InkWell(onTap: onTap, child: row),
            ),
    );
  }
}

/// iOS table-cell press state: grey while the finger is down, no ripple.
class _PressHighlight extends StatefulWidget {
  const _PressHighlight({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_PressHighlight> createState() => _PressHighlightState();
}

class _PressHighlightState extends State<_PressHighlight> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: Duration(milliseconds: _down ? 0 : 220),
        color: _down ? s.statePress : Colors.transparent,
        child: widget.child,
      ),
    );
  }
}

/// A site's icon, or its initials when it has none or it does not load.
class AppIcon extends StatelessWidget {
  const AppIcon({
    super.key,
    required this.name,
    required this.icons,
    this.size = 36,
  });

  final String name;
  final List<String> icons;
  final double size;

  String get _initials {
    final parts = name
        .split(RegExp(r'[.\-_\s]'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'DA';
    if (parts.length == 1) {
      final first = parts.first;
      return (first.length >= 2 ? first.substring(0, 2) : first).toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final fallback = Center(
      child: Text(
        _initials,
        style: zuniaMono(fontSize: size * 0.3, color: s.fg),
      ),
    );
    final url = icons.isEmpty ? null : icons.first;
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.26),
        color: s.glass2,
        border: Border.all(color: s.line),
      ),
      child: url == null || !url.startsWith('https://')
          ? fallback
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
              frameBuilder: (context, child, frame, sync) =>
                  frame == null && !sync ? fallback : child,
            ),
    );
  }
}

class ConnectedAppScreen extends ConsumerStatefulWidget {
  const ConnectedAppScreen({
    super.key,
    required this.id,
    required this.transport,
  });

  final String id;
  final ConnectTransport transport;

  @override
  ConsumerState<ConnectedAppScreen> createState() => _ConnectedAppScreenState();
}

class _ConnectedAppScreenState extends ConsumerState<ConnectedAppScreen>
    with _LiveSessions<ConnectedAppScreen> {
  String? _busyChain;

  ConnectedApp? get _app {
    for (final app in apps) {
      if (app.id == widget.id && app.transport == widget.transport) return app;
    }
    return null;
  }

  Future<void> _disconnect(ConnectedApp app) async {
    final ok = await showZuniaConfirm(
      context,
      title: 'Disconnect ${app.name}?',
      message:
          '${app.host} will no longer see your addresses or ask you to sign.',
      confirmLabel: 'Disconnect',
      destructive: true,
    );
    if (!ok || !mounted) return;
    unawaited(ZuniaHaptics.warning());
    final navigator = Navigator.of(context);
    try {
      if (app.transport == ConnectTransport.zuniaConnect) {
        await ref.read(nativeConnectProvider).disconnectSession(app.id);
      } else {
        await ref.read(walletConnectProvider).disconnectTopic(app.id);
      }
    } catch (e) {
      debugPrint('disconnect: $e');
    }
    if (mounted) navigator.pop();
  }

  Future<void> _toggle(ConnectedApp app, String chainId, bool on) async {
    final next = [
      for (final c in app.requestedChains)
        if (c == chainId ? on : app.chains.contains(c)) c,
    ];
    final phrase = ref.read(phraseProvider);
    final account = ref.read(walletProvider).active;
    List<NativeConnectAccount> accountsFor(List<String> chainIds) =>
        phrase == null || account == null
        ? const []
        : connectAccountsFor(
            phrase: phrase,
            accountIndex: account.index,
            chainIds: chainIds,
            accountName: account.name,
          );
    setState(() => _busyChain = chainId);
    final messenger = ScaffoldMessenger.of(context);
    // Deriving the account blocks for a moment; let the spinner show first.
    if (on) await Future<void>.delayed(const Duration(milliseconds: 16));
    try {
      if (app.transport == ConnectTransport.zuniaConnect) {
        await ref
            .read(nativeConnectProvider)
            .setSessionChains(app.id, next, accountsFor: accountsFor);
      } else {
        await ref
            .read(walletConnectProvider)
            .setSessionChains(app.id, next, accountsFor: accountsFor);
      }
      final after = _app;
      if (on && after != null && !after.chains.contains(chainId)) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Zunia has no account it can share on $chainId'),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e is ConnectException
                ? e.message
                : 'Could not change the chains: $e',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyChain = null);
    }
  }

  @override
  Widget build(BuildContext context) => _flightSafe(context, _detail(context));

  Widget _detail(BuildContext context) {
    final app = _app;
    if (app == null) {
      // Ended while open (the site disconnected or it expired).
      return ZuniaLargeTitleScaffold(
        title: 'Connected app',
        slivers: const [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: ZuniaEmptyState(
                title: 'No longer connected',
                description: 'This app disconnected or its session expired.',
              ),
            ),
          ),
        ],
      );
    }
    final s = ZuniaSemanticsExt.of(context);
    final now = DateTime.now();
    final expires = app.expiresAt;
    final catalog = ChainCatalog.isLoaded ? ChainCatalog.instance : null;
    final chainCount = app.chains.length;

    return ZuniaLargeTitleScaffold(
      title: app.name,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Row(
              children: [
                AppIcon(name: app.name, icons: app.icons, size: 52),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.host,
                        style: zuniaMono(fontSize: 13, color: s.info),
                      ),
                      if (app.description != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          app.description!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(
                            fontSize: 13,
                            height: 1.4,
                            color: s.fgMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (app.originMismatch)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: ZuniaCallout(
                tone: ZuniaCalloutTone.danger,
                title: 'This site is not where it says',
                body:
                    'The address it was opened from differs from the one it '
                    'claims. Disconnect it unless you opened it yourself.',
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'Connection',
            children: [
              ZuniaListTile(
                title: 'Protocol',
                value: app.transport == ConnectTransport.zuniaConnect
                    ? 'Zunia Connect'
                    : 'WalletConnect v2',
              ),
              if (app.online != null)
                ZuniaListTile(
                  title: 'Site',
                  value: app.online! ? 'Online' : 'Offline',
                ),
              ZuniaListTile(
                title: 'Origin',
                value: app.verifiedOrigin == null
                    ? 'Not confirmed'
                    : app.originMismatch
                    ? 'Mismatch'
                    : 'Verified',
              ),
              if (app.pairedAt != null)
                ZuniaListTile(title: 'Paired', value: _date(app.pairedAt!)),
              if (expires != null)
                ZuniaListTile(title: 'Expires', value: expiresIn(expires, now)),
              if (app.transport == ConnectTransport.zuniaConnect)
                ZuniaListTile(
                  title: 'Paired from',
                  value: app.sameDevice ? 'This phone' : 'A scanned code',
                ),
              if (app.returnLabel != null)
                ZuniaListTile(title: 'Returns to', value: app.returnLabel),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: ZuniaListSection(
            header: 'Chains and addresses',
            footer:
                'A chain turned off is hidden from ${app.host}: it no '
                'longer sees that address and cannot ask for signatures on it.',
            children: [
              for (final chainId in app.requestedChains)
                _ChainRow(
                  chainName: catalog?.find(chainId)?.chainName ?? chainId,
                  chainId: chainId,
                  address: [
                    for (final a in app.accounts)
                      if (a.chainId == chainId) a.address,
                  ].firstOrNull,
                  on: app.chains.contains(chainId),
                  busy: _busyChain == chainId,
                  locked: app.requiredChains.contains(chainId)
                      ? 'Required by ${app.name}'
                      : (app.chains.contains(chainId) && chainCount == 1)
                      ? 'Last chain'
                      : catalog != null && catalog.find(chainId) == null
                      ? 'Not supported'
                      : null,
                  onChanged: (on) => _toggle(app, chainId, on),
                ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: ZuniaListSection(
            children: [
              ZuniaListTile(
                title: 'Disconnect',
                leading: Icons.link_off,
                destructive: true,
                onTap: () => _disconnect(app),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChainRow extends StatelessWidget {
  const _ChainRow({
    required this.chainName,
    required this.chainId,
    required this.address,
    required this.on,
    required this.busy,
    required this.locked,
    required this.onChanged,
  });

  final String chainName;
  final String chainId;
  final String? address;
  final bool on;
  final bool busy;

  /// Why the switch cannot move, or null.
  final String? locked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      on && address != null ? truncateAddress(address!) : chainId,
      ?locked,
    ].join(' · ');
    return Semantics(
      toggled: on,
      label: '$chainName${locked == null ? '' : ', $locked'}',
      child: ZuniaListTile(
        title: chainName,
        subtitle: subtitle,
        trailing: busy
            ? const ZuniaActivityIndicator(size: 18)
            : ZuniaAdaptiveSwitch(
                value: on,
                onChanged: locked != null ? null : onChanged,
              ),
      ),
    );
  }
}
