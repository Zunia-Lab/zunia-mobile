/// Swap: sell any token the wallet holds for any token Osmosis trades,
/// delivered on the chain the user picks.
///
/// Matches zunia-extension 0.1.5 in logic (`lib/state/swap_state.dart` holds
/// it); this file is the native form. Four paths reach Osmosis: the
/// crosschain-swaps contract (one signature on the chain holding the funds),
/// Osmosis's own pools for funds already there (optionally sending the
/// output on in the same transaction), and moving the funds to Osmosis first
/// when the contract cannot swap the pair where they are. Every control that
/// cannot work yet is disabled with the reason under it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/send_screen.dart';
import 'package:zunia_mobile/screens/swap/swap_settings_sheet.dart';
import 'package:zunia_mobile/screens/swap/swap_token_sheet.dart';
import 'package:zunia_mobile/screens/swap/swap_widgets.dart';
import 'package:zunia_mobile/screens/swap_review_screen.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/swap/pool_swap.dart';
import 'package:zunia_mobile/swap/swap_amounts.dart';
import 'package:zunia_mobile/swap/swap_assets.dart';
import 'package:zunia_mobile/swap/swap_fee.dart';
import 'package:zunia_mobile/swap/swap_path.dart';
import 'package:zunia_mobile/swap/swap_review.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/wallet_header.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// A token's fiat value, when a price source exists for it. Null hides the
/// hint. INTEGRATION NOTE: this branch has no price source; the portfolio
/// workstream's prices plug in here and nowhere else.
typedef SwapFiatOf = String? Function(SwapAsset asset, BigInt units);

final swapFiatProvider = Provider<SwapFiatOf>(
  (ref) =>
      (asset, units) => null,
);

class SwapTab extends ConsumerStatefulWidget {
  const SwapTab({super.key, this.showHeader = true});

  /// When false, the wallet chrome is omitted (full-page push from Home).
  final bool showHeader;

  @override
  ConsumerState<SwapTab> createState() => _SwapTabState();
}

