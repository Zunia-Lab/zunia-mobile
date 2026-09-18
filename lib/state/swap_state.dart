/// Planning and pricing one cross-chain swap.
///
/// The wallet plans the route itself: discover and verify channels, work out
/// what the token unwinds to, ask Osmosis for a price, and compose one
/// MsgTransfer whose memo carries the crosschain-swap. Everything chain-facing
/// comes from `lib/services/interchain`; this file only sequences it and turns
/// each failure into a sentence a screen can render next to a disabled control.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/config/interchain_config.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/denom.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/memo.dart';
import 'package:zunia_mobile/services/interchain/registry.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/swap.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

/// One hop the user may override by hand.
@immutable
class SwapHopChoice {
  const SwapHopChoice({
    required this.index,
    required this.fromChainId,
    required this.toChainId,
    required this.channelId,
    required this.options,
    this.check,
    this.manual = false,
  });

  final int index;
  final String fromChainId;
  final String? toChainId;

  /// The channel the plan will use.
  final String channelId;

  /// Channels discovered on chain for this pair. Empty when discovery failed,
  /// which is exactly when the manual field matters.
  final List<IbcChannelOption> options;

  /// The result of checking a hand-typed id, or null when nothing was typed.
  final IbcChannelCheck? check;

  final bool manual;
}

/// Everything the swap screen renders.
@immutable
class SwapPlanState {
  const SwapPlanState({
    this.planning = false,
    this.quoting = false,
    this.blockedReason,
    this.planError,
    this.quoteError,
    this.candidate,
    this.quote,
    this.hops = const [],
    this.warnings = const [],
    this.denomAdvice,
    this.venueInputDenom,
    this.outputDenomOnVenue,
    this.arrivalDenom,
    this.memoInspection,
    this.recoveryAddress,
    this.slippagePercent = kSwapDefaultSlippagePercent,
  });

  final bool planning;
  final bool quoting;

  /// Why there is nothing to review. Always specific, never just "unavailable".
  final String? blockedReason;

  final String? planError;
  final String? quoteError;

  final RoutePlanCandidate? candidate;
  final OsmosisSwapQuote? quote;

  /// Per-hop channel choices, in travel order.
  final List<SwapHopChoice> hops;

  /// Plan-level warnings, verbatim from the engine.
  final List<String> warnings;

  final DenomRecommendation? denomAdvice;

  /// The input denom as Osmosis names it. Null when it could not be computed,
  /// which blocks the quote rather than guessing.
  final String? venueInputDenom;

  /// The output denom as Osmosis names it: what goes in the memo.
  final String? outputDenomOnVenue;

  /// The denom the recipient actually ends up holding.
  final String? arrivalDenom;

  /// What the memo will do, read back from the memo itself.
  final MemoInspection? memoInspection;

  /// `on_failed_delivery.local_recovery_addr`.
  final String? recoveryAddress;

  final double slippagePercent;

  bool get ready =>
      candidate != null &&
      quote != null &&
      blockedReason == null &&
      planError == null &&
      quoteError == null;

  SwapPlanState copyWith({
    bool? planning,
    bool? quoting,
    String? blockedReason,
    String? planError,
    String? quoteError,
    RoutePlanCandidate? candidate,
    OsmosisSwapQuote? quote,
    List<SwapHopChoice>? hops,
    List<String>? warnings,
    DenomRecommendation? denomAdvice,
    String? venueInputDenom,
    String? outputDenomOnVenue,
    String? arrivalDenom,
    MemoInspection? memoInspection,
    String? recoveryAddress,
    double? slippagePercent,
    bool clearResults = false,
  }) =>
      SwapPlanState(
        planning: planning ?? this.planning,
        quoting: quoting ?? this.quoting,
        blockedReason: clearResults ? blockedReason : blockedReason ?? this.blockedReason,
        planError: clearResults ? planError : planError ?? this.planError,
        quoteError: clearResults ? quoteError : quoteError ?? this.quoteError,
        candidate: clearResults ? candidate : candidate ?? this.candidate,
        quote: clearResults ? quote : quote ?? this.quote,
        hops: hops ?? this.hops,
        warnings: warnings ?? this.warnings,
        denomAdvice: denomAdvice ?? this.denomAdvice,
        venueInputDenom:
            clearResults ? venueInputDenom : venueInputDenom ?? this.venueInputDenom,
        outputDenomOnVenue: clearResults
            ? outputDenomOnVenue
            : outputDenomOnVenue ?? this.outputDenomOnVenue,
        arrivalDenom: clearResults ? arrivalDenom : arrivalDenom ?? this.arrivalDenom,
        memoInspection:
            clearResults ? memoInspection : memoInspection ?? this.memoInspection,
        recoveryAddress: recoveryAddress ?? this.recoveryAddress,
        slippagePercent: slippagePercent ?? this.slippagePercent,
      );
}

