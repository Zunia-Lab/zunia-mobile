/// The swap's confirm card, and signing it.
///
/// One card: what the user pays, what they receive and where, the minimum,
/// the rate, Zunia's fee, the network fee (with its speed), and how long the
/// price holds. It shows a frozen review ([SwapReview]) and signs exactly the
/// messages built from it. Before the Sign button is enabled, and again at
/// the moment of signing, the messages are read back ([reviewProblems]): the
/// swap, the fee (recipient, denom, amount) and nothing else. If the form
/// under it moves after review the button reads "Out of date".
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_mobile/screens/packet_status_screen.dart';
import 'package:zunia_mobile/screens/swap/swap_widgets.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/swap/pool_swap.dart';
import 'package:zunia_mobile/swap/swap_amounts.dart';
import 'package:zunia_mobile/swap/swap_data.dart';
import 'package:zunia_mobile/swap/swap_fee.dart';
import 'package:zunia_mobile/swap/swap_path.dart';
import 'package:zunia_mobile/swap/swap_review.dart';
import 'package:zunia_mobile/swap/swap_tokens.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// SECURITY WORKSTREAM HOOK: the one call site where a swap asks the user to
/// confirm the signature (password per signature, biometrics) before the
/// kernel signs. Replace the body with the security workstream's
/// `confirmSigning(...)`; until then an unlocked wallet (a phrase in
/// `phraseProvider`) is the only gate, as for every other flow on this branch.
Future<bool> confirmSwapSigning(
  BuildContext context,
  WidgetRef ref,
  TxQuote quote,
) async => true;

class SwapReviewScreen extends ConsumerStatefulWidget {
  const SwapReviewScreen({
    super.key,
    required this.prepared,
    required this.quote,
    this.engine,
  });

  final PreparedSwap prepared;

  /// The kernel's preview of exactly `prepared.msgs`, with its fee.
  final TxQuote quote;

  /// Tests pass their own; the app signs through [TxEngine.instance].
  final TxEngine? engine;

  @override
  ConsumerState<SwapReviewScreen> createState() => _SwapReviewScreenState();
}

class _SwapReviewScreenState extends ConsumerState<SwapReviewScreen> {
  late SwapReview _review = widget.prepared.review;
  late TxQuote _quote = widget.quote;
  bool _refreshing = false;
  bool _signing = false;
  String? _error;
  Timer? _ticker;

  TxEngine get _engine => widget.engine ?? TxEngine.instance;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  SwapData? get _data => ref.read(swapDataProvider).valueOrNull;

  List<String> _problems(SwapData data, DateTime now) => reviewProblems(
    _review,
    msgs: _quote.msgs,
    chainId: _quote.chain.chainId,
    policy: data.fees,
    book: data.book,
    now: now,
    venueChainId: data.venueChainId,
  );

  bool _feeShort(SwapView live) {
    final coin = _quote.feeCoin;
    if (coin == null || coin.denom != _review.from.denom) return false;
    var balance = _review.from.amount;
    for (final asset in live.sources) {
      if (asset.key == _review.from.key) balance = asset.amount;
    }
    return balance - _review.amountUnits < BigInt.parse(coin.amount);
  }

  ({String label, String reason})? _block(
    SwapData data,
    SwapView live,
    DateTime now,
  ) {
    final problems = _problems(data, now);
    return swapSignBlock(
      problem: problems.isEmpty ? null : problems.first,
      drift: reviewDrift(_review, live.live),
      price: _review.price,
      refreshing: _refreshing,
      now: now,
      ttl: data.config.quoteTtl,
      feeShort: _feeShort(live),
    );
  }

