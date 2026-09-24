import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/config/connect_config.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

enum DappConnectKind { walletConnect, unknown }

/// WalletConnect session-approval payload for the bottom sheet. Zunia
/// Connect requests have their own sheet in `native_request_sheets.dart`.
class DappConnectOffer {
  const DappConnectOffer({
    required this.kind,
    required this.name,
    required this.url,
    this.description,
    this.icons = const [],
    this.chains = const [],
    this.methods = const [],
    this.rawUri,
    this.wcProposal,
  });

  factory DappConnectOffer.fromUri(String uri) {
    if (uri.startsWith('wc:') || uri.contains('relay-protocol')) {
      return DappConnectOffer(
        kind: DappConnectKind.walletConnect,
        name: 'WalletConnect',
        url: 'WalletConnect pairing',
        rawUri: uri,
      );
    }
    return DappConnectOffer(
      kind: DappConnectKind.unknown,
      name: 'Scanned payload',
      url: uri,
      rawUri: uri,
    );
  }

  factory DappConnectOffer.fromWcProposal(WcSessionProposal p) {
    return DappConnectOffer(
      kind: DappConnectKind.walletConnect,
      name: p.name.isEmpty ? 'dApp' : p.name,
      url: p.url,
      description: p.description,
      icons: p.icons,
      chains: p.chains,
      methods: p.methods,
      wcProposal: p,
    );
  }

  final DappConnectKind kind;
  final String name;
  final String url;
  final String? description;
  final List<String> icons;
  final List<String> chains;
  final List<String> methods;
  final String? rawUri;
  final WcSessionProposal? wcProposal;
}

Future<void> showDappConnectSheet(
  BuildContext context, {
  String? uri,
  DappConnectOffer? offer,
}) {
  assert(uri != null || offer != null, 'uri or offer required');
  final resolved = offer ?? DappConnectOffer.fromUri(uri!);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _DappConnectSheet(offer: resolved),
  );
}

class _DappConnectSheet extends ConsumerStatefulWidget {
  const _DappConnectSheet({required this.offer});

  final DappConnectOffer offer;

  @override
  ConsumerState<_DappConnectSheet> createState() => _DappConnectSheetState();
}

class _DappConnectSheetState extends ConsumerState<_DappConnectSheet> {
  bool _busy = false;
  String? _error;

  DappConnectOffer get offer => widget.offer;

