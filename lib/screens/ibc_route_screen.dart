/// Recipient, route and review for a send.
///
/// Same-prefix sends stay on one chain. Anything else is routed by
/// `lib/services/interchain` — the Dart port of `@zunialab/interchain` — which
/// discovers and verifies the channels, decides whether the token should unwind
/// rather than wrap again, and composes the transfer plus, when no direct
/// channel exists, the packet-forward memo that carries it the rest of the way.
///
/// The channel discovery, validation and state parsing that used to live in
/// `chain_client.dart` is gone: it tested for `OPEN` before `TRYOPEN`, so a
/// channel still mid-handshake read as ready to receive funds.
library;

import 'dart:async';

import 'package:bech32/bech32.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/config/interchain_config.dart';
import 'package:zunia_mobile/crypto/amino_tx.dart';
import 'package:zunia_mobile/screens/address_book_screen.dart';
import 'package:zunia_mobile/screens/packet_status_screen.dart';
import 'package:zunia_mobile/screens/qr_scanner_screen.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/memo.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/services/wallet_tx_service.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/transfer_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/address_payload.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/address_field_actions.dart';
import 'package:zunia_mobile/widgets/transfer_sent_sheet.dart';
import 'package:zunia_ui/zunia_ui.dart';

class IbcRouteScreen extends ConsumerStatefulWidget {
  const IbcRouteScreen({
    super.key,
    required this.chainId,
    required this.denom,
    required this.amount,
    required this.fromAddress,
    required this.sourcePrefix,
    this.destChainId,
    this.destPrefix,
    this.forceIbc = false,
  });

  final String chainId;
  final String denom;
  final String amount;
  final String fromAddress;
  final String sourcePrefix;
  final String? destChainId;
  final String? destPrefix;
  final bool forceIbc;

  @override
  ConsumerState<IbcRouteScreen> createState() => _IbcRouteScreenState();
}

