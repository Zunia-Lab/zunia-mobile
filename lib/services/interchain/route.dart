/// Route planning: what a hosted routing API would do, done locally.
///
/// Dart mirror of `route.ts`. A route is a single ICS20 transfer the user signs
/// on the source chain, plus a memo that makes every remaining hop happen
/// without another signature. This module decides which channels that transfer
/// uses and what goes in the memo. It produces [RoutePlan] data and stops:
/// nothing here encodes a message, derives an address, signs, or broadcasts.
///
/// Two things it deliberately refuses to do:
///
/// 1. Invent numbers. A route through a pool has no output amount until someone
///    quotes the pool, so swap candidates carry a null quote and
///    `requiresQuote: true`. Price impact and output amounts belong to
///    `swap.dart`.
/// 2. Hide a broken graph. Channel discovery fails on chains with slow or
///    partial LCDs. Every hop accepts a manual override, and an override alone
///    is enough to build a plan even when the directory knows nothing.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'denom.dart';
import 'memo.dart';
import 'swap.dart';
import 'types.dart';

/// Hop budget when the caller does not set [RouteRequest.maxHops].
const int kDefaultMaxHops = 3;

/// Hard ceiling on hops, whatever the caller asks for.
///
/// Each hop is another relayer that has to be alive and another packet that can
/// time out. Past five the expected success rate is not worth offering.
const int kMaxHopsCap = 5;

const int _defaultMaxPaths = 12;
const int _defaultMaxLinksPerPair = 3;
const int _defaultMaxCandidates = 8;
const int _defaultTimeoutMinutes = 10;

/// Score penalty for sending a wrapped token onward instead of unwinding it.
///
/// Larger than the cost of a hop on purpose. Forwarding `ibc/…ATOM` from
/// Osmosis to Juno works, and leaves the recipient holding a double-wrapped
/// denom that no UI can name and no pool will trade. The penalty has to outrank
/// one hop while still losing to three.
const int _missedUnwindPenalty = 120;

/* -------------------------------------------------------------------------- *
 * The channel graph
 * -------------------------------------------------------------------------- */

/// Where a channel came from, which is how much we trust it.
enum ChannelLinkSource { verified, seed, manual }

/// One directed transfer channel.
///
/// Direction matters. `channel-0` on Osmosis and `channel-0` on the Hub are
/// unrelated, so a link is never reused backwards unless
/// [counterpartyChannelId] says what the other end is called.
@immutable
class ChannelLink {
  const ChannelLink({
    required this.sourceChainId,
    required this.destChainId,
    required this.channelId,
    this.port,
    this.counterpartyChannelId,
    this.counterpartyPortId,
    this.source = ChannelLinkSource.seed,
    this.state = IbcChannelState.unknown,
    this.derived = false,
  });

  final String sourceChainId;
  final String destChainId;
  final String channelId;
  final String? port;

  /// Channel id on [destChainId]. Without it the planner cannot compute the
  /// denom the recipient ends up holding, because the receiving chain prefixes
  /// the trace with its own channel.
  final String? counterpartyChannelId;
  final String? counterpartyPortId;

  final ChannelLinkSource source;
  final IbcChannelState state;

  /// True when this link was derived by reversing another.
  final bool derived;

  ChannelLink copyWith({
    String? channelId,
    String? port,
    String? counterpartyChannelId,
    bool clearCounterparty = false,
    ChannelLinkSource? source,
    IbcChannelState? state,
    bool? derived,
  }) =>
      ChannelLink(
        sourceChainId: sourceChainId,
        destChainId: destChainId,
        channelId: channelId ?? this.channelId,
        port: port ?? this.port,
        counterpartyChannelId: clearCounterparty
            ? counterpartyChannelId
            : (counterpartyChannelId ?? this.counterpartyChannelId),
        counterpartyPortId: counterpartyPortId,
        source: source ?? this.source,
        state: state ?? this.state,
        derived: derived ?? this.derived,
      );
}

/// The host's view of which chains are connected.
abstract class ChannelDirectory {
  /// Every known channel leaving [chainId]. May be empty.
  List<ChannelLink> from(String chainId);
}

String _linkKey(ChannelLink link) => [
      link.sourceChainId,
      link.destChainId,
      link.port ?? transferPort,
      link.channelId,
    ].join('|');

ChannelLink? _reverseLink(ChannelLink link) {
  final counterparty = link.counterpartyChannelId;
  if (counterparty == null || counterparty.isEmpty) return null;
  return ChannelLink(
    sourceChainId: link.destChainId,
    destChainId: link.sourceChainId,
    channelId: counterparty,
    port: link.counterpartyPortId ?? transferPort,
    counterpartyChannelId: link.channelId,
    counterpartyPortId: link.port ?? transferPort,
    source: link.source,
    state: link.state,
    derived: true,
  );
}

int _sourceRank(ChannelLinkSource source) {
  // Manual first: the user said this one. Verified before seed: seed tables go
  // stale and we would rather offer a channel someone has actually looked at.
  switch (source) {
    case ChannelLinkSource.manual:
      return 0;
    case ChannelLinkSource.verified:
      return 1;
    case ChannelLinkSource.seed:
      return 2;
  }
}

int _stateRank(IbcChannelState state) {
  if (state == IbcChannelState.open) return 0;
  if (state == IbcChannelState.unknown) return 1;
  return 2;
}

/// Numeric-aware ordering so `channel-9` sorts before `channel-141`.
int _compareChannelIds(String a, String b) {
  final an = int.tryParse(a.replaceFirst('channel-', ''));
  final bn = int.tryParse(b.replaceFirst('channel-', ''));
  if (an != null && bn != null) return an.compareTo(bn);
  return a.compareTo(b);
}

int _compareLinks(ChannelLink a, ChannelLink b) {
  final bySource = _sourceRank(a.source) - _sourceRank(b.source);
  if (bySource != 0) return bySource;
  final byState = _stateRank(a.state) - _stateRank(b.state);
  if (byState != 0) return byState;
  final byDerived = (a.derived ? 1 : 0) - (b.derived ? 1 : 0);
  if (byDerived != 0) return byDerived;
  final byDest = a.destChainId.compareTo(b.destChainId);
  if (byDest != 0) return byDest;
  return _compareChannelIds(a.channelId, b.channelId);
}

class _MapDirectory implements ChannelDirectory {
  _MapDirectory(this._byChain);

  final Map<String, List<ChannelLink>> _byChain;

  @override
  List<ChannelLink> from(String chainId) => _byChain[chainId] ?? const [];
}

