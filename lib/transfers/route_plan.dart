/// Route planning for a send to another chain.
///
/// Port of the transfer half of `zunia-extension/lib/route-plan.ts` (0.1.5).
/// Every routing decision is the engine's (`lib/services/interchain/route.dart`
/// picks the hops and composes the packet-forward memo, `validateMemo` says
/// what the memo will do). This module answers the one question that is the
/// host's: may a channel the engine picked carry the transfer at all?
///
/// A channel can stay `STATE_OPEN` for years after its light client expired,
/// and every packet sent into it is then lost to a timeout. So every channel on
/// a plan's path is checked on both chains (open, each end naming the other,
/// both light clients Active) before the plan is offered for signing; a channel
/// that fails is dropped from the graph and the route planned again.
///
/// The graph starts from the chain registry's canonical channels
/// (`assets/data/ibc-channels.json`) and what this wallet has discovered. A
/// direct channel is always preferred; when none exists the engine may route
/// through packet-forward middleware, with the wallet's own address as the
/// receiver on each intermediate chain.
///
/// Nothing here signs or broadcasts.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/memo.dart';
import 'package:zunia_mobile/services/interchain/registry.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/tokens/token_registry.dart';
import 'package:zunia_mobile/transfers/channel_verdict.dart';

/// Hop ceiling for route search: each extra hop is another timeout to survive.
const int kMaxRouteHops = 3;

/// Per-hop ICS20 packet timeout, in minutes.
const int kTransferTimeoutMinutes = 10;

/* -------------------------------------------------------------------------- *
 * Shapes the screens render
 * -------------------------------------------------------------------------- */

/// A channel the user typed in, pinned onto one leg of the route.
@immutable
class ManualChannel {
  const ManualChannel({
    required this.fromChainId,
    required this.toChainId,
    required this.channelId,
    this.counterpartyChannelId,
    this.port,
    this.verdict,
  });

  final String fromChainId;
  final String toChainId;
  final String channelId;
  final String? counterpartyChannelId;

  /// Port on the leaving chain. `transfer` when absent.
  final String? port;

  /// What the on-chain check concluded when the user picked it.
  final ChannelVerdictKind? verdict;

  ManualChannel withCounterparty(String counterparty) => ManualChannel(
        fromChainId: fromChainId,
        toChainId: toChainId,
        channelId: channelId,
        counterpartyChannelId: counterparty,
        port: port,
        verdict: verdict,
      );
}

/// One leg of a planned route, ready for `ZuniaRoutePreview`.
@immutable
class RouteHopView {
  const RouteHopView({
    required this.index,
    required this.chainId,
    required this.chainName,
    required this.counterpartyChainId,
    required this.counterpartyChainName,
    required this.channelId,
    required this.port,
    required this.kind,
    this.channelSource,
    this.channelVerified = false,
    this.channelState,
  });

  final int index;
  final String chainId;
  final String chainName;
  final String? counterpartyChainId;
  final String? counterpartyChainName;
  final String channelId;
  final String port;
  final RouteHopKind kind;
  final ChannelLinkSource? channelSource;
  final bool channelVerified;
  final IbcChannelState? channelState;
}

/// What the two chains said about one channel.
/// - `active`: open on both chains, each end names the other, both light
///   clients Active. The only unqualified yes.
/// - `activeUnconfirmed`: all of that except the client status, which a node
///   would not serve; given only to the registry's canonical channel.
/// - `clientInactive`: a light client is Expired, Frozen or otherwise not Active.
/// - `rejected`: closed, missing, pointing elsewhere.
/// - `statusUnreadable`: no client status, and the channel is not canonical.
/// - `inconclusive`: a chain could not be asked. Proves nothing either way.
enum ChannelHopVerdict { active, activeUnconfirmed, clientInactive, rejected, statusUnreadable, inconclusive }

/// One channel, checked on both of its chains.
@immutable
class ChannelHopCheck {
  const ChannelHopCheck({
    required this.sourceChainId,
    required this.destChainId,
    required this.channelId,
    required this.portId,
    required this.counterpartyChannelId,
    required this.verdict,
    required this.message,
    required this.checkedAt,
    this.warning,
  });

  final String sourceChainId;
  final String destChainId;
  final String channelId;
  final String portId;
  final String? counterpartyChannelId;
  final ChannelHopVerdict verdict;

  /// One sentence naming the channel and both chains.
  final String message;

  /// A caveat on a channel that is usable anyway.
  final String? warning;
  final DateTime checkedAt;

  /// The only verdicts a signable plan may cross.
  bool get usable =>
      verdict == ChannelHopVerdict.active || verdict == ChannelHopVerdict.activeUnconfirmed;
}

/// A plan plus everything the confirm screen needs to describe and block it.
@immutable
class RoutePlanView {
  const RoutePlanView({
    required this.plan,
    required this.candidate,
    required this.receiver,
    required this.hops,
    required this.warnings,
    required this.memo,
    required this.blockedReason,
    required this.failedCheck,
  });

  final RoutePlan plan;
  final RoutePlanCandidate candidate;

  /// ICS20 receiver of the one transfer the user signs.
  final String receiver;
  final List<RouteHopView> hops;
  final List<String> warnings;

  /// What the memo will do, from the engine's own classifier.
  final MemoInspection memo;