/// Plans and prices a swap. One instance per swap screen.
class SwapController extends StateNotifier<SwapPlanState> {
  SwapController(this._ref) : super(const SwapPlanState());

  final Ref _ref;

  /// Channels the user typed, keyed by hop index.
  ///
  /// The chain pair is kept alongside the id because an override has two jobs:
  /// replacing the channel the search picked, and *being* the edge when
  /// discovery found nothing at all. Without the pair the second job is
  /// impossible, and a chain with a slow LCD would leave the user stuck.
  final Map<int, RouteHopOverride> _overrides = {};

  /// Bump on every plan so a slow answer from a previous input is dropped
  /// rather than rendered over a newer one.
  int _generation = 0;

  void setSlippage(double percent) {
    state = state.copyWith(slippagePercent: percent);
  }

  /// Record a hand-typed channel for a hop. An empty value clears it.
  void setOverride(
    int hopIndex,
    String channelId, {
    String? fromChainId,
    String? toChainId,
  }) {
    final normalized = normalizeChannelId(channelId);
    if (normalized.isEmpty) {
      _overrides.remove(hopIndex);
      return;
    }
    _overrides[hopIndex] = RouteHopOverride(
      hopIndex: hopIndex,
      channelId: normalized,
      fromChainId: fromChainId,
      toChainId: toChainId,
    );
  }

  String? overrideFor(int hopIndex) => _overrides[hopIndex]?.channelId;

  void reset() {
    _generation += 1;
    _overrides.clear();
    state = SwapPlanState(slippagePercent: state.slippagePercent);
  }