/// Index a flat list of links into a [ChannelDirectory].
///
/// Explicit links win over derived ones with the same key, so a table that
/// states both directions keeps whatever it said about each.
ChannelDirectory createChannelDirectory(
  List<ChannelLink> links, {
  bool deriveReverse = true,
}) {
  final byKey = <String, ChannelLink>{};
  for (final link in links) {
    if (link.sourceChainId.isEmpty ||
        link.destChainId.isEmpty ||
        link.channelId.isEmpty) {
      continue;
    }
    byKey[_linkKey(link)] = link;
  }
  if (deriveReverse) {
    for (final link in links) {
      final reversed = _reverseLink(link);
      if (reversed == null) continue;
      byKey.putIfAbsent(_linkKey(reversed), () => reversed);
    }
  }

  final byChain = <String, List<ChannelLink>>{};
  for (final link in byKey.values) {
    byChain.putIfAbsent(link.sourceChainId, () => <ChannelLink>[]).add(link);
  }
  for (final bucket in byChain.values) {
    bucket.sort(_compareLinks);
  }
  return _MapDirectory(byChain);
}

/* -------------------------------------------------------------------------- *
 * Path finding
 * -------------------------------------------------------------------------- */

/// A chain sequence and the channels that join it.
@immutable
class RoutePath {
  const RoutePath({required this.chainIds, required this.links});

  /// Chains visited, source first, destination last. Always `links.length + 1`.
  final List<String> chainIds;

  /// Channels in travel order. `links[0]` is the transfer the user signs.
  final List<ChannelLink> links;
}

class _PartialPath {
  const _PartialPath(this.chainIds, this.links, this.visited);

  final List<String> chainIds;
  final List<ChannelLink> links;
  final Set<String> visited;
}

int _clampHops(int? value, int fallback) {
  final raw = value ?? fallback;
  return raw.clamp(1, kMaxHopsCap);
}

/// Every simple path from one chain to another, shortest first.
///
/// Breadth-first, so paths come back ordered by hop count with no post-sort.
/// Cycles are impossible: a chain already on the path is never revisited.
///
/// Channels known to be `closed` are dropped. A channel of unknown state is
/// kept — most directories cannot tell us, and refusing to plan over "unknown"
/// would mean refusing to plan at all.
List<RoutePath> findRoutePaths(
  String fromChainId,
  String toChainId,
  ChannelDirectory directory, {
  int? maxHops,
  int? maxPaths,
  int? maxLinksPerPair,
}) {
  final hopLimit = _clampHops(maxHops, kDefaultMaxHops);
  final pathLimit = (maxPaths ?? _defaultMaxPaths).clamp(1, 1 << 20);
  final perPairLimit = (maxLinksPerPair ?? _defaultMaxLinksPerPair).clamp(1, 64);

  if (fromChainId.isEmpty || toChainId.isEmpty || fromChainId == toChainId) {
    return const [];
  }

  final found = <RoutePath>[];
  var frontier = <_PartialPath>[
    _PartialPath([fromChainId], const [], {fromChainId}),
  ];

  for (var depth = 0; depth < hopLimit && frontier.isNotEmpty; depth++) {
    final next = <_PartialPath>[];
    for (final partial in frontier) {
      final head = partial.chainIds.last;
      final perPair = <String, int>{};
      for (final link in directory.from(head)) {
        if (link.state == IbcChannelState.closed) continue;
        if (partial.visited.contains(link.destChainId)) continue;
        final used = perPair[link.destChainId] ?? 0;
        if (used >= perPairLimit) continue;
        perPair[link.destChainId] = used + 1;

        final chainIds = [...partial.chainIds, link.destChainId];
        final links = [...partial.links, link];
        if (link.destChainId == toChainId) {
          found.add(RoutePath(chainIds: chainIds, links: links));
          if (found.length >= pathLimit) return found;
          // A path that has arrived is complete; do not extend it further.
          continue;
        }
        next.add(_PartialPath(
          chainIds,
          links,
          {...partial.visited, link.destChainId},
        ));
      }
    }
    frontier = next;
  }

  return found;
}

/* -------------------------------------------------------------------------- *
 * Manual overrides
 * -------------------------------------------------------------------------- */

/// A channel the user chose by hand.
///
/// Discovery fails: an LCD is slow, paginates badly, or has no client state for
/// a connection. When that happens the user still knows the channel, and the
/// wallet must let them proceed. An override naming a chain pair is added to
/// the graph before the search; one naming [hopIndex] replaces whatever the
/// search picked at that position.
@immutable
class RouteHopOverride {
  const RouteHopOverride({
    required this.channelId,
    this.hopIndex,
    this.fromChainId,
    this.toChainId,
    this.port,
    this.counterpartyChannelId,
  });

  final int? hopIndex;
  final String? fromChainId;
  final String? toChainId;
  final String channelId;
  final String? port;
  final String? counterpartyChannelId;
}

ChannelLink? _overrideToLink(RouteHopOverride override) {
  final from = override.fromChainId;
  final to = override.toChainId;
  if (from == null || to == null || override.channelId.isEmpty) return null;
  return ChannelLink(
    sourceChainId: from,
    destChainId: to,
    channelId: override.channelId,
    port: override.port ?? transferPort,
    counterpartyChannelId: override.counterpartyChannelId,
    source: ChannelLinkSource.manual,
  );
}

bool _matchesOverride(RouteHopOverride override, ChannelLink link, int index) {
  if (override.hopIndex != null) return override.hopIndex == index;
  if (override.fromChainId != null &&
      override.fromChainId != link.sourceChainId) {
    return false;
  }
  if (override.toChainId != null && override.toChainId != link.destChainId) {
    return false;
  }
  return override.fromChainId != null || override.toChainId != null;
}

List<ChannelLink> _applyOverrides(
  List<ChannelLink> links,
  List<RouteHopOverride> overrides,
) {
  return [
    for (var index = 0; index < links.length; index++)
      () {
        final link = links[index];
        RouteHopOverride? hit;
        for (final candidate in overrides) {
          if (_matchesOverride(candidate, link, index)) {
            hit = candidate;
            break;
          }
        }
        if (hit == null || hit.channelId == link.channelId) return link;
        return ChannelLink(
          sourceChainId: link.sourceChainId,
          destChainId: link.destChainId,
          channelId: hit.channelId,
          port: hit.port ?? link.port ?? transferPort,
          // The counterparty of the original channel does not apply to a
          // different channel, so drop it unless the user supplied one. Losing
          // it only costs us the computed destination denom, which we warn
          // about.
          counterpartyChannelId: hit.counterpartyChannelId,
          source: ChannelLinkSource.manual,
        );
      }(),
  ];
}

class _OverlayDirectory implements ChannelDirectory {
  _OverlayDirectory(this._base, List<ChannelLink> extra)
      : _extra = <String, List<ChannelLink>>{} {
    for (final link in extra) {
      _extra.putIfAbsent(link.sourceChainId, () => <ChannelLink>[]).add(link);
    }
  }

  final ChannelDirectory _base;
  final Map<String, List<ChannelLink>> _extra;

  @override
  List<ChannelLink> from(String chainId) {
    final added = _extra[chainId];
    if (added == null) return _base.from(chainId);
    final base = _base.from(chainId).where((link) => !added.any((a) =>
        a.channelId == link.channelId &&
        (a.port ?? transferPort) == (link.port ?? transferPort)));
    return [...added, ...base]..sort(_compareLinks);
  }
}