  String get _initials {
    final host = offer.name;
    final parts = host.split(RegExp(r'[.\-_\s]')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return 'DA';
    final first = parts.first;
    if (parts.length == 1) {
      return first.length >= 2
          ? first.substring(0, 2).toUpperCase()
          : first.toUpperCase();
    }
    return (first[0] + parts.elementAt(1)[0]).toUpperCase();
  }

  String get _sessionLabel {
    switch (offer.kind) {
      case DappConnectKind.walletConnect:
        return 'WalletConnect v2';
      case DappConnectKind.unknown:
        return 'raw payload';
    }
  }

  List<({String chainId, String address})> _wcAccounts() {
    final chains = ref.read(chainAccountsProvider);
    return [
      for (final a in chains)
        (chainId: a.chain.chainId, address: a.address),
    ];
  }

  Future<void> _reject() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wcProposal = offer.wcProposal;
      if (wcProposal != null) {
        final wc = ref.read(walletConnectProvider);
        if (wc.isReady) await wc.rejectProposal(wcProposal);
      }
    } catch (e) {
      debugPrint('reject connect: $e');
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _approve() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      switch (offer.kind) {
        case DappConnectKind.walletConnect:
          await _approveWc();
        case DappConnectKind.unknown:
          throw StateError('Cannot connect an unrecognized payload');
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected to ${offer.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _approveWc() async {
    final wc = ref.read(walletConnectProvider);
    if (kWalletConnectProjectId.isEmpty) {
      throw UnsupportedError(
        'WalletConnect is not configured. Set WALLETCONNECT_PROJECT_ID.',
      );
    }
    if (!wc.isReady) await wc.init();

    final accounts = _wcAccounts();
    if (accounts.isEmpty) {
      throw StateError('Unlock the wallet and enable at least one chain');
    }
    wc.registerCosmosAccounts(accounts);

    final proposal = offer.wcProposal;
    if (proposal != null) {
      await wc.approveProposal(proposal, accounts: accounts);
      return;
    }

    final uri = offer.rawUri;
    if (uri == null || uri.isEmpty) {
      throw StateError('Missing WalletConnect URI');
    }

    final next = wc.sessionProposals.first;
    await wc.pair(uri);
    final arrived = await next.timeout(const Duration(seconds: 45));
    await wc.approveProposal(arrived, accounts: accounts);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final wallet = ref.watch(walletProvider);
    final chains = ref.watch(chainAccountsProvider);
    final chainLabel = offer.chains.isNotEmpty
        ? offer.chains.take(3).join(', ')
        : (chains.isEmpty
            ? 'none enabled'
            : chains.take(2).map((a) => a.chain.chainId).join(', '));

    final canConnect = offer.kind != DappConnectKind.unknown &&
        (offer.kind != DappConnectKind.walletConnect ||
            kWalletConnectProjectId.isNotEmpty ||
            offer.wcProposal != null);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.sheetGradient,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: s.lineStrong)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: s.lineStrong,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(13),
                      color: s.glass2,
                      border: Border.all(color: s.line),
                    ),
                    child: Text(
                      _initials,
                      style: zuniaMono(fontSize: 11, color: s.fg),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          offer.name,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: s.fg,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${offer.url} · $_sessionLabel',
                          overflow: TextOverflow.ellipsis,
                          style: zuniaMono(fontSize: 10.5, color: s.info),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (offer.description != null &&
                  offer.description!.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  offer.description!,
                  style: zuniaSans(
                    fontSize: 12.5,
                    height: 1.45,
                    color: s.fgMuted,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Text(
                offer.kind == DappConnectKind.unknown
                    ? 'Scanned value. Approve only if you trust the source.'
                    : 'This site wants to connect to your wallet. It can see '
                        'your addresses and ask you to sign. It cannot move '
                        'funds without a signature.',
                style: zuniaSans(
                  fontSize: 13,
                  height: 1.6,
                  color: s.fgMuted,
                ),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: s.surfaceRaisedGradient,
                ),
                child: Column(
                  children: [
                    ZuniaKeyValueRow(
                      label: 'Wallet',
                      value: wallet.active?.name ?? 'Wallet',
                    ),
                    const SizedBox(height: 11),
                    ZuniaKeyValueRow(
                      label: 'Chains',
                      value: chainLabel,
                    ),
                    const SizedBox(height: 11),
                    ZuniaKeyValueRow(
                      label: 'Session',
                      value: _sessionLabel,
                    ),
                    if (offer.methods.isNotEmpty) ...[
                      const SizedBox(height: 11),
                      ZuniaKeyValueRow(
                        label: 'Methods',
                        value: offer.methods.take(3).join(', '),
                      ),
                    ],
                    const SizedBox(height: 11),
                    const ZuniaKeyValueRow(
                      label: 'Expires',
                      value: '24 hours',
                    ),
                  ],
                ),
              ),
              if (!canConnect) ...[
                const SizedBox(height: 14),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: s.glass,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: s.info,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          offer.kind == DappConnectKind.walletConnect
                              ? 'No WalletConnect project id is configured, so '
                                  'Connect will not open a session.'
                              : 'This payload cannot start a session.',
                          style: zuniaSans(
                            fontSize: 11,
                            height: 1.45,
                            color: s.fgMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: zuniaSans(fontSize: 12, color: s.danger, height: 1.4),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: ZuniaButton(
                      label: 'Reject',
                      variant: ZuniaButtonVariant.secondary,
                      size: ZuniaButtonSize.lg,
                      onPressed: _busy ? null : _reject,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ZuniaButton(
                      label: _busy ? 'Connecting…' : 'Connect',
                      size: ZuniaButtonSize.lg,
                      onPressed: (_busy || !canConnect) ? null : _approve,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