  Future<void> _refresh() async {
    final phrase = ref.read(phraseProvider);
    final index = ref.read(walletProvider).active?.index ?? 0;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final next = await ref
          .read(swapControllerProvider.notifier)
          .refreshReview(_review);
      if (!mounted) return;
      final msgs = next.msgs;
      if (msgs != null && phrase != null) {
        // In the pools the floor is a number in the message: a new price is a
        // new transaction, previewed again by the kernel.
        final quote = await _engine.quote(
          phrase: phrase,
          accountIndex: index,
          chain: _quote.chain,
          signer: _review.signer,
          msgs: msgs,
          memo: _quote.memo,
          speed: _quote.speed,
          gasAdjustment: _quote.gasAdjustment,
        );
        if (!mounted) return;
        setState(() {
          _review = next.review;
          _quote = quote;
        });
      } else {
        setState(() {
          _review = next.review;
          _error = next.error;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error is TxException ? error.message : '$error',
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _editSpeed() async {
    final speed = await showZuniaActionSheet<FeeSpeed>(
      context,
      title: 'Network fee speed',
      message: 'A faster speed pays more gas to be included sooner.',
      actions: [
        for (final value in FeeSpeed.values)
          ZuniaAlertAction(
            label: value.label,
            value: value,
            isDefault: value == _quote.speed,
          ),
      ],
    );
    if (speed == null || speed == _quote.speed || !mounted) return;
    try {
      setState(() => _quote = _engine.reprice(_quote, speed));
      final settings = ref.read(swapSettingsProvider);
      unawaited(
        ref
            .read(swapSettingsProvider.notifier)
            .update(settings.copyWith(feeSpeed: speed)),
      );
    } on Object catch (error) {
      setState(() => _error = '$error');
    }
  }

  Future<void> _sign() async {
    final data = _data;
    if (data == null) return;
    // The button is off for each of these; checked again here, at the moment
    // of signing, against the clock rather than the last tick.
    final block = _block(
      data,
      ref.read(swapViewProvider),
      ref.read(swapClockProvider)(),
    );
    if (block != null) {
      ZuniaHaptics.warning();
      setState(() => _error = block.reason);
      return;
    }
    final phrase = ref.read(phraseProvider);
    final index = ref.read(walletProvider).active?.index ?? 0;
    if (phrase == null) {
      setState(() => _error = 'Unlock the wallet to sign.');
      return;
    }
    // SECURITY WORKSTREAM: confirmSigning(...) goes through this one call.
    if (!await confirmSwapSigning(context, ref, _quote)) return;
    if (!mounted) return;
    setState(() {
      _signing = true;
      _error = null;
    });
    try {
      final hash = await _engine.signAndBroadcast(
        phrase: phrase,
        accountIndex: index,
        quote: _quote,
      );
      if (!mounted) return;
      ZuniaHaptics.success();
      ref.invalidate(swapHoldingsProvider);
      await _showResult(data, hash);
    } on Object catch (error) {
      if (!mounted) return;
      ZuniaHaptics.error();
      setState(() {
        _signing = false;
        _error = error is TxException ? error.message : '$error';
      });
    }
  }

  Future<void> _showResult(SwapData data, String hash) {
    final review = _review;
    final navigator = Navigator.of(context);
    switch (review) {
      case ContractSwapReview():
        // A transfer (or a call that sends one) is a route: follow its packets,
        // with the recovery action ready if delivery fails after the swap.
        return navigator.pushReplacement(
          MaterialPageRoute(
            builder: (_) => PacketStatusScreen(
              plan: review.plan,
              sourceTxHash: hash,
              expectedAmount: review.venueOrigin
                  ? null
                  : review.fee.net.toString(),
              swapContract: review.contract,
              recoveryAddress: review.recoveryAddress,
            ),
          ),
          result: true,
        );
      case PoolSwapReview(:final delivery):
        if (delivery != null) {
          return navigator.pushReplacement(
            MaterialPageRoute(
              builder: (_) => PacketStatusScreen(
                plan: delivery.planFor(
                  data.venueChainId,
                  review.venueOutputDenom,
                  data.config.packetTimeoutMinutes,
                ),
                sourceTxHash: hash,
                expectedAmount: review.minOut,
              ),
            ),
            result: true,
          );
        }
        return navigator.pushReplacement(
          MaterialPageRoute(
            builder: (_) => SwapResultScreen(review: review, txHash: hash),
          ),
          result: true,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final data = ref.watch(swapDataProvider).valueOrNull;
    final live = ref.watch(swapViewProvider);
    final hidden = ref.watch(preferencesProvider.select((p) => p.hideAmounts));
    final now = ref.watch(swapClockProvider)();
    if (data == null) {
      return const Scaffold(body: Center(child: ZuniaActivityIndicator()));
    }
    final problems = _problems(data, now);
    final drift = problems.isEmpty ? reviewDrift(_review, live.live) : null;
    final block = _block(data, live, now);
    final feeShort = _feeShort(live);
    final review = _review;
    final ttl = data.config.quoteTtl;
    final left = review.price.quote == null
        ? Duration.zero
        : ttl - now.difference(review.price.at);
    final secondsLeft = left.isNegative
        ? 0
        : (left.inMilliseconds / 1000).ceil();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Confirm swap',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              _SummaryCard(
                review: review,
                data: data,
                quote: _quote,
                hidden: hidden,
                onEditSpeed: _signing ? null : _editSpeed,
                clock: SwapQuoteClock(
                  confirm: true,
                  secondsLeft: secondsLeft,
                  refreshing: _refreshing,
                  onRefresh: _signing ? null : _refresh,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                swapFeeOutcome(review),
                style: zuniaSans(fontSize: 12, height: 1.45, color: s.fgMuted),
              ),
              if (problems.isNotEmpty) ...[
                const SizedBox(height: 12),
                ZuniaCallout(
                  tone: ZuniaCalloutTone.danger,
                  title: 'Zunia will not sign this',
                  body: problems.join('\n'),
                ),
              ],
              if (drift != null) ...[
                const SizedBox(height: 12),
                ZuniaCallout(
                  tone: ZuniaCalloutTone.warning,
                  title: 'This review is out of date',
                  body:
                      '$drift Nothing was signed. Go back and review the swap again.',
                ),
              ],
              if (feeShort) ...[
                const SizedBox(height: 12),
                const ZuniaCallout(
                  tone: ZuniaCalloutTone.danger,
                  title: 'Not enough left for the network fee',
                  body:
                      'Lower the amount or the fee speed. The chain takes the fee first, then the swap.',
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                ZuniaCallout(
                  tone: ZuniaCalloutTone.danger,
                  title: 'Could not sign',
                  body: _error!,
                ),
              ],
              const SizedBox(height: 14),
              _Details(review: review, quote: _quote, data: data),
            ],
          ),
          footer: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ZuniaButton(
                  label: block?.label ?? 'Sign',
                  size: ZuniaButtonSize.lg,
                  loading: _signing,
                  onPressed: block == null && !_signing ? _sign : null,
                ),
                if (block != null &&
                    block.label != 'Cannot sign' &&
                    block.label != 'Out of date') ...[
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      block.reason,
                      textAlign: TextAlign.center,
                      style: zuniaSans(
                        fontSize: 12,
                        height: 1.35,
                        color: s.fgMuted,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* -------------------------------------------------------------------------- *
 * The card
 * -------------------------------------------------------------------------- */

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.review,
    required this.data,
    required this.quote,
    required this.hidden,
    required this.onEditSpeed,
    required this.clock,
  });

  final SwapReview review;
  final SwapData data;
  final TxQuote quote;
  final bool hidden;
  final VoidCallback? onEditSpeed;
  final Widget clock;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final from = review.from;
    final to = review.to;
    final price = review.price.quote;
    String mask(String text) => hidden ? '••••' : text;

    String receive;
    String receiveLine;
    ({String value, String? note})? minimum;
    switch (review) {
      case ContractSwapReview():
        receive = price == null
            ? '—'
            : '≈ ${swapTickerAmount(price.outputAmount, to.identity)}';
        receiveLine = 'Delivered on ${to.chainName}';
        final slippage = price?.slippagePercent;
        minimum = price == null
            ? null
            : (
                value: swapTickerAmount(price.minReceived, to.identity),
                note:
                    'The contract refuses less than the ${_trim(slippage ?? 0)}% time-weighted price allows; this is today\'s estimate.',
              );
      case PoolSwapReview(
        :final minOut,
        :final venueOutputDenom,
        :final poolPath,
      ):
        final bought = data.book.identityOf(
          data.venueChainId,
          venueOutputDenom,
        );
        if (poolPath == SwapPath.pool) {
          receive = price == null
              ? '—'
              : '≈ ${swapTickerAmount(price.outputAmount, to.identity)}';
          receiveLine = 'On ${to.chainName}';
          minimum = (value: swapTickerAmount(minOut, bought), note: null);
        } else {
          // The transfer sends exactly the floor; what the swap pays above it
          // stays on Osmosis.
          receive = swapTickerAmount(minOut, bought);
          final rest = price == null
              ? BigInt.zero
              : BigInt.parse(price.outputAmount) - BigInt.parse(minOut);
          receiveLine = rest > BigInt.zero
              ? 'Delivered on ${to.chainName} · about ${swapTickerAmount(rest, bought)} more stays on Osmosis'
              : 'Delivered on ${to.chainName}';
          minimum = null;
        }
    }
    final rate = price == null
        ? null
        : swapRateLine(
            price.inputAmount,
            from.identity,
            price.outputAmount,
            to.identity,
          );
    final feeCoin = quote.feeCoin;
    final chain = quote.chain;
    final networkFee = feeCoin == null
        ? 'None'
        : '${formatBaseUnitsExact(feeCoin.amount, decimals: chain.feeDecimals, maxFractionDigits: 6)} ${chain.feeDenom}';

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.surfaceRaisedGradient,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: s.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Side(
              label: 'You pay',
              identity: from.identity,
              chainIconUrl: from.chainIconUrl,
              amount: mask(swapTickerAmount(review.amountUnits, from.identity)),
              line: 'From ${from.chainName}',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.arrow_downward,
                    size: 18,
                    color: s.fgDim,
                    semanticLabel: 'for',
                  ),
                ),
              ),
            ),
            _Side(
              label: 'You receive',
              identity: to.identity,
              chainIconUrl: to.chainIconUrl,
              amount: mask(receive),
              line: receiveLine,
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: s.line),
            const SizedBox(height: 8),
            if (minimum != null)
              SwapFact(
                label: 'Minimum received',
                value: mask(minimum.value),
                note: minimum.note,
              ),
            if (rate != null) SwapFact(label: 'Rate', value: rate),
            if (review.fee.charged)
              SwapFact(
                label: 'Zunia fee (${feeRateText(review.fee.bps)})',
                value: mask(swapTickerAmount(review.fee.fee, from.identity)),
              ),
            SwapFact(
              label: 'Network fee',
              value: networkFee,
              note:
                  '${quote.speed.label} speed${quote.feeNote == null ? '' : ' · ${quote.feeNote}'}',
              trailing: Semantics(
                container: true,
                button: true,
                label: 'Edit the network fee speed',
                excludeSemantics: true,
                child: TextButton(
                  onPressed: onEditSpeed,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 36),
                    foregroundColor: s.accent,
                  ),
                  child: Text(
                    'Edit',
                    style: zuniaMono(fontSize: 11.5, color: s.accent),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            clock,
            if (review.price.error != null && review.price.quote == null)
              Text(
                review.price.error!,
                style: zuniaSans(fontSize: 12, color: s.warning),
              ),
          ],
        ),
      ),
    );
  }

