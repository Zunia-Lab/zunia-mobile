/// Review, sign and follow one wallet transaction: the flow every Earn and
/// Governance action ends in.
///
/// 1. [TxReviewScreen] asks [TxEngine.quote] for the account, the simulated
///    gas and the kernel's own description of what will be signed, and shows
///    them with the fee at the chosen speed.
/// 2. Sign goes through [confirmSigning], then [TxEngine.signAndBroadcast],
///    which refuses to sign bytes other than the ones reviewed.
/// 3. [TxResultScreen] says "Confirming" until the transaction is in a block,
///    then what the block decided, with an explorer link when one is known.
///
/// Candidate for promotion: nothing here is specific to staking.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_core/zunia_core.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/notifications/device_alerts.dart';
import 'package:zunia_mobile/notifications/notifications.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/tx/explorer_links.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/tx/tx_inclusion.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';
import 'package:zunia_mobile/ui/facts.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Wording for the result page of one kind of transaction.
@immutable
class TxResultCopy {
  const TxResultCopy({
    required this.sending,
    required this.done,
    required this.failed,
    required this.doneMessage,
  });

  /// "Staking"
  final String sending;

  /// "Staked"
  final String done;

  /// "Stake failed"
  final String failed;

  /// One sentence on what being done means.
  final String doneMessage;
}

/// What the user is about to do, worded for people; the messages are what
/// gets signed.
@immutable
class TxIntent {
  const TxIntent({
    required this.title,
    required this.action,
    required this.chain,
    required this.signer,
    required this.msgs,
    required this.headlineLabel,
    required this.headline,
    required this.result,
    this.headlineLine,
    this.facts = const [],
    this.notice,
    this.memo = '',
    this.gainBaseUnits,
    this.offerNotifications = false,
    this.onSettled,
  });

  /// Screen title: "Review stake".
  final String title;

  /// Sign button: "Sign stake".
  final String action;
  final ChainEntry chain;
  final String signer;
  final List<TxMsg> msgs;

  /// "You stake", "You claim", "Your vote".
  final String headlineLabel;

  /// "10 ATOM", "Yes".
  final String headline;

  /// "With Figment · Cosmos Hub".
  final String? headlineLine;
  final List<({String label, String value})> facts;

  /// A consequence the user must see before signing (the unbonding period).
  final String? notice;
  final String memo;

  /// For a claim: what it brings in, in base units of the fee denom, so the
  /// review can say when the fee is larger than the gain.
  final BigInt? gainBaseUnits;

  /// After it lands, offer device notifications if they are off.
  final bool offerNotifications;
  final TxResultCopy result;

  /// Called once the transaction is in a block (or failed there), so the
  /// screens behind can re-read.
  final VoidCallback? onSettled;
}

/// Whether the flow ended with the transaction in a block.
class TxOutcome {
  bool included = false;
}

/// Push the review for [intent]. Done on the result page returns to
/// [returnTo] (the screen that called this, by default), and the future
/// completes with true when the transaction made it into a block.
Future<bool> showTxReview(
  BuildContext context,
  TxIntent intent, {
  ModalRoute<dynamic>? returnTo,
}) async {
  final origin = returnTo ?? ModalRoute.of(context);
  final outcome = TxOutcome();
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          TxReviewScreen(intent: intent, origin: origin, outcome: outcome),
    ),
  );
  return outcome.included;
}

String _feeText(TxQuote quote) {
  final coin = quote.feeCoin;
  if (coin == null) return 'No fee';
  final chain = quote.chain;
  final feeDenom =
      chain.feeMinimalDenom.isEmpty ? chain.coinMinimalDenom : chain.feeMinimalDenom;
  if (coin.denom == feeDenom) {
    final decimals =
        chain.feeMinimalDenom.isEmpty ? chain.coinDecimals : chain.feeDecimals;
    final symbol = chain.feeDenom.isEmpty ? chain.coinDenom : chain.feeDenom;
    return '${formatBaseUnitsExact(coin.amount, decimals: decimals, maxFractionDigits: 6)} $symbol';
  }
  return '${coin.amount} ${coin.denom}';
}

