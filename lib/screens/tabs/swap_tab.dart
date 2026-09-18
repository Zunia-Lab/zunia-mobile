/// Cross-chain swap: one signature on the source chain, an Osmosis
/// crosschain-swap executed inside packet processing, and the output delivered
/// to the destination chain.
///
/// No aggregator. The wallet plans the route with `lib/services/interchain`
/// (the Dart port of `@zunialab/interchain`), prices the pool against Osmosis
/// itself, and composes the ibc-hooks memo locally. Every control that cannot
/// work yet is disabled with the reason next to it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/config/interchain_config.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/swap_review_screen.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_mobile/widgets/wallet_header.dart';
import 'package:zunia_ui/zunia_ui.dart';

class SwapTab extends ConsumerStatefulWidget {
  const SwapTab({super.key, this.showHeader = true});

  /// When false, the wallet chrome is omitted (full-page push from Home).
  final bool showHeader;

  @override
  ConsumerState<SwapTab> createState() => _SwapTabState();
}

class _SwapTabState extends ConsumerState<SwapTab> {
  final _amount = TextEditingController();
  String? _fromId;
  String? _toId;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _amount.dispose();
    super.dispose();
  }

  /// Re-plan after the user stops typing. A quote costs several round trips and
  /// goes stale in seconds, so it is not worth firing one per keystroke.
  void _schedulePlan() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _plan);
  }

  Future<void> _plan() async {
    final accounts = ref.read(chainAccountsProvider);
    if (accounts.length < 2) return;
    final from = _accountFor(accounts, _fromId) ?? accounts.first;
    final to = _accountFor(accounts, _toId) ??
        accounts.firstWhere((a) => a.chain.chainId != from.chain.chainId);
    final units = toBaseUnits(_amount.text.trim(), from.chain.coinDecimals);
    await ref.read(swapControllerProvider.notifier).plan(
          from: from,
          to: to,
          amountBaseUnits: units ?? '',
          phrase: ref.read(phraseProvider),
          accountIndex: ref.read(walletProvider).active?.index ?? 0,
        );
  }

  ChainAccount? _accountFor(List<ChainAccount> accounts, String? chainId) {
    if (chainId == null) return null;
    for (final account in accounts) {
      if (account.chain.chainId == chainId) return account;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final balances = ref.watch(balancesProvider).valueOrNull ?? const {};
    final plan = ref.watch(swapControllerProvider);
    final venue = ref.watch(swapVenueStatusProvider);

    if (accounts.length < 2) {
      return _Shell(
        showHeader: widget.showHeader,
        child: Center(
          child: ZuniaEmptyState(
            title: 'Need two networks',
            description: 'Enable at least two chains to swap between.',
            action: ZuniaButton(
              label: 'Networks',
              size: ZuniaButtonSize.sm,
              variant: ZuniaButtonVariant.secondary,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NetworksScreen()),
              ),
            ),
          ),
        ),
      );
    }

    final from = _accountFor(accounts, _fromId) ?? accounts.first;
    final to = _accountFor(accounts, _toId) ??
        accounts.firstWhere((a) => a.chain.chainId != from.chain.chainId);

    String available(ChainAccount account) {
      final base = balances[account.chain.chainId]?.available;
      if (base == null) return '—';
      return prefs.mask(
        formatBaseUnits(base, decimals: account.chain.coinDecimals),
      );
    }

    final venueOffline = venue.maybeWhen(
      data: (status) => status.ready ? null : status.reason,
      orElse: () => null,
    );
    final blocked = venueOffline ?? plan.blockedReason;

    final status = blocked ??
        plan.planError ??
        plan.quoteError ??
        (plan.planning
            ? 'Finding route…'
            : plan.quoting
                ? 'Pricing…'
                : null);

    return _Shell(
      showHeader: widget.showHeader,
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ZuniaButton(
              label: 'Review',
              size: ZuniaButtonSize.lg,
              loading: plan.planning || plan.quoting,
              onPressed: plan.ready
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SwapReviewScreen(from: from, to: to),
                        ),
                      )
                  : null,
            ),
            if (status != null) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  status,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
                ),
              ),
            ],
          ],
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
        children: [
          _Leg(
            label: 'You pay',
            account: from,
            available: available(from),
            controller: _amount,
            accounts: accounts,
            onPick: (id) {
              setState(() {
                _fromId = id;
                if (_toId == id) _toId = null;
              });
              _plan();
            },
            onAmountChanged: (_) => _schedulePlan(),
          ),
          const SizedBox(height: 6),
          Center(
            child: Semantics(
              button: true,
              label: 'Flip networks',
              child: Material(
                color: s.accent,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    setState(() {
                      final previous = from.chain.chainId;
                      _fromId = to.chain.chainId;
                      _toId = previous;
                    });
                    _plan();
                  },
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(Icons.swap_vert, size: 16, color: s.accentFg),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          _Leg(
            label: 'You get',
            account: to,
            available: available(to),
            accounts: accounts
                .where((a) => a.chain.chainId != from.chain.chainId)
                .toList(),
            onPick: (id) {
              setState(() => _toId = id);
              _plan();
            },
            estimate: _estimatedOut(plan, to),
          ),
          const SizedBox(height: 14),
          ZuniaSwapQuotePanel(
            quote: _quoteView(plan, from, to),
            gasChainName: from.chain.chainName,
            swapVenueName: _venueName(),
            slippagePercent: plan.slippagePercent,
            slippagePresets: kSlippagePresets,
            onSlippageChanged: (value) {
              ref.read(swapControllerProvider.notifier).setSlippage(value);
              _plan();
            },
            loading: plan.quoting,
            error: plan.quoteError,
            onRetry: _plan,
            compact: true,
            title: null,
          ),
          const SizedBox(height: 8),
          _RouteDetails(
            plan: plan,
            from: from,
            to: to,
            venueName: _venueName(),
            venueChainId: _venueChainId(),
            onRetry: _plan,
            onChannelChanged: (index, value, fromChainId, toChainId) {
              ref.read(swapControllerProvider.notifier).setOverride(
                    index,
                    value,
                    fromChainId: fromChainId,
                    toChainId: toChainId,
                  );
              _schedulePlan();
            },
            channelValueFor: (index) =>
                ref.read(swapControllerProvider.notifier).overrideFor(index),
            hops: _previewHops(plan),
          ),
          if (venueOffline != null || !prefs.liveReads) ...[
            const SizedBox(height: 12),
            ZuniaCallout(
              tone: ZuniaCalloutTone.warning,
              title: !prefs.liveReads ? 'Live reads off' : 'Swaps unavailable',
              body: !prefs.liveReads
                  ? 'Turn live reads on in Settings.'
                  : venueOffline!,
            ),
          ],
        ],
      ),
    );
  }

  String _venueChainId() =>
      ref.read(swapVenueStatusProvider).valueOrNull?.chainId ??
      kSwapVenueChainId;

  String _venueName() {
    final status = ref.read(swapVenueStatusProvider).valueOrNull;
    final chainId = status?.chainId ?? kSwapVenueChainId;
    return ref.read(interchainRegistryProvider).get(chainId)?.chainName ??
        chainId;
  }

  String? _estimatedOut(SwapPlanState plan, ChainAccount to) {
    final quote = plan.quote;
    if (quote == null) return null;
    return formatBaseUnitsExact(
      quote.outputAmount,
      decimals: to.chain.coinDecimals,
      maxFractionDigits: 6,
    );
  }

  ZuniaSwapQuoteView? _quoteView(
    SwapPlanState plan,
    ChainAccount from,
    ChainAccount to,
  ) {
    final quote = plan.quote;
    if (quote == null) return null;
    final inAmount = formatBaseUnitsExact(
      quote.inputAmount,
      decimals: from.chain.coinDecimals,
      maxFractionDigits: 6,
    );
    final outAmount = formatBaseUnitsExact(
      quote.outputAmount,
      decimals: to.chain.coinDecimals,
      maxFractionDigits: 6,
    );
    final rate = _rateLine(quote, from, to);
    return ZuniaSwapQuoteView(
      inputAmount: inAmount,
      inputSymbol: from.chain.coinDenom,
      outputAmount: outAmount,
      outputSymbol: to.chain.coinDenom,
      rate: rate,
      minReceived: formatBaseUnitsExact(
        quote.minReceived,
        decimals: to.chain.coinDecimals,
        maxFractionDigits: 6,
      ),
      // Null stays null: the panel renders "not reported" rather than a zero
      // that would read as "no impact".
      priceImpact: quote.priceImpact,
      poolFee: quote.poolFee,
      route: [
        for (final leg in quote.route) ZuniaSwapPoolLeg(poolId: leg.poolId),
      ],
    );
  }

  String? _rateLine(SwapQuote quote, ChainAccount from, ChainAccount to) {
    final input = BigInt.tryParse(quote.inputAmount);
    final output = BigInt.tryParse(quote.outputAmount);
    if (input == null || output == null || input == BigInt.zero) return null;
    // Scaled integer division, then one conversion: base units routinely exceed
    // what a double can hold exactly.
    const scale = 1000000;
    final scaled = (output * BigInt.from(scale)) ~/ input;
    final perUnit = scaled.toDouble() /
        scale *
        _pow10(from.chain.coinDecimals - to.chain.coinDecimals);
    return '1 ${from.chain.coinDenom} ≈ '
        '${formatCompact(perUnit, fractionDigits: 4)} ${to.chain.coinDenom}';
  }

  double _pow10(int exponent) {
    var value = 1.0;
    for (var i = 0; i < exponent.abs(); i++) {
      value *= 10;
    }
    return exponent >= 0 ? value : 1 / value;
  }

  List<ZuniaRoutePreviewHop> _previewHops(SwapPlanState plan) {
    final candidate = plan.candidate;
    if (candidate == null) return const [];
    final registry = ref.read(interchainRegistryProvider);
    var linkIndex = 0;
    final hops = <ZuniaRoutePreviewHop>[];
    for (final hop in candidate.plan.hops) {
      final link = hop.kind == RouteHopKind.swap || linkIndex >= candidate.links.length
          ? null
          : candidate.links[linkIndex];
      if (hop.kind != RouteHopKind.swap) linkIndex += 1;
      hops.add(ZuniaRoutePreviewHop(
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
        // Only an explicit true claims verification.
        channelVerified: link?.source == ChannelLinkSource.verified &&
            link?.state == IbcChannelState.open,
        channelState: switch (link?.state) {
          IbcChannelState.open => ZuniaChannelState.open,
          IbcChannelState.closed => ZuniaChannelState.closed,
          IbcChannelState.init => ZuniaChannelState.init,
          IbcChannelState.tryopen => ZuniaChannelState.tryopen,
          _ => ZuniaChannelState.unknown,
        },
      ));
    }
    return hops;
  }
}

