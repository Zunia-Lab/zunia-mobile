/// Denom traces, `ibc/HASH`, and unwinding.
///
/// Dart mirror of `denom.ts`. One divergence, and it is a simplification: the
/// hash functions are synchronous here because `package:crypto` is
/// synchronous, where the TS twin has to await WebCrypto. Everything that
/// mattered about the async signature — that a missing implementation degrades
/// to "unknown denom" rather than a wrong one — is unchanged, because the
/// failure mode does not exist on this platform.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'lcd.dart';
import 'types.dart';

const String _ibcPrefix = 'ibc/';
const String _denomTracesPath = '/ibc/apps/transfer/v1/denom_traces';

/// ibc-go v9 renamed the route. Tried only after the documented one 404s.
const String _denomsPath = '/ibc/apps/transfer/v1/denoms';

final RegExp _hashPattern = RegExp(r'^[0-9a-fA-F]{64}$');
final RegExp _channelPattern = RegExp(r'^channel-\d+$');

const Duration _defaultTraceCacheTtl = Duration(minutes: 10);

InterchainError _malformed(String message, [String? chainId]) => InterchainError(
      InterchainErrorCode.malformedResponse,
      message,
      chainId: chainId,
    );

Map<String, Object?>? _asRecord(Object? value) =>
    value is Map<String, Object?> ? value : null;

/// Trim surrounding whitespace and leading/trailing slashes, and nothing else.
///
/// Interior empty segments are deliberately left in place: `transfer//channel-0`
/// is a malformed trace, and silently closing the gap would turn it into a path
/// that hashes to a denom nobody holds.
String _normalizePath(String path) => path
    .trim()
    .replaceAll(RegExp(r'^/+'), '')
    .replaceAll(RegExp(r'/+$'), '');

/* -------------------------------------------------------------------------- *
 * Hashing
 * -------------------------------------------------------------------------- */

/// Uppercase SHA-256 of `path/baseDenom`: the part after `ibc/`.
String ibcDenomHashHex(String path, String baseDenom) {
  final base = baseDenom.trim();
  if (base.isEmpty) throw _malformed('Cannot hash an empty base denom');
  final prefix = _normalizePath(path);
  final input = prefix.isEmpty ? base : '$prefix/$base';
  return sha256.convert(utf8.encode(input)).toString().toUpperCase();
}

/// The full voucher denom, `ibc/` + [ibcDenomHashHex].
///
/// Use this to name a token *before* it moves: given the channel that will
/// receive it, the arriving denom is known without asking the destination.
String ibcDenomHash(String path, String baseDenom) =>
    '$_ibcPrefix${ibcDenomHashHex(path, baseDenom)}';

/// True when [denom] is an IBC voucher.
bool isIbcDenom(String denom) => denom.trim().startsWith(_ibcPrefix);

/// The uppercase hash inside an `ibc/…` denom, or null when native.
///
/// Throws [InterchainError] `malformedResponse` when the denom carries the
/// `ibc/` prefix but not 64 hex characters — that is a corrupt balance row, not
/// a native denom, and treating it as native would hide it.
String? ibcHashFromDenom(String denom) {
  final trimmed = denom.trim();
  if (!trimmed.startsWith(_ibcPrefix)) return null;
  final hash = trimmed.substring(_ibcPrefix.length);
  if (!_hashPattern.hasMatch(hash)) {
    throw _malformed('"$denom" is not a 64-character ibc/ hash');
  }
  // LCDs accept either case; ours is canonical uppercase so hashes compare.
  return hash.toUpperCase();
}

/* -------------------------------------------------------------------------- *
 * Trace paths
 * -------------------------------------------------------------------------- */

/// Split a trace path into ordered hops, outermost first.
///
/// Malformed input is rejected rather than repaired: an odd segment count, an
/// empty segment, a port that is not `transfer` or a channel that is not
/// `channel-<n>` all mean the path is not what we think it is, and guessing
/// produces a wrong `ibc/` hash further down.
List<DenomHop> parseTracePath(
  String path, {
  bool allowNonTransferPorts = false,
  bool allowNonStandardChannelIds = false,
}) {
  final normalized = _normalizePath(path);
  if (normalized.isEmpty) return const [];

  final segments = normalized.split('/');
  if (segments.length.isOdd) {
    throw _malformed('Trace path "$path" has ${segments.length} segments; '
        'ports and channels come in pairs');
  }

  final hops = <DenomHop>[];
  for (var i = 0; i < segments.length; i += 2) {
    final port = segments[i];
    final channelId = segments[i + 1];
    if (port.isEmpty || channelId.isEmpty) {
      throw _malformed('Trace path "$path" has an empty segment');
    }
    if (port != transferPort && !allowNonTransferPorts) {
      throw _malformed('Trace path "$path" uses port "$port", not "transfer"');
    }
    if (!_channelPattern.hasMatch(channelId) && !allowNonStandardChannelIds) {
      throw _malformed('Trace path "$path" has "$channelId" where a '
          'channel-<n> was expected');
    }
    hops.add(DenomHop(port: port, channelId: channelId));
  }
  return hops;
}