  /// Set when the plan cannot be signed as-is, in the words the button shows.
  final String? blockedReason;

  /// The channel check on this path that failed or could not complete.
  final ChannelHopCheck? failedCheck;
}

/// Result of planning a same-asset cross-chain transfer.
@immutable
class TransferPlanResult {
  const TransferPlanResult({
    required this.best,
    required this.alternatives,
    required this.warnings,
    required this.error,
  });

  final RoutePlanView? best;
  final List<RoutePlanView> alternatives;

  /// Planner-level notes: why some route was not offered at all.
  final List<String> warnings;
  final String? error;
}

/// What the caller wants moved, and who it belongs to.
@immutable
class PlanInput {
  const PlanInput({
    required this.sourceChainId,
    required this.destChainId,
    required this.inputDenom,
    required this.amountBaseUnits,
    required this.sender,
    required this.recipient,
    required this.resolveAddresses,
    this.manualChannels = const [],
  });

  final String sourceChainId;
  final String destChainId;

  /// Denom as held on the source chain: `usaf` or `ibc/…`.
  final String inputDenom;

  /// Base units, decimal string. Never a number.
  final String amountBaseUnits;
  final String sender;
  final String recipient;
  final List<ManualChannel> manualChannels;

  /// Derives the wallet's own address on each chain, for the ICS20 receiver
  /// on an intermediate hop.
  final Future<Map<String, String>> Function(List<String> chainIds) resolveAddresses;
}

/* -------------------------------------------------------------------------- *
 * Light-client status
 * -------------------------------------------------------------------------- */

/// What one chain says about the light client behind one of its channels.
@immutable
class ChannelClientRead {
  const ChannelClientRead.ok({required this.clientId, required this.trackedChainId, required this.status})
      : kind = ChannelClientReadKind.ok,
        detail = null;
  const ChannelClientRead.unsupported(this.detail)
      : kind = ChannelClientReadKind.unsupported,
        clientId = null,
        trackedChainId = null,
        status = null;
  const ChannelClientRead.unreachable(this.detail)
      : kind = ChannelClientReadKind.unreachable,
        clientId = null,
        trackedChainId = null,
        status = null;

  final ChannelClientReadKind kind;
  final String? clientId;

  /// Chain the client tracks. Null for a client type that does not say.
  final String? trackedChainId;

  /// `Active`, `Expired`, `Frozen`, … (ibc-go's spelling).
  final String? status;
  final String? detail;
}

enum ChannelClientReadKind { ok, unsupported, unreachable }

const Set<int> _routeAbsentStatuses = {404, 405, 501};

ChannelClientRead _clientReadFailure(Object error, String what) {
  if (error is InterchainError) {
    if (error.code == InterchainErrorCode.aborted || error.code == InterchainErrorCode.readsDisabled) {
      throw error;
    }
    final status = error.httpStatus;
    if (status != null && _routeAbsentStatuses.contains(status)) {
      return ChannelClientRead.unsupported('$what: HTTP $status');
    }
  }
  return ChannelClientRead.unreachable('$what: $error');
}

String? _text(Object? value) => value is String && value.isNotEmpty ? value : null;

/// Read the light client behind [channelId] on a chain, and its status: the
/// channel's `client_state` names the client and the chain it tracks, then
/// `client_status` says whether it is still Active.
///
/// Throws [InterchainError] `aborted` or `readsDisabled` only.
Future<ChannelClientRead> readChannelClient(
  LcdClient? client,
  String chainId,
  String channelId,
  String portId,
) async {
  if (client == null) return ChannelClientRead.unreachable('$chainId has no REST endpoint');
  const options = LcdRequestOptions(cacheTtl: Duration(seconds: 30));
  String? clientId;
  String? tracked;
  try {
    final body = await client.getJson(
      '/ibc/core/channel/v1/channels/${Uri.encodeComponent(channelId)}'
      '/ports/${Uri.encodeComponent(portId)}/client_state',
      options,
    );
    final identified = body is Map ? body['identified_client_state'] : null;
    clientId = identified is Map ? _text(identified['client_id']) : null;
    final state = identified is Map ? identified['client_state'] : null;
    tracked = state is Map ? _text(state['chain_id']) : null;
  } on Object catch (error) {
    return _clientReadFailure(error, 'client_state of $channelId on $chainId');
  }
  if (clientId == null) {
    return ChannelClientRead.unreachable('$chainId named no client for $channelId');
  }
  try {
    final body = await client.getJson(
      '/ibc/core/client/v1/client_status/${Uri.encodeComponent(clientId)}',
      options,
    );
    final status = body is Map ? _text(body['status']) : null;
    if (status == null) {
      return ChannelClientRead.unreachable('$chainId gave no status for $clientId');
    }
    return ChannelClientRead.ok(clientId: clientId, trackedChainId: tracked, status: status);
  } on Object catch (error) {
    return _clientReadFailure(error, 'client_status of $clientId on $chainId');
  }
}

/* -------------------------------------------------------------------------- *
 * The channel graph
 * -------------------------------------------------------------------------- */

/// What the graph knows about channels beyond the cache rows themselves.
@immutable
class RoutingKnowledge {
  const RoutingKnowledge({required this.canonical, required this.refused});