class _SwapTabState extends ConsumerState<SwapTab> with WidgetsBindingObserver {
  final _amount = TextEditingController();
  Timer? _debounce;
  Timer? _refreshTimer;
  Timer? _ticker;
  bool _busy = false;
  String? _error;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A view built before this widget mounted may already be plannable.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _schedulePlan(ref.read(swapViewProvider).planKey);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _refreshTimer?.cancel();
    _ticker?.cancel();
    _amount.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _scheduleRefresh(ref.read(swapViewProvider));
  }

  /// Plan after the inputs settle: the amount field fires per keystroke and a
  /// plan is several round trips.
  void _schedulePlan(String key) {
    _debounce?.cancel();
    if (key.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      final view = ref.read(swapViewProvider);
      if (view.planKey == key) {
        unawaited(ref.read(swapControllerProvider.notifier).plan(view));
      }
    });
  }

  /// The form keeps the price current on its own, while it is on screen. The
  /// confirm card does not: a number changing under the user's thumb right
  /// before they sign is worse than asking them to refresh it.
  void _scheduleRefresh(SwapView view) {
    _refreshTimer?.cancel();
    final at = view.quotedAt;
    final ttl = view.data?.config.quoteTtl;
    if (at == null || ttl == null || view.planKey.isEmpty) return;
    final due = at.add(ttl).difference(ref.read(swapClockProvider)());
    _refreshTimer = Timer(due.isNegative ? Duration.zero : due, () {
      if (!mounted || !_visible()) return;
      final current = ref.read(swapViewProvider);
      if (current.planKey == view.planKey && !current.refreshing) {
        unawaited(ref.read(swapControllerProvider.notifier).refresh(current));
      }
    });
  }

  bool _visible() =>
      _foreground &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      TickerMode.valuesOf(context).enabled;

  void _syncTicker(SwapView view) {
    final wanted = view.quotedAt != null;
    if (wanted && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || !_visible()) return;
        setState(() {});
        // Back on screen after the price ran out (the review was open, or the
        // app was away): fetch a new one rather than wait for a tap.
        final current = ref.read(swapViewProvider);
        final at = current.quotedAt;
        final ttl = current.data?.config.quoteTtl;
        if (at != null &&
            ttl != null &&
            !current.refreshing &&
            current.planKey.isNotEmpty &&
            ref.read(swapClockProvider)().difference(at) >= ttl) {
          unawaited(_controller.refresh(current));
        }
      });
    } else if (!wanted && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  SwapController get _controller => ref.read(swapControllerProvider.notifier);

  Future<void> _pickFrom(SwapView view) async {
    final key = await showSwapTokenSheet(
      context,
      title: 'You pay',
      options: view.sources,
      selectedKey: view.from?.key,
      hideAmounts: ref.read(preferencesProvider).hideAmounts,
    );
    if (key == null || !mounted) return;
    _controller.pickFrom(key);
    _amount.clear();
  }

  Future<void> _pickTo(SwapView view) async {
    final key = await showSwapTokenSheet(
      context,
      title: 'You receive',
      options: view.destinations,
      selectedKey: view.to?.key,
      hideAmounts: ref.read(preferencesProvider).hideAmounts,
    );
    if (key == null || !mounted) return;
    _controller.pickTo(key);
  }

  void _flip(SwapView view) {
    if (_controller.flip(view)) {
      ZuniaHaptics.selection();
      final next = ref.read(swapViewProvider);
      _amount.text = next.amountText;
    }
  }

  void _max(SwapView view) {
    _controller.applyMax(view);
    ZuniaHaptics.selection();
    _amount.text = ref.read(swapViewProvider).amountText;
  }

  Future<void> _openSettings(SwapView view) async {
    final data = view.data;
    if (data == null) return;
    await showSwapSettingsSheet(
      context,
      config: data.config,
      settings: ref.read(swapSettingsProvider),
      onSave: (next) =>
          unawaited(ref.read(swapSettingsProvider.notifier).update(next)),
    );
  }

  Future<void> _review(SwapView view) async {
    final phrase = ref.read(phraseProvider);
    final index = ref.read(walletProvider).active?.index ?? 0;
    if (phrase == null) {
      setState(() => _error = 'Unlock the wallet to swap.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final prepared = await _controller.prepareReview(view);
      final settings = ref.read(swapSettingsProvider);
      final quote = await TxEngine.instance.quote(
        phrase: phrase,
        accountIndex: index,
        chain: prepared.chain,
        signer: prepared.review.signer,
        msgs: prepared.msgs,
        memo: prepared.memo,
        speed: settings.feeSpeed,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      final done = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => SwapReviewScreen(prepared: prepared, quote: quote),
        ),
      );
      if (done == true && mounted) {
        _controller.clearAmount();
        _amount.clear();
        ref.invalidate(swapHoldingsProvider);
      }
    } on Object catch (error) {
      if (!mounted) return;
      ZuniaHaptics.error();
      setState(() {
        _busy = false;
        _error = error is TxException ? error.message : '$error';
      });
    }
  }

  Future<void> _moveFirst(SwapView view) async {
    final from = view.from;
    if (from == null) return;
    await _controller.rememberMoveFirst(view);
    if (!mounted) return;
    // Send has no token or destination prefill yet: it opens on the chain the
    // tokens are on, and the callout above says where to send them.
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SendScreen(chainId: from.chainId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final accounts = ref.watch(chainAccountsProvider);
    final prefs = ref.watch(preferencesProvider);
    final view = ref.watch(swapViewProvider);
    final settings = ref.watch(swapSettingsProvider);

    ref.listen<String>(
      swapViewProvider.select((v) => v.planKey),
      (_, key) => _schedulePlan(key),
    );
    ref.listen<DateTime?>(swapViewProvider.select((v) => v.quotedAt), (_, _) {
      _scheduleRefresh(ref.read(swapViewProvider));
    });
    _syncTicker(view);

    // The field follows the form when it changes from elsewhere (a pick, a
    // review that pinned the pair, an intent restored on open).
    if (_amount.text != view.amountText && !FocusScope.of(context).hasFocus) {
      _amount.text = view.amountText;
    }

    if (accounts.isEmpty) {
      return _Shell(
        showHeader: widget.showHeader,
        child: Center(
          child: ZuniaEmptyState(
            title: 'No networks enabled',
            description: 'Enable a network that holds tokens to swap them.',
            action: ZuniaButton(
              label: 'Networks',
              size: ZuniaButtonSize.sm,
              variant: ZuniaButtonVariant.secondary,
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const NetworksScreen())),
            ),
          ),
        ),
      );
    }

    final from = view.from;
    final to = view.to;
    final moveFirst = view.path == SwapPath.moveFirst;
    final reason =
        _error ??
        (moveFirst
            ? view.moveBlocked
            : (view.ready ? null : view.blockedReason));

    return _Shell(
      showHeader: widget.showHeader,
      title: _TitleRow(
        onSettings: view.data == null ? null : () => _openSettings(view),
      ),
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (moveFirst && from != null)
              ZuniaButton(
                label: 'Move to Osmosis',
                size: ZuniaButtonSize.lg,
                onPressed: view.moveBlocked == null && !_busy
                    ? () => _moveFirst(view)
                    : null,
              )
            else
              ZuniaButton(
                label: _busy ? 'Getting price…' : 'Review swap',
                size: ZuniaButtonSize.lg,
                loading: _busy,
                onPressed: view.ready && !_busy ? () => _review(view) : null,
              ),
            if (reason != null) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  reason,
                  textAlign: TextAlign.center,
                  style: zuniaSans(
                    fontSize: 12,
                    height: 1.35,
                    color: _error != null ? s.danger : s.fgMuted,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      child: view.loading
          ? const _FormSkeleton()
          : view.sources.isEmpty && view.holdingsLoaded
          ? Center(
              child: ZuniaEmptyState(
                title: 'Nothing to swap yet',
                description: prefs.liveReads
                    ? 'This wallet holds no tokens on its enabled networks.'
                    : 'Turn on live reads in Settings to see what this wallet holds.',
              ),
            )
          : ZuniaRefresh(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  _PayCard(
                    view: view,
                    controller: _amount,
                    hidden: prefs.hideAmounts,
                    fiat: from == null || view.amountUnits == null
                        ? null
                        : ref.watch(swapFiatProvider)(from, view.amountUnits!),
                    onPick: () => _pickFrom(view),
                    onMax: () => _max(view),
                    onChanged: (text) {
                      if (from != null) _controller.setAmount(text, from);
                    },
                  ),
                  _FlipButton(view: view, onFlip: () => _flip(view)),
                  _ReceiveCard(
                    view: view,
                    fiat: to == null || view.quote == null
                        ? null
                        : ref.watch(swapFiatProvider)(
                            to,
                            BigInt.parse(view.quote!.outputAmount),
                          ),
                    onPick: () => _pickTo(view),
                  ),
                  const SizedBox(height: 14),
                  _Fees(view: view, settings: settings),
                  if (view.quote != null && view.quotedAt != null) ...[
                    const SizedBox(height: 4),
                    SwapQuoteClock(
                      secondsLeft: _secondsLeft(view),
                      refreshing: view.refreshing,
                      onRefresh: () => unawaited(_controller.refresh(view)),
                    ),
                  ],
                  ..._notes(context, view),
                  if (settings.routeDetails) ...[
                    const SizedBox(height: 12),
                    _RouteDetails(view: view),
                  ],
                ],
              ),
            ),
    );
  }

  /// Pull to refresh: read the balances again and plan the same inputs anew.
  Future<void> _reload() async {
    ref.invalidate(swapHoldingsProvider);
    _controller.retry();
    try {
      await ref.read(swapHoldingsProvider.future);
    } on Object {
      // The form says what is missing; the gesture just ends.
    }
  }

  int _secondsLeft(SwapView view) {
    final at = view.quotedAt;
    final ttl = view.data?.config.quoteTtl;
    if (at == null || ttl == null) return 0;
    final left = ttl - ref.read(swapClockProvider)().difference(at);
    return left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil();
  }

  List<Widget> _notes(BuildContext context, SwapView view) {
    final from = view.from;
    final to = view.to;
    final out = <Widget>[];
    void add(Widget widget) => out
      ..add(const SizedBox(height: 12))
      ..add(widget);

    if (!view.liveReads) {
      add(
        const ZuniaCallout(
          tone: ZuniaCalloutTone.warning,
          title: 'Live reads are off',
          body:
              'Swapping reads balances, routes and prices from public endpoints. Turn live reads on in Settings.',
        ),
      );
    }
    if (view.path == SwapPath.moveFirst && from != null && to != null) {
      final quote = view.quote;
      add(
        ZuniaCallout(
          tone: ZuniaCalloutTone.info,
          title: 'Two steps, both on Osmosis',
          body:
              "Osmosis's swap contract has no route from ${from.ticker} to ${to.ticker}, "
              "and Osmosis's own pools swap only tokens already on Osmosis.\n"
              '1. Move your ${from.ticker} from ${from.chainName} to your Osmosis address with Send: '
              'an IBC transfer, with no Zunia fee.\n'
              '2. Come back here: Swap opens on your ${from.ticker} on Osmosis and swaps it in one '
              'transaction${quote == null ? '' : ', for about ${swapTickerAmount(quote.outputAmount, to.identity)} at today\'s price'}.',
        ),
      );
    }
    if (view.path == SwapPath.poolDeliver &&
        to != null &&
        view.pool?.quote.minOut != null) {
      final bought = view.data!.book.identityOf(
        view.venueChainId,
        view.pool!.venueOutputDenom,
      );
      add(
        Text(
          'In the same transaction, ${swapTickerAmount(view.pool!.quote.minOut!, bought)} '
          "(the swap's guaranteed minimum) goes on to your address on ${to.chainName}. "
          'Anything the swap pays above it stays in your Osmosis account.',
          style: zuniaSans(
            fontSize: 12,
            height: 1.45,
            color: ZuniaSemanticsExt.of(context).fgMuted,
          ),
        ),
      );
    }
    if (view.path == SwapPath.contract &&
        view.venue != null &&
        !view.venue!.ready &&
        !view.venueLoading) {
      add(
        ZuniaCallout(
          tone: ZuniaCalloutTone.danger,
          title: 'Cross-chain swaps are off',
          body:
              view.venue!.reason ?? 'The swap contract could not be confirmed.',
        ),
      );
    }
    if (view.quoteError != null && !view.planning) {
      add(
        ZuniaCallout(
          tone: ZuniaCalloutTone.danger,
          title: 'No price for this swap',
          body: view.quoteError!,
        ),
      );
    }
    if (view.fee != null &&
        view.fee!.charged &&
        view.path == SwapPath.contract &&
        view.from?.chainId != view.venueChainId) {
      add(
        Text(
          'If the swap fails on Osmosis, the amount swapped comes back to you, but the ${feeRateText(view.fee!.bps)} Zunia fee does not.',
          style: zuniaSans(
            fontSize: 12,
            height: 1.45,
            color: ZuniaSemanticsExt.of(context).fgMuted,
          ),
        ),
      );
    }
    if (view.osmosisError != null) {
      add(
        Text(
          'The Osmosis token list did not load (${view.osmosisError}), so only chain coins and your own tokens are offered to receive.',
          style: zuniaSans(
            fontSize: 12,
            height: 1.45,
            color: ZuniaSemanticsExt.of(context).fgMuted,
          ),
        ),
      );
    }
    return out;
  }
}