/// Join hops back into a trace path. Inverse of [parseTracePath].
String joinTracePath(List<DenomHop> hops) =>
    hops.map((hop) => '${hop.port}/${hop.channelId}').join('/');

/* -------------------------------------------------------------------------- *
 * Response parsing
 * -------------------------------------------------------------------------- */

/// Normalise one denom trace out of an LCD body.
///
/// Three shapes are accepted: the documented `{"denom_trace":{…}}`, the bare
/// `{"path":…,"base_denom":…}` some gateways unwrap to, and ibc-go v9's
/// `{"denom":{"base":…,"trace":[…]}}`.
///
/// Throws when no shape matches or the base denom is missing: an endpoint that
/// answers "I don't know this hash" with an empty body must not be mistaken for
/// a native denom.
DenomTrace parseDenomTrace(Object? body) {
  final root = _asRecord(body);
  if (root == null) throw _malformed('Denom trace response is not a JSON object');

  final wrapped = _asRecord(root['denom_trace']);
  final flat = wrapped ?? (root.containsKey('base_denom') ? root : null);
  if (flat != null) {
    final baseDenom = (flat['base_denom'] as String? ?? '').trim();
    if (baseDenom.isEmpty) throw _malformed('Denom trace has no base_denom');
    final rawPath = flat['path'];
    if (rawPath != null && rawPath is! String) {
      throw _malformed('Denom trace path is not a string');
    }
    return DenomTrace(
      path: _normalizePath(rawPath as String? ?? ''),
      baseDenom: baseDenom,
    );
  }

  final v9 = _asRecord(root['denom']);
  if (v9 != null) {
    final baseDenom = (v9['base'] as String? ?? '').trim();
    if (baseDenom.isEmpty) throw _malformed('Denom trace has no base');
    final rawTrace = v9['trace'];
    final hops = <DenomHop>[];
    if (rawTrace is List) {
      for (final entry in rawTrace) {
        final hop = _asRecord(entry);
        final port = hop?['port_id'] as String?;
        final channelId = hop?['channel_id'] as String?;
        if (port == null || channelId == null) {
          throw _malformed('Denom trace hop is incomplete');
        }
        hops.add(DenomHop(port: port, channelId: channelId));
      }
    } else if (rawTrace != null) {
      throw _malformed('Denom trace `trace` is not an array');
    }
    return DenomTrace(path: joinTracePath(hops), baseDenom: baseDenom);
  }

  throw _malformed(
      'Denom trace response has no denom_trace, path or denom key');
}

/* -------------------------------------------------------------------------- *
 * Context
 * -------------------------------------------------------------------------- */

/// Channel -> counterparty chain id. Wire this to the channel service.
///
/// Resolve to null rather than throwing when the counterparty cannot be
/// determined; a throw is caught and treated as null, except `aborted`.
typedef ChannelCounterpartyLookup = Future<String?> Function(
  String chainId,
  String portId,
  String channelId,
);

/// Everything this module needs from the host.
@immutable
class DenomContext {
  const DenomContext({
    required this.lcd,
    required this.registry,
    this.counterparty,
    this.traceCacheTtl,
    this.inferOriginFromRegistry = true,
  });

  final LcdClientFactory lcd;
  final ChainRegistry registry;

  /// Without it the origin chain of a voucher cannot be proven and
  /// [ResolvedDenomOnChain.originChainId] stays null.
  final ChannelCounterpartyLookup? counterparty;

  final Duration? traceCacheTtl;

  /// Let [recommendDenom] fall back to "which chain calls this its native
  /// denom?" when no [counterparty] lookup is wired. The guess is always
  /// reported through [DenomRecommendation.originProvenance] and a warning, and
  /// is only used when exactly one chain in the registry matches.
  final bool inferOriginFromRegistry;
}