/* -------------------------------------------------------------------------- *
 * Capabilities and venues
 * -------------------------------------------------------------------------- */

/// Middleware a chain runs.
///
/// The Keplr-format registry does not publish this, so the host supplies it.
/// Every field is nullable and null means "nobody checked", which the planner
/// reports differently from a known false.
@immutable
class ChainCapabilities {
  const ChainCapabilities({this.pfm, this.ibcHooks, this.cosmwasm});

  final bool? pfm;
  final bool? ibcHooks;
  final bool? cosmwasm;
}

/// Capability lookup, implemented by the host. Synchronous, like the registry.
typedef ChainCapabilityLookup = ChainCapabilities? Function(String chainId);

/// A place a swap can happen.
///
/// [contractAddress] is never hardcoded in this package. The crosschain-swaps
/// addresses that circulate in Osmosis governance and docs are unverified
/// candidates, and a wrong contract address in a memo sends funds to a contract
/// that will not send them back. The host looks the address up, checks it
/// exists on chain, and passes it in.
@immutable
class SwapVenue {
  const SwapVenue({
    required this.chainId,
    required this.contractAddress,
    this.denoms,
    this.label,
  });

  final String chainId;
  final String contractAddress;

  /// Denoms the venue can trade, as held on [chainId]. Null when the host does
  /// not have the list; the planner then offers the venue and warns instead of
  /// silently ruling it out.
  final List<String>? denoms;

  final String? label;
}

/* -------------------------------------------------------------------------- *
 * Denom arithmetic
 * -------------------------------------------------------------------------- */

@immutable
class _DenomState {
  const _DenomState(this.path, this.baseDenom);

  final String path;
  final String baseDenom;
}

List<DenomHop> _splitTracePath(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  final hops = <DenomHop>[];
  // Pairs only. An odd tail is a malformed trace; drop it rather than guess, so
  // the caller sees a shorter path than expected, never a wrong one.
  for (var i = 0; i + 1 < parts.length; i += 2) {
    hops.add(DenomHop(port: parts[i], channelId: parts[i + 1]));
  }
  return hops;
}

/// Move a denom across one channel.
///
/// Two cases, and getting them the wrong way round is how wallets mint denoms
/// nobody can name: the trace already starts with this channel, so ICS20
/// unwraps one hop; or anything else wraps, and the receiving chain prefixes
/// the trace with its own port and channel — which is why
/// [ChannelLink.counterpartyChannelId] matters. Without it we return null
/// rather than guess.
_DenomState? _stepDenom(_DenomState state, ChannelLink link) {
  final port = link.port ?? transferPort;
  final hops = _splitTracePath(state.path);
  if (hops.isNotEmpty &&
      hops.first.port == port &&
      hops.first.channelId == link.channelId) {
    return _DenomState(joinTracePath(hops.sublist(1)), state.baseDenom);
  }
  final counterparty = link.counterpartyChannelId;
  if (counterparty == null || counterparty.isEmpty) return null;
  return _DenomState(
    joinTracePath([
      DenomHop(
        port: link.counterpartyPortId ?? transferPort,
        channelId: counterparty,
      ),
      ...hops,
    ]),
    state.baseDenom,
  );
}

_DenomState? _stepDenomAlong(_DenomState? state, List<ChannelLink> links) {
  var current = state;
  for (final link in links) {
    if (current == null) return null;
    current = _stepDenom(current, link);
  }
  return current;
}

String? _denomStringFor(_DenomState? state) {
  if (state == null) return null;
  if (state.path.isEmpty) return state.baseDenom;
  return ibcDenomHash(state.path, state.baseDenom);
}

/// The denom [inputDenom] becomes after travelling [links].
///
/// Returns null when the arithmetic cannot be completed — an unknown
/// counterparty channel, or a wrapped input whose trace was never resolved. Null
/// means "unknown", and a caller must not fall back to the input denom.
///
/// Exposed because [RoutePlanCandidate] does not carry the denom that arrives at
/// a swap venue, and a venue cannot be asked for a quote without it. `route.ts`
/// computes the same value internally and drops it; that is an engine gap, not a
/// difference of behaviour, and this function is the same arithmetic.
String? denomAfterHops(
  String inputDenom,
  ResolvedDenom? resolvedInput,
  List<ChannelLink> links,
) {
  final start = resolvedInput != null
      ? _DenomState(resolvedInput.path, resolvedInput.baseDenom)
      : inputDenom.startsWith('ibc/')
          ? null
          : _DenomState('', inputDenom);
  return _denomStringFor(_stepDenomAlong(start, links));
}

/* -------------------------------------------------------------------------- *
 * Memos
 * -------------------------------------------------------------------------- */

/// Nest forward hops into a PFM memo, or return [tail] when there is nothing to
/// forward. The nesting, the `"pfm"` sentinel and the validation all live in
/// `memo.dart`; this only handles the zero-hop case, which is a plan with no
/// forwarding rather than an error.
Map<String, Object?>? _forwardMemoOrNull(
  List<ForwardHop> hops,
  String finalReceiver,
  String timeout,
  int retries, [
  Map<String, Object?>? tail,
]) {
  if (hops.isEmpty) return tail;
  return buildForwardMemoJson(
    hops,
    finalReceiver,
    timeout: timeout,
    retries: retries,
    next: tail,
    // The planner's own hop budget already bounded this list, so pin memo.dart's
    // ceiling to the same number: a plan the planner refused to enumerate must
    // not become buildable by going through the memo builder directly.
    maxHops: kMaxHopsCap,
  );
}

/// An empty memo and an absent memo are the same on the wire, so `''` is the
/// canonical "no memo" and a built memo is encoded exactly once, here.
String _stringifyMemo(Map<String, Object?>? memo) =>
    memo == null ? '' : jsonEncode(memo);

XcsSlippage _planSlippage(
  double slippagePercent,
  int? windowSeconds,
  String? minOutputAmount,
) {
  if (minOutputAmount != null) return XcsMinOutputSlippage(minOutputAmount);
  return XcsTwapSlippage(
    // A string, not a number: the contract parses a Decimal.
    slippagePercentage: formatPlainDecimal(slippagePercent),
    windowSeconds: windowSeconds,
  );
}

/* -------------------------------------------------------------------------- *
 * Plans
 * -------------------------------------------------------------------------- */

/// How a plan moves the value.
enum RouteStrategy {
  /// Same chain, same denom. No IBC at all.
  bankSend,

  /// Same chain, different denom, through a contract on it.
  localSwap,

  /// One ICS20 hop, no memo.
  ibcTransfer,

  /// One signed hop plus packet-forward-middleware hops.
  ibcForward,

  /// An ibc-hooks contract call on a venue chain, with forwards around it.
  ibcSwap,
}