class _IbcRouteScreenState extends ConsumerState<IbcRouteScreen> {
  final _recipient = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _recipient.dispose();
    super.dispose();
  }

  /// The prefix of the address actually typed, or null when it does not decode.
  String? get _typedPrefix {
    final value = _recipient.text.trim();
    if (value.isEmpty) return null;
    try {
      return const Bech32Codec().decode(value).hrp;
    } on Object {
      return null;
    }
  }

  /// The destination prefix for display: the chain the user chose, falling back
  /// to whatever they typed.
  String? get _destPrefix => widget.destPrefix ?? _typedPrefix;

  String? get _addressError {
    final value = _recipient.text.trim();
    if (value.isEmpty) return null;
    try {
      const Bech32Codec().decode(value);
    } on Object {
      return 'Not a valid bech32 address';
    }
    final expected =
        widget.destPrefix ?? (widget.forceIbc ? null : widget.sourcePrefix);
    // Compared against the typed prefix, not the chosen one: the previous
    // version read `_destPrefix`, which returned the *chosen* chain's prefix
    // whenever one was known — so a well-formed address for some other chain
    // passed the check and would have been used as the packet receiver.
    if (expected != null && _typedPrefix != expected) {
      return 'Expected a $expected… address';
    }
    return null;
  }

  bool get _ibc {
    if (widget.forceIbc) return true;
    final dest = _destPrefix;
    return dest != null && dest != widget.sourcePrefix;
  }

  void _schedulePlan() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _plan);
  }

  Future<void> _plan() async {
    if (!_ibc) return;
    // The catalog is loaded at startup, but this screen can be built by a deep
    // link before that finishes; planning without it would throw rather than
    // leave the CTA disabled with a reason.
    if (!ChainCatalog.isLoaded) return;
    final destChainId = widget.destChainId;
    final chain = ChainCatalog.instance.find(widget.chainId);
    if (destChainId == null || chain == null) return;
    final units = toBaseUnits(widget.amount, chain.coinDecimals);
    await ref.read(transferPlanControllerProvider.notifier).plan(
          sourceChainId: widget.chainId,
          destChainId: destChainId,
          inputDenom: chain.coinMinimalDenom,
          amountBaseUnits: units ?? '0',
          sender: widget.fromAddress,
          recipient: _recipient.text.trim(),
          phrase: ref.read(phraseProvider),
          accountIndex: ref.read(walletProvider).active?.index ?? 0,
        );
  }

  Future<void> _scanQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const QrScannerScreen(
          title: 'Scan address',
          extractAddress: true,
        ),
      ),
    );
    if (!mounted || raw == null) return;
    setState(() => _recipient.text = extractBech32Address(raw) ?? raw);
    _plan();
  }

  Future<void> _pickBook() async {
    final address = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AddressBookScreen(
          pickMode: true,
          prefixFilter: widget.destPrefix ??
              (widget.forceIbc ? null : widget.sourcePrefix),
        ),
      ),
    );
    if (!mounted || address == null) return;
    setState(() => _recipient.text = address);
    _plan();
  }

  Future<void> _signAndBroadcast(
    BuildContext sheetContext,
    RoutePlanCandidate? candidate,
  ) async {
    final phrase = ref.read(phraseProvider);
    final chain = ChainCatalog.instance.find(widget.chainId);
    final account = ref.read(walletProvider).active;
    if (phrase == null || chain == null || account == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unlock the wallet to sign.')),
      );
      return;
    }
    final units = toBaseUnits(widget.amount, chain.coinDecimals);
    if (units == null || units == '0') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid amount')),
      );
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final coin = (denom: chain.coinMinimalDenom, amount: units);
      final msgs = _ibc
          ? [
              msgIbcTransfer(
                // Straight from the plan: the channel, the receiver (which is
                // not always the recipient) and the memo that carries the
                // remaining hops all come from one place.
                sourceChannel: candidate!.plan.hops.first.channelId,
                sourcePort: candidate.plan.hops.first.port,
                token: coin,
                sender: widget.fromAddress,
                receiver: candidate.receiver,
                timeoutTimestamp:
                    defaultIbcTimeoutNs(minutes: kPacketTimeoutMinutes),
                memo: candidate.plan.memo,
              ),
            ]
          : [
              msgSend(
                fromAddress: widget.fromAddress,
                toAddress: _recipient.text.trim(),
                amount: [coin],
              ),
            ];
      final hash = await WalletTxService.instance.signAndBroadcast(
        phrase: phrase,
        chain: chain,
        signerAddress: widget.fromAddress,
        msgs: msgs,
        accountIndex: account.index,
      );
      if (!mounted) return;
      Navigator.of(context).pop(); // loading
      if (sheetContext.mounted) Navigator.of(sheetContext).pop();

      if (_ibc && candidate != null) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PacketStatusScreen(
              plan: candidate.plan,
              sourceTxHash: hash,
              expectedAmount: units,
            ),
          ),
        );
        return;
      }
      await showTransferSent(
        context,
        txHash: hash,
        onDone: () {
          if (context.mounted) Navigator.of(context).pop();
        },
      );
    } on Object catch (err) {
      if (!mounted) return;
      Navigator.of(context).pop(); // loading
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$err')),
      );
    }
  }

  void _review(TransferPlanState plan) {
    final s = ZuniaSemanticsExt.of(context);
    final candidate = plan.candidate;
    final inspection = plan.memoInspection;
    // A memo the wallet cannot account for is never signed. An empty memo is a
    // plain transfer and is accounted for.
    final memoUnreadable = _ibc &&
        inspection != null &&
        inspection.kind != MemoKind.empty &&
        inspection.kind != MemoKind.forward;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      // Without this the sheet is capped at 9/16 of the screen and the review
      // rows push the action out of reach on a short phone.
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => Container(
        decoration: BoxDecoration(
          gradient: s.sheetGradient,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: s.line)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
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
                  'Review transfer',
                  style: zuniaSans(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.3,
                    color: s.fg,
                  ),
                ),
                const SizedBox(height: 18),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: s.surfaceRaisedGradient,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                    child: Column(
                      children: [
                        Text(
                          'SENDING',
                          style: zuniaMono(
                            fontSize: 10,
                            letterSpacing: 1.6,
                            color: s.fgMuted,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          children: [
                            ZuniaAmount(value: widget.amount, hero: true),
                            Text(
                              widget.denom,
                              style: zuniaMono(fontSize: 16, color: s.fgMuted),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // ZuniaFeeSummary rather than key-value rows: its label column
                // flexes, and at 320dp a label plus a bech32 address does not
                // fit on one line without it.
                ZuniaFeeSummary(
                  rows: [
                    ZuniaFeeRow(
                      label: 'To',
                      value: truncateAddress(_recipient.text.trim()),
                    ),
                    ZuniaFeeRow(
                      label: 'Message',
                      value: _ibc ? 'MsgTransfer' : 'MsgSend',
                    ),
                    if (_ibc && candidate != null) ...[
                      ZuniaFeeRow(
                        label: 'Channel',
                        value: candidate.plan.hops.first.channelId,
                      ),
                      ZuniaFeeRow(
                        label: 'Packet receiver',
                        value: truncateAddress(candidate.receiver),
                      ),
                      ZuniaFeeRow(
                        label: 'Arrives as',
                        value: candidate.plan.outputDenom.startsWith('ibc/')
                            ? truncateAddress(candidate.plan.outputDenom,
                                left: 10, right: 6)
                            : candidate.plan.outputDenom,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                ZuniaCallout(
                  tone: memoUnreadable
                      ? ZuniaCalloutTone.danger
                      : ZuniaCalloutTone.info,
                  title: memoUnreadable
                      ? 'Zunia cannot read this memo'
                      : 'Decoded on device',
                  body: inspection == null || inspection.kind == MemoKind.empty
                      ? 'Decoded from the raw message. There is no memo: the '
                          'funds go straight to the address above.'
                      : inspection.summary,
                ),
                for (final warning
                    in inspection?.warnings ?? const <String>[]) ...[
                  const SizedBox(height: 8),
                  ZuniaCallout(tone: ZuniaCalloutTone.warning, body: warning),
                ],
                const SizedBox(height: 12),
                ZuniaButton(
                  label: 'Sign and broadcast',
                  size: ZuniaButtonSize.lg,
                  onPressed: memoUnreadable
                      ? null
                      : () => _signAndBroadcast(context, candidate),
                ),
                if (memoUnreadable) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Signing is off because the wallet could not account for '
                    'every part of this memo.',
                    textAlign: TextAlign.center,
                    style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
                  ),
                ],
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'Close',
                    style: zuniaMono(fontSize: 11.5, color: s.fgDim),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final contacts = ref.watch(addressBookProvider);
    final plan = ref.watch(transferPlanControllerProvider);
    final dest = _destPrefix;
    final registry = ref.watch(interchainRegistryProvider);

    final ready = _addressError == null &&
        _recipient.text.trim().isNotEmpty &&
        (!_ibc || plan.ready);

    // A disabled CTA has to say what is still missing.
    final String? blocked;
    if (ready) {
      blocked = null;
    } else if (_recipient.text.trim().isEmpty) {
      blocked = 'Enter a recipient address';
    } else if (_addressError != null) {
      blocked = _addressError;
    } else if (plan.planning) {
      blocked = 'Planning the route…';
    } else {
      blocked = plan.blockedReason ??
          plan.planError ??
          'No route has been planned yet';
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: widget.forceIbc ? 'Cross-send' : 'Recipient',
          onBack: () => Navigator.of(context).pop(),
          trailing: Text(
            '2 / 2',
            style: zuniaMono(fontSize: 11, color: s.fgDim),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      s.accent.withValues(alpha: 0.24),
                      s.accent.withValues(alpha: 0.1),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: s.info.withValues(alpha: 0.5)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
                  child: TextField(
                    controller: _recipient,
                    style: zuniaMono(fontSize: 12, height: 1.4, color: s.fg),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      labelText: 'Recipient address',
                      floatingLabelBehavior: FloatingLabelBehavior.never,
                      hintText: '${widget.destPrefix ?? widget.sourcePrefix}1…',
                      hintStyle: zuniaMono(fontSize: 12, color: s.fgDim),
                      errorText: _addressError,
                      errorStyle: zuniaMono(fontSize: 10, color: s.danger),
                      suffixIcon: AddressFieldActions(
                        onScan: _scanQr,
                        onBook: _pickBook,
                      ),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 72,
                        minHeight: 36,
                      ),
                    ),
                    onChanged: (_) {
                      setState(() {});
                      _schedulePlan();
                    },
                  ),
                ),
              ),
              if (dest != null && _addressError == null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration:
                          BoxDecoration(shape: BoxShape.circle, color: s.info),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _ibc
                            ? 'Valid $dest address'
                            : 'Valid ${widget.chainId} address',
                        style: zuniaMono(fontSize: 10.5, color: s.info),
                      ),
                    ),
                  ],
                ),
              ],
              if (_ibc) ...[
                const SizedBox(height: 18),
                ZuniaRoutePreview(
                  hops: [
                    for (final hop in plan.candidate?.plan.hops ?? const [])
                      ZuniaRoutePreviewHop(
                        chainId: hop.chainId,
                        chainName: registry.get(hop.chainId)?.chainName,
                        counterpartyChainId: hop.counterpartyChainId,
                        counterpartyChainName: hop.counterpartyChainId == null
                            ? null
                            : registry
                                .get(hop.counterpartyChainId!)
                                ?.chainName,
                        channelId: hop.channelId,
                        port: hop.port,
                        kind: hop.kind == RouteHopKind.forward
                            ? ZuniaRouteHopKind.forward
                            : ZuniaRouteHopKind.transfer,
                        channelSource: _sourceOf(plan, hop.channelId),
                        channelVerified: _verified(plan, hop.channelId),
                      ),
                  ],
                  estimatedDurationSeconds:
                      plan.candidate?.plan.estimatedDurationSeconds,
                  warnings: plan.warnings,
                  requiresPfm: plan.candidate?.plan.requiresPfm ?? false,
                  gasChainName:
                      registry.get(widget.chainId)?.chainName ?? widget.chainId,
                  loading: plan.planning,
                  error: plan.planError,
                  onRetry: _plan,
                  emptyTitle: 'No route yet',
                  emptyDescription:
                      'Enter the recipient and the wallet will look for open '
                      'channels to their chain.',
                  compact: MediaQuery.sizeOf(context).width < 360,
                  footer: _ChannelChoice(
                    hops: plan.candidate?.links ?? const [],
                    options: plan.options,
                    sourceChainId: widget.chainId,
                    destChainId: widget.destChainId,
                    valueFor: (index) => ref
                        .read(transferPlanControllerProvider.notifier)
                        .overrideFor(index),
                    onChanged: (index, value, fromChainId, toChainId) {
                      ref
                          .read(transferPlanControllerProvider.notifier)
                          .setOverride(
                            index,
                            value,
                            fromChainId: fromChainId,
                            toChainId: toChainId,
                          );
                      _schedulePlan();
                    },
                  ),
                ),
                if (plan.denomAdvice != null &&
                    plan.denomAdvice!.warnings.isNotEmpty) ...[
                  const SizedBox(height: 13),
                  ZuniaCallout(
                    tone: ZuniaCalloutTone.info,
                    title: 'About this token',
                    body: plan.denomAdvice!.warnings.join(' '),
                  ),
                ],
              ],
              if (contacts.isNotEmpty) ...[
                const SizedBox(height: 18),
                const ZuniaSectionLabel('Recent'),
                const SizedBox(height: 12),
                for (final contact in contacts.take(6))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          setState(() => _recipient.text = contact.address);
                          _plan();
                        },
                        borderRadius: BorderRadius.circular(13),
                        child: Ink(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(color: s.glass2),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 22,
                                  height: 22,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: s.glass2,
                                  ),
                                  child: Text(
                                    contact.label.isEmpty
                                        ? '?'
                                        : contact.label.characters.first
                                            .toUpperCase(),
                                    style: zuniaMono(
                                      fontSize: 9,
                                      color: s.fgMuted,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    '${contact.label} · '
                                    '${truncateAddress(contact.address)}',
                                    overflow: TextOverflow.ellipsis,
                                    style: zuniaMono(
                                      fontSize: 11,
                                      color: s.fgMuted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _pickBook,
                    child: Text(
                      'Address book',
                      style: zuniaMono(fontSize: 11, color: s.info),
                    ),
                  ),
                ),
              ],
            ],
          ),
          footer: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ZuniaButton(
                label: 'Review transfer',
                size: ZuniaButtonSize.lg,
                loading: plan.planning,
                onPressed: ready ? () => _review(plan) : null,
              ),
              if (blocked != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    blocked,
                    textAlign: TextAlign.center,
                    style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  ZuniaChannelSource _sourceOf(TransferPlanState plan, String channelId) {
    for (final link in plan.candidate?.links ?? const <ChannelLink>[]) {
      if (link.channelId != channelId) continue;
      return switch (link.source) {
        ChannelLinkSource.manual => ZuniaChannelSource.manual,
        ChannelLinkSource.verified => ZuniaChannelSource.discovered,
        ChannelLinkSource.seed => ZuniaChannelSource.seed,
      };
    }
    return ZuniaChannelSource.seed;
  }

  /// Only a channel confirmed open on chain this session is called verified.
  bool _verified(TransferPlanState plan, String channelId) {
    for (final link in plan.candidate?.links ?? const <ChannelLink>[]) {
      if (link.channelId != channelId) continue;
      return link.source == ChannelLinkSource.verified &&
          link.state == IbcChannelState.open;
    }
    return false;
  }
}

/// Channel choice for each hop: the discovered options, and a field for the id
/// the user knows.
///
/// Rendered even when no route was planned, because that is precisely when the
/// user needs it: discovery fails on chains with slow or partial endpoints, and
/// a screen that only offers a channel field once it has already found one is
/// no help at all.
class _ChannelChoice extends ConsumerWidget {
  const _ChannelChoice({
    required this.hops,
    required this.options,
    required this.sourceChainId,
    required this.destChainId,
    required this.valueFor,
    required this.onChanged,
  });

  final List<ChannelLink> hops;
  final List<IbcChannelOption> options;
  final String sourceChainId;
  final String? destChainId;
  final String? Function(int index) valueFor;
  final void Function(
    int index,
    String channelId,
    String? fromChainId,
    String? toChainId,
  ) onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final pairs = hops.isNotEmpty
        ? [
            for (final link in hops) (link.sourceChainId, link.destChainId),
          ]
        : [(sourceChainId, destChainId ?? '')];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        const ZuniaSectionLabel('Channels'),
        const SizedBox(height: 8),
        if (options.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in options)
                ChoiceChip(
                  label: Text(
                    option.channelId,
                    style: zuniaMono(fontSize: 11, color: s.fg),
                  ),
                  selected:
                      hops.isNotEmpty && option.channelId == hops.first.channelId,
                  onSelected: (_) => onChanged(
                    0,
                    option.channelId,
                    pairs.first.$1,
                    pairs.first.$2,
                  ),
                  selectedColor: s.stateSelected,
                  backgroundColor: s.glass,
                  side: BorderSide(color: s.line),
                ),
            ],
          )
        else
          Text(
            'No channel was discovered between these chains. Discovery fails on '
            'chains with slow or partial endpoints; if you know the channel id, '
            'enter it and the wallet will plan with it.',
            style: zuniaMono(fontSize: 10, height: 1.4, color: s.fgMuted),
          ),
        for (var i = 0; i < pairs.length; i++) ...[
          const SizedBox(height: 10),
          _ChannelField(
            key: ValueKey('hop-$i-${pairs[i].$1}'),
            initial: valueFor(i) ?? '',
            label: pairs.length == 1
                ? 'Channel on ${pairs[i].$1}'
                : 'Hop ${i + 1} on ${pairs[i].$1}',
            hint: i < hops.length ? hops[i].channelId : 'channel-141',
            sourceChainId: pairs[i].$1,
            destChainId: pairs[i].$2.isEmpty ? null : pairs[i].$2,
            onChanged: (value) =>
                onChanged(i, value, pairs[i].$1, pairs[i].$2),
          ),
        ],
      ],
    );
  }
}

