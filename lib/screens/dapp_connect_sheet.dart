import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/browser/origin_risk.dart';
import 'package:zunia_mobile/config/connect_config.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/native_request_sheets.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/ui/review_widgets.dart';
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

/// The WalletConnect connection prompt, in the same review sheet as every
/// other dApp request. The site's own URL is a claim WalletConnect does not
/// verify, so it gets the lookalike check like any page.
Future<void> showDappConnectSheet(
  BuildContext context, {
  String? uri,
  DappConnectOffer? offer,
}) {
  assert(uri != null || offer != null, 'uri or offer required');
  final resolved = offer ?? DappConnectOffer.fromUri(uri!);
  final container = ProviderScope.containerOf(context, listen: false);
  final wallet = container.read(walletProvider);
  final chains = container.read(chainAccountsProvider);
  final site = Uri.tryParse(resolved.url)?.hasScheme == true ? resolved.url : 'https://${resolved.url}';
  final sessionLabel = switch (resolved.kind) {
    DappConnectKind.walletConnect => 'WalletConnect v2',
    DappConnectKind.unknown => 'raw payload',
  };
  final chainIds = resolved.chains.isNotEmpty
      ? resolved.chains
      : [for (final a in chains.take(3)) a.chain.chainId];
  final configured = resolved.kind == DappConnectKind.walletConnect &&
      (kWalletConnectProjectId.isNotEmpty || resolved.wcProposal != null);

  final data = ReviewSheetData(
    kind: ReviewKind.connect,
    label: 'Connection request',
    effect: resolved.kind == DappConnectKind.unknown
        ? 'Scanned value. Approve only if you trust the source.'
        : 'This site wants to connect to your wallet. It can see your addresses and ask '
            'you to sign. It cannot move funds without a signature.',
    site: ReviewSite(origin: site, name: resolved.name, pill: (sessionLabel, ZuniaPillTone.neutral)),
    approveLabel: 'Connect',
    chainIds: chainIds,
    accountName: wallet.active?.name ?? 'Wallet',
    warnings: resolved.kind == DappConnectKind.walletConnect && resolved.wcProposal != null
        ? assessOrigin(site).warnings
        : const [],
    extras: [
      if (resolved.description != null && resolved.description!.trim().isNotEmpty)
        ReviewNote(resolved.description!),
    ],
    rows: [
      ('Session', sessionLabel),
      if (resolved.methods.isNotEmpty) ('Methods', resolved.methods.take(3).join(', ')),
      ('Expires', '24 hours'),
    ],
    cannotApprove: configured
        ? null
        : resolved.kind == DappConnectKind.walletConnect
            ? 'No WalletConnect project id is configured, so Connect will not open a session.'
            : 'This payload cannot start a session.',
  );

  return showReviewSheet(
    context,
    data: data,
    onReject: () async {
      final proposal = resolved.wcProposal;
      if (proposal == null) return;
      final wc = container.read(walletConnectProvider);
      if (wc.isReady) await wc.rejectProposal(proposal);
    },
    onApprove: (_) async {
      await _approveWc(container, resolved);
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Connected to ${resolved.name}')),
        );
      }
    },
  );
}

Future<void> _approveWc(ProviderContainer container, DappConnectOffer offer) async {
  final wc = container.read(walletConnectProvider);
  if (kWalletConnectProjectId.isEmpty && offer.wcProposal == null) {
    throw UnsupportedError('WalletConnect is not configured. Set WALLETCONNECT_PROJECT_ID.');
  }
  if (!wc.isReady) await wc.init();

  final accounts = [
    for (final a in container.read(chainAccountsProvider)) (chainId: a.chain.chainId, address: a.address),
  ];
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