/// Header plus gradient, shared by every state of the tab.
class _Shell extends StatelessWidget {
  const _Shell({required this.child, this.footer, this.showHeader = true});

  final Widget child;
  final Widget? footer;
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
              onOpenNetworks: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NetworksScreen()),
              ),
            ),
          Expanded(child: child),
          ?footer,
        ],
      ),
    );
  }
}

/// Collapsed route + channel overrides so the main swap view stays lean.
class _RouteDetails extends StatelessWidget {
  const _RouteDetails({
    required this.plan,
    required this.from,
    required this.to,
    required this.venueName,
    required this.venueChainId,
    required this.onRetry,
    required this.onChannelChanged,
    required this.channelValueFor,
    required this.hops,
  });

  final SwapPlanState plan;
  final ChainAccount from;
  final ChainAccount to;
  final String venueName;
  final String venueChainId;
  final VoidCallback onRetry;
  final void Function(
    int index,
    String channelId,
    String? fromChainId,
    String? toChainId,
  ) onChannelChanged;
  final String? Function(int index) channelValueFor;
  final List<ZuniaRoutePreviewHop> hops;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final hopCount = hops.isEmpty ? plan.hops.length : hops.length;
    final subtitle = plan.planning
        ? 'Planning…'
        : hopCount == 0
            ? 'Enter an amount'
            : '$hopCount hop${hopCount == 1 ? '' : 's'} · $venueName';

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        iconColor: s.fgMuted,
        collapsedIconColor: s.fgMuted,
        title: Text(
          'Route',
          style: zuniaSans(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: s.fg,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
        ),
        children: [
          ZuniaRoutePreview(
            hops: hops,
            estimatedDurationSeconds:
                plan.candidate?.plan.estimatedDurationSeconds,
            warnings: plan.warnings,
            requiresPfm: plan.candidate?.plan.requiresPfm ?? false,
            requiresIbcHooks: plan.candidate?.plan.requiresIbcHooks ?? false,
            gasChainName: from.chain.chainName,
            swapVenueName: venueName,
            loading: plan.planning,
            error: plan.planError,
            onRetry: onRetry,
            emptyTitle: 'No route',
            emptyDescription: 'Enter an amount to plan hops.',
            compact: true,
            title: null,
            footer: _ChannelOverrides(
              hops: plan.hops,
              fallback: plan.candidate == null
                  ? [
                      _HopPair(
                        index: 0,
                        fromChainId: from.chain.chainId,
                        toChainId: venueChainId,
                      ),
                      _HopPair(
                        index: 1,
                        fromChainId: venueChainId,
                        toChainId: to.chain.chainId,
                      ),
                    ]
                  : const [],
              onChanged: onChannelChanged,
              valueFor: channelValueFor,
            ),
          ),
        ],
      ),
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

/// Per-hop channel choice: the discovered options, and a field for the id the
/// user knows when discovery came back empty.
class _ChannelOverrides extends StatelessWidget {
  const _ChannelOverrides({
    required this.hops,
    required this.fallback,
    required this.onChanged,
    required this.valueFor,
  });