/* -------------------------------------------------------------------------- *
 * Layout pieces
 * -------------------------------------------------------------------------- */

class _Shell extends StatelessWidget {
  const _Shell({
    required this.child,
    this.footer,
    this.title,
    this.showHeader = true,
  });

  final Widget child;
  final Widget? footer;
  final Widget? title;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(gradient: s.screenGradient),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeader)
            WalletHeader(
              onOpenNetworks: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const NetworksScreen())),
            ),
          ?title,
          Expanded(child: child),
          ?footer,
        ],
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.onSettings});

  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 8, 2),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 8,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    'Swap',
                    style: zuniaSans(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.4,
                      color: s.fg,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    'via Osmosis',
                    style: zuniaSans(fontSize: 12, color: s.fgDim),
                  ),
                ),
              ],
            ),
          ),
          ZuniaIconButton(
            label: 'Swap settings',
            icon: Icons.tune,
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }
}

class _FormSkeleton extends StatelessWidget {
  const _FormSkeleton();

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    Widget card() => Container(
      height: 118,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: s.surfaceRaisedGradient,
        borderRadius: BorderRadius.circular(22),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwapSkeletonLine(width: 70, height: 9),
          SizedBox(height: 22),
          SwapSkeletonLine(width: 160, height: 22),
        ],
      ),
    );
    return Semantics(
      label: 'Loading what this wallet can swap',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        physics: const NeverScrollableScrollPhysics(),
        children: [card(), card()],
      ),
    );
  }
}