/// How confident we are about [ResolvedDenomOnChain.originChainId].
enum OriginProvenance {
  /// The denom is native to the chain that holds it.
  native,

  /// Every hop was walked through [ChannelCounterpartyLookup].
  channelWalk,

  /// Guessed from the registry because exactly one chain claims the base denom.
  registryGuess,

  /// Not determined. Do not route on this.
  unknown,
}

/// A [ResolvedDenom] plus the context routing needs.
@immutable
class ResolvedDenomOnChain extends ResolvedDenom {
  const ResolvedDenomOnChain({
    required super.denom,
    required super.baseDenom,
    required super.path,
    required super.hops,
    required super.originChainId,
    required super.isNative,
    required super.ibcHash,
    required this.chainId,
    required this.hopChainIds,
    required this.originProvenance,
  });

  /// Chain the denom was resolved on, i.e. the chain holding the balance.
  final String chainId;

  /// Chain reached after each hop of [ResolvedDenom.hops], same order and
  /// length; null where the counterparty could not be resolved. The last entry
  /// is the origin chain.
  final List<String?> hopChainIds;

  final OriginProvenance originProvenance;
}

/// One leg of the walk back to a voucher's origin chain.
@immutable
class UnwindStep {
  const UnwindStep({
    required this.index,
    required this.port,
    required this.channelId,
    required this.fromChainId,
    required this.toChainId,
    required this.denom,
    required this.nextDenom,
    required this.nextPath,
    required this.landsOnOrigin,
  });

  final int index;
  final String port;

  /// Channel to send out on, on [fromChainId]. Any other channel wraps instead
  /// of burning.
  final String channelId;

  final String? fromChainId;
  final String? toChainId;
  final String denom;
  final String nextDenom;
  final String nextPath;
  final bool landsOnOrigin;
}

/// What to do with a holding that is being sent to another chain.
enum DenomStrategy {
  /// Send it as-is: it is native here, so the destination mints the voucher.
  direct,

  /// Send it back along its own trace; the destination is on that path.
  unwind,

  /// Walk back to the origin chain first, then forward to the destination.
  unwindThenForward,

  /// The origin could not be determined; refuse to guess.
  unknown,
}

/// The answer [recommendDenom] gives.
@immutable
class DenomRecommendation {
  const DenomRecommendation({
    required this.strategy,
    required this.sourceChainId,
    required this.destChainId,
    required this.inputDenom,
    required this.baseDenom,
    required this.originChainId,
    required this.originProvenance,
    required this.outputDenom,
    required this.unwind,
    required this.firstHop,
    required this.warnings,
    required this.reason,
  });

  final DenomStrategy strategy;
  final String sourceChainId;
  final String destChainId;
  final String inputDenom;
  final String baseDenom;
  final String? originChainId;
  final OriginProvenance originProvenance;

  /// Denom the recipient ends up holding, or null when it cannot be named
  /// without a receiving channel on the destination.
  final String? outputDenom;

  /// Hops to walk before the final leg. Empty for `direct`.
  final List<UnwindStep> unwind;

  /// The channel the first transfer must leave on when the strategy fixes it.
  /// Null for `direct`, where the router may pick any open channel.
  final DenomHop? firstHop;

  final List<String> warnings;

  /// One sentence explaining the strategy. Developer-facing.
  final String reason;
}

/* -------------------------------------------------------------------------- *
 * Resolution
 * -------------------------------------------------------------------------- */

ChainInfo _requireChain(ChainRegistry registry, String chainId) {
  final chain = registry.get(chainId);
  if (chain == null) {
    throw InterchainError(
      InterchainErrorCode.unsupportedChain,
      'Unknown chain $chainId',
      chainId: chainId,
    );
  }
  return chain;
}

Future<DenomTrace> _fetchTrace(
  DenomContext ctx,
  String chainId,
  String hash,
) async {
  final client = ctx.lcd(_requireChain(ctx.registry, chainId));
  final options = LcdRequestOptions(
    cacheTtl: ctx.traceCacheTtl ?? _defaultTraceCacheTtl,
  );
  try {
    return parseDenomTrace(
        await client.getJson('$_denomTracesPath/$hash', options));
  } on InterchainError catch (error) {
    // ibc-go v9 dropped the endpoint. Retry once on the newer path; anything
    // else (timeout, 5xx, bad JSON) is the caller's problem and is rethrown.
    final gone = error.httpStatus == 404 || error.httpStatus == 501;
    if (!gone) rethrow;
    try {
      return parseDenomTrace(await client.getJson('$_denomsPath/$hash', options));
    } on Object {
      throw error;
    }
  }
}