String _groupDigits(int value) {
  final text = value.toString();
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 == 0) out.write(',');
    out.write(text[i]);
  }
  return out.toString();
}

class TxReviewScreen extends ConsumerStatefulWidget {
  const TxReviewScreen({
    super.key,
    required this.intent,
    this.origin,
    this.outcome,
  });

  final TxIntent intent;

  /// The route the flow started from; Done returns there.
  final ModalRoute<dynamic>? origin;
  final TxOutcome? outcome;

  @override
  ConsumerState<TxReviewScreen> createState() => _TxReviewScreenState();
}

class _TxReviewScreenState extends ConsumerState<TxReviewScreen> {
  TxQuote? _quote;
  String? _error;
  bool _quoting = true;
  bool _signing = false;
  bool _details = false;
  FeeSpeed _speed = FeeSpeed.average;

  TxIntent get intent => widget.intent;

  @override
  void initState() {
    super.initState();
    unawaited(_requote());
  }

  Future<void> _requote() async {
    setState(() {
      _quoting = true;
      _error = null;
    });
    final phrase = ref.read(phraseProvider);
    final account = ref.read(walletProvider).active;
    if (phrase == null || account == null) {
      setState(() {
        _quoting = false;
        _error = 'Unlock the wallet to review this transaction.';
      });
      return;
    }
    try {
      final quote = await TxEngine.instance.quote(
        phrase: phrase,
        accountIndex: account.index,
        chain: intent.chain,
        signer: intent.signer,
        msgs: intent.msgs,
        memo: intent.memo,
        speed: _speed,
      );
      if (!mounted) return;
      setState(() {
        _quote = quote;
        _quoting = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _quoting = false;
        _error = e is TxException ? e.message : explainChainError('$e');
      });
    }
  }