/// How long a route takes, roughly.
///
/// Order-of-magnitude figures for "arrives in about a minute" copy, derived
/// from typical six-second blocks plus relayer polling — not a measurement and
/// not a promise.
@immutable
class RouteDurationModel {
  const RouteDurationModel({
    this.bankSendSeconds = 10,
    this.baseSeconds = 20,
    this.perPacketHopSeconds = 40,
    this.swapSeconds = 15,
  });

  final int bankSendSeconds;
  final int baseSeconds;
  final int perPacketHopSeconds;
  final int swapSeconds;
}

/// One route the user could take.
@immutable
class RoutePlanCandidate {
  const RoutePlanCandidate({
    required this.plan,
    required this.strategy,
    required this.links,
    required this.receiver,
    required this.quote,
    required this.requiresQuote,
    required this.venue,
    required this.unwindsDenom,
    required this.unverifiedChannelCount,
    required this.packetHopCount,
    required this.score,
  });

  final RoutePlan plan;
  final RouteStrategy strategy;

  /// Channels used, in travel order. Empty for a same-chain plan.
  final List<ChannelLink> links;

  /// ICS20 `receiver` for the transfer the user signs.
  ///
  /// Not always the final recipient: a swap route addresses the packet to the
  /// contract (ibc-hooks requires the receiver to be `""` or the contract), and
  /// a forward route addresses it to the intermediate chain.
  final String receiver;

  /// Always null here. The planner has no pool state and will not invent an
  /// output amount or a price impact; `swap.dart` fills this in.
  final SwapQuote? quote;

  /// True when the plan is meaningless until [quote] is filled in.
  final bool requiresQuote;

  final SwapVenue? venue;

  /// True when the first hop sends a wrapped token back the way it came.
  final bool unwindsDenom;

  /// Channels on the path that nobody has verified as open.
  final int unverifiedChannelCount;

  /// Hops that move an IBC packet. Excludes the swap hop.
  final int packetHopCount;

  /// Ranking score, lower is better. Exposed so a UI can show ties honestly.
  final int score;

  RoutePlanCandidate withQuote(SwapQuote quote, {RoutePlan? plan}) =>
      RoutePlanCandidate(
        plan: plan ?? this.plan,
        strategy: strategy,
        links: links,
        receiver: receiver,
        quote: quote,
        requiresQuote: false,
        venue: venue,
        unwindsDenom: unwindsDenom,
        unverifiedChannelCount: unverifiedChannelCount,
        packetHopCount: packetHopCount,
        score: score,
      );
}

/// Everything [planRoute] found.
@immutable
class RoutePlanResult {
  const RoutePlanResult({
    required this.sourceChainId,
    required this.destChainId,
    required this.inputDenom,
    required this.requestedOutputDenom,
    required this.candidates,
    required this.best,
    required this.warnings,
    required this.resolvedInput,
  });

  final String sourceChainId;
  final String destChainId;
  final String inputDenom;

  /// Output denom the caller asked for, defaulted to the unwrapped input.
  final String requestedOutputDenom;

  /// Viable plans, best first. Empty when nothing works; see [warnings].
  final List<RoutePlanCandidate> candidates;

  /// `candidates.first`, or null.
  final RoutePlanCandidate? best;

  /// Why some route was not offered. Planner-level, not per-plan.
  final List<String> warnings;

  /// The input denom's trace, when a resolver was available and it was wrapped.
  final ResolvedDenom? resolvedInput;
}

/// What [planRoute] needs from the host.
@immutable
class RoutePlannerDeps {
  const RoutePlannerDeps({
    required this.registry,
    required this.channels,
    this.resolveDenom,
    this.capabilities,
    this.venues = const [],
  });

  final ChainRegistry registry;
  final ChannelDirectory channels;

  /// Denom trace lookup. Without it, `ibc/…` inputs stay opaque.
  final Future<ResolvedDenom> Function(ChainInfo chain, String denom)?
      resolveDenom;

  final ChainCapabilityLookup? capabilities;

  /// Places a swap can happen. Empty disables every swap route.
  final List<SwapVenue> venues;
}

/// Tuning for [planRoute].
@immutable
class PlanRouteOptions {
  const PlanRouteOptions({
    this.maxCandidates,
    this.maxPathsPerLeg,
    this.maxLinksPerPair,
    this.overrides = const [],
    this.intermediateReceivers = const {},
    this.pfmRetries,
    this.twapWindowSeconds,
    this.minOutputAmount,
    this.requirePfmSupport = false,
    this.requireIbcHooksSupport = false,
    this.durations = const RouteDurationModel(),
    this.resolvedInput,
  });

  final int? maxCandidates;
  final int? maxPathsPerLeg;
  final int? maxLinksPerPair;
  final List<RouteHopOverride> overrides;

  /// Receiver to address the packet to on each intermediate chain, keyed by
  /// chain id.
  ///
  /// This package does not derive addresses, so the host — which has the user's
  /// key material — re-encodes the sender for each intermediate prefix and
  /// passes the results here. Without an entry the planner falls back to the
  /// `"pfm"` placeholder and warns.
  final Map<String, String> intermediateReceivers;

  final int? pfmRetries;

  /// `window_seconds` for TWAP slippage. Null omits the key, so the contract's
  /// own default (3600) applies rather than a guess.
  final int? twapWindowSeconds;

  /// Use `{"min_output_amount": …}` slippage instead of TWAP. Only meaningful
  /// once something has quoted the pool, so the planner never computes it.
  final String? minOutputAmount;

  final bool requirePfmSupport;
  final bool requireIbcHooksSupport;
  final RouteDurationModel durations;

  /// Pre-resolved trace for the input denom, so a caller that already has one
  /// can plan without a network read.
  final ResolvedDenom? resolvedInput;
}

/* -------------------------------------------------------------------------- *
 * Warnings and scoring
 * -------------------------------------------------------------------------- */

void _addWarning(List<String> list, String text) {
  if (!list.contains(text)) list.add(text);
}

String _chainLabel(ChainRegistry registry, String chainId) =>
    registry.get(chainId)?.chainName ?? chainId;

bool _isBaseUnitAmount(String value) => RegExp(r'^[0-9]+$').hasMatch(value);

bool _hasCosmwasm(ChainInfo chain, ChainCapabilityLookup? capabilities) {
  final declared = capabilities?.call(chain.chainId)?.cosmwasm;
  if (declared != null) return declared;
  final features = chain.features;
  // A registry row with no `features` array tells us nothing; the catalog
  // generator drops the field today. Treat silence as "maybe", not "no".
  if (features == null) return true;
  return features.contains('cosmwasm');
}

class _PathWarnings {
  const _PathWarnings(this.unverified, this.capabilityGaps);

  final int unverified;
  final int capabilityGaps;
}

