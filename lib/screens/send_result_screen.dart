/// After a send is broadcast: whether the chain included it, and for another
/// chain, where the packet is until it lands or comes back.
///
/// The transfer keeps being followed after this screen closes (and after the
/// app restarts) from the in-flight list; this screen is only a view of it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/activity/bundled_links.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/packet_status_screen.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/transfer_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/transfers/pending_transfers.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/widgets/portfolio_feedback.dart';
import 'package:zunia_ui/zunia_ui.dart';

class SendResultScreen extends ConsumerStatefulWidget {
  const SendResultScreen({
    super.key,
    required this.chain,
    required this.txHash,
    required this.identity,
    required this.units,
    required this.recipient,
    this.recipientLabel,
    this.usingSelf = false,
    this.record,
  });

  /// A transfer still in flight, opened from Activity or the Send banner.
  factory SendResultScreen.tracked({Key? key, required PendingTransfer record}) {
    final chain = ChainCatalog.instance.find(record.chainId)!;
    return SendResultScreen(
      key: key,
      chain: chain,
      txHash: record.txHash,
      identity: identityOf(record.chainId, record.plan.inputDenom),
      units: BigInt.tryParse(record.amountBaseUnits) ?? BigInt.zero,
      recipient: '',
      record: record,
    );
  }

  final ChainEntry chain;
  final String txHash;
  final TokenIdentity identity;
  final BigInt units;

  /// Empty when opened from the in-flight list (no save-contact offer).
  final String recipient;
  final String? recipientLabel;
  final bool usingSelf;

  /// Set for a transfer to another chain.
  final PendingTransfer? record;

  @override
  ConsumerState<SendResultScreen> createState() => _SendResultScreenState();
}