  final List<String> Function(String sourceChainId, String destChainId) canonical;
  final bool Function(ChannelLink link) refused;
}

/// The channels leaving one chain that automatic routing may use: a channel
/// this session found unusable is dropped, and where the registry names a
/// canonical channel for a pair that has not been ruled out, every other
/// non-manual channel for that pair is dropped.
List<ChannelLink> routableLinks(List<ChannelLink> links, RoutingKnowledge knowledge) {
  final live = links.where((link) => !knowledge.refused(link)).toList();
  bool isCanonical(ChannelLink link) =>
      (link.port ?? transferPort) == transferPort &&
      knowledge.canonical(link.sourceChainId, link.destChainId).contains(link.channelId);
  final covered = {
    for (final link in live)
      if (isCanonical(link)) '${link.sourceChainId}\u0000${link.destChainId}',
  };
  return [
    for (final link in live)
      if (link.source == ChannelLinkSource.manual ||
          isCanonical(link) ||
          !covered.contains('${link.sourceChainId}\u0000${link.destChainId}'))
        link,
  ];
}

class _RoutableDirectory implements ChannelDirectory {
  _RoutableDirectory(this._base, this._knowledge);

  final ChannelDirectory _base;
  final RoutingKnowledge _knowledge;
  final Map<String, List<ChannelLink>> _memo = {};

  @override
  List<ChannelLink> from(String chainId) =>
      _memo.putIfAbsent(chainId, () => routableLinks(_base.from(chainId), _knowledge));
}

/// A directory that answers through [routableLinks].
ChannelDirectory routableDirectory(ChannelDirectory base, RoutingKnowledge knowledge) =>
    _RoutableDirectory(base, knowledge);

/* -------------------------------------------------------------------------- *
 * The planner
 * -------------------------------------------------------------------------- */

/// How long a check stands before the chains are asked again.
const Duration _channelCheckTtl = Duration(minutes: 10);

/// Rounds of plan, check, plan again one request may take.
const int _maxPlanRounds = 5;

const String _routeNotChecked =
    'The channels on this route have not been checked on chain yet, so it cannot be signed as it stands.';
const String _noSettledRoute =
    'Zunia could not settle on a channel for this route, so it will not ask you to sign. Try again in a moment.';

class _PathCheck {
  const _PathCheck({
    required this.ok,
    required this.replan,
    required this.fresh,
    required this.blockedReason,
    required this.failed,
    required this.warnings,
    required this.confirmed,
  });

  final bool ok;
  final bool replan;
  final bool fresh;
  final String? blockedReason;
  final ChannelHopCheck? failed;
  final List<String> warnings;
  final Set<String> confirmed;
}

class _LegWalk {
  const _LegWalk(this.read, this.failure);
  final List<String> read;
  final String? failure;
}

/// Everything [TransferPlanner] needs from the app.
class TransferPlannerDeps {
  const TransferPlannerDeps({
    required this.registry,
    required this.channels,
    required this.routes,
    required this.rememberRoutes,
    required this.lcdFor,
    required this.resolveDenom,
    required this.probeCapabilities,
    required this.capabilities,
  });

  final ChainRegistry registry;
  final IbcChannelService channels;

  /// The cached channel rows, seeds included.
  final List<ChannelRoute> Function() routes;

  /// Persist rows a check or discovery confirmed.
  final Future<void> Function(List<ChannelRoute> routes) rememberRoutes;
  final LcdClient? Function(String chainId) lcdFor;
  final Future<ResolvedDenom> Function(ChainInfo chain, String denom)? resolveDenom;
  final Future<void> Function(String chainId) probeCapabilities;
  final ChainCapabilityLookup capabilities;
}