_PathWarnings _collectPathWarnings({
  required ChainRegistry registry,
  required ChainCapabilityLookup? capabilities,
  required List<ChannelLink> links,
  required List<String> chainIds,
  required List<String> forwardingChainIds,
  required List<String> warnings,
}) {
  var unverified = 0;
  var capabilityGaps = 0;

  for (final link in links) {
    if (link.source == ChannelLinkSource.verified &&
        link.state == IbcChannelState.open) {
      continue;
    }
    unverified += 1;
    final from = _chainLabel(registry, link.sourceChainId);
    if (link.source == ChannelLinkSource.manual) {
      _addWarning(warnings,
          '${link.channelId} on $from was entered by hand and has not been checked');
    } else if (link.state == IbcChannelState.closed) {
      _addWarning(warnings, '${link.channelId} on $from is closed');
    } else {
      _addWarning(
          warnings, '${link.channelId} on $from has not been verified as open');
    }
    final counterparty = link.counterpartyChannelId;
    if (counterparty == null || counterparty.isEmpty) {
      _addWarning(
        warnings,
        'The counterparty of ${link.channelId} on $from is unknown, so the '
        'denom on arrival cannot be computed',
      );
    }
  }

  for (final chainId in forwardingChainIds) {
    final pfm = capabilities?.call(chainId)?.pfm;
    if (pfm == true) continue;
    capabilityGaps += 1;
    final label = _chainLabel(registry, chainId);
    _addWarning(
      warnings,
      pfm == false
          ? '$label does not run packet-forward-middleware, so the forward will fail'
          : 'Packet forwarding on $label is unconfirmed',
    );
  }

  final networks = <String>{};
  for (final chainId in chainIds) {
    final network = registry.get(chainId)?.network;
    if (network != null) networks.add(network);
  }
  if (networks.length > 1) {
    _addWarning(warnings,
        'This route mixes mainnet and testnet chains and will not complete');
  }

  return _PathWarnings(unverified, capabilityGaps);
}

int _durationFor(RouteDurationModel model, int packetHops, int swaps) =>
    model.baseSeconds +
    packetHops * model.perPacketHopSeconds +
    swaps * model.swapSeconds;

RouteHop _transferHop(ChannelLink link, RouteHopKind kind) => RouteHop(
      chainId: link.sourceChainId,
      channelId: link.channelId,
      port: link.port ?? transferPort,
      counterpartyChainId: link.destChainId,
      kind: kind,
    );

/// The swap hop.
///
/// `channelId` and `port` are empty because nothing moves: the contract runs on
/// the venue chain during packet processing and the value stays there until the
/// next hop sends it on, so `counterpartyChainId` is the venue itself.
RouteHop _swapHop(String chainId) => RouteHop(
      chainId: chainId,
      channelId: '',
      port: '',
      counterpartyChainId: chainId,
      kind: RouteHopKind.swap,
    );

int _scoreOf({
  required int packetHops,
  required int unverified,
  required int capabilityGaps,
  required bool isSwap,
  required bool missedUnwind,
}) =>
    packetHops * 100 +
    unverified * 10 +
    capabilityGaps * 5 +
    (isSwap ? 5 : 0) +
    (missedUnwind ? _missedUnwindPenalty : 0);

/// Receiver for the packet landing on an intermediate chain.
///
/// The fallback is honest rather than clever: `"pfm"` is the placeholder the
/// middleware itself uses, and the warning tells the caller it needs a real
/// address.
String _intermediateReceiverFor(
  String chainId,
  ChainRegistry registry,
  Map<String, String> receivers,
  List<String> warnings,
) {
  final supplied = receivers[chainId];
  if (supplied != null && supplied.isNotEmpty) return supplied;
  _addWarning(
    warnings,
    'No receiver address for ${_chainLabel(registry, chainId)}; the '
    'placeholder "$pfmIntermediateReceiver" is used and the host must replace '
    'it before signing',
  );
  return pfmIntermediateReceiver;
}

/* -------------------------------------------------------------------------- *
 * planRoute
 * -------------------------------------------------------------------------- */