  final List<SwapHopChoice> hops;

  /// Rendered instead of [hops] when no route could be planned at all.
  final List<_HopPair> fallback;

  final void Function(
    int index,
    String channelId,
    String? fromChainId,
    String? toChainId,
  ) onChanged;
  final String? Function(int index) valueFor;

  @override
  Widget build(BuildContext context) {
    if (hops.isEmpty && fallback.isEmpty) return const SizedBox.shrink();
    final s = ZuniaSemanticsExt.of(context);
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        const ZuniaSectionLabel('Channels'),
        const SizedBox(height: 8),
        if (hops.isEmpty)
          Text(
            'No route found. Enter channel ids if you know them.',
            style: zuniaMono(fontSize: 10, height: 1.4, color: s.fgMuted),
          ),
        for (var i = 0; i < pairs.length; i++) ...[
          const SizedBox(height: 10),
          Text(
            'Hop ${pairs[i].index + 1}',
            style: zuniaMono(fontSize: 10, color: s.fgMuted),
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
                    onSelected: (_) => onChanged(
                      pairs[i].index,
                      option.channelId,
                      pairs[i].fromChainId,
                      pairs[i].toChainId,
                    ),
                    selectedColor: s.stateSelected,
                    backgroundColor: s.glass,
                    side: BorderSide(color: s.line),
                  ),
              ],
            )
          else if (i < hops.length)
            Text(
              'No channel discovered.',
              style: zuniaMono(fontSize: 10, height: 1.4, color: s.fgMuted),
            ),
          const SizedBox(height: 8),
          _ChannelField(
            key: ValueKey('swap-hop-${pairs[i].index}-${pairs[i].fromChainId}'),
            initial: valueFor(pairs[i].index) ?? '',
            hint: i < hops.length && hops[i].channelId.isNotEmpty
                ? hops[i].channelId
                : 'channel-141',
            onChanged: (value) => onChanged(
              pairs[i].index,
              value,
              pairs[i].fromChainId,
              pairs[i].toChainId,
            ),
            sourceChainId: pairs[i].fromChainId,
            destChainId: pairs[i].toChainId.isEmpty ? null : pairs[i].toChainId,
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

/// A channel id typed by hand, checked against the source chain as it is typed.
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

class _Leg extends StatelessWidget {
  const _Leg({
    required this.label,
    required this.account,
    required this.available,
    required this.accounts,
    required this.onPick,
    this.controller,
    this.onAmountChanged,
    this.estimate,
  });

  final String label;
  final ChainAccount account;
  final String available;
  final List<ChainAccount> accounts;
  final ValueChanged<String> onPick;
  final TextEditingController? controller;
  final ValueChanged<String>? onAmountChanged;

  /// Pre-formatted expected output. Null renders as an em dash, never as 0.
  final String? estimate;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.surfaceRaisedGradient,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  label.toUpperCase(),
                  style: zuniaMono(fontSize: 10, color: s.fgMuted),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    '$available available',
                    overflow: TextOverflow.ellipsis,
                    style: zuniaMono(fontSize: 10, color: s.fgMuted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Wrap rather than Row: at 320dp a long denom and a 26pt amount do
            // not fit on one line, and an overflow here hides the amount.
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                PopupMenuButton<String>(
                  onSelected: onPick,
                  color: s.surfaceRaised,
                  position: PopupMenuPosition.under,
                  tooltip: 'Choose the $label network',
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: s.line),
                  ),
                  itemBuilder: (_) => [
                    for (final a in accounts)
                      PopupMenuItem<String>(
                        value: a.chain.chainId,
                        child: Text(
                          '${a.chain.coinDenom} · ${a.chain.chainName}',
                          style: zuniaSans(fontSize: 12.5, color: s.fg),
                        ),
                      ),
                  ],
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: s.glass,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(7, 7, 12, 7),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ChainAvatar(chain: account.chain, size: 24),
                          const SizedBox(width: 8),
                          Text(
                            account.chain.coinDenom,
                            style: zuniaSans(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: s.fg,
                            ),
                          ),
                          Icon(Icons.expand_more, size: 14, color: s.fgMuted),
                        ],
                      ),
                    ),
                  ),
                ),
                if (controller != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 120),
                    child: IntrinsicWidth(
                      child: TextField(
                        controller: controller,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textAlign: TextAlign.right,
                        onChanged: onAmountChanged,
                        style: zuniaSans(
                          fontSize: 26,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -0.9,
                          color: s.fg,
                          tabular: FontFeature.tabularFigures(),
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '0.00',
                          labelText: 'Amount',
                          floatingLabelBehavior: FloatingLabelBehavior.never,
                          hintStyle: zuniaSans(
                            fontSize: 26,
                            fontWeight: FontWeight.w500,
                            color: s.fgDim,
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  Text(
                    estimate ?? '—',
                    style: zuniaSans(
                      fontSize: 26,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.9,
                      color: estimate == null ? s.fgDim : s.fg,
                      tabular: FontFeature.tabularFigures(),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
