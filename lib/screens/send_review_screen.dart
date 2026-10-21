/// The review of one send: what leaves, where it goes, what arrives, what the
/// network charges, and what the kernel will sign, in its own words.
///
/// The quote it shows is the one signed: `TxEngine.signAndBroadcast` checks
/// that the sign bytes still match the reviewed preview, so a fee changed here
/// re-prices the quote and the review together.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/send_result_screen.dart';
import 'package:zunia_mobile/screens/send_screen.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/state/fee_prefs.dart';
import 'package:zunia_mobile/state/transfer_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/transfers/channel_verdict.dart';
import 'package:zunia_mobile/transfers/pending_transfers.dart';
import 'package:zunia_mobile/transfers/route_plan.dart';
import 'package:zunia_mobile/transfers/send_arrival.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_mobile/widgets/portfolio_feedback.dart';
import 'package:zunia_mobile/widgets/token_widgets.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Everything the review was built from, captured when it opened so nothing
/// moves if balances refresh underneath it.
@immutable
class SendReview {
  const SendReview({
    required this.chain,
    required this.dest,
    required this.sender,
    required this.identity,
    required this.units,
    required this.recipient,
    required this.recipientLabel,
    required this.usingSelf,
    required this.quote,
    required this.plan,
    required this.userPins,
  });

  final ChainEntry chain;

  /// Null for a same-chain send.
  final ChainEntry? dest;
  final String sender;

  /// The token sent, with the exponent its amount was typed with.
  final TokenIdentity identity;
  final BigInt units;
  final String recipient;
  final String? recipientLabel;
  final bool usingSelf;
  final TxQuote quote;
  final RoutePlanView? plan;
  final List<ManualChannel> userPins;

  bool get cross => dest != null;
}

/// A review older than this is not signed: the packet timeout was set when it
/// opened, and a stale one could expire before a relayer carries it.
const Duration _reviewLifetime = Duration(minutes: 5);

class SendReviewScreen extends ConsumerStatefulWidget {
  const SendReviewScreen({super.key, required this.review});

  final SendReview review;

  @override
  ConsumerState<SendReviewScreen> createState() => _SendReviewScreenState();
}

class _SendReviewScreenState extends ConsumerState<SendReviewScreen> {
  late TxQuote _quote = widget.review.quote;
  final DateTime _openedAt = DateTime.now();
  bool _busy = false;
  String? _error;

  SendReview get _r => widget.review;

  String get _signLabel {
    if (!_r.cross) return 'Sign send';
    return (_r.plan?.plan.requiresPfm ?? false) ? 'Sign route' : 'Sign IBC send';
  }

  String get _title {
    if (!_r.cross) return 'Confirm send';
    return (_r.plan?.plan.requiresPfm ?? false) ? 'Confirm IBC route' : 'Confirm IBC send';
  }

  Future<void> _editFee() async {
    final changed = await showFeePrefsSheet(context, ref);
    if (!changed || !mounted) return;
    final prefs = ref.read(feePrefsProvider);
    try {
      setState(() => _quote = TxEngine.instance.reprice(_quote, prefs.speed, gasAdjustment: prefs.gasAdjustment));
    } on Object catch (error) {
      setState(() => _error = plainSendError(error, _r.chain.chainName));
    }
  }