  /// Plan and price a swap from [from] to [to].
  ///
  /// Every early return carries a reason: the screen shows it beside a disabled
  /// review button rather than an empty quote.
  Future<void> plan({
    required ChainAccount from,
    required ChainAccount to,
    required String amountBaseUnits,
    String? phrase,
    int accountIndex = 0,
  }) async {
    final generation = ++_generation;
    void publish(SwapPlanState next) {
      if (_generation == generation && mounted) state = next;
    }

    if (amountBaseUnits.isEmpty || BigInt.tryParse(amountBaseUnits) == null) {
      publish(state.copyWith(
        clearResults: true,
        blockedReason: 'Enter an amount to swap.',
      ));
      return;
    }
    if (BigInt.parse(amountBaseUnits) == BigInt.zero) {
      publish(state.copyWith(
        clearResults: true,
        blockedReason: 'Enter an amount greater than zero.',
      ));
      return;
    }
    if (from.chain.chainId == to.chain.chainId) {
      publish(state.copyWith(
        clearResults: true,
        blockedReason: 'Pick two different networks. A swap between two assets '
            'on one chain is a contract call, not a cross-chain route, and this '
            'screen does not build one yet.',
      ));
      return;
    }

    publish(state.copyWith(
      planning: true,
      clearResults: true,
      blockedReason: null,
      planError: null,
      quoteError: null,
      candidate: null,
      quote: null,
    ));

    final venueStatus = await _ref.read(swapVenueStatusProvider.future);
    final venue = venueStatus.venue;
    if (venue == null) {
      publish(state.copyWith(
        planning: false,
        clearResults: true,
        blockedReason: venueStatus.reason,
      ));
      return;
    }

    final registry = _ref.read(interchainRegistryProvider);
    final channels = _ref.read(channelServiceProvider);
    final routes = _ref.read(routeRegistryProvider);
    final capabilities = _ref.read(chainCapabilityCacheProvider);

    // 1. Discover the channels this route could use, and remember them. A pair
    //    that discovery cannot answer for is not fatal: the seed table and the
    //    manual override both feed the same graph.
    final discovered = <ChannelRoute>[];
    Future<List<IbcChannelOption>> discover(String a, String b) async {
      if (a == b) return const [];
      try {
        final options = await channels.findIbcChannels(a, b);
        for (final option in options) {
          discovered.add(ChannelRoute(
            sourceChainId: a,
            destChainId: b,
            channelId: option.channelId,
            counterpartyChannelId: option.counterpartyChannelId,
            verifiedAt: DateTime.now().millisecondsSinceEpoch,
            source: ChannelRouteSource.discovered,
          ));
        }
        return options;
      } on InterchainError {
        // Discovery fails on chains with slow or partial LCDs. The plan can
        // still be built from a seed row or a channel the user types.
        return const [];
      }
    }

    final inbound = await discover(from.chain.chainId, venue.chainId);
    final outbound = await discover(venue.chainId, to.chain.chainId);
    await routes.remember(discovered);

    // 2. Probe the middleware each chain runs, so the plan can say what is
    //    unconfirmed instead of assuming it works.
    await capabilities.probe(venue.chainId);
    await capabilities.probe(from.chain.chainId);

    // 3. What the token is, and what it unwinds to.
    DenomRecommendation? advice;
    try {
      advice = await recommendDenom(
        _ref.read(denomContextProvider),
        from.chain.chainId,
        venue.chainId,
        from.chain.coinMinimalDenom,
        destinationReceiveChannelId:
            inbound.isEmpty ? null : inbound.first.counterpartyChannelId,
      );
    } on InterchainError {
      // Only costs the advice line; the planner resolves the trace itself.
      advice = null;
    }

    // 4. The denom Osmosis will swap *into*. The user picked a chain and its
    //    native asset, and Osmosis knows that asset by the hash of its own
    //    receiving channel — not by the name the destination chain uses.
    final outputDenomOnVenue = _outputDenomOnVenue(venue, to, outbound);
    if (outputDenomOnVenue == null) {
      publish(state.copyWith(
        planning: false,
        clearResults: true,
        denomAdvice: advice,
        blockedReason:
            'No open channel between ${_name(registry, venue.chainId)} and '
            '${to.chain.chainName} could be found, so the denom to swap into '
            'cannot be named. Enter the channel by hand, or pick another '
            'destination.',
      ));
      return;
    }

    // 5. Plan. Run it once to see which chains the route crosses, derive a
    //    receiver for each of those, then plan again so no packet is addressed
    //    to the "pfm" placeholder.
    final deps = RoutePlannerDeps(
      registry: registry,
      channels: createChannelDirectory(routes.links()),
      capabilities: capabilities.lookup,
      venues: [venue],
      resolveDenom: (chain, denom) =>
          _ref.read(denomResolverProvider).resolve(chain.chainId, denom),
    );
    // Without this the contract is told "do_nothing", and output stranded by a
    // failed delivery has no recorded owner and is gone for good. A swap that
    // cannot name a recovery address is planned and priced — the user still
    // gets to see the route — but it is not offered for signing.
    final recoveryAddress = _venueAddress(venue.chainId, phrase, accountIndex);
    final recoveryBlock = recoveryAddress == null
        ? 'The wallet could not derive an address on '
            '${_name(registry, venue.chainId)} to recover the swap output if '
            'delivery fails, so this swap is not offered for signing. Unlock '
            'the wallet and try again.'
        : null;

    final request = RouteRequest(
      sourceChainId: from.chain.chainId,
      destChainId: to.chain.chainId,
      inputDenom: from.chain.coinMinimalDenom,
      outputDenom: outputDenomOnVenue,
      amount: amountBaseUnits,
      sender: from.address,
      recipient: to.address,
      slippagePercent: state.slippagePercent,
      allowSwap: true,
      timeoutMinutes: kPacketTimeoutMinutes,
      recoveryAddress: recoveryAddress,
    );

    RoutePlanResult result;
    try {
      result = await planRoute(
        request,
        deps,
        PlanRouteOptions(
          overrides: _overrideList(),
          twapWindowSeconds: kTwapWindowSeconds,
        ),
      );
      final intermediates = _intermediateReceivers(
        result,
        from: from,
        to: to,
        phrase: phrase,
        accountIndex: accountIndex,
      );
      if (intermediates.isNotEmpty) {
        result = await planRoute(
          request,
          deps,
          PlanRouteOptions(
            overrides: _overrideList(),
            twapWindowSeconds: kTwapWindowSeconds,
            intermediateReceivers: intermediates,
          ),
        );
      }
    } on InterchainError catch (error) {
      publish(state.copyWith(
        planning: false,
        clearResults: true,
        denomAdvice: advice,
        planError: error.message,
      ));
      return;
    }

    final candidate = result.best;
    if (candidate == null) {
      publish(state.copyWith(
        planning: false,
        clearResults: true,
        denomAdvice: advice,
        warnings: result.warnings,
        blockedReason: result.warnings.isEmpty
            ? 'No route from ${from.chain.chainName} to ${to.chain.chainName} '
                'could be planned.'
            : 'No route could be planned: ${result.warnings.first}',
      ));
      return;
    }

    final hops = _hopChoices(candidate, inbound, outbound);
    final memoInspection = validateMemo(
      candidate.plan.memo,
      receiver: candidate.receiver,
    );

    // The ICS20 receiver must never be the middleware's placeholder: no key
    // controls it, so a packet addressed there is lost. The planner warns; this
    // refuses.
    if (candidate.receiver == pfmIntermediateReceiver) {
      publish(state.copyWith(
        planning: false,
        clearResults: true,
        candidate: candidate,
        hops: hops,
        denomAdvice: advice,
        warnings: [...result.warnings, ...candidate.plan.warnings],
        blockedReason: 'This route passes through a chain the wallet has no '
            'address for, so the first packet has nowhere safe to land. Unlock '
            'the wallet, or pick a destination with a direct channel.',
      ));
      return;
    }

    // 6. Price it. The venue quotes the denom as *it* names it.
    final preSwapLinks = candidate.links
        .take(candidate.plan.hops
            .takeWhile((hop) => hop.kind != RouteHopKind.swap)
            .length)
        .toList();
    final venueInputDenom = denomAfterHops(
      from.chain.coinMinimalDenom,
      result.resolvedInput,
      preSwapLinks,
    );

    publish(state.copyWith(
      planning: false,
      quoting: true,
      candidate: candidate,
      hops: hops,
      denomAdvice: advice,
      warnings: [...result.warnings, ...candidate.plan.warnings],
      venueInputDenom: venueInputDenom,
      outputDenomOnVenue: outputDenomOnVenue,
      arrivalDenom: to.chain.coinMinimalDenom,
      memoInspection: memoInspection,
      recoveryAddress: recoveryAddress,
      blockedReason: recoveryBlock,
    ));

    if (venueInputDenom == null) {
      publish(state.copyWith(
        quoting: false,
        quoteError: 'The denom arriving on ${_name(registry, venue.chainId)} '
            'could not be computed, so the swap cannot be priced. This usually '
            'means the channel it crosses has no known counterparty.',
      ));
      return;
    }

    final venueChain = registry.get(venue.chainId);
    if (venueChain == null || lcdEndpointsFromChain(venueChain).isEmpty) {
      publish(state.copyWith(
        quoting: false,
        quoteError: 'No REST endpoint for ${_name(registry, venue.chainId)}, '
            'so the swap cannot be priced.',
      ));
      return;
    }

    final factory = _ref.read(lcdFactoryProvider);
    final router = _ref.read(swapRouterClientProvider);

    try {
      final quote = await quoteOsmosisSwap(
        OsmosisSwapQuoteParams(
          tokenInDenom: venueInputDenom,
          tokenInAmount: amountBaseUnits,
          tokenOutDenom: outputDenomOnVenue,
          slippagePercent: state.slippagePercent,
          router: router,
        ),
        factory(venueChain),
      );
      publish(state.copyWith(quoting: false, quote: quote));
    } on InterchainError catch (error) {
      publish(state.copyWith(
        quoting: false,
        quoteError: switch (error.code) {
          InterchainErrorCode.noRoute =>
            'Osmosis has no pool that trades this pair at this size.',
          InterchainErrorCode.readsDisabled =>
            'Live reads are off, so nothing can be priced. Turn them on in '
                'Settings.',
          _ => 'Could not price this swap: ${error.message}',
        },
      ));
    }
  }