  String _trim(double value) =>
      value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
}

class _Side extends StatelessWidget {
  const _Side({
    required this.label,
    required this.identity,
    required this.chainIconUrl,
    required this.amount,
    required this.line,
  });

  final String label;
  final SwapTokenIdentity identity;
  final String? chainIconUrl;
  final String amount;
  final String line;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      container: true,
      label: '$label $amount. $line',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwapTokenMark(
            identity: identity,
            chainIconUrl: chainIconUrl,
            size: 36,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: zuniaMono(
                    fontSize: 10.5,
                    letterSpacing: 0.8,
                    color: s.fgMuted,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  amount,
                  style: zuniaSans(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.4,
                    color: s.fg,
                    tabular: const FontFeature.tabularFigures(),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  line,
                  style: zuniaSans(
                    fontSize: 12,
                    height: 1.35,
                    color: s.fgMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* -------------------------------------------------------------------------- *
 * Details
 * -------------------------------------------------------------------------- */

class _Details extends StatelessWidget {
  const _Details({
    required this.review,
    required this.quote,
    required this.data,
  });

  final SwapReview review;
  final TxQuote quote;
  final SwapData data;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final rows = <Widget>[];
    final fee = review.fee;
    if (fee.charged) {
      rows.add(_Copyable(label: 'Zunia fee address', value: fee.recipient!));
    }
    switch (review) {
      case final ContractSwapReview contract:
        rows.add(
          _Copyable(
            label: contract.venueOrigin ? 'Contract called' : 'Packet receiver',
            value: contract.contract,
            note:
                contract.contractLabel ??
                'The Osmosis swap contract Zunia verified on chain',
          ),
        );
        rows.add(_Copyable(label: 'Pays out to', value: contract.recipient));
        rows.add(
          _Copyable(label: 'Recovery address', value: contract.recoveryAddress),
        );
      case PoolSwapReview(:final routes, :final delivery):
        rows.add(SwapFact(label: 'Route', value: poolRouteText(routes)));
        if (delivery != null) {
          rows.add(
            SwapFact(label: 'Then sent over', value: delivery.sourceChannel),
          );
          rows.add(_Copyable(label: 'Pays out to', value: review.recipient));
        }
    }
    final summaries = quote.preview.summaries;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        iconColor: s.fgMuted,
        collapsedIconColor: s.fgMuted,
        title: Text(
          'Transaction details',
          style: zuniaSans(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: s.fg,
          ),
        ),
        subtitle: Text(
          '${quote.msgs.length} message${quote.msgs.length == 1 ? '' : 's'} · ${quote.chain.chainName}',
          style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
        ),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...rows,
          const SizedBox(height: 10),
          const ZuniaSectionLabel('What the kernel will sign'),
          const SizedBox(height: 6),
          for (var i = 0; i < summaries.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${i + 1}. ${summaries[i]}',
                style: zuniaMono(fontSize: 11, height: 1.45, color: s.fg),
              ),
            ),
          SwapFact(
            label: 'Memo',
            value: quote.memo.isEmpty ? 'None' : quote.memo,
          ),
          const SizedBox(height: 6),
          _RawJson(quote: quote),
        ],
      ),
    );
  }
}

