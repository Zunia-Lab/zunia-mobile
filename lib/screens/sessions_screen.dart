import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Active WalletConnect + Zunia native sessions with disconnect actions.
class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({super.key});

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen> {
  StreamSubscription<void>? _nativeSub;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _nativeSub =
        ref.read(nativeConnectProvider).sessionsChanged.listen((_) {
      if (mounted) setState(() => _tick++);
    });
  }

  @override
  void dispose() {
    _nativeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    // Touch _tick so rebuilds from native session changes apply.
    final _ = _tick;
    final wc = ref.watch(walletConnectProvider);
    final native = ref.watch(nativeConnectProvider);
    final wcSessions = wc.activeSessions;
    final nativeSessions = native.activeSessions;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Connected apps',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              if (wcSessions.isEmpty && nativeSessions.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 28),
                  child: Text(
                    'No active sessions. Pair a dApp with WalletConnect or '
                    'open a zunia://connect link.',
                    style: zuniaSans(
                      fontSize: 13,
                      height: 1.55,
                      color: s.fgMuted,
                    ),
                  ),
                ),
              if (wcSessions.isNotEmpty) ...[
                ZuniaSectionLabel('WalletConnect'),
                const SizedBox(height: 8),
                for (final session in wcSessions)
                  _SessionTile(
                    name: session.name,
                    meta: '${session.url}\n${session.chains.take(2).join(', ')}',
                    badge: 'WC',
                    onDisconnect: () async {
                      await wc.disconnectTopic(session.topic);
                      if (mounted) setState(() => _tick++);
                    },
                  ),
                const SizedBox(height: 18),
              ],
              if (nativeSessions.isNotEmpty) ...[
                ZuniaSectionLabel('Zunia Connect'),
                const SizedBox(height: 8),
                for (final session in nativeSessions)
                  _SessionTile(
                    name: session.name,
                    meta:
                        '${session.url}\n${session.chains.take(2).join(', ')}',
                    badge: 'ZS',
                    onDisconnect: () async {
                      await native.disconnectSession(session.sessionId);
                      if (mounted) setState(() => _tick++);
                    },
                  ),
              ],
            ],
          ),
          footer: (wcSessions.isEmpty && nativeSessions.isEmpty)
              ? null
              : ZuniaButton(
                  label: 'Disconnect all',
                  variant: ZuniaButtonVariant.secondary,
                  size: ZuniaButtonSize.lg,
                  onPressed: () async {
                    await wc.disconnectAll();
                    await native.disconnectAll();
                    if (mounted) setState(() => _tick++);
                  },
                ),
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.name,
    required this.meta,
    required this.badge,
    required this.onDisconnect,
  });

  final String name;
  final String meta;
  final String badge;
  final Future<void> Function() onDisconnect;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: s.surfaceRaisedGradient,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                color: s.glass2,
                border: Border.all(color: s.line),
              ),
              child: Text(
                badge,
                style: zuniaMono(fontSize: 10, color: s.fg),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: zuniaSans(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: s.fg,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    meta,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: zuniaMono(fontSize: 10, color: s.fgMuted, height: 1.35),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => onDisconnect(),
              child: Text(
                'Disconnect',
                style: zuniaSans(fontSize: 12, color: s.danger),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