/// Plans transfers and remembers this session's channel answers.
class TransferPlanner {
  TransferPlanner(this._deps, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final TransferPlannerDeps _deps;
  final DateTime Function() _now;

  final Map<String, ChannelHopCheck> _checks = {};
  final Map<String, Future<_LegWalk>> _discoveryRuns = {};
  final Map<String, _LegWalk> _walkedLegs = {};

  String chainName(String chainId) => _deps.registry.get(chainId)?.chainName ?? chainId;

  static String _checkKey(String source, String dest, String channelId, String portId) =>
      [source, dest, portId, channelId].join('\u0000');

  static String linkCheckKey(ChannelLink link) => _checkKey(
        link.sourceChainId,
        link.destChainId,
        normalizeChannelId(link.channelId),
        link.port ?? transferPort,
      );

  ChannelHopCheck? _cached(String key) {
    final hit = _checks[key];
    if (hit == null) return null;
    if (_now().difference(hit.checkedAt) <= _channelCheckTtl) return hit;
    _checks.remove(key);
    return null;
  }

  bool _sessionConfirmed(String source, String dest, String channelId, String portId) =>
      _cached(_checkKey(source, dest, channelId, portId))?.usable == true;

  bool _sessionRefused(ChannelLink link) {
    final hit = _cached(linkCheckKey(link));
    return hit != null && !hit.usable;
  }

  /// Forget this session's channel answers and discovery runs.
  void reset() {
    _checks.clear();
    _discoveryRuns.clear();
    _walkedLegs.clear();
  }

  /// The registry's canonical channel ids for one direction (seeds included).
  List<String> canonicalChannelIds(String sourceChainId, String destChainId) {
    final ids = <String>[
      ...TokenRegistry.instance?.canonicalChannelIds(sourceChainId, destChainId) ?? const [],
    ];
    for (final seed in seedChannelRoutes) {
      if (seed.sourceChainId == sourceChainId &&
          seed.destChainId == destChainId &&
          !ids.contains(seed.channelId)) {
        ids.add(seed.channelId);
      }
    }
    return ids;
  }

  bool isCanonicalChannel(String sourceChainId, String destChainId, String channelId) =>
      canonicalChannelIds(sourceChainId, destChainId).contains(channelId);

  /// Every channel row the graph is built from: the canonical table as seeds,
  /// then what this wallet has discovered or the user entered.
  List<ChannelRoute> _allRoutes() {
    final registry = RouteRegistry([
      for (final row in TokenRegistry.instance?.channelRows ?? const <IbcChannelRow>[])
        ChannelRoute(
          sourceChainId: row.sourceChainId,
          destChainId: row.destChainId,
          channelId: row.channelId,
          counterpartyChannelId: row.counterpartyChannelId,
          verifiedAt: 0,
          source: ChannelRouteSource.seed,
        ),
      ...seedChannelRoutes,
    ]);
    registry.putMany(_deps.routes());
    return registry.list();
  }

  ChannelLink _routeToLink(ChannelRoute route) {
    final confirmed =
        _sessionConfirmed(route.sourceChainId, route.destChainId, route.channelId, transferPort);
    final fresh = route.verifiedAt > 0 &&
        _now().difference(DateTime.fromMillisecondsSinceEpoch(route.verifiedAt)) < kRouteMaxAge;
    final ChannelLinkSource source;
    if (route.source == ChannelRouteSource.manual) {
      source = ChannelLinkSource.manual;
    } else if (confirmed || (route.source == ChannelRouteSource.discovered && fresh)) {
      source = ChannelLinkSource.verified;
    } else {
      source = ChannelLinkSource.seed;
    }
    return ChannelLink(
      sourceChainId: route.sourceChainId,
      destChainId: route.destChainId,
      channelId: route.channelId,
      port: transferPort,
      counterpartyChannelId: route.counterpartyChannelId.isEmpty ? null : route.counterpartyChannelId,
      source: source,
      // Only a check is evidence the channel is open; a seed never renders so.
      state: confirmed || fresh ? IbcChannelState.open : IbcChannelState.unknown,
    );
  }

  /// Everything the wallet currently believes about the channel graph,
  /// narrowed to what automatic routing may use.
  ChannelDirectory channelDirectory() => routableDirectory(
        createChannelDirectory([for (final route in _allRoutes()) _routeToLink(route)]),
        RoutingKnowledge(canonical: canonicalChannelIds, refused: _sessionRefused),
      );

  /// Direct paths the cache already knows from [sourceChainId] to
  /// [destChainId], for the route list before anything is planned.
  List<RoutePath> knownPaths(String sourceChainId, String destChainId, {int maxHops = 1}) =>
      findRoutePaths(sourceChainId, destChainId, channelDirectory(), maxHops: maxHops, maxPaths: 8);

  /// For each destination, the best direct path the graph knows, from one
  /// build of the graph: the destination list sorts by it without asking
  /// any chain.
  Map<String, RoutePath> directReach(String sourceChainId, Iterable<String> destChainIds) {
    final directory = channelDirectory();
    return {
      for (final dest in destChainIds)
        if (dest != sourceChainId)
          if (findRoutePaths(sourceChainId, dest, directory, maxHops: 1, maxPaths: 1) case [final path, ...])
            dest: path,
    };
  }

  /* ---------------------------------------------------------------- *
   * Channel checks
   * ---------------------------------------------------------------- */

  static String _sentence(String text) {
    final trimmed = text.trim();
    return RegExp(r'[.!?]$').hasMatch(trimmed) ? trimmed : '$trimmed.';
  }

  static String _clientStatusPhrase(String status) {
    final word = status.toLowerCase();
    return word == 'expired' || word == 'frozen' ? word : 'not active (the chain says "$status")';
  }

  Future<ChannelHopCheck> _inspect(
    String sourceChainId,
    String destChainId,
    String channelId,
    String portId,
  ) async {
    final label = '$channelId from ${chainName(sourceChainId)} to ${chainName(destChainId)}';
    ChannelHopCheck answer(ChannelHopVerdict verdict, String message, String? counterparty,
            [String? warning]) =>
        ChannelHopCheck(
          sourceChainId: sourceChainId,
          destChainId: destChainId,
          channelId: channelId,
          portId: portId,
          counterpartyChannelId: counterparty,
          verdict: verdict,
          message: message,
          warning: warning,
          checkedAt: _now(),
        );

    final validation = await _deps.channels.validateIbcChannel(
      sourceChainId,
      channelId,
      destChainId: destChainId,
      portId: portId,
      checkCounterparty: true,
    );
    final counterparty =
        (validation.counterpartyChannelId ?? '').isEmpty ? null : validation.counterpartyChannelId;
    final verdict = classifyChannelCheck(validation, destChainId);
    if (verdict.kind == ChannelVerdictKind.rejected) {
      return answer(ChannelHopVerdict.rejected,
          'Zunia will not use $label. ${_sentence(verdict.note)}', counterparty);
    }
    if (verdict.kind != ChannelVerdictKind.verified || counterparty == null) {
      return answer(
        ChannelHopVerdict.inconclusive,
        'Zunia could not confirm $label on both chains, so this route stays unsigned for now. '
        '${_sentence(verdict.note)}',
        counterparty,
      );
    }

    final reads = await Future.wait([
      readChannelClient(_deps.lcdFor(sourceChainId), sourceChainId, channelId, portId),
      readChannelClient(
        _deps.lcdFor(destChainId),
        destChainId,
        counterparty,
        validation.counterparty?.portId ?? transferPort,
      ),
    ]);
    final ends = [
      (chainId: sourceChainId, otherChainId: destChainId, read: reads[0]),
      (chainId: destChainId, otherChainId: sourceChainId, read: reads[1]),
    ];
    for (final end in ends) {
      final read = end.read;
      if (read.kind == ChannelClientReadKind.ok &&
          read.trackedChainId != null &&
          read.trackedChainId != end.otherChainId) {
        return answer(
          ChannelHopVerdict.rejected,
          'Zunia will not use $label. Its light client on ${chainName(end.chainId)} follows '
          '${chainName(read.trackedChainId!)}, not ${chainName(end.otherChainId)}.',
          counterparty,
        );
      }
    }
    for (final end in ends) {
      final read = end.read;
      if (read.kind == ChannelClientReadKind.ok && read.status != 'Active') {
        return answer(
          ChannelHopVerdict.clientInactive,
          'Zunia will not use $label. Its light client on ${chainName(end.chainId)} is '
          '${_clientStatusPhrase(read.status ?? '')}, so nothing sent over it can arrive.',
          counterparty,
        );
      }
    }
    final tracked = reads[0].kind == ChannelClientReadKind.ok ? reads[0].trackedChainId : null;
    if ((validation.counterpartyChainId ?? tracked) != destChainId) {
      return answer(
        ChannelHopVerdict.inconclusive,
        'Zunia could not confirm that $label leads to ${chainName(destChainId)}, so this route stays unsigned for now.',
        counterparty,
      );
    }
    for (final end in ends) {
      if (end.read.kind == ChannelClientReadKind.unreachable) {
        return answer(
          ChannelHopVerdict.inconclusive,
          '${chainName(end.chainId)} did not answer for the light-client status of $label, so this '
          'route stays unsigned for now. Try again in a moment.',
          counterparty,
        );
      }
    }
    for (final end in ends) {
      if (end.read.kind != ChannelClientReadKind.unsupported) continue;
      final why = '${chainName(end.chainId)} does not report light-client status, so Zunia cannot '
          'confirm $label is live';
      if (portId == transferPort && isCanonicalChannel(sourceChainId, destChainId, channelId)) {
        return answer(
          ChannelHopVerdict.activeUnconfirmed,
          '$label is open on both chains.',
          counterparty,
          "$why. It is the chain registry's canonical channel for this pair, so it is used.",
        );
      }
      return answer(
        ChannelHopVerdict.statusUnreadable,
        "$why, and only the chain registry's canonical channel is used without that check.",
        counterparty,
      );
    }
    return answer(
      ChannelHopVerdict.active,
      '$label is open on both chains and both light clients are active.',
      counterparty,
    );
  }

  /// Check one channel on both chains, or answer from this session's check.
  /// A definite answer is kept for the session; a usable one is stored as a
  /// discovered route. An inconclusive one is not kept.
  ///
  /// Throws [InterchainError] `aborted` or `readsDisabled` only.
  Future<ChannelHopCheck> checkChannelHop(
    String sourceChainId,
    String destChainId,
    String channelId, {
    String portId = transferPort,
  }) async {
    final channel = normalizeChannelId(channelId);
    final key = _checkKey(sourceChainId, destChainId, channel, portId);
    final cached = _cached(key);
    if (cached != null) return cached;
    final check = await _inspect(sourceChainId, destChainId, channel, portId);
    if (check.verdict == ChannelHopVerdict.inconclusive) return check;
    _checks[key] = check;
    if (portId == transferPort && check.usable) {
      try {
        await _deps.rememberRoutes([
          ChannelRoute(
            sourceChainId: check.sourceChainId,
            destChainId: check.destChainId,
            channelId: check.channelId,
            counterpartyChannelId: check.counterpartyChannelId ?? '',
            verifiedAt: check.checkedAt.millisecondsSinceEpoch,
            source: ChannelRouteSource.discovered,
          ),
        ]);
      } on Object {
        // A cache write that fails changes nothing about the answer.
      }
    }
    return check;
  }

  /// Check one channel id the user typed, on the source chain and the far side.
  Future<IbcChannelCheck> validateChannel(
    String sourceChainId,
    String channelId,
    String destChainId, {
    String portId = transferPort,
  }) =>
      _deps.channels.validateIbcChannel(
        sourceChainId,
        channelId,
        destChainId: destChainId,
        portId: portId,
        checkCounterparty: true,
      );

  ChannelHopCheck? _misspelled(ChannelLink link) {
    final written = normalizeChannelId(link.channelId);
    if (written == link.channelId) return null;
    return ChannelHopCheck(
      sourceChainId: link.sourceChainId,
      destChainId: link.destChainId,
      channelId: link.channelId,
      portId: link.port ?? transferPort,
      counterpartyChannelId: null,
      verdict: ChannelHopVerdict.rejected,
      message: 'The route names the channel from ${chainName(link.sourceChainId)} to '
          '${chainName(link.destChainId)} as "${link.channelId}", which is not how the chain writes '
          'it ("$written"), so Zunia will not sign it.',
      checkedAt: _now(),
    );
  }

  _PathCheck _summarize(
    List<ChannelHopCheck> checks, {
    required bool replan,
    required bool fresh,
    required bool unchecked,
  }) {
    ChannelHopCheck? failed;
    for (final check in checks) {
      if (!check.usable) {
        failed = check;
        break;
      }
    }
    return _PathCheck(
      ok: failed == null && !unchecked,
      replan: replan,
      fresh: fresh,
      blockedReason: failed?.message ?? (unchecked ? _routeNotChecked : null),
      failed: failed,
      warnings: [for (final check in checks) if (check.warning != null) check.warning!],
      confirmed: {
        for (final check in checks)
          if (check.usable) _checkKey(check.sourceChainId, check.destChainId, check.channelId, check.portId),
      },
    );
  }

  static bool _isPinned(ChannelHopCheck check, List<ManualChannel> pinned) => pinned.any(
        (pin) => pin.fromChainId == check.sourceChainId && pin.toChainId == check.destChainId,
      );

  Future<_PathCheck> _checkPath(List<ChannelLink> links, List<ManualChannel> pinned) async {
    final unknown = {
      for (final link in links)
        if (_cached(linkCheckKey(link)) == null) linkCheckKey(link),
    };
    final checks = await Future.wait([
      for (final link in links)
        () async {
          final misspelled = _misspelled(link);
          if (misspelled != null) return misspelled;
          return checkChannelHop(
            link.sourceChainId,
            link.destChainId,
            link.channelId,
            portId: link.port ?? transferPort,
          );
        }(),
    ]);
    return _summarize(
      checks,
      replan: checks.any((check) =>
          !check.usable &&
          check.verdict != ChannelHopVerdict.inconclusive &&
          unknown.contains(_checkKey(check.sourceChainId, check.destChainId, check.channelId, check.portId)) &&
          !_isPinned(check, pinned)),
      fresh: unknown.isNotEmpty,
      unchecked: false,
    );
  }

  _PathCheck _sessionPathCheck(List<ChannelLink> links) {
    final checks = <ChannelHopCheck>[];
    for (final link in links) {
      final known = _misspelled(link) ?? _cached(linkCheckKey(link));
      if (known != null) checks.add(known);
    }
    return _summarize(checks, replan: false, fresh: false, unchecked: checks.length < links.length);
  }

  /* ---------------------------------------------------------------- *
   * Discovery, as a fallback
   * ---------------------------------------------------------------- */

  /// Discover open transfer channels between two chains and remember them.
  Future<List<IbcChannelOption>> discoverChannels(String sourceChainId, String destChainId) async {
    final found = await _deps.channels.findIbcChannels(sourceChainId, destChainId);
    if (found.isEmpty) return found;
    final now = _now().millisecondsSinceEpoch;
    await _deps.rememberRoutes([
      for (final option in found)
        ChannelRoute(
          sourceChainId: sourceChainId,
          destChainId: destChainId,
          channelId: option.channelId,
          counterpartyChannelId: option.counterpartyChannelId,
          verifiedAt: now,
          source: ChannelRouteSource.discovered,
        ),
    ]);
    return found;
  }

  Future<_LegWalk> _walkLeg(String from, String to) async {
    final read = <String>[];
    final failures = <String>[];
    Future<List<IbcChannelOption>> walk(String chainId, String otherChainId) async {
      try {
        final found = await discoverChannels(chainId, otherChainId);
        read.add(chainId);
        return found;
      } on Object catch (error) {
        failures.add("${chainName(chainId)}'s channel list could not be read. "
            '${_sentence(describeInterchainError(error, chainName))}');
        return const [];
      }
    }

    final leaving = await walk(from, to);
    final usable = leaving.any((option) => !_sessionRefused(ChannelLink(
          sourceChainId: from,
          destChainId: to,
          channelId: option.channelId,
          port: option.portId,
          source: ChannelLinkSource.verified,
        )));
    if (!usable) await walk(to, from);
    return _LegWalk(read, failures.isEmpty ? null : failures.join(' '));
  }

  Future<_LegWalk> _discoverOnce(String from, String to) {
    final key = '$from\u0000$to';
    final existing = _discoveryRuns[key];
    if (existing != null) return existing;
    final run = _walkLeg(from, to).then((walked) {
      if (walked.failure == null) _walkedLegs[key] = walked;
      return walked;
    });
    _discoveryRuns[key] = run;
    run.whenComplete(() => _discoveryRuns.remove(key));
    return run;
  }

  Future<bool> _discoverLegs(List<(String, String)> legs, Map<String, _LegWalk> tried) async {
    final pending = [
      for (final leg in legs)
        if (!_walkedLegs.containsKey('${leg.$1}\u0000${leg.$2}') &&
            !tried.containsKey('${leg.$1}\u0000${leg.$2}'))
          leg,
    ];
    if (pending.isEmpty) return false;
    await Future.wait([
      for (final leg in pending)
        () async {
          tried['${leg.$1}\u0000${leg.$2}'] = await _discoverOnce(leg.$1, leg.$2);
        }(),
    ]);
    return true;
  }

  String _channelLists(List<String> chainIds) {
    final names = chainIds.map(chainName).toList();
    if (names.length == 1) return "${names.first}'s channel list";
    return 'the channel lists of ${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  List<String> _noChannelWarnings(String from, String to, Map<String, _LegWalk> tried) {
    final key = '$from\u0000$to';
    final lead = 'No usable transfer channel from ${chainName(from)} to ${chainName(to)} is known';
    final walked = tried[key] ?? _walkedLegs[key];
    final read = walked?.read ?? const <String>[];
    final summary = [
      read.isNotEmpty ? '$lead, and reading ${_channelLists(read)} turned up none.' : '$lead.',
      if (walked?.failure != null) walked!.failure!,
      'Enter the channel by hand if you know it.',
    ].join(' ');
    final refusals = [
      for (final key in _checks.keys.toList())
        if (_cached(key) case final check?)
          if (!check.usable && check.sourceChainId == from && check.destChainId == to) check.message,
    ];
    return [summary, ...refusals];
  }

  /* ---------------------------------------------------------------- *
   * Views
   * ---------------------------------------------------------------- */

  List<RouteHopView> _hopViews(RoutePlanCandidate candidate, Set<String> confirmed) {
    final views = <RouteHopView>[];
    var linkIndex = 0;
    for (var index = 0; index < candidate.plan.hops.length; index++) {
      final hop = candidate.plan.hops[index];
      final link = hop.kind == RouteHopKind.swap || linkIndex >= candidate.links.length
          ? null
          : candidate.links[linkIndex];
      if (hop.kind != RouteHopKind.swap) linkIndex += 1;
      final open = link != null &&
          (link.state == IbcChannelState.open || confirmed.contains(linkCheckKey(link)));
      views.add(RouteHopView(
        index: index,
        chainId: hop.chainId,
        chainName: chainName(hop.chainId),
        counterpartyChainId: hop.counterpartyChainId,
        counterpartyChainName: hop.counterpartyChainId == null ? null : chainName(hop.counterpartyChainId!),
        channelId: hop.channelId,
        port: hop.port,
        kind: hop.kind,
        channelSource: link?.source,
        channelVerified: open,
        channelState: open ? IbcChannelState.open : link?.state,
      ));
    }
    return views;
  }

  /// Hop views for a path read straight off the directory, before any plan.
  List<RouteHopView> pathHopViews(List<ChannelLink> links) => [
        for (var index = 0; index < links.length; index++)
          RouteHopView(
            index: index,
            chainId: links[index].sourceChainId,
            chainName: chainName(links[index].sourceChainId),
            counterpartyChainId: links[index].destChainId,
            counterpartyChainName: chainName(links[index].destChainId),
            channelId: links[index].channelId,
            port: links[index].port ?? transferPort,
            kind: index == 0 ? RouteHopKind.transfer : RouteHopKind.forward,
            channelSource: links[index].source,
            channelVerified: links[index].state == IbcChannelState.open,
            channelState: links[index].state,
          ),
      ];

  static String? _blockedReasonFor(RoutePlan plan, MemoInspection memo) {
    if (plan.memo.contains('"receiver":"$pfmIntermediateReceiver"') &&
        memo.forward?.finalReceiver == pfmIntermediateReceiver) {
      return 'Zunia has no address for one of the chains on this route, so it cannot say where the funds end up.';
    }
    if (memo.kind == MemoKind.unknown) {
      return 'Zunia could not read what this memo will do on arrival, so it will not ask you to sign it.';
    }
    return null;
  }

  RoutePlanView _toView(RoutePlanCandidate candidate, _PathCheck checked) {
    final memo = validateMemo(candidate.plan.memo, receiver: candidate.receiver);
    return RoutePlanView(
      plan: candidate.plan,
      candidate: candidate,
      receiver: candidate.receiver,
      hops: _hopViews(candidate, checked.confirmed),
      warnings: [...candidate.plan.warnings, ...memo.warnings, ...checked.warnings],
      memo: memo,
      blockedReason: _blockedReasonFor(candidate.plan, memo) ?? checked.blockedReason,
      failedCheck: checked.failed,
    );
  }

  /* ---------------------------------------------------------------- *
   * Planning
   * ---------------------------------------------------------------- */

  List<RouteHopOverride> _overrides(List<ManualChannel> manual) => [
        for (final entry in manual)
          RouteHopOverride(
            fromChainId: entry.fromChainId,
            toChainId: entry.toChainId,
            channelId: entry.channelId,
            port: entry.port,
            counterpartyChannelId: entry.counterpartyChannelId,
          ),
      ];

  Future<RoutePlanResult> _runPlan(
    PlanInput input,
    ChannelDirectory directory, {
    required int maxHops,
    Map<String, String> intermediateReceivers = const {},
  }) =>
      planRoute(
        RouteRequest(
          sourceChainId: input.sourceChainId,
          destChainId: input.destChainId,
          inputDenom: input.inputDenom,
          amount: input.amountBaseUnits,
          sender: input.sender,
          recipient: input.recipient,
          maxHops: maxHops,
          allowSwap: false,
          allowPfm: true,
          timeoutMinutes: kTransferTimeoutMinutes,
        ),
        RoutePlannerDeps(
          registry: _deps.registry,
          channels: directory,
          resolveDenom: _deps.resolveDenom,
          capabilities: _deps.capabilities,
        ),
        PlanRouteOptions(
          overrides: _overrides(input.manualChannels),
          intermediateReceivers: intermediateReceivers,
        ),
      );

  static List<String> _pathChainIds(RoutePlanCandidate candidate) => {
        for (final hop in candidate.plan.hops) ...[
          hop.chainId,
          if (hop.counterpartyChainId != null) hop.counterpartyChainId!,
        ],
      }.toList();

  Future<({RoutePlanCandidate? best, List<RoutePlanCandidate> candidates, List<String> warnings})>
      _routeTransfer(PlanInput input, ChannelDirectory directory, int maxHops) async {
    final first = await _runPlan(input, directory, maxHops: maxHops);
    final best = first.best;
    if (best == null) return (best: null, candidates: const <RoutePlanCandidate>[], warnings: first.warnings);
    final chains = [
      for (final id in _pathChainIds(best))
        if (id != input.sourceChainId && id != input.destChainId) id,
    ];
    if (chains.isEmpty) return (best: best, candidates: first.candidates, warnings: first.warnings);
    final results = await Future.wait([
      input.resolveAddresses(chains),
      Future.wait([for (final chainId in chains) _deps.probeCapabilities(chainId)]),
    ]);
    final receivers = results[0] as Map<String, String>;
    final second = await _runPlan(input, directory, maxHops: maxHops, intermediateReceivers: receivers);
    return second.best != null
        ? (best: second.best, candidates: second.candidates, warnings: second.warnings)
        : (best: best, candidates: first.candidates, warnings: first.warnings);
  }

  /// Plan a same-asset cross-chain transfer.
  ///
  /// A direct channel first. With none known, the direct leg's channel lists
  /// are read once per session; only then may the engine route through
  /// packet-forward middleware. Every channel on the chosen path is checked on
  /// both chains; a channel that fails is dropped and the transfer planned
  /// again, and one the user pinned blocks the plan with the reason.
  Future<TransferPlanResult> planTransfer(PlanInput input) async {
    try {
      final tried = <String, _LegWalk>{};
      TransferPlanResult? result;
      for (var round = 0; round < _maxPlanRounds; round++) {
        final directory = channelDirectory();
        final direct = findRoutePaths(input.sourceChainId, input.destChainId, directory,
                maxHops: 1, maxPaths: 1)
            .isNotEmpty;
        if (!direct &&
            await _discoverLegs([(input.sourceChainId, input.destChainId)], tried)) {
          continue;
        }
        final routed = await _routeTransfer(input, directory, direct ? 1 : kMaxRouteHops);
        final best = routed.best;
        if (best == null) {
          return TransferPlanResult(
            best: null,
            alternatives: const [],
            warnings: [
              ..._noChannelWarnings(input.sourceChainId, input.destChainId, tried),
              ...routed.warnings,
            ],
            error: null,
          );
        }
        final checked = await _checkPath(best.links, input.manualChannels);
        result = TransferPlanResult(
          best: _toView(best, checked),
          alternatives: [
            for (final candidate in routed.candidates.skip(1))
              _toView(candidate, _sessionPathCheck(candidate.links)),
          ],
          warnings: routed.warnings,
          error: null,
        );
        if (!(checked.replan || (checked.ok && checked.fresh))) return result;
      }
      return result ??
          const TransferPlanResult(best: null, alternatives: [], warnings: [_noSettledRoute], error: null);
    } on Object catch (error) {
      return TransferPlanResult(
        best: null,
        alternatives: const [],
        warnings: const [],
        error: describeInterchainError(error, chainName),
      );
    }
  }
}

/// One sentence the user can act on, keyed off the engine's error code.
String describeInterchainError(Object error, [String Function(String chainId)? chainName]) {
  if (error is InterchainError) {
    String label(String? chainId) =>
        chainId == null ? 'the chain' : (chainName?.call(chainId) ?? chainId);
    switch (error.code) {
      case InterchainErrorCode.readsDisabled:
        return 'Live reads are off, so channels cannot be checked. Turn them on in Settings → Preferences.';
      case InterchainErrorCode.lcdUnreachable:
        return 'Could not reach ${label(error.chainId)}. Its public endpoint is down or slow; try again in a moment.';
      case InterchainErrorCode.malformedResponse:
        return '${label(error.chainId)} answered with something Zunia could not read, so nothing here is trustworthy. Try again.';
      case InterchainErrorCode.noRoute:
        return 'No route exists between these two chains for this asset.';
      case InterchainErrorCode.channelClosed:
        return 'A channel on this path is not open${error.channelId == null ? '' : ' (${error.channelId})'}. Pick another channel.';
      case InterchainErrorCode.packetTimeout:
        return 'The packet timed out. The funds were refunded on the source chain.';
      case InterchainErrorCode.aborted:
        return 'Cancelled.';
      default:
        return error.message;
    }
  }
  return '$error';
}