  List<RouteHopOverride> _overrideList() => _overrides.values.toList();

  String _name(ChainRegistry registry, String chainId) =>
      registry.get(chainId)?.chainName ?? chainId;

  /// The address the swap output is paid back to if delivery fails.
  ///
  /// Must be an address on the venue chain, because that is where the contract
  /// holds the funds. Null when the wallet is locked, which the planner turns
  /// into a `do_nothing` swap and a warning the screen shows.
  String? _venueAddress(String chainId, String? phrase, int accountIndex) {
    if (phrase == null || !ChainCatalog.isLoaded) return null;
    final chain = ChainCatalog.instance.find(chainId);
    if (chain == null) return null;
    try {
      return WalletKernel.instance
          .deriveAddress(
            phrase: phrase,
            chain: chain,
            accountIndex: accountIndex,
          )
          .address;
    } on Object {
      return null;
    }
  }

  /// A receiver on every chain the route lands on that is neither end.
  Map<String, String> _intermediateReceivers(
    RoutePlanResult result, {
    required ChainAccount from,
    required ChainAccount to,
    String? phrase,
    required int accountIndex,
  }) {
    final wanted = <String>{};
    for (final candidate in result.candidates) {
      for (final hop in candidate.plan.hops) {
        final chainId = hop.counterpartyChainId;
        if (chainId == null) continue;
        if (chainId == from.chain.chainId || chainId == to.chain.chainId) {
          continue;
        }
        wanted.add(chainId);
      }
    }
    final out = <String, String>{};
    for (final chainId in wanted) {
      final address = _venueAddress(chainId, phrase, accountIndex);
      if (address != null) out[chainId] = address;
    }
    return out;
  }