/// The token button on either card: logo with its chain badge, ticker, and
/// where it is.
class _TokenButton extends StatelessWidget {
  const _TokenButton({
    required this.asset,
    required this.onTap,
    required this.semanticLabel,
  });

  final SwapAsset? asset;
  final VoidCallback? onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final asset = this.asset;
    return Semantics(
      container: true,
      button: true,
      label: asset == null
          ? semanticLabel
          : '$semanticLabel: ${asset.ticker} on ${asset.chainName}',
      excludeSemantics: true,
      child: Material(
        color: s.glass,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (asset != null)
                    SwapTokenMark(
                      identity: asset.identity,
                      chainIconUrl: asset.chainIconUrl,
                      size: 28,
                    )
                  else
                    const SizedBox(width: 4),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          asset?.ticker ?? 'Select',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: s.fg,
                          ),
                        ),
                        if (asset != null)
                          Text(
                            'on ${asset.chainName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: zuniaSans(fontSize: 11, color: s.fgMuted),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.expand_more, size: 18, color: s.fgMuted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.surfaceRaisedGradient,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: s.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: child,
      ),
    );
  }
}

class _PayCard extends StatelessWidget {
  const _PayCard({
    required this.view,
    required this.controller,
    required this.hidden,
    required this.fiat,
    required this.onPick,
    required this.onMax,
    required this.onChanged,
  });