class _Copyable extends StatelessWidget {
  const _Copyable({required this.label, required this.value, this.note});

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return SwapFact(
      label: label,
      value: truncateAddress(value),
      note: note,
      trailing: IconButton(
        tooltip: 'Copy $label',
        icon: Icon(Icons.copy, size: 16, color: s.fgMuted),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: value));
          ZuniaHaptics.selection();
        },
      ),
    );
  }
}

class _RawJson extends StatelessWidget {
  const _RawJson({required this.quote});

  final TxQuote quote;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final json = const JsonEncoder.withIndent('  ').convert({
      'chainId': quote.chain.chainId,
      'memo': quote.memo,
      'fee': {
        'amount': [
          for (final c in quote.fee.amount)
            {'denom': c.denom, 'amount': c.amount},
        ],
        'gas': '${quote.fee.gasLimit}',
      },
      'messages': [for (final m in quote.msgs) m.toJson()],
    });
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          'Raw transaction',
          style: zuniaSans(fontSize: 13, color: s.fgMuted),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: s.glass,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              json,
              style: zuniaMono(fontSize: 10, height: 1.5, color: s.fg),
            ),
          ),
        ],
      ),
    );
  }
}

/* -------------------------------------------------------------------------- *
 * Result of a swap delivered on Osmosis
 * -------------------------------------------------------------------------- */