/// A hand-typed channel id, checked against the source chain as it is typed.
///
/// Discovery fails on chains with slow or incomplete LCDs, and the user must
/// still be able to proceed — so this never blocks on discovery, only on what
/// the chain says about the id in front of it.
class _ChannelField extends ConsumerStatefulWidget {
  const _ChannelField({
    super.key,
    required this.initial,
    required this.label,
    required this.hint,
    required this.sourceChainId,
    required this.destChainId,
    required this.onChanged,
  });

  final String initial;
  final String label;
  final String hint;
  final String sourceChainId;
  final String? destChainId;
  final ValueChanged<String> onChanged;

  @override
  ConsumerState<_ChannelField> createState() => _ChannelFieldState();
}

class _ChannelFieldState extends ConsumerState<_ChannelField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  Timer? _debounce;
  IbcChannelCheck? _check;
  bool _checking = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    widget.onChanged(value);
    _debounce?.cancel();
    final normalized = normalizeChannelId(value);
    if (normalized.isEmpty) {
      setState(() {
        _check = null;
        _checking = false;
      });
      return;
    }
    setState(() => _checking = true);
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      final result = await ref.read(channelServiceProvider).validateIbcChannel(
            widget.sourceChainId,
            normalized,
            destChainId: widget.destChainId,
            // Both ends are asked: a channel re-handshaked after an upgrade can
            // be open on one side only, and funds sent into it are escrowed on
            // this chain and never minted on the other.
            checkCounterparty: true,
          );
      if (!mounted) return;
      setState(() {
        _check = result;
        _checking = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final check = _check;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZuniaInput(
          controller: _controller,
          label: widget.label,
          hint: widget.hint.isEmpty ? 'channel-141' : widget.hint,
          errorText: check != null && !check.ok ? check.message : null,
          onChanged: _onChanged,
        ),
        if (_checking)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Checking this channel on ${widget.sourceChainId}…',
              style: zuniaMono(fontSize: 10, color: s.fgMuted),
            ),
          )
        else if (check != null && check.ok)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              check.message,
              style: zuniaMono(fontSize: 10, color: s.success),
            ),
          ),
      ],
    );
  }
}
