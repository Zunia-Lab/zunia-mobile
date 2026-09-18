/// Approve and sign one cross-chain swap.
///
/// The heart of this screen is the memo. The user signs a single MsgTransfer
/// whose memo tells Osmosis to swap and forward the proceeds, so the memo is
/// the transaction: it is read back through `validateMemo` and described in
/// plain language here, and anything the wallet cannot account for blocks the
/// signature rather than being waved through.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/config/interchain_config.dart';
import 'package:zunia_mobile/crypto/amino_tx.dart';
import 'package:zunia_mobile/screens/packet_status_screen.dart';
import 'package:zunia_mobile/services/interchain/memo.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/services/wallet_tx_service.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_ui/zunia_ui.dart';

class SwapReviewScreen extends ConsumerStatefulWidget {
  const SwapReviewScreen({super.key, required this.from, required this.to});

  final ChainAccount from;
  final ChainAccount to;

  @override
  ConsumerState<SwapReviewScreen> createState() => _SwapReviewScreenState();
}

class _SwapReviewScreenState extends ConsumerState<SwapReviewScreen> {
  bool _signing = false;
  String? _error;
  bool _showMemo = false;

  Future<void> _signAndBroadcast(SwapPlanState plan) async {
    final candidate = plan.candidate;
    final quote = plan.quote;
    final phrase = ref.read(phraseProvider);
    final account = ref.read(walletProvider).active;
    final chain = ChainCatalog.instance.find(widget.from.chain.chainId);
    if (candidate == null || quote == null || phrase == null || chain == null ||
        account == null) {
      setState(() => _error = 'Unlock the wallet to sign.');
      return;
    }

    setState(() {
      _signing = true;
      _error = null;
    });

    try {
      final hash = await WalletTxService.instance.signAndBroadcast(
        phrase: phrase,
        chain: chain,
        signerAddress: widget.from.address,
        accountIndex: account.index,
        msgs: [
          msgIbcTransfer(
            sourceChannel: candidate.plan.hops.first.channelId,
            sourcePort: candidate.plan.hops.first.port,
            token: (
              denom: candidate.plan.inputDenom,
              amount: quote.inputAmount,
            ),
            sender: widget.from.address,
            // Not the recipient: ibc-hooks only runs when the ICS20 receiver is
            // "" or the contract address, and the planner already resolved
            // which one this hop needs.
            receiver: candidate.receiver,
            timeoutTimestamp: defaultIbcTimeoutNs(
              minutes: kPacketTimeoutMinutes,
            ),
            memo: candidate.plan.memo,
          ),
        ],
      );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PacketStatusScreen(
            plan: candidate.plan,
            sourceTxHash: hash,
            expectedAmount: quote.inputAmount,
            swapContract: ref
                .read(swapVenueStatusProvider)
                .valueOrNull
                ?.contractAddress,
            recoveryAddress: plan.recoveryAddress,
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _signing = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final plan = ref.watch(swapControllerProvider);
    final candidate = plan.candidate;
    final quote = plan.quote;
    final inspection = plan.memoInspection;

    if (candidate == null || quote == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: ZuniaScreenScaffold(
            title: 'Review swap',
            onBack: () => Navigator.of(context).pop(),
            body: const ZuniaEmptyState(
              title: 'This quote has expired',
              description:
                  'Go back and price the swap again. A quote is only good for '
                  'a few seconds, and signing a stale one would accept a price '
                  'nobody offered.',
            ),
          ),
        ),
      );
    }

    // A memo the wallet cannot fully account for is never signed: it may be
    // middleware we do not model, or a forward we failed to read.
    final memoUnreadable = inspection == null ||
        (inspection.kind != MemoKind.xcs && inspection.kind != MemoKind.forward);
    // The same message the button will sign, so the fee shown is the fee paid.
    final signedMsg = msgIbcTransfer(
      sourceChannel: candidate.plan.hops.first.channelId,
      sourcePort: candidate.plan.hops.first.port,
      token: (denom: candidate.plan.inputDenom, amount: quote.inputAmount),
      sender: widget.from.address,
      receiver: candidate.receiver,
      timeoutTimestamp: '0',
      memo: candidate.plan.memo,
    );
    final fee = estimateFee(
      gasLimit: defaultGasFor([signedMsg]),
      gasPrice: widget.from.chain.averageGasPrice,
      denom: widget.from.chain.feeMinimalDenom.isEmpty
          ? widget.from.chain.coinMinimalDenom
          : widget.from.chain.feeMinimalDenom,
    );
    final feeLabel = fee.amount.isEmpty
        ? null
        : '≈ ${formatBaseUnitsExact(
            fee.amount.first.amount,
            decimals: widget.from.chain.feeDecimals,
            maxFractionDigits: 6,
          )} ${widget.from.chain.feeDenom}';

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Review swap',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: s.surfaceRaisedGradient,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 20,
                  ),
                  child: Column(
                    children: [
                      Text(
                        'SWAPPING',
                        style: zuniaMono(
                          fontSize: 10,
                          letterSpacing: 1.6,
                          color: s.fgMuted,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${formatBaseUnitsExact(
                          quote.inputAmount,
                          decimals: widget.from.chain.coinDecimals,
                          maxFractionDigits: 6,
                        )} ${widget.from.chain.coinDenom}',
                        textAlign: TextAlign.center,
                        style: zuniaSans(
                          fontSize: 22,
                          fontWeight: FontWeight.w500,
                          color: s.fg,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'for about ${formatBaseUnitsExact(
                          quote.outputAmount,
                          decimals: widget.to.chain.coinDecimals,
                          maxFractionDigits: 6,
                        )} ${widget.to.chain.coinDenom} on '
                        '${widget.to.chain.chainName}',
                        textAlign: TextAlign.center,
                        style: zuniaMono(
                          fontSize: 11,
                          height: 1.4,
                          color: s.fgMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // The security control: what the memo will actually do.
              const ZuniaSectionLabel('What this memo does'),
              const SizedBox(height: 8),
              ZuniaCallout(
                tone: memoUnreadable
                    ? ZuniaCalloutTone.danger
                    : ZuniaCalloutTone.info,
                title: memoUnreadable
                    ? 'Zunia cannot read this memo'
                    : 'Decoded on device',
                body: inspection?.summary ??
                    'The memo could not be classified, so nothing here can say '
                        'what it would do on arrival.',
              ),
              for (final warning in inspection?.warnings ?? const <String>[]) ...[
                const SizedBox(height: 8),
                ZuniaCallout(
                  tone: ZuniaCalloutTone.warning,
                  body: warning,
                ),
              ],
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _showMemo = !_showMemo),
                  child: Text(
                    _showMemo ? 'Hide the raw memo' : 'Show the raw memo',
                    style: zuniaMono(fontSize: 11, color: s.info),
                  ),
                ),
              ),
              if (_showMemo)
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: s.glass,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    candidate.plan.memo,
                    style: zuniaMono(fontSize: 10, height: 1.5, color: s.fg),
                  ),
                ),

              const SizedBox(height: 18),
              const ZuniaSectionLabel('Numbers'),
              const SizedBox(height: 10),
              ZuniaFeeSummary(
                rows: [
                  ZuniaFeeRow(
                    label: 'Minimum received',
                    value: '${formatBaseUnitsExact(
                      quote.minReceived,
                      decimals: widget.to.chain.coinDecimals,
                      maxFractionDigits: 6,
                    )} ${widget.to.chain.coinDenom}',
                    hint: 'derived from this quote at '
                        '${plan.slippagePercent}% slippage; the contract '
                        'enforces that tolerance against Osmosis\'s '
                        'time-weighted average price when the packet lands',
                  ),
                  ZuniaFeeRow(
                    label: 'Price impact',
                    value: quote.priceImpact == null
                        ? null
                        : '${quote.priceImpact!.toStringAsFixed(2)}%',
                  ),
                  ZuniaFeeRow(
                    label: 'Pool fee',
                    value: quote.poolFee == null
                        ? null
                        : '${quote.poolFee!.toStringAsFixed(2)}%',
                  ),
                  ZuniaFeeRow(
                    label: 'Network fee',
                    value: feeLabel,
                    hint: 'paid on ${widget.from.chain.chainName} only',
                    emphasise: true,
                  ),
                ],
                note: zuniaSourceGasNote(
                  widget.from.chain.chainName,
                  venueName: _venueName(),
                ),
              ),

              const SizedBox(height: 18),
              const ZuniaSectionLabel('Message'),
              const SizedBox(height: 10),
              // ZuniaFeeSummary rather than key-value rows: its label column
              // flexes, and at 320dp a label plus a bech32 address does not fit
              // on one line without it.
              ZuniaFeeSummary(
                rows: [
                  const ZuniaFeeRow(label: 'Type', value: 'MsgTransfer'),
                  ZuniaFeeRow(
                    label: 'Channel',
                    value: candidate.plan.hops.first.channelId,
                  ),
                  ZuniaFeeRow(
                    label: 'Packet receiver',
                    value: truncateAddress(candidate.receiver),
                    hint: 'the swap contract, as ibc-hooks requires',
                  ),
                  ZuniaFeeRow(
                    label: 'Pays out to',
                    value: truncateAddress(widget.to.address),
                  ),
                  ZuniaFeeRow(
                    label: 'Recovery address',
                    // Null renders as "not available", which is the truth: no
                    // address means stranded output cannot be reclaimed.
                    value: plan.recoveryAddress == null
                        ? null
                        : truncateAddress(plan.recoveryAddress!),
                  ),
                ],
              ),
              if (plan.recoveryAddress == null) ...[
                const SizedBox(height: 12),
                const ZuniaCallout(
                  tone: ZuniaCalloutTone.danger,
                  title: 'No recovery address',
                  body:
                      'The wallet could not derive an Osmosis address, so the '
                      'swap is built with on_failed_delivery: do_nothing. If '
                      'the swap succeeds but delivery fails, the output cannot '
                      'be reclaimed. Unlock the wallet and try again.',
                ),
              ],

              const SizedBox(height: 18),
              ZuniaRoutePreview(
                hops: _previewHops(candidate),
                estimatedDurationSeconds:
                    candidate.plan.estimatedDurationSeconds,
                warnings: candidate.plan.warnings,
                requiresPfm: candidate.plan.requiresPfm,
                requiresIbcHooks: candidate.plan.requiresIbcHooks,
                gasChainName: widget.from.chain.chainName,
                swapVenueName: _venueName(),
                compact: true,
              ),

              if (_error != null) ...[
                const SizedBox(height: 16),
                ZuniaCallout(
                  tone: ZuniaCalloutTone.danger,
                  title: 'Not broadcast',
                  body: _error!,
                ),
              ],
            ],
          ),
          footer: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ZuniaButton(
                label: 'Sign and broadcast',
                size: ZuniaButtonSize.lg,
                loading: _signing,
                onPressed:
                    memoUnreadable || _signing ? null : () => _signAndBroadcast(plan),
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
            ],
          ),
        ),
      ),
    );
  }

  String _venueName() {
    final status = ref.read(swapVenueStatusProvider).valueOrNull;
    final chainId = status?.chainId ?? kSwapVenueChainId;
    return ref.read(interchainRegistryProvider).get(chainId)?.chainName ??
        chainId;
  }

  List<ZuniaRoutePreviewHop> _previewHops(RoutePlanCandidate candidate) {
    final registry = ref.read(interchainRegistryProvider);
    return [
      for (final hop in candidate.plan.hops)
        ZuniaRoutePreviewHop(
          chainId: hop.chainId,
          chainName: registry.get(hop.chainId)?.chainName,
          counterpartyChainId: hop.counterpartyChainId,
          counterpartyChainName: hop.counterpartyChainId == null
              ? null
              : registry.get(hop.counterpartyChainId!)?.chainName,
          channelId: hop.channelId,
          port: hop.port.isEmpty ? 'transfer' : hop.port,
          kind: switch (hop.kind) {
            RouteHopKind.transfer => ZuniaRouteHopKind.transfer,
            RouteHopKind.forward => ZuniaRouteHopKind.forward,
            RouteHopKind.swap => ZuniaRouteHopKind.swap,
          },
        ),
    ];
  }
}