  void _reprice(FeeSpeed speed) {
    final quote = _quote;
    setState(() => _speed = speed);
    if (quote == null) return;
    try {
      setState(() => _quote = TxEngine.instance.reprice(quote, speed));
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _sign() async {
    final quote = _quote;
    final phrase = ref.read(phraseProvider);
    final account = ref.read(walletProvider).active;
    if (quote == null || phrase == null || account == null) return;
    // "Password on every signature" is asked inside TxEngine.signAndBroadcast.
    if (!mounted) return;
    setState(() => _signing = true);
    unawaited(ZuniaHaptics.medium());
    final retry = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TxResultScreen(
          intent: intent,
          origin: widget.origin,
          outcome: widget.outcome,
          send: () => TxEngine.instance.signAndBroadcast(
            phrase: phrase,
            accountIndex: account.index,
            quote: quote,
          ),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _signing = false);
    // Back from a failure: the sequence or the fee may have moved, so the
    // next attempt starts from a fresh quote.
    if (retry == true) await _requote();
  }

  @override
  Widget build(BuildContext context) {
    final quote = _quote;
    final feeCoin = quote?.feeCoin;
    final gain = intent.gainBaseUnits;
    final feeExceedsGain = gain != null &&
        feeCoin != null &&
        (BigInt.tryParse(feeCoin.amount) ?? BigInt.zero) >= gain;

    return Scaffold(
      backgroundColor: zuniaGroundTop(context),
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: intent.title,
          onBack: () => Navigator.of(context).maybePop(),
          footer: Semantics(
            button: true,
            label: intent.action,
            child: ZuniaButton(
              label: _quoting
                  ? 'Preparing…'
                  : quote == null
                      ? 'Cannot sign yet'
                      : intent.action,
              size: ZuniaButtonSize.lg,
              loading: _signing,
              onPressed:
                  quote == null || _quoting || _signing ? null : _sign,
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              _Headline(intent: intent),
              if (intent.facts.isNotEmpty) ...[
                const SizedBox(height: 12),
                FactsCard(
                  children: [
                    for (final fact in intent.facts)
                      FactRow(label: fact.label, value: fact.value),
                  ],
                ),
              ],
              if (intent.notice != null) ...[
                const SizedBox(height: 12),
                ZuniaCallout(
                  tone: ZuniaCalloutTone.warning,
                  body: intent.notice!,
                ),
              ],
              const SectionCaption('Network fee'),
              if (_quoting && quote == null)
                const ListSkeleton(rows: 2, label: 'Simulating the transaction')
              else if (quote == null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ZuniaCallout(
                      tone: ZuniaCalloutTone.danger,
                      title: 'This transaction cannot be prepared',
                      body: _error ?? 'Unknown error',
                    ),
                    const SizedBox(height: 12),
                    ZuniaButton(
                      label: 'Try again',
                      variant: ZuniaButtonVariant.secondary,
                      onPressed: _requote,
                    ),
                  ],
                )
              else ...[
                ZuniaSegmented<FeeSpeed>(
                  value: _speed,
                  onChanged: _reprice,
                  options: {
                    for (final speed in FeeSpeed.values) speed: speed.label,
                  },
                ),
                const SizedBox(height: 10),
                FactsCard(
                  children: [
                    FactRow(
                      label: 'Fee',
                      value: _feeText(quote),
                      emphasis: true,
                    ),
                    FactRow(
                      label: 'Gas limit',
                      value: quote.gasUsed == null
                          ? '${_groupDigits(quote.fee.gasLimit)} (not simulated)'
                          : '${_groupDigits(quote.fee.gasLimit)} '
                              '(${_groupDigits(quote.gasUsed!)} simulated)',
                    ),
                    FactRow(label: 'Network', value: intent.chain.chainName),
                  ],
                ),
                if (quote.feeNote != null) ...[
                  const SizedBox(height: 10),
                  ZuniaCallout(
                    tone: ZuniaCalloutTone.warning,
                    body: quote.feeNote!,
                  ),
                ],
                if (feeExceedsGain) ...[
                  const SizedBox(height: 10),
                  const ZuniaCallout(
                    tone: ZuniaCalloutTone.warning,
                    body: 'The fee is larger than what this claims. You would '
                        'end up with less than you have now.',
                  ),
                ],
                const SizedBox(height: 6),
                _Disclosure(
                  open: _details,
                  onToggle: () => setState(() => _details = !_details),
                  title: 'What you sign',
                  child: _SignedDetails(quote: quote),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.intent});

  final TxIntent intent;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.surfaceRaisedGradient,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: s.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: MergeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                intent.headlineLabel.toUpperCase(),
                style: zuniaMono(
                  fontSize: 10.5,
                  letterSpacing: 1.4,
                  color: s.fgDim,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                intent.headline,
                style: zuniaSans(
                  fontSize: 26,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.8,
                  color: s.fg,
                  tabular: const FontFeature.tabularFigures(),
                ),
              ),
              if (intent.headlineLine != null) ...[
                const SizedBox(height: 6),
                Text(
                  intent.headlineLine!,
                  style: zuniaSans(fontSize: 13, color: s.fgMuted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Disclosure extends StatelessWidget {
  const _Disclosure({
    required this.open,
    required this.onToggle,
    required this.title,
    required this.child,
  });

  final bool open;
  final VoidCallback onToggle;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: open,
          label: title,
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: zuniaSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: s.fg,
                      ),
                    ),
                  ),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: s.fgMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: open ? child : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _SignedDetails extends StatelessWidget {
  const _SignedDetails({required this.quote});

  final TxQuote quote;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final preview = quote.preview;
    final hash = preview.signBytesHash.replaceFirst('0x', '');
    return FactsCard(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 4),
          child: Text(
            'As the signing core reads it',
            style: zuniaSans(fontSize: 12.5, color: s.fgMuted),
          ),
        ),
        for (final line in preview.summaries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              line,
              style: zuniaMono(fontSize: 12, height: 1.45, color: s.fg),
            ),
          ),
        const SizedBox(height: 6),
        FactRow(label: 'Signer', value: quote.signer),
        FactRow(label: 'Chain ID', value: preview.chainId),
        FactRow(
          label: 'Account / sequence',
          value: '${quote.accountNumber} / ${quote.sequence}',
        ),
        FactRow(
          label: 'Memo',
          value: preview.memo.isEmpty ? 'None' : preview.memo,
        ),
        FactRow(
          label: 'Sign mode',
          value: preview.mode == ZuniaSignMode.direct ? 'Direct' : 'Amino',
        ),
        FactRow(
          label: 'Bytes signed (SHA-256)',
          value: hash.length > 24
              ? '${hash.substring(0, 12)}…${hash.substring(hash.length - 12)}'
              : hash,
        ),
      ],
    );
  }
}

enum _Phase { sending, confirming, done, failed, unconfirmed }

class TxResultScreen extends ConsumerStatefulWidget {
  const TxResultScreen({
    super.key,
    required this.intent,
    required this.send,
    this.origin,
    this.outcome,
  });

  final TxIntent intent;

  /// Signs and broadcasts; returns the hash.
  final Future<String> Function() send;
  final ModalRoute<dynamic>? origin;
  final TxOutcome? outcome;

  @override
  ConsumerState<TxResultScreen> createState() => _TxResultScreenState();
}

class _TxResultScreenState extends ConsumerState<TxResultScreen> {
  _Phase _phase = _Phase.sending;
  String? _hash;
  String? _error;
  String? _height;
  Uri? _explorer;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final intent = widget.intent;
    try {
      final hash = await widget.send();
      if (!mounted) return;
      setState(() {
        _hash = hash;
        _phase = _Phase.confirming;
      });
      unawaited(
        explorerTxUrl(intent.chain.chainId, hash).then((url) {
          if (mounted) setState(() => _explorer = url);
        }),
      );
      final inclusion = await waitForInclusion(intent.chain, hash);
      if (!mounted) return;
      switch (inclusion) {
        case Included(:final height):
          widget.outcome?.included = true;
          setState(() {
            _phase = _Phase.done;
            _height = height;
          });
          unawaited(ZuniaHaptics.success());
        case FailedInBlock(:final message):
          setState(() {
            _phase = _Phase.failed;
            _error = message;
          });
          unawaited(ZuniaHaptics.error());
        case NotYetSeen():
          setState(() => _phase = _Phase.unconfirmed);
      }
      intent.onSettled?.call();
    } on Object catch (e) {
      if (!mounted) return;
      final message = e is TxException ? e.message : explainChainError('$e');
      final hash = e is TxException ? e.txhash : null;
      setState(() {
        _phase = _Phase.failed;
        _error = message;
        _hash = hash;
      });
      unawaited(ZuniaHaptics.error());
      if (hash != null) {
        unawaited(
          explorerTxUrl(intent.chain.chainId, hash).then((url) {
            if (mounted) setState(() => _explorer = url);
          }),
        );
      }
    }
  }

  void _finish() {
    final origin = widget.origin;
    final nav = Navigator.of(context);
    if (origin != null && origin.isActive) {
      nav.popUntil((route) => route == origin);
    } else {
      nav.pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final copy = widget.intent.result;
    final busy = _phase == _Phase.sending || _phase == _Phase.confirming;
    final title = switch (_phase) {
      _Phase.sending || _Phase.confirming => copy.sending,
      _Phase.done => copy.done,
      _Phase.failed => copy.failed,
      _Phase.unconfirmed => 'Sent',
    };
    final message = switch (_phase) {
      _Phase.sending => 'Signing on this device and sending to '
          '${widget.intent.chain.chainName}.',
      _Phase.confirming =>
        'Sent. Waiting for ${widget.intent.chain.chainName} to include it in a block.',
      _Phase.done => copy.doneMessage,
      _Phase.failed => _error ?? 'The network did not accept it.',
      _Phase.unconfirmed =>
        '${widget.intent.chain.chainName} accepted it but has not put it in a '
            'block yet. The explorer will show when it lands.',
    };

    return PopScope(
      canPop: !busy,
      child: Scaffold(
        backgroundColor: zuniaGroundTop(context),
        body: SafeArea(
          bottom: false,
          child: ZuniaScreenScaffold(
            title: title,
            onBack: busy ? null : _finish,
            footer: busy
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_explorer != null) ...[
                        ZuniaButton(
                          label: 'View on explorer',
                          variant: ZuniaButtonVariant.secondary,
                          size: ZuniaButtonSize.lg,
                          leading: const Icon(Icons.open_in_new),
                          onPressed: () => launchUrl(
                            _explorer!,
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      if (_phase == _Phase.failed && _hash == null) ...[
                        ZuniaButton(
                          label: 'Back to review',
                          variant: ZuniaButtonVariant.secondary,
                          size: ZuniaButtonSize.lg,
                          onPressed: () => Navigator.of(context).pop(true),
                        ),
                        const SizedBox(height: 10),
                      ],
                      ZuniaButton(
                        label: 'Done',
                        size: ZuniaButtonSize.lg,
                        onPressed: _finish,
                      ),
                    ],
                  ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
              children: [
                Center(child: _StatusMark(phase: _phase)),
                const SizedBox(height: 20),
                Semantics(
                  liveRegion: true,
                  child: Column(
                    children: [
                      Text(
                        widget.intent.headline,
                        textAlign: TextAlign.center,
                        style: zuniaSans(
                          fontSize: 26,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -0.8,
                          color: s.fg,
                          tabular: const FontFeature.tabularFigures(),
                        ),
                      ),
                      if (widget.intent.headlineLine != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          widget.intent.headlineLine!,
                          textAlign: TextAlign.center,
                          style: zuniaSans(fontSize: 13.5, color: s.fgMuted),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: zuniaSans(
                          fontSize: 14,
                          height: 1.45,
                          color: _phase == _Phase.failed ? s.dangerFg : s.fgMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_hash != null) ...[
                  const SizedBox(height: 22),
                  FactsCard(
                    children: [
                      FactRow(
                        label: 'Transaction',
                        value: _hash!,
                        valueWidget: _CopyHash(hash: _hash!),
                      ),
                      if (_height != null)
                        FactRow(label: 'Block', value: _height!),
                    ],
                  ),
                ],
                if (_phase == _Phase.done && widget.intent.offerNotifications)
                  const _NotifyOffer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusMark extends StatelessWidget {
  const _StatusMark({required this.phase});

  final _Phase phase;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final (IconData? icon, Color color) = switch (phase) {
      _Phase.sending || _Phase.confirming => (null, s.accent),
      _Phase.done => (Icons.check_rounded, s.success),
      _Phase.failed => (Icons.close_rounded, s.danger),
      _Phase.unconfirmed => (Icons.schedule_rounded, s.warning),
    };
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      alignment: Alignment.center,
      child: icon == null
          ? const ZuniaActivityIndicator(size: 28)
          : Icon(icon, size: 34, color: color),
    );
  }
}

class _CopyHash extends StatelessWidget {
  const _CopyHash({required this.hash});

  final String hash;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final short = hash.length > 20
        ? '${hash.substring(0, 8)}…${hash.substring(hash.length - 8)}'
        : hash;
    return Semantics(
      button: true,
      label: 'Copy transaction hash',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: hash));
          unawaited(ZuniaHaptics.selection());
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Transaction hash copied')),
          );
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                short,
                style: zuniaMono(fontSize: 12.5, color: s.fg),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.copy_rounded, size: 14, color: s.fgMuted),
          ],
        ),
      ),
    );
  }
}

/// After a stake or claim lands: the moment notifications are worth asking
/// for, because there is now something to be told about.
class _NotifyOffer extends ConsumerWidget {
  const _NotifyOffer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permission = ref.watch(alertPermissionProvider).valueOrNull;
    if (permission != AlertPermission.off &&
        permission != AlertPermission.provisional) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: ZuniaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ZuniaCallout(
              title: 'Know when rewards are ready',
              body: 'Zunia can tell you, once per cycle, when staking rewards '
                  'are ready to claim. Nothing leaves this phone for it.',
            ),
            const SizedBox(height: 12),
            ZuniaButton(
              label: 'Turn on notifications',
              variant: ZuniaButtonVariant.secondary,
              onPressed: () async {
                final ok = await enableDeviceNotifications(ref);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      ok
                          ? 'Notifications are on.'
                          : 'Notifications are off in system settings.',
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
