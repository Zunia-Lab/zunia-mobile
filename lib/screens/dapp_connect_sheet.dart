import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/config/connect_config.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

enum DappConnectKind { walletConnect, nativeWs, unknown }

/// Unified connect / session-approval payload for the bottom sheet.
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
    this.nativeRequest,
  });

  factory DappConnectOffer.fromUri(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed != null && NativeConnectService.parseConnectLink(parsed) != null) {
      return DappConnectOffer(
        kind: DappConnectKind.nativeWs,
        name: 'Zunia Connect',
        url: parsed.host.isEmpty ? 'zunia://connect' : parsed.host,
        rawUri: uri,
      );
    }
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

  factory DappConnectOffer.fromNative(NativeConnectRequest r) {
    return DappConnectOffer(
      kind: DappConnectKind.nativeWs,
      name: r.metadata.name,
      url: r.metadata.url.isEmpty ? r.origin : r.metadata.url,
      description: r.metadata.description,
      icons: r.metadata.icons,
      chains: r.chains,
      methods: r.methods,
      nativeRequest: r,
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
  final NativeConnectRequest? nativeRequest;
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
      case DappConnectKind.nativeWs:
        return 'Zunia Connect';
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

  List<NativeConnectAccount> _nativeAccounts() {
    final phrase = ref.read(phraseProvider);
    final wallet = ref.read(walletProvider);
    final account = wallet.active;
    final chains = ref.read(chainAccountsProvider);
    if (phrase == null || account == null) return const [];
    final kernel = WalletKernel.instance;
    final out = <NativeConnectAccount>[];
    for (final ca in chains) {
      try {
        final derived = kernel.deriveAddress(
          phrase: phrase,
          chain: ca.chain,
          accountIndex: account.index,
        );
        out.add(
          NativeConnectAccount(
            chainId: ca.chain.chainId,
            address: derived.address,
            algo: 'secp256k1',
            pubkey: base64Encode(derived.publicKey),
            name: account.name,
          ),
        );
      } catch (_) {}
    }
    return out;
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
      if (offer.kind == DappConnectKind.nativeWs &&
          offer.nativeRequest != null) {
        await ref.read(nativeConnectProvider).rejectConnect();
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
        case DappConnectKind.nativeWs:
          await _approveNative();
          break;
        case DappConnectKind.walletConnect:
          await _approveWc();
          break;
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

  Future<void> _approveNative() async {
    final native = ref.read(nativeConnectProvider);
    final accounts = _nativeAccounts();
    if (accounts.isEmpty) {
      throw StateError('Unlock the wallet and enable at least one chain');
    }

    // Deep-link URI may still need the WS handshake.
    final raw = offer.rawUri;
    if (raw != null && !native.isConnected) {
      await native.connectFromDeepLink(Uri.parse(raw));
    }
    final chains = offer.chains.isNotEmpty
        ? offer.chains
        : accounts.map((a) => a.chainId).toList();
    await native.approveConnect(accounts: accounts, chains: chains);
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

/// Sign-request sheet for native WS (and reusable for WC later).
Future<void> showNativeSignSheet(
  BuildContext context, {
  required NativeSignRequest request,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _NativeSignSheet(request: request),
  );
}

class _NativeSignSheet extends ConsumerStatefulWidget {
  const _NativeSignSheet({required this.request});

  final NativeSignRequest request;

  @override
  ConsumerState<_NativeSignSheet> createState() => _NativeSignSheetState();
}

class _NativeSignSheetState extends ConsumerState<_NativeSignSheet> {
  bool _busy = false;

  Future<void> _reject() async {
    setState(() => _busy = true);
    await ref.read(nativeConnectProvider).respondSignReject(
          requestId: widget.request.id,
        );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _approvePlaceholder() async {
    // Kernel signing for amino/direct lands in a later pass; reject with a
    // clear code so the dApp does not hang, and surface guidance to the user.
    setState(() => _busy = true);
    await ref.read(nativeConnectProvider).respondSignReject(
          requestId: widget.request.id,
          reason: 'Signing UI is ready; kernel sign path not wired yet',
          code: 'SIGN_NOT_IMPLEMENTED',
        );
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${widget.request.type} needs kernel signing. Request was declined.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final req = widget.request;
    final preview = const JsonEncoder.withIndent('  ').convert(req.payload);

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
              Text(
                'Sign request',
                style: zuniaSans(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: s.fg,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${req.type} · ${req.chainId}',
                style: zuniaMono(fontSize: 11, color: s.info),
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Text(
                    preview,
                    style: zuniaMono(fontSize: 10, color: s.fgMuted, height: 1.45),
                  ),
                ),
              ),
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
                      label: 'Approve',
                      size: ZuniaButtonSize.lg,
                      onPressed: _busy ? null : _approvePlaceholder,
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