/// Plan every viable way to move value from one chain to another.
///
/// Strategies, all of which contribute candidates:
///
/// 1. Same chain, same denom — a bank send with no hops.
/// 2. Same chain, different denom — a contract swap on that chain.
/// 3. Cross chain, same asset — a direct ICS20 transfer, or a
///    packet-forward-middleware chain when nothing direct exists.
/// 4. Cross chain, different asset — through a swap venue's ibc-hooks contract,
///    with forwards before or after as the path needs.
/// 5. A wrapped token native to neither side — the first hop unwinds it along
///    the channel it arrived on, and routing continues from its origin.
///
/// An empty [RoutePlanResult.candidates] is a normal answer, not an error —
/// [RoutePlanResult.warnings] says why. Throws [InterchainError]
/// `unsupportedChain` when either chain is unknown; nothing else here throws.
Future<RoutePlanResult> planRoute(
  RouteRequest request,
  RoutePlannerDeps deps, [
  PlanRouteOptions options = const PlanRouteOptions(),
]) async {
  final warnings = <String>[];
  final registry = deps.registry;

  final source = registry.get(request.sourceChainId);
  if (source == null) {
    throw InterchainError(
      InterchainErrorCode.unsupportedChain,
      'Unknown source chain ${request.sourceChainId}',
      chainId: request.sourceChainId,
    );
  }
  final dest = registry.get(request.destChainId);
  if (dest == null) {
    throw InterchainError(
      InterchainErrorCode.unsupportedChain,
      'Unknown destination chain ${request.destChainId}',
      chainId: request.destChainId,
    );
  }

  if (!_isBaseUnitAmount(request.amount)) {
    _addWarning(warnings,
        'Amount is not a whole number of base units; check it before signing');
  }
  if (request.recipient.isEmpty) {
    _addWarning(warnings, 'No recipient address was supplied');
  }

  final maxHops = _clampHops(request.maxHops, kDefaultMaxHops);
  final allowPfm = request.allowPfm;
  final allowSwap = request.allowSwap;
  final overrides = options.overrides;
  final candidates = <RoutePlanCandidate>[];

  // Resolve the input denom's trace. Only an `ibc/` denom needs it: anything
  // else is native to the chain that holds it, by definition.
  ResolvedDenom? resolvedInput = options.resolvedInput;
  if (resolvedInput == null && request.inputDenom.startsWith('ibc/')) {
    final resolver = deps.resolveDenom;
    if (resolver != null) {
      try {
        resolvedInput = await resolver(source, request.inputDenom);
      } on Object {
        // A trace lookup that fails costs us the origin chain and the computed
        // output denom, not the route. Carry on and say so.
        _addWarning(warnings,
            "Could not read the denom trace, so the token's origin chain is unknown");
      }
    } else {
      _addWarning(
        warnings,
        "No denom resolver was supplied, so this wrapped token's origin chain "
        'is unknown',
      );
    }
  }

  final inputState = resolvedInput != null
      ? _DenomState(resolvedInput.path, resolvedInput.baseDenom)
      : request.inputDenom.startsWith('ibc/')
          ? null
          : _DenomState('', request.inputDenom);

  final unwrappedInput = resolvedInput?.baseDenom ?? request.inputDenom;
  final requestedOutputDenom = request.outputDenom ?? unwrappedInput;
  final sameAsset = request.outputDenom == null ||
      request.outputDenom == request.inputDenom ||
      request.outputDenom == unwrappedInput;

  RoutePlanResult finish(List<RoutePlanCandidate> rows) {
    final ranked = [...rows]..sort((a, b) {
        if (a.score != b.score) return a.score - b.score;
        // Deterministic tie-break, so the same inputs always produce the same
        // "best" route and the UI does not reshuffle between renders.
        final aKey = a.links.map((l) => l.channelId).join(',');
        final bKey = b.links.map((l) => l.channelId).join(',');
        return _compareChannelIds(aKey, bKey);
      });
    final capped = ranked
        .take((options.maxCandidates ?? _defaultMaxCandidates).clamp(1, 64))
        .toList();
    return RoutePlanResult(
      sourceChainId: source.chainId,
      destChainId: dest.chainId,
      inputDenom: request.inputDenom,
      requestedOutputDenom: requestedOutputDenom,
      candidates: capped,
      best: capped.isEmpty ? null : capped.first,
      warnings: warnings,
      resolvedInput: resolvedInput,
    );
  }

  RoutePlanResult emptyResult() => finish(const []);

  /* ---------------------------------------------------------------- *
   * 1 & 2: same chain
   * ---------------------------------------------------------------- */

  if (source.chainId == dest.chainId) {
    if (request.outputDenom == null ||
        request.outputDenom == request.inputDenom) {
      candidates.add(RoutePlanCandidate(
        plan: RoutePlan(
          sourceChainId: source.chainId,
          destChainId: dest.chainId,
          inputDenom: request.inputDenom,
          outputDenom: request.inputDenom,
          hops: const [],
          memo: '',
          warnings: [...warnings],
          estimatedDurationSeconds: options.durations.bankSendSeconds,
          requiresPfm: false,
          requiresIbcHooks: false,
        ),
        strategy: RouteStrategy.bankSend,
        links: const [],
        receiver: request.recipient,
        quote: null,
        requiresQuote: false,
        venue: null,
        unwindsDenom: false,
        unverifiedChannelCount: 0,
        packetHopCount: 0,
        score: 0,
      ));
      return finish(candidates);
    }

    // Different denom on the same chain: a contract swap, not IBC.
    if (!allowSwap) {
      _addWarning(
          warnings, 'Swaps are turned off, so a same-chain swap was not planned');
      return emptyResult();
    }
    if (!_hasCosmwasm(source, deps.capabilities)) {
      _addWarning(warnings,
          '${source.chainName} does not run CosmWasm, so it cannot host a swap');
      return emptyResult();
    }
    SwapVenue? localVenue;
    for (final venue in deps.venues) {
      if (venue.chainId == source.chainId) {
        localVenue = venue;
        break;
      }
    }
    if (localVenue == null) {
      _addWarning(
          warnings, 'No swap venue is configured on ${source.chainName}');
      return emptyResult();
    }

    final planWarnings = [...warnings];
    _addWarning(
        planWarnings, 'The output amount is unknown until the pool is quoted');
    candidates.add(RoutePlanCandidate(
      plan: RoutePlan(
        sourceChainId: source.chainId,
        destChainId: dest.chainId,
        inputDenom: request.inputDenom,
        outputDenom: requestedOutputDenom,
        hops: [_swapHop(source.chainId)],
        // A local swap is an ExecuteContract the user signs directly; there is
        // no packet and therefore no memo.
        memo: '',
        warnings: planWarnings,
        estimatedDurationSeconds: _durationFor(options.durations, 0, 1),
        requiresPfm: false,
        requiresIbcHooks: false,
      ),
      strategy: RouteStrategy.localSwap,
      links: const [],
      receiver: request.recipient,
      quote: null,
      requiresQuote: true,
      venue: localVenue,
      unwindsDenom: false,
      unverifiedChannelCount: 0,
      packetHopCount: 0,
      score: 5,
    ));
    return finish(candidates);
  }

  /* ---------------------------------------------------------------- *
   * Graph: the host's links, plus anything the user forced
   * ---------------------------------------------------------------- */

  final extraLinks = <ChannelLink>[];
  for (final override in overrides) {
    final link = _overrideToLink(override);
    if (link != null) extraLinks.add(link);
  }

  // 5: the unwind edge. A wrapped token leaves along the channel it arrived on;
  // add that edge so the search can use it even when the directory has no entry.
  String? unwindChannelId;
  if (resolvedInput != null && !resolvedInput.isNative) {
    final hops = resolvedInput.hops;
    if (hops.isNotEmpty) {
      final firstHop = hops.first;
      unwindChannelId = firstHop.channelId;
      final known = deps.channels.from(source.chainId).where((link) =>
          link.channelId == firstHop.channelId &&
          (link.port ?? transferPort) == firstHop.port);
      if (known.isEmpty) {
        // Only safe when the trace has a single hop: then the channel's other
        // end is the origin chain. With more hops the next chain along is not
        // the origin and we cannot name it, so the edge is left out.
        final origin = resolvedInput.originChainId;
        if (hops.length == 1 && origin != null) {
          extraLinks.add(ChannelLink(
            sourceChainId: source.chainId,
            destChainId: origin,
            channelId: firstHop.channelId,
            port: firstHop.port,
          ));
        } else {
          _addWarning(
            warnings,
            'Channel ${firstHop.channelId} unwinds this token but is not in '
            'the channel list',
          );
        }
      }
    }
  }

  final directory = extraLinks.isEmpty
      ? deps.channels
      : _OverlayDirectory(deps.channels, extraLinks);
  final pathHops = allowPfm ? maxHops : 1;
  if (!allowPfm && maxHops > 1) {
    _addWarning(warnings,
        'Packet forwarding is turned off, so only a direct channel was considered');
  }

  final timeout = '${request.timeoutMinutes ?? _defaultTimeoutMinutes}m';
  final retries = options.pfmRetries ?? defaultPfmRetries;

  /* ---------------------------------------------------------------- *
   * 3: cross chain, same asset
   * ---------------------------------------------------------------- */

  if (sameAsset) {
    final paths = findRoutePaths(
      source.chainId,
      dest.chainId,
      directory,
      maxHops: pathHops,
      maxPaths: options.maxPathsPerLeg,
      maxLinksPerPair: options.maxLinksPerPair,
    );
    if (paths.isEmpty) {
      _addWarning(
        warnings,
        'No channel path from ${source.chainName} to ${dest.chainName} within '
        '$maxHops hops',
      );
    }

    for (final path in paths) {
      final links = _applyOverrides(path.links, overrides);
      if (links.isEmpty) continue;
      final first = links.first;

      final planWarnings = [...warnings];
      final forwardingChainIds = path.chainIds.sublist(1, path.chainIds.length - 1);
      final collected = _collectPathWarnings(
        registry: registry,
        capabilities: deps.capabilities,
        links: links,
        chainIds: path.chainIds,
        forwardingChainIds: forwardingChainIds,
        warnings: planWarnings,
      );

      // Hops after the one the user signs. `memo.dart` puts the real recipient
      // on the last of them and the "pfm" sentinel on every earlier one.
      final forwards = <ForwardHop>[
        for (var i = 1; i < links.length; i++)
          ForwardHop(
            channelId: links[i].channelId,
            port: links[i].port ?? transferPort,
          ),
      ];
      final memo =
          _forwardMemoOrNull(forwards, request.recipient, timeout, retries);
      final receiver = links.length == 1
          ? request.recipient
          : _intermediateReceiverFor(
              path.chainIds.length > 1 ? path.chainIds[1] : '',
              registry,
              options.intermediateReceivers,
              planWarnings,
            );

      final computedOutput = _denomStringFor(_stepDenomAlong(inputState, links));
      final outputDenom = computedOutput ?? requestedOutputDenom;
      if (computedOutput == null) {
        // Null here means the trace arithmetic gave up (an unknown counterparty
        // channel). The honest answer is "unknown", never the input denom
        // passed off as the output.
        _addWarning(planWarnings,
            'The denom the recipient ends up with could not be computed');
      }

      final unwindsDenom =
          unwindChannelId != null && first.channelId == unwindChannelId;
      final missedUnwind = unwindChannelId != null && !unwindsDenom;
      if (missedUnwind) {
        _addWarning(
          planWarnings,
          'This sends a wrapped token onward instead of unwinding it, so the '
          'recipient receives a double-wrapped denom',
        );
      }
      if (links.length > 2) {
        _addWarning(
          planWarnings,
          '${links.length} hops: each one adds delay and another chance of a '
          'timeout',
        );
      }

      if (options.requirePfmSupport && collected.capabilityGaps > 0) continue;

      candidates.add(RoutePlanCandidate(
        plan: RoutePlan(
          sourceChainId: source.chainId,
          destChainId: dest.chainId,
          inputDenom: request.inputDenom,
          outputDenom: outputDenom,
          hops: [
            for (var i = 0; i < links.length; i++)
              _transferHop(
                links[i],
                i == 0 ? RouteHopKind.transfer : RouteHopKind.forward,
              ),
          ],
          memo: _stringifyMemo(memo),
          warnings: planWarnings,
          estimatedDurationSeconds:
              _durationFor(options.durations, links.length, 0),
          requiresPfm: forwards.isNotEmpty,
          requiresIbcHooks: false,
        ),
        strategy: forwards.isNotEmpty
            ? RouteStrategy.ibcForward
            : RouteStrategy.ibcTransfer,
        links: links,
        receiver: receiver,
        quote: null,
        requiresQuote: false,
        venue: null,
        unwindsDenom: unwindsDenom,
        unverifiedChannelCount: collected.unverified,
        packetHopCount: links.length,
        score: _scoreOf(
          packetHops: links.length,
          unverified: collected.unverified,
          capabilityGaps: collected.capabilityGaps,
          isSwap: false,
          missedUnwind: missedUnwind,
        ),
      ));
    }

    return finish(candidates);
  }

  /* ---------------------------------------------------------------- *
   * 4: cross chain, different asset
   * ---------------------------------------------------------------- */

  if (!allowSwap) {
    _addWarning(warnings,
        'Swaps are turned off, so no cross-chain swap route was planned');
    return emptyResult();
  }
  if (deps.venues.isEmpty) {
    _addWarning(warnings, 'No swap venue is configured');
    return emptyResult();
  }
  if (request.slippagePercent == null) {
    _addWarning(warnings,
        'No slippage tolerance was given; $kDefaultSlippagePercent% is assumed');
  }
  if (request.recoveryAddress == null) {
    _addWarning(
      warnings,
      'No recovery address: if the swap succeeds but delivery fails, the funds '
      'cannot be reclaimed',
    );
  }

  final slippage = _planSlippage(
    request.slippagePercent ?? kDefaultSlippagePercent,
    options.twapWindowSeconds,
    options.minOutputAmount,
  );

  for (final venue in deps.venues) {
    final venueChain = registry.get(venue.chainId);
    if (venueChain == null) {
      _addWarning(warnings,
          'Swap venue chain ${venue.chainId} is not in the registry');
      continue;
    }
    if (venue.chainId == source.chainId) {
      // ibc-hooks fires on an incoming packet. Swapping where the funds already
      // are means a contract call and then a transfer: two signatures, which is
      // a different flow, not a route.
      _addWarning(
        warnings,
        'Swapping on ${venueChain.chainName} and then transferring takes two '
        'transactions and is not planned as one route',
      );
      continue;
    }
    if (!_hasCosmwasm(venueChain, deps.capabilities)) {
      _addWarning(
        warnings,
        '${venueChain.chainName} does not run CosmWasm, so it cannot host the swap',
      );
      continue;
    }
    final hooks = deps.capabilities?.call(venue.chainId)?.ibcHooks;
    if (hooks == false && options.requireIbcHooksSupport) {
      _addWarning(
        warnings,
        '${venueChain.chainName} does not run ibc-hooks, so the swap memo would '
        'be ignored',
      );
      continue;
    }

    final inPaths = findRoutePaths(
      source.chainId,
      venue.chainId,
      directory,
      maxHops: pathHops,
      maxPaths: options.maxPathsPerLeg,
      maxLinksPerPair: options.maxLinksPerPair,
    );
    if (inPaths.isEmpty) {
      _addWarning(warnings,
          'No channel path from ${source.chainName} to ${venueChain.chainName}');
      continue;
    }
    final outPaths = venue.chainId == dest.chainId
        ? <RoutePath>[RoutePath(chainIds: [venue.chainId], links: const [])]
        : findRoutePaths(
            venue.chainId,
            dest.chainId,
            directory,
            maxHops: pathHops,
            maxPaths: options.maxPathsPerLeg,
            maxLinksPerPair: options.maxLinksPerPair,
          );
    if (outPaths.isEmpty) {
      _addWarning(warnings,
          'No channel path from ${venueChain.chainName} to ${dest.chainName}');
      continue;
    }

    for (final inPath in inPaths) {
      for (final outPath in outPaths) {
        final totalHops = inPath.links.length + outPath.links.length;
        if (totalHops > maxHops) continue;

        final inLinks = _applyOverrides(inPath.links, overrides);
        final outLinks = _applyOverrides(outPath.links, overrides);
        if (inLinks.isEmpty) continue;
        final first = inLinks.first;

        final planWarnings = [...warnings];
        final chainIds = [...inPath.chainIds, ...outPath.chainIds.sublist(1)];
        final forwardingChainIds =
            inPath.chainIds.sublist(1, inPath.chainIds.length - 1);
        final collected = _collectPathWarnings(
          registry: registry,
          capabilities: deps.capabilities,
          links: [...inLinks, ...outLinks],
          chainIds: chainIds,
          forwardingChainIds: forwardingChainIds,
          warnings: planWarnings,
        );
        if (hooks != true) {
          _addWarning(
            planWarnings,
            hooks == false
                ? '${venueChain.chainName} does not run ibc-hooks, so the swap '
                    'memo may be ignored'
                : 'ibc-hooks support on ${venueChain.chainName} is unconfirmed',
          );
        }

        // What the swap receives, as denominated on the venue chain. Needed to
        // tell the venue what it is selling; unknowable without a trace.
        final venueInputDenom =
            _denomStringFor(_stepDenomAlong(inputState, inLinks));
        if (venueInputDenom == null) {
          _addWarning(
            planWarnings,
            'The denom arriving on ${venueChain.chainName} could not be computed',
          );
        } else if (venue.denoms != null &&
            !venue.denoms!.contains(venueInputDenom)) {
          _addWarning(
            planWarnings,
            '${venueChain.chainName} does not list $venueInputDenom as tradeable',
          );
        }
        if (venue.denoms == null) {
          _addWarning(
            planWarnings,
            'The tradeable denoms on ${venueChain.chainName} are unknown, so '
            'the pool may not exist',
          );
        }

        // Post-swap addressing. The contract sends the swapped token to
        // `receiver`, whose prefix picks the destination chain, and `next_memo`
        // carries any further forwards from there.
        final afterVenueChainId =
            outPath.chainIds.length > 1 ? outPath.chainIds[1] : dest.chainId;
        final swapReceiver = outLinks.length <= 1
            ? request.recipient
            : _intermediateReceiverFor(
                afterVenueChainId,
                registry,
                options.intermediateReceivers,
                planWarnings,
              );
        final postForwards = <ForwardHop>[
          for (var i = 1; i < outLinks.length; i++)
            ForwardHop(
              channelId: outLinks[i].channelId,
              port: outLinks[i].port ?? transferPort,
            ),
        ];
        final nextMemo = _forwardMemoOrNull(
          postForwards,
          request.recipient,
          timeout,
          retries,
        );

        final recovery = request.recoveryAddress;
        final onFailedDelivery = recovery == null
            ? const XcsDoNothing()
            : XcsLocalRecovery(recovery);
        // `buildXcsSwapMemoJson` emits the whole `{wasm:{contract,msg}}`, so the
        // exactly-two-keys rule is enforced in one place for every caller.
        final wasmMemo = buildXcsSwapMemoJson(
          contract: venue.contractAddress,
          outputDenom: requestedOutputDenom,
          receiver: swapReceiver,
          slippage: slippage,
          onFailedDelivery: onFailedDelivery,
          nextMemo: nextMemo,
        );

        // The last pre-swap forward lands on the venue chain, so its receiver is
        // the contract — ibc-hooks requires the ICS20 receiver to be "" or the
        // contract address — and the wasm memo rides in its `next`.
        final preForwards = <ForwardHop>[
          for (var i = 1; i < inLinks.length; i++)
            ForwardHop(
              channelId: inLinks[i].channelId,
              port: inLinks[i].port ?? transferPort,
            ),
        ];
        final memo = _forwardMemoOrNull(
          preForwards,
          venue.contractAddress,
          timeout,
          retries,
          wasmMemo,
        );
        final receiver = inLinks.length == 1
            ? venue.contractAddress
            : _intermediateReceiverFor(
                inPath.chainIds.length > 1 ? inPath.chainIds[1] : '',
                registry,
                options.intermediateReceivers,
                planWarnings,
              );

        // The recipient holds the venue's output denom wrapped by whatever it
        // crossed on the way out.
        final outputState = requestedOutputDenom.startsWith('ibc/')
            ? null
            : _stepDenomAlong(
                _DenomState('', requestedOutputDenom),
                outLinks,
              );
        final computedOutput = _denomStringFor(outputState);
        final outputDenom = computedOutput ?? requestedOutputDenom;
        if (computedOutput == null && outLinks.isNotEmpty) {
          _addWarning(
            planWarnings,
            'The denom on ${dest.chainName} is the IBC form of '
            '$requestedOutputDenom and could not be computed here',
          );
        }

        _addWarning(
            planWarnings, 'The output amount is unknown until the pool is quoted');
        if (totalHops > 2) {
          _addWarning(
            planWarnings,
            '$totalHops hops: each one adds delay and another chance of a timeout',
          );
        }

        if (options.requirePfmSupport && collected.capabilityGaps > 0) continue;

        candidates.add(RoutePlanCandidate(
          plan: RoutePlan(
            sourceChainId: source.chainId,
            destChainId: dest.chainId,
            inputDenom: request.inputDenom,
            outputDenom: outputDenom,
            hops: [
              for (var i = 0; i < inLinks.length; i++)
                _transferHop(
                  inLinks[i],
                  i == 0 ? RouteHopKind.transfer : RouteHopKind.forward,
                ),
              _swapHop(venue.chainId),
              // The outbound packet is emitted by the contract, not by the user
              // and not by PFM, but from the packet's point of view it is a
              // forward.
              for (final link in outLinks)
                _transferHop(link, RouteHopKind.forward),
            ],
            memo: _stringifyMemo(memo),
            warnings: planWarnings,
            estimatedDurationSeconds:
                _durationFor(options.durations, totalHops, 1),
            requiresPfm: preForwards.isNotEmpty || postForwards.isNotEmpty,
            requiresIbcHooks: true,
          ),
          strategy: RouteStrategy.ibcSwap,
          links: [...inLinks, ...outLinks],
          receiver: receiver,
          quote: null,
          requiresQuote: true,
          venue: venue,
          unwindsDenom:
              unwindChannelId != null && first.channelId == unwindChannelId,
          unverifiedChannelCount: collected.unverified,
          packetHopCount: totalHops,
          score: _scoreOf(
            packetHops: totalHops,
            unverified: collected.unverified,
            capabilityGaps: collected.capabilityGaps,
            isSwap: true,
            missedUnwind: false,
          ),
        ));
      }
    }
  }

  return finish(candidates);
}

/// The single best plan, for callers that do not offer a choice.
///
/// Throws [InterchainError] `noRoute` when nothing works. The message carries
/// the planner's warnings, because "no route" on its own tells the user nothing
/// they can act on.
Future<RoutePlan> bestRoutePlan(
  RouteRequest request,
  RoutePlannerDeps deps, [
  PlanRouteOptions options = const PlanRouteOptions(),
]) async {
  final result = await planRoute(request, deps, options);
  final best = result.best;
  if (best == null) {
    final detail = result.warnings.join('; ');
    throw InterchainError(
      InterchainErrorCode.noRoute,
      detail.isEmpty
          ? 'No route from ${request.sourceChainId} to ${request.destChainId}'
          : 'No route from ${request.sourceChainId} to '
              '${request.destChainId}: $detail',
      chainId: request.sourceChainId,
    );
  }
  return best.plan;
}