  Future<void> _sign() async {
    if (_r.cross && DateTime.now().difference(_openedAt) > _reviewLifetime) {
      setState(() => _error = 'This review is more than five minutes old, and its packet timeout was set when '
          'it opened. Go back and review the send again.');
      return;
    }
    // "Password on every signature" is asked inside TxEngine.signAndBroadcast.
    if (!mounted) return;
    final phrase = ref.read(phraseProvider);
    final index = ref.read(walletProvider).active?.index;
    if (phrase == null || index == null) {
      setState(() => _error = 'Unlock the wallet to sign.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final hash = await TxEngine.instance.signAndBroadcast(phrase: phrase, accountIndex: index, quote: _quote);
      // A saved contact remembers the send (use count, last used).
      unawaited(ref.read(addressBookProvider.notifier).touch(_r.recipient));
      await ZuniaHaptics.success();
      PendingTransfer? record;
      final plan = _r.plan;
      if (_r.cross && plan != null) {
        record = PendingTransfer(
          kind: 'transfer',
          txHash: hash,
          chainId: _r.chain.chainId,
          plan: plan.plan,
          amountBaseUnits: _r.units.toString(),
          label: transferLabel(_r.units, _r.identity, _r.dest!.chainName),
          startedAt: DateTime.now(),
        );
        // Saved before the screen changes: an app closed on the next frame
        // keeps the only view of where the funds are.
        await ref.read(pendingTransfersProvider.notifier).add(record);
      }
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => SendResultScreen(
          chain: _r.chain,
          txHash: hash,
          identity: _r.identity,
          units: _r.units,
          recipient: _r.recipient,
          recipientLabel: _r.recipientLabel,
          usingSelf: _r.usingSelf,
          record: record,
        ),
      ));
    } on Object catch (error) {
      await ZuniaHaptics.error();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error is TxException ? error.message : plainSendError(error, _r.chain.chainName);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final planner = ref.read(transferPlannerProvider);
    final r = _r;
    final sent = r.identity;
    final scale = AmountScale.of(sent);
    final figure = exactAmountText(r.units, scale);
    final destName = r.dest?.chainName ?? r.chain.chainName;
    final plan = r.plan;
    final arrival = r.cross && plan != null
        ? sendArrival(
            sourceChainId: plan.plan.sourceChainId,
            inputDenom: plan.plan.inputDenom,
            destChainId: plan.plan.destChainId,
            outputDenom: plan.plan.outputDenom,
            destChainName: destName,
            warnings: plan.warnings,
            links: plan.candidate.links,
            sent: sent,
          )
        : null;
    final feeCoin = _quote.feeCoin;
    final feeChain = _quote.chain;
    final feeIdentity = feeCoin == null ? null : identityOf(feeChain.chainId, feeCoin.denom);
    final feeText = feeCoin == null
        ? 'No fee'
        : formatTokenAmount(
            feeCoin.amount,
            feeCoin.denom == feeChain.coinMinimalDenom
                ? AmountScale.known(feeChain.coinDecimals, feeTicker(feeChain), denom: feeCoin.denom)
                : AmountScale.of(feeIdentity!),
            TokenAmountVariant.confirm,
            unit: true,
          );
    final forwarders = plan != null && plan.plan.requiresPfm
        ? [for (final hop in plan.hops) if (hop.kind == RouteHopKind.forward) hop.chainName]
        : const <String>[];
    final eta = plan?.plan.estimatedDurationSeconds;
    final unconfirmedPins = [
      for (final pin in r.userPins)
        if (pin.verdict != ChannelVerdictKind.verified &&
            (plan?.hops.any((hop) =>
                    hop.chainId == pin.fromChainId &&
                    hop.counterpartyChainId == pin.toChainId &&
                    hop.channelId == pin.channelId) ??
                false))
          pin,
    ];
    final memo = _quote.preview.memo;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: _title,
          onBack: _busy ? null : () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              ZuniaCard(
                tone: ZuniaCardTone.raised,
                padding: const EdgeInsets.all(16),
                radius: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Party(
                      label: 'YOU SEND',
                      leading: TokenAvatar(identity: sent, size: 40),
                      title: '$figure ${sent.ticker}',
                      line: tokenText(sent, TokenTextVariant.row),
                      a11y: '${tokenText(sent, TokenTextVariant.a11y)}${sent.proven ? ', verified' : ''}',
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Icon(Icons.south, size: 18, color: s.fgDim),
                    ),
                    _Party(
                      label: 'TO',
                      leading: ChainAvatar(chain: r.dest ?? r.chain, size: 40),
                      title: r.recipientLabel ?? truncateAddress(r.recipient, left: 10, right: 8),
                      line: arrival != null
                          ? 'Arrives as ${arrival.text}'
                          : r.recipientLabel != null
                              ? '${truncateAddress(r.recipient, left: 10, right: 8)} · on $destName'
                              : 'On $destName',
                      warning: arrival?.warning != null,
                    ),
                    const SizedBox(height: 14),
                    Divider(color: s.line, height: 1),
                    const SizedBox(height: 10),
                    if (r.cross)
                      _Fact(
                        label: 'Route',
                        value: '${r.chain.chainName} → $destName',
                        note: forwarders.isEmpty ? null : 'Forwarded by ${forwarders.join(', ')}',
                      ),
                    if (r.cross && eta != null)
                      _Fact(label: 'Arrives in', value: 'about ${(eta / 60).round().clamp(1, 999)} min'),
                    if (r.chain.isTestnet) const _Fact(label: 'Network', value: 'Testnet'),
                    _Fact(
                      label: 'Network fee',
                      value: feeText,
                      trailing: TextButton(
                        onPressed: _busy ? null : _editFee,
                        child: Text('${_quote.speed.label} · Edit'),
                      ),
                    ),
                    if (_quote.feeNote != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_quote.feeNote!, style: zuniaSans(fontSize: 11.5, color: s.warning)),
                      ),
                  ],
                ),
              ),
              if (arrival?.warning != null) ...[
                const SizedBox(height: 10),
                ZuniaCallout(
                  tone: ZuniaCalloutTone.warning,
                  title: arrival!.warning!.title,
                  body: arrival.warning!.body,
                ),
              ],
              for (final pin in unconfirmedPins) ...[
                const SizedBox(height: 10),
                ZuniaCallout(
                  tone: ZuniaCalloutTone.warning,
                  title: '${pin.channelId} was entered by hand',
                  body: 'Nothing confirmed that it leads from ${planner.chainName(pin.fromChainId)} to '
                      '${planner.chainName(pin.toChainId)}. If it goes somewhere else, the funds can land on '
                      'another chain or come back as a refund after the timeout.',
                ),
              ],
              const SizedBox(height: 14),
              const ZuniaSectionLabel('What you sign'),
              const SizedBox(height: 8),
              for (final line in _quote.preview.summaries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Container(width: 5, height: 5, decoration: BoxDecoration(color: s.accent, shape: BoxShape.circle)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(line, style: zuniaSans(fontSize: 13, height: 1.4, color: s.fg))),
                    ],
                  ),
                ),
              Text(
                r.cross
                    ? 'Decoded by the signing core on this device. You pay gas only on ${r.chain.chainName}, '
                        'in ${feeTicker(r.chain)}; relayers carry the packet the rest of the way.'
                    : 'Decoded by the signing core on this device. This stays on ${r.chain.chainName}: the '
                        'recipient can spend it once the transaction is in a block.',
                style: zuniaSans(fontSize: 12, height: 1.4, color: s.fgDim),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                ZuniaCallout(tone: ZuniaCalloutTone.danger, title: 'Not sent', body: _error!),
              ],
              const SizedBox(height: 12),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('Transaction details', style: zuniaSans(fontSize: 14, fontWeight: FontWeight.w500, color: s.fg)),
                  subtitle: Text('addresses, denom, memo', style: zuniaSans(fontSize: 12, color: s.fgMuted)),
                  children: [
                    _CopyRow(label: 'From', value: r.sender, hint: 'You'),
                    _CopyRow(
                      label: 'To',
                      value: r.recipient,
                      hint: r.recipientLabel ?? (r.cross ? destName : null),
                    ),
                    _DetailRow(
                      label: 'Message',
                      value: !r.cross ? 'MsgSend' : (plan?.plan.requiresPfm ?? false) ? 'MsgTransfer · PFM' : 'MsgTransfer',
                    ),
                    _DetailRow(label: 'Token', value: '${tokenKindLabel(sent.kind)} · ${issuerText(sent)}'),
                    if (sent.kind != TokenKind.native) _CopyRow(label: 'Denom', value: sent.denom, short: shortDenom(sent.denom)),
                    if (arrival?.denom != null)
                      _CopyRow(label: 'Arrives as', value: arrival!.denom!, short: shortDenom(arrival.denom!)),
                    if (plan != null)
                      _DetailRow(
                        label: 'Channels',
                        value: [
                          for (final hop in plan.hops)
                            if (hop.kind != RouteHopKind.swap && hop.counterpartyChainId != null)
                              '${hop.channelId.isEmpty ? '?' : hop.channelId} to ${hop.counterpartyChainName ?? hop.counterpartyChainId}',
                        ].join(', then '),
                      ),
                    if (r.cross) const _DetailRow(label: 'Timeout', value: '$kTransferTimeoutMinutes min, refunded if not received'),
                    _DetailRow(label: 'Memo', value: memo.isEmpty ? '(none)' : memo),
                    _DetailRow(label: 'Gas', value: '${_quote.fee.gasLimit}'),
                    if (plan != null && plan.memo.summary.isNotEmpty && plan.plan.memo.isNotEmpty)
                      _DetailRow(label: 'Packet memo', value: plan.memo.summary),
                  ],
                ),
              ),
            ],
          ),
          footer: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ZuniaButton(
                label: _busy ? 'Signing…' : _signLabel,
                size: ZuniaButtonSize.lg,
                loading: _busy,
                onPressed: _busy ? null : _sign,
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Party extends StatelessWidget {
  const _Party({
    required this.label,
    required this.leading,
    required this.title,
    required this.line,
    this.warning = false,
    this.a11y,
  });

  final String label;
  final Widget leading;
  final String title;
  final String line;
  final bool warning;
  final String? a11y;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      label: '$label ${a11y ?? title}, $line',
      excludeSemantics: true,
      child: Row(
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: zuniaMono(fontSize: 9.5, letterSpacing: 1.3, color: s.fgDim)),
                const SizedBox(height: 2),
                Text(
                  title,
                  style: zuniaSans(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.5,
                    color: s.fg,
                    tabular: const FontFeature.tabularFigures(),
                  ),
                ),
                Text(line, style: zuniaSans(fontSize: 12.5, color: warning ? s.warning : s.fgMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.note, this.trailing});

  final String label;
  final String value;
  final String? note;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: zuniaSans(fontSize: 13, color: s.fgMuted)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value,
                    textAlign: TextAlign.end,
                    style: zuniaSans(fontSize: 13, fontWeight: FontWeight.w500, color: s.fg)),
                if (note != null)
                  Text(note!, textAlign: TextAlign.end, style: zuniaSans(fontSize: 11.5, color: s.fgDim)),
                ?trailing,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 96, child: Text(label, style: zuniaSans(fontSize: 12.5, color: s.fgMuted))),
          Expanded(
            child: SelectableText(value, textAlign: TextAlign.end, style: zuniaMono(fontSize: 11.5, color: s.fg)),
          ),
        ],
      ),
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({required this.label, required this.value, this.hint, this.short});

  final String label;
  final String value;
  final String? hint;
  final String? short;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 96, child: Text(label, style: zuniaSans(fontSize: 12.5, color: s.fgMuted))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (hint != null) Text(hint!, style: zuniaSans(fontSize: 12.5, fontWeight: FontWeight.w500, color: s.fg)),
                Text(short ?? value, textAlign: TextAlign.end, style: zuniaMono(fontSize: 11, color: s.fgMuted)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy ${label.toLowerCase()} ${short ?? ''}'.trim(),
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            onPressed: () => copyWithFeedback(context, value, label),
            icon: Icon(Icons.copy_rounded, size: 16, color: s.accent),
          ),
        ],
      ),
    );
  }
}