  /// The destination asset as the swap venue names it.
  ///
  /// Osmosis holds another chain's token as `ibc/HASH` of its own receiving
  /// channel, so the memo's `output_denom` is that hash and not the name the
  /// destination chain uses. Null when no channel between the venue and the
  /// destination is known, which is a reason to stop rather than to guess.
  String? _outputDenomOnVenue(
    SwapVenue venue,
    ChainAccount to,
    List<IbcChannelOption> outbound,
  ) {
    if (venue.chainId == to.chain.chainId) return to.chain.coinMinimalDenom;
    // Prefer what the chain said; fall back to the channel the user typed for
    // the hop leaving the venue, which is the whole point of the override.
    String? manual;
    for (final override in _overrides.values) {
      if (override.fromChainId == venue.chainId) manual = override.channelId;
    }
    final channelId = outbound.isNotEmpty ? outbound.first.channelId : manual;
    if (channelId == null) return null;
    // The token arrived on Osmosis over this channel, so Osmosis prefixes its
    // trace with it.
    return ibcDenomHash('$transferPort/$channelId', to.chain.coinMinimalDenom);
  }

  List<SwapHopChoice> _hopChoices(
    RoutePlanCandidate candidate,
    List<IbcChannelOption> inbound,
    List<IbcChannelOption> outbound,
  ) {
    final choices = <SwapHopChoice>[];
    for (var i = 0; i < candidate.links.length; i++) {
      final link = candidate.links[i];
      final options = link.sourceChainId == candidate.plan.sourceChainId
          ? inbound
          : outbound;
      choices.add(SwapHopChoice(
        index: i,
        fromChainId: link.sourceChainId,
        toChainId: link.destChainId,
        channelId: link.channelId,
        options: options
            .where((o) => o.counterpartyChainId == link.destChainId)
            .toList(),
        manual: link.source == ChannelLinkSource.manual,
      ));
    }
    return choices;
  }
}

final swapControllerProvider =
    StateNotifierProvider.autoDispose<SwapController, SwapPlanState>(
  (ref) => SwapController(ref),
);