  final SwapView view;
  final TextEditingController controller;
  final bool hidden;
  final String? fiat;
  final VoidCallback onPick;
  final VoidCallback onMax;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final from = view.from;
    final spendable = view.spendable;
    final maxLabel = from == null || spendable == null
        ? null
        : hidden
        ? '••••'
        : '${swapAmountText(spendable, from.identity)}${from.decimalsKnown ? ' ${from.ticker}' : ''}';
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'YOU PAY',
                style: zuniaMono(
                  fontSize: 10.5,
                  letterSpacing: 0.8,
                  color: s.fgMuted,
                ),
              ),
              const Spacer(),
              if (maxLabel != null)
                Flexible(
                  flex: 4,
                  child: Semantics(
                    container: true,
                    button: true,
                    label: 'Use the maximum, $maxLabel',
                    excludeSemantics: true,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: onMax,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: maxLabel,
                                style: zuniaMono(
                                  fontSize: 11,
                                  color: s.fgMuted,
                                ),
                              ),
                              TextSpan(
                                text: '  Max',
                                style: zuniaMono(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: s.accent,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 10,
            children: [
              _TokenButton(
                asset: from,
                onTap: onPick,
                semanticLabel: 'Token to pay with',
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
                child: IntrinsicWidth(
                  child: Semantics(
                    label: 'Amount to pay',
                    textField: true,
                    child: TextField(
                      controller: controller,
                      enabled: from != null,
                      // Without a proven exponent a typed "1.5" has no meaning
                      // in base units: only Max, the exact balance, sets it.
                      readOnly: from != null && !from.decimalsKnown,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: const [DecimalDigitFormatter()],
                      textAlign: TextAlign.right,
                      onChanged: onChanged,
                      style: zuniaSans(
                        fontSize: 28,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.9,
                        color: s.fg,
                        tabular: const FontFeature.tabularFigures(),
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '0',
                        hintStyle: zuniaSans(
                          fontSize: 28,
                          fontWeight: FontWeight.w500,
                          color: s.fgDim,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (fiat != null || (from != null && !from.decimalsKnown)) ...[
            const SizedBox(height: 6),
            Text(
              from != null && !from.decimalsKnown
                  ? "This token's decimals are unknown: the amount is in base units, and only Max sets it."
                  : fiat!,
              textAlign: TextAlign.right,
              style: zuniaMono(fontSize: 11, color: s.fgDim),
            ),
          ],
        ],
      ),
    );
  }
}

class _FlipButton extends StatelessWidget {
  const _FlipButton({required this.view, required this.onFlip});

  final SwapView view;
  final VoidCallback onFlip;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final to = view.to;
    final from = view.from;
    final canFlip = from != null && to != null && to.held && from.key != to.key;
    final label = to != null && !to.held
        ? 'Swap the two sides: you hold no ${to.ticker} on ${to.chainName} to sell'
        : 'Swap the two sides';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Semantics(
          container: true,
          button: true,
          enabled: canFlip,
          label: label,
          excludeSemantics: true,
          child: Material(
            color: canFlip ? s.accent : s.glass2,
            shape: CircleBorder(side: BorderSide(color: s.bg, width: 3)),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: canFlip ? onFlip : null,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  Icons.swap_vert,
                  size: 20,
                  color: canFlip ? s.accentFg : s.fgDim,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReceiveCard extends StatelessWidget {
  const _ReceiveCard({
    required this.view,
    required this.fiat,
    required this.onPick,
  });

  final SwapView view;
  final String? fiat;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final to = view.to;
    final quote = view.quote;
    final waiting = view.planning || (view.refreshing && quote == null);
    final estimate = to == null || quote == null
        ? null
        : swapAmountText(quote.outputAmount, to.identity);
    final where = to == null
        ? null
        : view.path == SwapPath.poolDeliver
        ? 'Swapped on Osmosis, delivered on ${to.chainName}'
        : 'Delivered on ${to.chainName}';
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'YOU RECEIVE',
            style: zuniaMono(
              fontSize: 10.5,
              letterSpacing: 0.8,
              color: s.fgMuted,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 10,
            children: [
              _TokenButton(
                asset: to,
                onTap: view.from == null ? null : onPick,
                semanticLabel: 'Token to receive',
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: waiting
                    ? const SwapSkeletonLine(
                        key: ValueKey('skeleton'),
                        width: 110,
                        height: 24,
                      )
                    : Semantics(
                        key: ValueKey(estimate),
                        label: estimate == null
                            ? 'No estimate yet'
                            : 'About $estimate ${to?.ticker ?? ''}',
                        excludeSemantics: true,
                        child: Text(
                          estimate == null ? '—' : '≈ $estimate',
                          style: zuniaSans(
                            fontSize: 26,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.9,
                            color: estimate == null ? s.fgDim : s.fg,
                            tabular: const FontFeature.tabularFigures(),
                          ),
                        ),
                      ),
              ),
            ],
          ),
          if (where != null || fiat != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                if (where != null)
                  Expanded(
                    child: Text(
                      where,
                      style: zuniaSans(fontSize: 11.5, color: s.fgMuted),
                    ),
                  ),
                if (fiat != null)
                  Text(fiat!, style: zuniaMono(fontSize: 11, color: s.fgDim)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Fees extends StatelessWidget {
  const _Fees({required this.view, required this.settings});

  final SwapView view;
  final SwapSettings settings;

  @override
  Widget build(BuildContext context) {
    final from = view.from;
    final rows = <Widget>[];
    if (from != null && ChainCatalog.isLoaded) {
      final entry = ChainCatalog.instance.find(from.chainId);
      if (entry != null) {
        final fee = TxEngine.feeFor(
          entry,
          (swapReserveGasLimit * defaultGasAdjustment).ceil(),
          settings.feeSpeed,
        );
        final coin = fee.amount.isEmpty ? null : fee.amount.first;
        rows.add(
          SwapFact(
            label: 'Network fee',
            value: coin == null
                ? '—'
                : '≈ ${formatBaseUnitsExact(coin.amount, decimals: entry.feeDecimals, maxFractionDigits: 6)} ${entry.feeDenom}',
            note: '${settings.feeSpeed.label} speed · an estimate until review',
          ),
        );
      }
    }
    final quote = view.quote;
    if (quote?.poolFee != null && quote!.poolFee!.isFinite) {
      final fee = quote.poolFee!;
      rows.add(
        SwapFact(
          label: 'Pool fee',
          value: '${fee.toStringAsFixed(fee >= 1 ? 2 : 3)}%',
        ),
      );
    }
    final zunia = from == null ? null : swapFeeLine(view.fee, from.identity);
    if (zunia != null) {
      // Read as one line: "Zunia fee 0.5% · 0.05 OSMO".
      rows.add(SwapFact(label: zunia.label, value: zunia.value));
    }
    final rate = quote == null || from == null || view.to == null
        ? null
        : swapRateLine(
            quote.inputAmount,
            from.identity,
            quote.outputAmount,
            view.to!.identity,
          );
    if (rate != null) rows.add(SwapFact(label: 'Rate', value: rate));
    // Null stays off the screen: "no impact" and "impact not reported" are
    // different claims, and the router does not always report one.
    final impact = quote?.priceImpact;
    if (settings.routeDetails && impact != null && impact.isFinite) {
      rows.add(
        SwapFact(
          label: 'Price impact',
          value: '${impact.toStringAsFixed(2)}%',
          valueColor: impact >= 3
              ? ZuniaSemanticsExt.of(context).warning
              : null,
        ),
      );
    }
    rows.add(SwapFact(label: 'Slippage', value: '${_trim(view.slippage)}%'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  String _trim(double value) =>
      value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
}

/* -------------------------------------------------------------------------- *
 * Route details
 * -------------------------------------------------------------------------- */

class _RouteDetails extends ConsumerWidget {
  const _RouteDetails({required this.view});

  final SwapView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final registry = ref.watch(interchainRegistryProvider);
    final from = view.from;
    final to = view.to;
    final venueName =
        view.venue?.label ??
        registry.get(view.venueChainId)?.chainName ??
        view.venueChainId;
    if (from == null || to == null) return const SizedBox.shrink();

    if (view.path != SwapPath.contract) {
      final routes = view.pool?.quote.routes;
      return ZuniaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ZuniaSectionLabel('Route'),
            const SizedBox(height: 8),
            Text(
              view.path == SwapPath.moveFirst
                  ? '${from.ticker} moves to Osmosis first, then swaps in its pools.'
                  : routes == null
                  ? 'Via Osmosis pools'
                  : 'Via Osmosis pools: ${poolRouteText(routes)}',
              style: zuniaSans(fontSize: 13, color: s.fg),
            ),
            const SizedBox(height: 4),
            Text(
              view.path == SwapPath.pool
                  ? '${from.ticker} → ${to.ticker}, both on Osmosis · no transfer'
                  : view.path == SwapPath.poolDeliver
                  ? 'Then one transfer to ${to.chainName}${view.delivery == null ? '' : ' over ${view.delivery!.sourceChannel}'}'
                  : 'Send, then swap here',
              style: zuniaMono(fontSize: 10.5, height: 1.4, color: s.fgMuted),
            ),
          ],
        ),
      );
    }

    final plan = view.contract?.plan;
    final hops = <ZuniaRoutePreviewHop>[];
    if (plan != null) {
      var linkIndex = 0;
      final links = view.contract!.links;
      for (final hop in plan.hops) {
        final link = hop.kind == RouteHopKind.swap || linkIndex >= links.length
            ? null
            : links[linkIndex];
        if (hop.kind != RouteHopKind.swap) linkIndex += 1;
        hops.add(
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
            channelSource: switch (link?.source) {
              ChannelLinkSource.manual => ZuniaChannelSource.manual,
              ChannelLinkSource.verified => ZuniaChannelSource.discovered,
              _ => ZuniaChannelSource.seed,
            },
            channelVerified:
                link?.source == ChannelLinkSource.verified &&
                link?.state == IbcChannelState.open,
          ),
        );
      }
    }
    final contract = view.venue?.contractAddress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZuniaRoutePreview(
          hops: hops,
          estimatedDurationSeconds: plan?.estimatedDurationSeconds,
          warnings: view.contract?.warnings ?? const [],
          requiresPfm: plan?.requiresPfm ?? false,
          requiresIbcHooks: plan?.requiresIbcHooks ?? false,
          gasChainName: from.chainName,
          swapVenueName: venueName,
          loading: view.planning,
          error: view.contract?.error,
          onRetry: () => ref.read(swapControllerProvider.notifier).retry(),
          emptyTitle: view.liveReads ? 'No route yet' : 'Route planning is off',
          emptyDescription: view.liveReads
              ? 'Pick both tokens and an amount, and Zunia will plan the hops.'
              : 'Turn on live reads in Settings so Zunia can read channels.',
          compact: true,
          title: null,
          footer: from.chainId == view.venueChainId
              ? null
              : _ChannelOverrides(
                  hops: view.contract?.hops ?? const [],
                  fallback: plan == null
                      ? [
                          _HopPair(
                            index: 0,
                            fromChainId: from.chainId,
                            toChainId: view.venueChainId,
                          ),
                          if (to.chainId != view.venueChainId)
                            _HopPair(
                              index: 1,
                              fromChainId: view.venueChainId,
                              toChainId: to.chainId,
                            ),
                        ]
                      : const [],
                ),
        ),
        if (contract != null) ...[
          const SizedBox(height: 8),
          Text(
            'Verified ${view.venue?.label ?? 'contract'} ${truncateAddress(contract)} on ${view.venueChainId}',
            style: zuniaMono(fontSize: 10, height: 1.4, color: s.fgDim),
          ),
        ],
      ],
    );
  }
}

/// One chain pair a channel can be typed for.
@immutable
class _HopPair {
  const _HopPair({
    required this.index,
    required this.fromChainId,
    required this.toChainId,
  });

  final int index;
  final String fromChainId;
  final String toChainId;
}

/// Per-hop channel choice: the discovered options, and a field for the id
/// the user knows when discovery came back empty.
class _ChannelOverrides extends ConsumerWidget {
  const _ChannelOverrides({required this.hops, required this.fallback});

  final List<SwapHopChoice> hops;
  final List<_HopPair> fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (hops.isEmpty && fallback.isEmpty) return const SizedBox.shrink();
    final s = ZuniaSemanticsExt.of(context);
    final controller = ref.read(swapControllerProvider.notifier);
    final pairs = hops.isNotEmpty
        ? [
            for (final hop in hops)
              _HopPair(
                index: hop.index,
                fromChainId: hop.fromChainId,
                toChainId: hop.toChainId ?? '',
              ),
          ]
        : fallback;
    void set(_HopPair pair, String value) => controller.setOverride(
      pair.index,
      value,
      fromChainId: pair.fromChainId,
      toChainId: pair.toChainId,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        const ZuniaSectionLabel('Channels'),
        if (hops.isEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'Nothing has confirmed a path yet. Pick or type the channel for each leg and Zunia will plan again.',
            style: zuniaSans(fontSize: 12, height: 1.4, color: s.fgMuted),
          ),
        ],
        for (var i = 0; i < pairs.length; i++) ...[
          const SizedBox(height: 10),
          Text(
            'Hop ${pairs[i].index + 1}',
            style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
          ),
          const SizedBox(height: 6),
          if (i < hops.length && hops[i].options.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in hops[i].options)
                  ChoiceChip(
                    label: Text(
                      option.channelId,
                      style: zuniaMono(fontSize: 11, color: s.fg),
                    ),
                    selected: option.channelId == hops[i].channelId,
                    onSelected: (_) {
                      ZuniaHaptics.selection();
                      set(pairs[i], option.channelId);
                    },
                    selectedColor: s.stateSelected,
                    backgroundColor: s.glass,
                    side: BorderSide(color: s.line),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          _ChannelField(
            key: ValueKey('swap-hop-${pairs[i].index}-${pairs[i].fromChainId}'),
            initial: controller.overrideFor(pairs[i].index) ?? '',
            hint: i < hops.length && hops[i].channelId.isNotEmpty
                ? hops[i].channelId
                : 'channel-141',
            onChanged: (value) => set(pairs[i], value),
            sourceChainId: pairs[i].fromChainId,
            destChainId: pairs[i].toChainId.isEmpty ? null : pairs[i].toChainId,
          ),
        ],
      ],
    );
  }
}

/// A channel id typed by hand, checked against the source chain as it is
/// typed.
class _ChannelField extends ConsumerStatefulWidget {
  const _ChannelField({
    super.key,
    required this.initial,
    required this.hint,
    required this.onChanged,
    required this.sourceChainId,
    required this.destChainId,
  });

  final String initial;
  final String hint;
  final ValueChanged<String> onChanged;
  final String sourceChainId;
  final String? destChainId;

  @override
  ConsumerState<_ChannelField> createState() => _ChannelFieldState();
}

class _ChannelFieldState extends ConsumerState<_ChannelField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
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
      final result = await ref
          .read(channelServiceProvider)
          .validateIbcChannel(
            widget.sourceChainId,
            normalized,
            destChainId: widget.destChainId,
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
          label: 'Channel',
          hint: widget.hint,
          errorText: check != null && !check.ok ? check.message : null,
          onChanged: _onChanged,
        ),
        if (_checking)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Checking…',
              style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
            ),
          )
        else if (check != null && check.ok)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              check.message,
              style: zuniaMono(fontSize: 10.5, color: s.success),
            ),
          ),
      ],
    );
  }
}