Future<List<String?>> _walkHopChains(
  DenomContext ctx,
  String chainId,
  List<DenomHop> hops,
) async {
  final lookup = ctx.counterparty;
  if (lookup == null || hops.isEmpty) {
    return List<String?>.filled(hops.length, null);
  }

  final out = <String?>[];
  String? current = chainId;
  for (final hop in hops) {
    if (current == null) {
      out.add(null);
      continue;
    }
    String? next;
    try {
      next = await lookup(current, hop.port, hop.channelId);
    } on InterchainError catch (error) {
      // A cancelled request is a global condition, not a missing counterparty.
      if (error.code == InterchainErrorCode.aborted) rethrow;
      next = null;
    }
    out.add(next);
    current = next;
  }
  return out;
}

/// Resolve what a denom actually is on the chain that holds it.
///
/// A native denom is returned as-is with no network call. An `ibc/…` voucher is
/// looked up and the trace is verified to hash back to the requested denom,
/// because the endpoint is a stranger's node and a trace we did not check could
/// rename a token.
Future<ResolvedDenomOnChain> resolveDenom(
  DenomContext ctx,
  String chainId,
  String denom, {
  bool allowNonTransferPorts = false,
  bool allowNonStandardChannelIds = false,
}) async {
  // Validated even for a native denom: the result claims this chain holds the
  // token, and a chain the registry has never heard of cannot.
  _requireChain(ctx.registry, chainId);

  final trimmed = denom.trim();
  if (trimmed.isEmpty) throw _malformed('Cannot resolve an empty denom', chainId);

  final hash = ibcHashFromDenom(trimmed);
  if (hash == null) {
    return ResolvedDenomOnChain(
      denom: trimmed,
      baseDenom: trimmed,
      path: '',
      hops: const [],
      originChainId: chainId,
      isNative: true,
      ibcHash: null,
      chainId: chainId,
      hopChainIds: const [],
      originProvenance: OriginProvenance.native,
    );
  }

  final trace = await _fetchTrace(ctx, chainId, hash);

  final recomputed = ibcDenomHashHex(trace.path, trace.baseDenom);
  if (recomputed != hash) {
    throw _malformed(
      'Denom trace for $trimmed hashes to $recomputed; the endpoint answered '
      'with a different token',
      chainId,
    );
  }

  final hops = parseTracePath(
    trace.path,
    allowNonTransferPorts: allowNonTransferPorts,
    allowNonStandardChannelIds: allowNonStandardChannelIds,
  );
  final hopChainIds = await _walkHopChains(ctx, chainId, hops);
  final last = hopChainIds.isEmpty ? null : hopChainIds.last;
  final originChainId = hops.isEmpty ? chainId : last;

  return ResolvedDenomOnChain(
    denom: trimmed,
    baseDenom: trace.baseDenom,
    path: trace.path,
    hops: hops,
    originChainId: originChainId,
    // The chain holds a voucher, so the token is not native here even in the
    // degenerate empty-path case.
    isNative: false,
    ibcHash: hash,
    chainId: chainId,
    hopChainIds: hopChainIds,
    originProvenance: originChainId == null
        ? OriginProvenance.unknown
        : OriginProvenance.channelWalk,
  );
}

/* -------------------------------------------------------------------------- *
 * Unwinding
 * -------------------------------------------------------------------------- */

/// The ordered hops that walk a voucher back to its origin chain.
///
/// The walk follows [ResolvedDenom.hops] left to right, which is the token's
/// own journey in reverse: hop 0 is the channel on the chain holding the token,
/// and sending out of exactly that channel burns the voucher instead of
/// wrapping it again.
///
/// `fromChainId` / `toChainId` are populated only when [resolved] came from
/// [resolveDenom] with a counterparty lookup wired; otherwise they are null and
/// the denoms are still exact.
List<UnwindStep> unwindPath(ResolvedDenom resolved) {
  final hops = resolved.hops;
  if (hops.isEmpty) return const [];

  final onChain = resolved is ResolvedDenomOnChain ? resolved : null;
  final chainIds = onChain?.hopChainIds ?? const <String?>[];
  final holder = onChain?.chainId;
  final steps = <UnwindStep>[];

  var denom = resolved.denom;
  for (var i = 0; i < hops.length; i++) {
    final hop = hops[i];
    final nextPath = joinTracePath(hops.sublist(i + 1));
    final nextDenom = nextPath.isEmpty
        ? resolved.baseDenom
        : ibcDenomHash(nextPath, resolved.baseDenom);
    steps.add(UnwindStep(
      index: i,
      port: hop.port,
      channelId: hop.channelId,
      fromChainId: i == 0 ? holder : (i - 1 < chainIds.length ? chainIds[i - 1] : null),
      toChainId: i < chainIds.length ? chainIds[i] : null,
      denom: denom,
      nextDenom: nextDenom,
      nextPath: nextPath,
      landsOnOrigin: i == hops.length - 1,
    ));
    denom = nextDenom;
  }
  return steps;
}

