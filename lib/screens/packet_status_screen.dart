/// Follow a signed transfer hop by hop until it lands or fails.
///
/// Four outcomes, and the user's next action differs in every one: a timeout or
/// an error acknowledgement means the funds came back on their own; a stall
/// means they are safe but nothing is moving; and a swap that succeeded whose
/// delivery failed means the output is sitting in the Osmosis contract until it
/// is claimed. The tracker never shows a progress bar, because a bar cannot say
/// any of that.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/amino_tx.dart';
import 'package:zunia_mobile/screens/dapp_browser_screen.dart';
import 'package:zunia_mobile/services/interchain/tracking.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/services/wallet_tx_service.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// How often the chains are asked again while the transfer is in flight.
const Duration _pollInterval = Duration(seconds: 15);

class PacketStatusScreen extends ConsumerStatefulWidget {
  const PacketStatusScreen({
    super.key,
    required this.plan,
    required this.sourceTxHash,
    this.expectedAmount,
    this.swapContract,
    this.recoveryAddress,
  });

  final RoutePlan plan;
  final String sourceTxHash;

  /// Base units moved, used to pick our packet out of a relayer's batch.
  final String? expectedAmount;

  /// The crosschain-swaps contract, from host config. Null disables recovery
  /// with a stated reason rather than offering a button that cannot work.
  final String? swapContract;

  final String? recoveryAddress;

  @override
  ConsumerState<PacketStatusScreen> createState() => _PacketStatusScreenState();
}