class _SendResultScreenState extends ConsumerState<SendResultScreen> {
  TxDetailInfo? _detail;
  bool _waiting = true;
  int _tries = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(loadBundledLinks());
    if (widget.record == null) {
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_poll()));
      unawaited(_poll());
    } else {
      unawaited(ref.read(pendingTransfersProvider.notifier).pollNow());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Ask the chain for the transaction until it is in a block (two minutes at most).
  Future<void> _poll() async {
    if (!_waiting) return;
    _tries += 1;
    try {
      final detail = await ref.read(chainClientProvider).txDetail(
            widget.chain,
            widget.txHash,
            ref.read(chainAccountsProvider).where((a) => a.chain.chainId == widget.chain.chainId).firstOrNull?.address ?? '',
          );
      if (!mounted) return;
      if (detail != null) {
        _timer?.cancel();
        setState(() {
          _detail = detail;
          _waiting = false;
        });
        if (detail.success) {
          unawaited(ZuniaHaptics.success());
          unawaited(ref.read(portfolioProvider.notifier).refresh(force: true));
        } else {
          unawaited(ZuniaHaptics.error());
        }
        return;
      }
    } on Object {
      // Not indexed yet, or the node is slow: ask again on the next tick.
    }
    if (_tries >= 60 && mounted) {
      _timer?.cancel();
      setState(() => _waiting = false);
    }
  }

  void _done() => Navigator.of(context).popUntil((route) => route.isFirst);

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final record = widget.record;
    final url = explorerTxUrl(widget.chain.chainId, widget.txHash);
    final figure = '${exactAmountText(widget.units, AmountScale.of(widget.identity))} ${widget.identity.ticker}';

    Widget body;
    String title;
    if (record != null) {
      final tracked = ref.watch(pendingTransfersProvider.select((s) => s.tracked[record.txHash]));
      final trace = tracked?.trace;
      final outcome = tracked?.outcome;
      title = switch (outcome) {
        RouteOutcome.delivered => 'Transfer complete',
        RouteOutcome.failed => 'Transfer failed',
        RouteOutcome.refunded => 'Transfer came back',
        RouteOutcome.recoverable => 'Transfer needs you',
        null => 'Transfer in progress',
      };
      final registry = ref.read(interchainRegistryProvider);
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Text(record.label.isEmpty ? figure : record.label,
              style: zuniaSans(fontSize: 18, fontWeight: FontWeight.w500, color: s.fg)),
          const SizedBox(height: 12),
          if (outcome == RouteOutcome.failed)
            ZuniaCallout(
              tone: ZuniaCalloutTone.danger,
              title: 'The chain rejected it',
              body: '${explainChainError(tracked?.sourceError ?? '')} Nothing was sent.',
            )
          else
            ZuniaPacketTracker(
              hops: packetTrackerHops(record.plan, trace, registry),
              sourceTxHash: record.txHash,
              sourceChainId: record.chainId,
              failure: trackerFailure(trace?.failure),
              txUrl: explorerTxUrl,
              onOpenTx: (link) => unawaited(openExternal(context, link)),
              onCopyTxHash: (hash) => unawaited(copyWithFeedback(context, hash, 'Transaction hash')),
              loading: tracked == null,
              error: tracked?.error,
              onRefresh: () => unawaited(ref.read(pendingTransfersProvider.notifier).pollNow()),
              lastUpdatedAt: tracked?.updatedAt,
              compact: MediaQuery.sizeOf(context).width < 360,
            ),
          if (outcome == null) ...[
            const SizedBox(height: 10),
            Text(
              'You can leave this screen: Zunia keeps following the transfer while the app is open, '
              'picks it up again after a restart, and lists it under Activity.',
              style: zuniaSans(fontSize: 12.5, height: 1.4, color: s.fgDim),
            ),
          ],
          if (widget.recipient.isNotEmpty && !widget.usingSelf) ...[
            const SizedBox(height: 16),
            _SaveContactPrompt(address: widget.recipient, chainId: record.plan.destChainId),
          ],
        ],
      );
    } else {
      final detail = _detail;
      final failed = detail != null && !detail.success;
      final included = detail?.success ?? false;
      title = _waiting ? 'Sending' : failed ? 'Send failed' : included ? 'Sent' : 'Send submitted';
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        children: [
          Center(
            child: _waiting
                ? const ZuniaActivityIndicator(size: 44)
                : Icon(
                    failed ? Icons.error_outline_rounded : Icons.check_circle_rounded,
                    size: 56,
                    color: failed ? s.danger : s.success,
                  ),
          ),
          const SizedBox(height: 16),
          Text(
            figure,
            textAlign: TextAlign.center,
            style: zuniaSans(fontSize: 26, fontWeight: FontWeight.w500, letterSpacing: -0.6, color: s.fg),
          ),
          const SizedBox(height: 6),
          Text(
            'To ${widget.recipientLabel ?? truncateAddress(widget.recipient, left: 10, right: 8)} · on ${widget.chain.chainName}',
            textAlign: TextAlign.center,
            style: zuniaSans(fontSize: 13, color: s.fgMuted),
          ),
          const SizedBox(height: 18),
          Semantics(
            liveRegion: true,
            child: Text(
              _waiting
                  ? 'Waiting for ${widget.chain.chainName} to include it.'
                  : failed
                      ? explainChainError(detail.error ?? '')
                      : included
                          ? 'Confirmed on ${widget.chain.chainName}.'
                          : '${widget.chain.chainName} has not confirmed it here yet. The explorer shows it as soon as it is in a block.',
              textAlign: TextAlign.center,
              style: zuniaSans(fontSize: 14, height: 1.4, color: failed ? s.danger : s.fg),
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: TextButton.icon(
              onPressed: () => copyWithFeedback(context, widget.txHash, 'Transaction hash'),
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: Text(truncateAddress(widget.txHash, left: 8, right: 8), style: zuniaMono(fontSize: 12)),
            ),
          ),
          if (!_waiting && widget.recipient.isNotEmpty) ...[
            const SizedBox(height: 16),
            _SaveContactPrompt(address: widget.recipient, chainId: widget.chain.chainId),
          ],
        ],
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: title,
          onBack: _done,
          body: body,
          footer: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (url != null)
                ZuniaButton(
                  label: 'View on explorer',
                  variant: ZuniaButtonVariant.secondary,
                  leading: const Icon(Icons.open_in_new_rounded),
                  onPressed: () => openExternal(context, url),
                ),
              if (url != null) const SizedBox(height: 8),
              ZuniaButton(label: 'Done', size: ZuniaButtonSize.lg, onPressed: _done),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Save this address?" after a send to someone not in the address book.
class _SaveContactPrompt extends ConsumerStatefulWidget {
  const _SaveContactPrompt({required this.address, required this.chainId});

  final String address;
  final String chainId;

  @override
  ConsumerState<_SaveContactPrompt> createState() => _SaveContactPromptState();
}

class _SaveContactPromptState extends ConsumerState<_SaveContactPrompt> {
  final _label = TextEditingController();
  bool _saved = false;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final contacts = ref.watch(addressBookProvider);
    final own = ref.watch(chainAccountsProvider).any((a) => a.address == widget.address);
    final known = contacts.where((c) => c.address == widget.address).firstOrNull;
    if (own) return const SizedBox.shrink();
    if (known != null) {
      return Text(
        _saved ? 'Saved as ${known.label}.' : 'Saved in your address book as ${known.label}.',
        textAlign: TextAlign.center,
        style: zuniaSans(fontSize: 12.5, color: s.fgMuted),
      );
    }
    return ZuniaCard(
      tone: ZuniaCardTone.glass,
      padding: const EdgeInsets.all(14),
      radius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Save this address?', style: zuniaSans(fontSize: 14, fontWeight: FontWeight.w500, color: s.fg)),
          const SizedBox(height: 4),
          Text(truncateAddress(widget.address, left: 12, right: 8), style: zuniaMono(fontSize: 11, color: s.fgMuted)),
          const SizedBox(height: 10),
          ZuniaInput(controller: _label, hint: 'Name, e.g. Exchange'),
          const SizedBox(height: 10),
          ZuniaButton(
            label: 'Save contact',
            size: ZuniaButtonSize.sm,
            variant: ZuniaButtonVariant.secondary,
            onPressed: () async {
              final label = _label.text.trim();
              await ref.read(addressBookProvider.notifier).save(AddressBookEntry(
                    label: label.isEmpty ? truncateAddress(widget.address) : label,
                    address: widget.address,
                    chainId: widget.chainId,
                  ));
              await ZuniaHaptics.success();
              if (mounted) setState(() => _saved = true);
            },
          ),
        ],
      ),
    );
  }
}