/// A pool swap delivered on Osmosis is one transaction there: followed until
/// the chain includes it, or says why not.
class SwapResultScreen extends ConsumerStatefulWidget {
  const SwapResultScreen({
    super.key,
    required this.review,
    required this.txHash,
  });

  final PoolSwapReview review;
  final String txHash;

  @override
  ConsumerState<SwapResultScreen> createState() => _SwapResultScreenState();
}

class _SwapResultScreenState extends ConsumerState<SwapResultScreen> {
  Timer? _timer;
  int _tries = 0;
  bool? _success;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_poll()),
    );
    unawaited(_poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_success != null || _tries >= 60) {
      _timer?.cancel();
      return;
    }
    _tries += 1;
    final data = ref.read(swapDataProvider).valueOrNull;
    final chain = ref
        .read(interchainRegistryProvider)
        .get(data?.venueChainId ?? 'osmosis-1');
    if (chain == null) return;
    try {
      final body = await ref
          .read(lcdFactoryProvider)(chain)
          .getJson(
            '/cosmos/tx/v1beta1/txs/${widget.txHash}',
            const LcdRequestOptions(cacheTtl: Duration.zero),
          );
      final response = body is Map ? body['tx_response'] : null;
      if (response is! Map) return;
      final code = response['code'];
      if (!mounted) return;
      setState(() {
        _success = code == 0 || code == null;
        _failure = _success!
            ? null
            : explainChainError('${response['raw_log'] ?? ''}');
      });
      if (_success!) {
        ZuniaHaptics.success();
      } else {
        ZuniaHaptics.error();
      }
      ref.invalidate(swapHoldingsProvider);
    } on InterchainError {
      // Not indexed yet; ask again on the next tick.
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final review = widget.review;
    final data = ref.watch(swapDataProvider).valueOrNull;
    final quote = review.price.quote;
    final bought = data?.book.identityOf(
      data.venueChainId,
      review.venueOutputDenom,
    );
    final waiting = _success == null && _tries < 60;
    final title = _success == true
        ? 'Swapped'
        : _success == false
        ? 'Swap failed'
        : 'Swap sent';
    final url = data?.config.explorerTxUrl(data.venueChainId, widget.txHash);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: title,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
            children: [
              Center(
                child: _success == null
                    ? const ZuniaActivityIndicator(size: 36)
                    : Icon(
                        _success! ? Icons.check_circle : Icons.error,
                        size: 52,
                        color: _success! ? s.success : s.danger,
                        semanticLabel: _success! ? 'Swapped' : 'Failed',
                      ),
              ),
              const SizedBox(height: 16),
              Text(
                quote == null
                    ? '—'
                    : '≈ ${swapTickerAmount(quote.outputAmount, review.to.identity)}',
                textAlign: TextAlign.center,
                style: zuniaSans(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: s.fg,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'for ${swapTickerAmount(review.fee.net, review.from.identity)}'
                '${bought == null ? '' : ' · at least ${swapTickerAmount(review.minOut, bought)}'}',
                textAlign: TextAlign.center,
                style: zuniaMono(fontSize: 11.5, color: s.fgMuted),
              ),
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Text(
                  _failure ??
                      (_success == true
                          ? 'It is in your Osmosis account. Balances update in a few seconds.'
                          : waiting
                          ? 'Waiting for Osmosis to include it.'
                          : 'Osmosis has not confirmed it here yet. The explorer shows it as soon as it is in a block.'),
                  textAlign: TextAlign.center,
                  style: zuniaSans(
                    fontSize: 13,
                    height: 1.45,
                    color: _failure != null ? s.danger : s.fgMuted,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(
                widget.txHash,
                textAlign: TextAlign.center,
                style: zuniaMono(fontSize: 10.5, color: s.fgDim),
              ),
            ],
          ),
          footer: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                if (url != null) ...[
                  Expanded(
                    child: ZuniaButton(
                      label: 'Explorer',
                      variant: ZuniaButtonVariant.secondary,
                      onPressed: () => launchUrl(
                        Uri.parse(url),
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: ZuniaButton(
                    label: 'Done',
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