class _PacketStatusScreenState extends ConsumerState<PacketStatusScreen> {
  RouteTrace? _trace;
  String? _error;
  bool _loading = true;
  bool _recovering = false;
  String? _recoveryResult;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(_pollInterval, (_) {
      final trace = _trace;
      // Stop polling once nothing further can happen; a terminal packet does not
      // change, and a phone should not keep two chains busy for nothing.
      if (trace != null && isTerminalPacketStatus(trace.status)) return;
      unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final trace = await trackRoute(
        widget.plan,
        widget.sourceTxHash,
        ref.read(lcdResolverProvider),
        expectedAmount: widget.expectedAmount,
        swapContract: widget.swapContract,
        recoveryAddress: widget.recoveryAddress,
        onUpdate: (partial) {
          // Render each hop as it resolves rather than after the whole walk.
          if (mounted) setState(() => _trace = partial);
        },
      );
      if (!mounted) return;
      setState(() {
        _trace = trace;
        _error = null;
        _loading = false;
      });
    } on InterchainError catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = switch (error.code) {
          InterchainErrorCode.readsDisabled =>
            'Live reads are off, so the wallet cannot follow this transfer. '
                'The transfer itself is unaffected.',
          InterchainErrorCode.unsupportedChain => error.message,
          _ => 'Could not read the transfer status: ${error.message}',
        };
      });
    }
  }

  Future<void> _recover(XcsRecovery recovery) async {
    final phrase = ref.read(phraseProvider);
    final account = ref.read(walletProvider).active;
    final chain = ChainCatalog.instance.find(recovery.chainId);
    final contract = recovery.contractAddress;
    final sender = recovery.recoveryAddress;
    if (phrase == null || account == null || chain == null ||
        contract == null || sender == null) {
      setState(() => _recoveryResult =
          'Unlock the wallet to sign the recovery on ${recovery.chainId}.');
      return;
    }

    setState(() {
      _recovering = true;
      _recoveryResult = null;
    });
    try {
      final hash = await WalletTxService.instance.signAndBroadcast(
        phrase: phrase,
        chain: chain,
        signerAddress: sender,
        accountIndex: account.index,
        msgs: [
          msgExecuteContract(
            sender: sender,
            contract: contract,
            msg: recovery.executeMsg,
          ),
        ],
      );
      if (!mounted) return;
      setState(() {
        _recovering = false;
        _recoveryResult = 'Recovery broadcast on ${chain.chainName}: $hash';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _recovering = false;
        _recoveryResult = 'Recovery was not broadcast: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final trace = _trace;
    final recovery = trace?.recovery;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Transfer status',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              ZuniaPacketTracker(
                hops: _hops(trace),
                sourceTxHash: widget.sourceTxHash,
                sourceChainId: widget.plan.sourceChainId,
                failure: switch (trace?.failure) {
                  PacketFailureKind.timeout => ZuniaPacketFailureKind.timeout,
                  PacketFailureKind.ackError => ZuniaPacketFailureKind.ackError,
                  PacketFailureKind.stalled => ZuniaPacketFailureKind.stalled,
                  PacketFailureKind.swapDeliveryFailed =>
                    ZuniaPacketFailureKind.swapDeliveryFailed,
                  null => null,
                },
                recoveryReady: recovery?.ready ?? false,
                recoverDisabledReason: recovery == null || recovery.ready
                    ? null
                    : 'The crosschain-swaps contract address is not configured '
                        'in this build, so a recover message cannot be built.',
                onRecover: recovery != null && recovery.ready && !_recovering
                    ? () => _recover(recovery)
                    : null,
                recoverLabel: _recovering ? 'Recovering…' : 'Recover funds',
                txUrl: _txUrl,
                onOpenTx: (url) => unawaited(
                  DappBrowserScreen.open(context, url: url, title: 'Explorer'),
                ),
                onCopyTxHash: (hash) =>
                    unawaited(Clipboard.setData(ClipboardData(text: hash))),
                loading: _loading && trace == null,
                error: _error,
                onRefresh: _refresh,
                lastUpdatedAt: trace?.updatedAt,
                compact: MediaQuery.sizeOf(context).width < 360,
              ),
              if (_recoveryResult != null) ...[
                const SizedBox(height: 14),
                ZuniaCallout(
                  tone: ZuniaCalloutTone.info,
                  title: 'Recovery',
                  body: _recoveryResult!,
                ),
              ],
              if (recovery != null && recovery.ready) ...[
                const SizedBox(height: 14),
                ZuniaCallout(
                  tone: ZuniaCalloutTone.warning,
                  title: 'Recovering needs gas on ${recovery.chainId}',
                  body:
                      'The swap itself cost you nothing there, but the recover '
                      'call is a transaction you sign on ${recovery.chainId} '
                      'and pay for in its token.',
                ),
              ],
              if (trace != null && trace.notes.isNotEmpty) ...[
                const SizedBox(height: 18),
                const ZuniaSectionLabel('Diagnostics'),
                const SizedBox(height: 8),
                for (final note in trace.notes.toSet())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      note,
                      style: zuniaMono(
                        fontSize: 10,
                        height: 1.4,
                        color: s.fgMuted,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// No explorer is configured for these chains, so no link is offered.
  ///
  /// Returning null makes the tracker render the hash as selectable text. A
  /// made-up explorer domain would be worse than no link.
  String? _txUrl(String chainId, String txHash) => null;

  List<ZuniaPacketTrackerHop> _hops(RouteTrace? trace) {
    if (trace == null) {
      // Before the first read: show the planned hops as pending rather than an
      // empty panel, so the user sees the shape of what they signed.
      final registry = ref.read(interchainRegistryProvider);
      return [
        for (final hop in widget.plan.hops)
          ZuniaPacketTrackerHop(
            chainId: hop.chainId,
            chainName: registry.get(hop.chainId)?.chainName,
            counterpartyChainId: hop.counterpartyChainId,
            counterpartyChainName: hop.counterpartyChainId == null
                ? null
                : registry.get(hop.counterpartyChainId!)?.chainName,
            channelId: hop.channelId.isEmpty ? null : hop.channelId,
            status: ZuniaPacketHopStatus.pending,
          ),
      ];
    }
    final registry = ref.read(interchainRegistryProvider);
    return [
      for (final hop in trace.hops)
        ZuniaPacketTrackerHop(
          chainId: hop.chainId,
          chainName: registry.get(hop.chainId)?.chainName,
          counterpartyChainId: hop.counterpartyChainId,
          counterpartyChainName: hop.counterpartyChainId == null
              ? null
              : registry.get(hop.counterpartyChainId!)?.chainName,
          channelId: hop.channelId.isEmpty ? null : hop.channelId,
          port: hop.port.isEmpty ? 'transfer' : hop.port,
          sequence: hop.sequence,
          sendTxHash: hop.sendTxHash,
          receiveTxHash: hop.receiveTxHash,
          error: hop.error,
          // The engine decides this against a per-hop-kind threshold; the UI
          // only renders it.
          stalled: hop.stalled,
          status: switch (hop.status) {
            PacketStatus.pending => ZuniaPacketHopStatus.pending,
            PacketStatus.relayed => ZuniaPacketHopStatus.relayed,
            PacketStatus.received => ZuniaPacketHopStatus.received,
            PacketStatus.acknowledged => ZuniaPacketHopStatus.acknowledged,
            PacketStatus.timeout => ZuniaPacketHopStatus.timeout,
            PacketStatus.failed => ZuniaPacketHopStatus.failed,
            PacketStatus.unknown => ZuniaPacketHopStatus.unknown,
          },
        ),
    ];
  }
}