/// Chains that call [baseDenom] their native token.
///
/// A weak signal — base denoms are not unique across a 332-chain registry — so
/// callers must treat a multi-element result as "unknown" rather than picking
/// the first.
List<ChainInfo> originCandidates(ChainRegistry registry, String baseDenom) =>
    registry.list().where((c) => c.coinMinimalDenom == baseDenom).toList();

/* -------------------------------------------------------------------------- *
 * Recommendation
 * -------------------------------------------------------------------------- */

/// Decide how to move a holding to another chain, and name the denom it will
/// arrive as.
///
/// - **native here** -> send it directly; the destination mints the first
///   voucher, `SHA256("transfer/<destChannel>/<denom>")`.
/// - **wrapped, destination on its trace** -> send it back along that trace; the
///   voucher is burned hop by hop and the recipient gets the denom that chain
///   already knows.
/// - **wrapped, destination elsewhere** -> unwind to the origin first, then
///   forward. Sending a wrapped token onward without unwinding does not fail; it
///   quietly succeeds and mints a double-wrapped `ibc/` denom whose hash no
///   registry names, no wallet can label and no pool prices.
/// - **origin unknown** -> `unknown`. Refusing beats a wrong guess, because the
///   wrong guess is the failure mode above.
Future<DenomRecommendation> recommendDenom(
  DenomContext ctx,
  String fromChainId,
  String toChainId,
  String denom, {
  String? destinationReceiveChannelId,
  String destinationReceivePort = transferPort,
}) async {
  _requireChain(ctx.registry, fromChainId);
  final dest = _requireChain(ctx.registry, toChainId);

  final resolved = await resolveDenom(ctx, fromChainId, denom);
  final warnings = <String>[];

  String? wrapOnArrival(String sent) {
    if (destinationReceiveChannelId == null) {
      warnings.add('Destination denom is unknown until a receiving channel on '
          '$toChainId is chosen.');
      return null;
    }
    return ibcDenomHash(
      '$destinationReceivePort/$destinationReceiveChannelId',
      sent,
    );
  }

  if (fromChainId == toChainId) {
    return DenomRecommendation(
      strategy: DenomStrategy.direct,
      sourceChainId: fromChainId,
      destChainId: toChainId,
      inputDenom: resolved.denom,
      baseDenom: resolved.baseDenom,
      originChainId: resolved.originChainId,
      originProvenance: resolved.originProvenance,
      outputDenom: resolved.denom,
      unwind: const [],
      firstHop: null,
      warnings: warnings,
      reason: 'Source and destination are the same chain; nothing moves.',
    );
  }

  if (resolved.isNative) {
    return DenomRecommendation(
      strategy: DenomStrategy.direct,
      sourceChainId: fromChainId,
      destChainId: toChainId,
      inputDenom: resolved.denom,
      baseDenom: resolved.baseDenom,
      originChainId: fromChainId,
      originProvenance: OriginProvenance.native,
      outputDenom: wrapOnArrival(resolved.denom),
      unwind: const [],
      firstHop: null,
      warnings: warnings,
      reason: '${resolved.denom} is native to $fromChainId; $toChainId mints '
          'the first voucher.',
    );
  }

  final steps = unwindPath(resolved);

  // Does the walk pass through the destination? If so we stop there: the
  // partially unwound denom is exactly what that chain already holds.
  final landing = steps.indexWhere((step) => step.toChainId == toChainId);
  if (landing >= 0) {
    final step = steps[landing];
    final truncated = steps.sublist(0, landing + 1);
    return DenomRecommendation(
      strategy: DenomStrategy.unwind,
      sourceChainId: fromChainId,
      destChainId: toChainId,
      inputDenom: resolved.denom,
      baseDenom: resolved.baseDenom,
      originChainId: resolved.originChainId,
      originProvenance: resolved.originProvenance,
      outputDenom: step.nextDenom,
      unwind: truncated,
      firstHop: resolved.hops.isEmpty ? null : resolved.hops.first,
      warnings: warnings,
      reason: truncated.length == 1
          ? '${resolved.denom} came from $toChainId over '
              '${truncated.first.channelId}; sending it back there burns the '
              'voucher.'
          : '${resolved.denom} unwinds to $toChainId in ${truncated.length} '
              'hops along its own trace.',
    );
  }

  // No channel data, or the walk never reached the destination. Fall back to the
  // registry: if exactly one chain calls this base denom its own, treat it as
  // the origin but say so.
  var originChainId = resolved.originChainId;
  var originProvenance = resolved.originProvenance;
  if (originChainId == null && ctx.inferOriginFromRegistry) {
    final candidates = originCandidates(ctx.registry, resolved.baseDenom);
    if (candidates.length == 1) {
      final only = candidates.first;
      originChainId = only.chainId;
      originProvenance = OriginProvenance.registryGuess;
      warnings.add('Origin chain inferred from the registry: ${only.chainName} '
          'is the only chain whose native denom is ${resolved.baseDenom}.');
    }
  }

  if (originChainId == null) {
    warnings.add('Could not determine where ${resolved.denom} came from; '
        'sending it on would mint a denom nothing recognises.');
    return DenomRecommendation(
      strategy: DenomStrategy.unknown,
      sourceChainId: fromChainId,
      destChainId: toChainId,
      inputDenom: resolved.denom,
      baseDenom: resolved.baseDenom,
      originChainId: null,
      originProvenance: OriginProvenance.unknown,
      outputDenom: null,
      unwind: steps,
      firstHop: resolved.hops.isEmpty ? null : resolved.hops.first,
      warnings: warnings,
      reason: 'The origin chain of ${resolved.denom} is unknown; refusing to '
          'guess a route.',
    );
  }

  if (originChainId == toChainId) {
    return DenomRecommendation(
      strategy: DenomStrategy.unwind,
      sourceChainId: fromChainId,
      destChainId: toChainId,
      inputDenom: resolved.denom,
      baseDenom: resolved.baseDenom,
      originChainId: originChainId,
      originProvenance: originProvenance,
      outputDenom: resolved.baseDenom,
      unwind: steps,
      firstHop: resolved.hops.isEmpty ? null : resolved.hops.first,
      warnings: warnings,
      reason: '$toChainId is the origin of ${resolved.baseDenom}; unwind along '
          'the trace and it arrives unwrapped.',
    );
  }

  warnings.add('Sending ${resolved.denom} straight to ${dest.chainName} would '
      'mint a new double-wrapped denom; the plan unwinds through '
      '$originChainId first.');
  return DenomRecommendation(
    strategy: DenomStrategy.unwindThenForward,
    sourceChainId: fromChainId,
    destChainId: toChainId,
    inputDenom: resolved.denom,
    baseDenom: resolved.baseDenom,
    originChainId: originChainId,
    originProvenance: originProvenance,
    outputDenom: wrapOnArrival(resolved.baseDenom),
    unwind: steps,
    firstHop: resolved.hops.isEmpty ? null : resolved.hops.first,
    warnings: warnings,
    reason: '${resolved.denom} unwinds to $originChainId, then forwards to '
        '$toChainId.',
  );
}

/* -------------------------------------------------------------------------- *
 * Resolver
 * -------------------------------------------------------------------------- */

/// A [resolveDenom] with a per-session cache.
///
/// A wallet resolves the same handful of vouchers on every render, and a trace
/// is immutable for the life of the channel, so caching costs nothing and saves
/// a round trip per balance row.
class DenomResolver {
  DenomResolver(this._ctx);

  final DenomContext _ctx;
  final Map<String, Future<ResolvedDenomOnChain>> _cache = {};

  Future<ResolvedDenomOnChain> resolve(String chainId, String denom) {
    final key = '$chainId|$denom';
    return _cache.putIfAbsent(key, () => resolveDenom(_ctx, chainId, denom))
      ..catchError((Object error) {
        // A failed lookup must not be remembered: the endpoint may recover, and
        // a cached failure would make the denom permanently unknown.
        _cache.remove(key);
        throw error;
      });
  }

  void clear() => _cache.clear();
}

/// Build a [DenomResolver] over a context.
DenomResolver createDenomResolver(DenomContext ctx) => DenomResolver(ctx);
