/// Transfer-channel discovery, validation and middleware probing.
///
/// Dart mirror of `channels.ts`, and the replacement for the hand-rolled
/// channel code that used to live in `chain_client.dart`. The copy in
/// [ChannelMessages] is the wording those screens already render, so switching
/// to this module changed no user-visible string.
library;

import 'package:flutter/foundation.dart';

import 'lcd.dart';
import 'types.dart';

/// HTTP statuses that mean "this route is not registered on this node".
///
/// The cosmos gRPC gateway answers 501 for a query service the chain does not
/// run, and reverse proxies in front of public LCDs answer 404 or 405. 400 is
/// deliberately absent: a bad request could also be a real route rejecting real
/// input, and misreading that as "module missing" would be a confident lie.
const Set<int> _routeAbsentStatuses = {404, 405, 501};

/// Candidate REST routes for the packet-forward-middleware params query.
///
/// The first is the route ibc-apps registers for the current `packetforward`
/// module; the others are the older `router` module name. Treat a hit as
/// evidence, not proof.
const List<String> pfmProbePaths = [
  '/ibc/apps/packetforward/v1/params',
  '/ibc/apps/router/v1/params',
  '/router/v1/params',
];

/// Candidate REST routes for an ibc-hooks params query.
///
/// Weaker evidence than the PFM probe: Osmosis' `x/ibc-hooks` is a middleware
/// wrapped around the transfer stack and several releases register no query
/// service at all.
const List<String> ibcHooksProbePaths = [
  '/ibc/apps/ibchooks/v1/params',
  '/osmosis/ibchooks/v1beta1/params',
];

/// Cheapest CosmWasm liveness probe: one page of one code id.
const String _wasmProbePath = '/cosmwasm/wasm/v1/codes';

const int _defaultPageLimit = 100;
const int _defaultMaxPages = 3;
const Duration _defaultChannelCacheTtl = Duration(seconds: 30);
const Duration _defaultConnectionCacheTtl = Duration(minutes: 5);
const Duration _defaultConnectionFailureTtl = Duration(seconds: 10);
const Duration _defaultModuleSupportTtl = Duration(minutes: 10);
const Duration _defaultModuleSupportUnknownTtl = Duration(seconds: 30);

/// Interchain modules this service can probe for.
///
/// DIVERGENCE from `channels.ts`, which has only the two middlewares:
/// `cosmWasm` exists because the bundled chain catalog drops the registry's
/// `features` array (see `generate-chain-catalog.mjs`), so
/// `supportsCosmWasm` answers "unknown" for all 332 chains and the whole NFT
/// surface would be dead. This asks the chain instead of guessing, and the
/// wasm probe stays in the one place that already owned it.
enum InterchainModule { packetForward, ibcHooks, cosmWasm }

/// How confident a probe is.
///
/// `unknown` is a real answer, not an error: public LCDs hide routes and some
/// middlewares register no query service. Both `unsupported` and `unknown` mean
/// "do not build a memo that depends on this module"; they differ only in what
/// the UI is entitled to claim.
enum ModuleSupportStatus { supported, unsupported, unknown }

/// Result of a module probe.
@immutable
class ModuleSupport {
  const ModuleSupport({
    required this.chainId,
    required this.module,
    required this.status,
    required this.evidence,
    required this.checkedAt,
  });

  final String chainId;
  final InterchainModule module;
  final ModuleSupportStatus status;

  bool get supported => status == ModuleSupportStatus.supported;

  /// Which probe produced this answer. Developer-facing, safe to log.
  final String evidence;

  final DateTime checkedAt;
}

/// Host-declared truth about a chain's middlewares.
///
/// The probes are heuristics. A host that has verified a chain can pin the
/// answer and skip the network. This package ships no per-chain list of its own.
@immutable
class ModuleSupportOverride {
  const ModuleSupportOverride({this.packetForward, this.ibcHooks});

  final bool? packetForward;
  final bool? ibcHooks;
}

/// The strings the screens render as-is.
@immutable
class ChannelMessages {
  const ChannelMessages();

  String get emptyInput => 'Enter a channel id (e.g. channel-141)';
  String get readsDisabled => 'Turn on live reads to check channels';
  String get noEndpoint => 'No REST endpoint for this chain';
  String get notFound => 'Channel not found on this chain';
  String get unreachable => 'Could not reach the chain to verify this channel';
  String notOpen(IbcChannelState state) => 'Channel is ${state.name}, not open';
  String wrongChain(String chainId) => 'Open, but connects to $chainId';
  String get open => 'Open and ready';
  String openWith(String chainId) => 'Open · $chainId';
  String counterpartyOk(String chainId) => 'Open on both sides · $chainId';
  String counterpartyNotFound(String chainId) =>
      'Open here, but missing on $chainId';
  String counterpartyNotOpen(IbcChannelState state, String chainId) =>
      'Open here, but ${state.name} on $chainId';
  String counterpartyMismatch(String expected, String? actual) => actual != null
      ? 'The other side points at $actual, not $expected'
      : 'The other side does not point back at $expected';
  String counterpartyUnreachable(String chainId) =>
      'Could not reach $chainId to check the other side';
  String counterpartySkipped(String reason) => 'Other side not checked: $reason';
}

/// Normalise a user-typed channel id.
///
/// Accepts `channel-141` and the bare `141`. Anything else is lowercased and
/// returned unchanged so the LCD gets the chance to reject it with a real
/// answer, which is more useful than a client-side guess.
String normalizeChannelId(String raw) {
  final value = raw.trim().toLowerCase();
  if (value.isEmpty) return '';
  if (RegExp(r'^channel-\d+$').hasMatch(value)) return value;
  if (RegExp(r'^\d+$').hasMatch(value)) return 'channel-$value';
  return value;
}

/// Normalise a channel state from the LCD.
///
/// Order matters, and this is where the module diverges from the code it
/// replaces: `'STATE_TRYOPEN'.contains('OPEN')` is true, so testing OPEN first —
/// as `chain_client.dart` did — reported a channel still mid-handshake as ready
/// to receive funds. TRYOPEN is checked first for that reason.
///
/// ibc-go v8.1's channel-upgrade states (`STATE_FLUSHING`,
/// `STATE_FLUSHCOMPLETE`) fall through to `unknown`, which is the safe reading:
/// a flushing channel is not accepting new packets.
IbcChannelState parseChannelState(Object? raw) {
  if (raw is int) {
    // ibc-go's State enum: 1 INIT, 2 TRYOPEN, 3 OPEN, 4 CLOSED.
    switch (raw) {
      case 1:
        return IbcChannelState.init;
      case 2:
        return IbcChannelState.tryopen;
      case 3:
        return IbcChannelState.open;
      case 4:
        return IbcChannelState.closed;
      default:
        return IbcChannelState.unknown;
    }
  }
  final value = (raw?.toString() ?? '').trim().toUpperCase();
  if (value.isEmpty) return IbcChannelState.unknown;
  // `STATE_UNINITIALIZED_UNSPECIFIED` contains "INIT". Rule the zero value out
  // before any substring test, or a channel that was never opened reads as one
  // that is mid-handshake.
  if (value.contains('UNINITIALIZED') || value.contains('UNSPECIFIED')) {
    return IbcChannelState.unknown;
  }
  if (value.contains('TRYOPEN') ||
      value.contains('TRY_OPEN') ||
      value.contains('TRY')) {
    return IbcChannelState.tryopen;
  }
  if (value.contains('CLOSED')) return IbcChannelState.closed;
  if (value.contains('INIT')) return IbcChannelState.init;
  if (value.contains('OPEN')) return IbcChannelState.open;
  return IbcChannelState.unknown;
}

Map<String, Object?>? _asRecord(Object? value) =>
    value is Map<String, Object?> ? value : null;

String? _asNonEmptyString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// A channel row, narrowed from LCD JSON.
@immutable
class _ParsedChannel {
  const _ParsedChannel({
    required this.channelId,
    required this.portId,
    required this.state,
    required this.connectionId,
    required this.counterpartyChannelId,
    required this.counterpartyPortId,
  });

  final String channelId;
  final String portId;
  final IbcChannelState state;
  final String? connectionId;
  final String counterpartyChannelId;
  final String counterpartyPortId;
}

/// Narrow one channel object.
///
/// `/ibc/core/channel/v1/channels` returns `IdentifiedChannel` rows, which carry
/// `channel_id` and `port_id`. `/channels/{id}/ports/{port}` returns a bare
/// `Channel`, which does not — hence the fallbacks.
_ParsedChannel? _parseChannel(
  Object? value,
  String fallbackChannelId,
  String fallbackPortId,
) {
  final row = _asRecord(value);
  if (row == null) return null;
  final channelId = _asNonEmptyString(row['channel_id']) ?? fallbackChannelId;
  if (channelId.isEmpty) return null;
  final hops = row['connection_hops'];
  final counterparty = _asRecord(row['counterparty']);
  return _ParsedChannel(
    channelId: channelId,
    portId: _asNonEmptyString(row['port_id']) ?? fallbackPortId,
    state: parseChannelState(row['state']),
    // Only the first hop identifies the directly connected chain. Multi-hop
    // connection paths are not used by any live IBC deployment.
    connectionId: hops is List && hops.isNotEmpty
        ? _asNonEmptyString(hops.first)
        : null,
    counterpartyChannelId: counterparty == null
        ? ''
        : _asNonEmptyString(counterparty['channel_id']) ?? '',
    counterpartyPortId: counterparty == null
        ? transferPort
        : _asNonEmptyString(counterparty['port_id']) ?? transferPort,
  );
}

@immutable
class _CacheEntry<T> {
  const _CacheEntry(this.value, this.expiresAt);

  final T value;
  final DateTime expiresAt;
}

/// Channel discovery, validation and middleware probing for one host.
///
/// Construct once and keep it: the connection-to-chain-id and module-probe
/// caches live on the instance, and a discovery pass over a hundred channels
/// collapses to a handful of requests because of them.
class IbcChannelService {
  IbcChannelService({
    required LcdClientFactory lcd,
    required ChainRegistry registry,
    this.messages = const ChannelMessages(),
    this.pageLimit = _defaultPageLimit,
    this.maxPages = _defaultMaxPages,
    this.channelCacheTtl = _defaultChannelCacheTtl,
    Map<String, ModuleSupportOverride> moduleSupport = const {},
    DateTime Function()? now,
  })  : _lcd = lcd,
        _registry = registry,
        _moduleSupport = moduleSupport,
        _now = now ?? DateTime.now;

  final LcdClientFactory _lcd;
  final ChainRegistry _registry;
  final ChannelMessages messages;
  final int pageLimit;
  final int maxPages;
  final Duration channelCacheTtl;
  final Map<String, ModuleSupportOverride> _moduleSupport;
  final DateTime Function() _now;

  final Map<String, _CacheEntry<String?>> _connectionCache = {};
  final Map<String, _CacheEntry<ModuleSupport>> _supportCache = {};

  ChainInfo? _chain(String chainId) =>
      chainId.trim().isEmpty ? null : _registry.get(chainId.trim());

  /// Build a read client, or null when the chain has no usable endpoint.
  ///
  /// "No REST endpoint" is a UI state, not an exception, so the factory's
  /// `unsupportedChain` is converted here.
  LcdClient? _clientFor(ChainInfo chain) {
    if (lcdEndpointsFromChain(chain).isEmpty) return null;
    return _lcd(chain);
  }

  LcdRequestOptions _options({Duration? cacheTtl, Map<String, Object?>? query}) =>
      LcdRequestOptions(
        cacheTtl: cacheTtl ?? channelCacheTtl,
        query: query,
      );

  Future<String?> _connectionChainId(
    LcdClient client,
    String connectionId,
  ) async {
    final key = '${client.chainId}|$connectionId';
    final hit = _connectionCache[key];
    if (hit != null && hit.expiresAt.isAfter(_now())) return hit.value;

    try {
      final connection = await client.getJson(
        '/ibc/core/connection/v1/connections/'
        '${Uri.encodeComponent(connectionId)}',
        _options(),
      );
      final row = _asRecord(connection);
      final clientId = _asNonEmptyString(_asRecord(row?['connection'])?['client_id']) ??
          _asNonEmptyString(row?['client_id']);
      if (clientId == null) {
        _rememberConnection(key, null);
        return null;
      }
      final clientState = await client.getJson(
        '/ibc/core/client/v1/client_states/${Uri.encodeComponent(clientId)}',
        _options(),
      );
      final stateRow = _asRecord(clientState);
      final nested = _asRecord(stateRow?['client_state']) ?? stateRow;
      final chainId = _asNonEmptyString(nested?['chain_id']);
      _rememberConnection(key, chainId);
      return chainId;
    } on InterchainError catch (error) {
      if (error.code == InterchainErrorCode.aborted ||
          error.code == InterchainErrorCode.readsDisabled) {
        rethrow;
      }
      // One unresolvable connection drops one channel from the list; it must not
      // fail the whole listing.
      _rememberConnection(key, null);
      return null;
    }
  }

  void _rememberConnection(String key, String? chainId) {
    _connectionCache[key] = _CacheEntry<String?>(
      chainId,
      _now().add(chainId == null
          ? _defaultConnectionFailureTtl
          : _defaultConnectionCacheTtl),
    );
  }

  Future<List<_ParsedChannel>> _listChannels(
    LcdClient client,
    String portId,
  ) async {
    final out = <_ParsedChannel>[];
    final seenKeys = <String>{};
    String? key;

    for (var page = 0; page < maxPages; page++) {
      final body = await client.getJson(
        '/ibc/core/channel/v1/channels',
        _options(query: {'pagination.limit': pageLimit, 'pagination.key': key}),
      );
      final rows = _asRecord(body)?['channels'];
      if (rows is List) {
        for (final raw in rows) {
          final parsed = _parseChannel(raw, '', portId);
          if (parsed == null || parsed.channelId.isEmpty) continue;
          if (parsed.portId != portId) continue;
          out.add(parsed);
        }
      }
      final next =
          _asNonEmptyString(_asRecord(_asRecord(body)?['pagination'])?['next_key']);
      // A node that echoes the same cursor forever would otherwise burn every
      // page of the budget on one page of data.
      if (next == null || seenKeys.contains(next)) break;
      seenKeys.add(next);
      key = next;
    }
    return out;
  }

  Future<_ParsedChannel?> _readChannel(
    LcdClient client,
    String channelId,
    String portId,
  ) async {
    final body = await client.getJson(
      '/ibc/core/channel/v1/channels/${Uri.encodeComponent(channelId)}'
      '/ports/${Uri.encodeComponent(portId)}',
      _options(),
    );
    return _parseChannel(_asRecord(body)?['channel'], channelId, portId);
  }

  CounterpartyCheck _skipped(String reason, String? chainId) => CounterpartyCheck(
        status: CounterpartyCheckStatus.skipped,
        ok: false,
        chainId: chainId,
        channelId: null,
        portId: null,
        state: IbcChannelState.unknown,
        pointsBackTo: null,
        message: messages.counterpartySkipped(reason),
      );

  /// Open transfer channels on [sourceChainId] whose connection client targets
  /// [destChainId].
  ///
  /// Returns an empty list when the source chain is unknown, has no REST
  /// endpoint, equals the destination, or when the host's live-reads gate is
  /// off — all four are ordinary UI states, not errors.
  Future<List<IbcChannelOption>> findIbcChannels(
    String sourceChainId,
    String destChainId, {
    String portId = transferPort,
  }) async {
    final sourceChain = _chain(sourceChainId);
    if (sourceChain == null || destChainId.trim().isEmpty) return const [];
    if (sourceChain.chainId == destChainId) return const [];

    final client = _clientFor(sourceChain);
    if (client == null) return const [];

    try {
      final rows = await _listChannels(client, portId);
      final matches = <IbcChannelOption>[];

      for (final row in rows) {
        if (row.state != IbcChannelState.open) continue;
        final connectionId = row.connectionId;
        if (connectionId == null) continue;
        final counterpartyChainId =
            await _connectionChainId(client, connectionId);
        if (counterpartyChainId != destChainId) continue;
        matches.add(IbcChannelOption(
          channelId: row.channelId,
          portId: row.portId,
          counterpartyChannelId: row.counterpartyChannelId,
          counterpartyPortId: row.counterpartyPortId,
          connectionId: connectionId,
          counterpartyChainId: counterpartyChainId,
          state: row.state,
        ));
      }

      matches.sort(_compareChannelIds);
      return matches;
    } on InterchainError catch (error) {
      if (error.code == InterchainErrorCode.aborted) rethrow;
      // Live reads off is a settings state; the screen renders its own prompt.
      if (error.code == InterchainErrorCode.readsDisabled) return const [];
      rethrow;
    }
  }

  static int _compareChannelIds(IbcChannelOption a, IbcChannelOption b) {
    final an = int.tryParse(a.channelId.replaceFirst('channel-', ''));
    final bn = int.tryParse(b.channelId.replaceFirst('channel-', ''));
    if (an != null && bn != null) return an.compareTo(bn);
    return a.channelId.compareTo(b.channelId);
  }

  /// Check one channel id typed by the user.
  ///
  /// Accepts `channel-141` or `141`. Never throws for a chain-state reason: the
  /// failure is the returned [IbcChannelCheck], whose message the screens render
  /// directly.
  Future<IbcChannelCheck> validateIbcChannel(
    String sourceChainId,
    String channelRaw, {
    String? destChainId,
    String portId = transferPort,
    bool checkCounterparty = false,
  }) async {
    final channelId = normalizeChannelId(channelRaw);
    if (channelId.isEmpty) {
      return IbcChannelCheck(
        ok: false,
        state: IbcChannelState.unknown,
        channelId: '',
        portId: portId,
        message: messages.emptyInput,
      );
    }

    final sourceChain = _chain(sourceChainId);
    final client = sourceChain == null ? null : _clientFor(sourceChain);
    if (sourceChain == null || client == null) {
      return IbcChannelCheck(
        ok: false,
        state: IbcChannelState.unknown,
        channelId: channelId,
        portId: portId,
        message: messages.noEndpoint,
      );
    }

    _ParsedChannel? row;
    try {
      row = await _readChannel(client, channelId, portId);
    } on InterchainError catch (error) {
      if (error.code == InterchainErrorCode.aborted) rethrow;
      final message = error.code == InterchainErrorCode.readsDisabled
          ? messages.readsDisabled
          // The gateway answers 404 for a channel the chain does not have,
          // which is a better message than "could not reach".
          : (error.httpStatus != null &&
                  _routeAbsentStatuses.contains(error.httpStatus))
              ? messages.notFound
              : messages.unreachable;
      return IbcChannelCheck(
        ok: false,
        state: IbcChannelState.unknown,
        channelId: channelId,
        portId: portId,
        message: message,
      );
    }

    if (row == null) {
      return IbcChannelCheck(
        ok: false,
        state: IbcChannelState.unknown,
        channelId: channelId,
        portId: portId,
        message: messages.notFound,
      );
    }

    String? counterpartyChainId;
    final connectionId = row.connectionId;
    if (connectionId != null) {
      try {
        counterpartyChainId = await _connectionChainId(client, connectionId);
      } on InterchainError catch (error) {
        if (error.code == InterchainErrorCode.aborted) rethrow;
        // reads-disabled mid-check: report what we have rather than lying.
        counterpartyChainId = null;
      }
    }

    if (row.state != IbcChannelState.open) {
      return IbcChannelCheck(
        ok: false,
        state: row.state,
        channelId: channelId,
        portId: portId,
        counterpartyChannelId: row.counterpartyChannelId,
        counterpartyChainId: counterpartyChainId,
        message: messages.notOpen(row.state),
      );
    }

    if (destChainId != null &&
        destChainId.isNotEmpty &&
        counterpartyChainId != null &&
        counterpartyChainId != destChainId) {
      return IbcChannelCheck(
        ok: false,
        state: row.state,
        channelId: channelId,
        portId: portId,
        counterpartyChannelId: row.counterpartyChannelId,
        counterpartyChainId: counterpartyChainId,
        message: messages.wrongChain(counterpartyChainId),
      );
    }

    final openResult = IbcChannelCheck(
      ok: true,
      state: row.state,
      channelId: channelId,
      portId: portId,
      counterpartyChannelId: row.counterpartyChannelId,
      counterpartyChainId: counterpartyChainId,
      message: counterpartyChainId != null
          ? messages.openWith(counterpartyChainId)
          : messages.open,
    );

    if (!checkCounterparty) return openResult;

    final counterparty = await _counterpartyCheck(
      sourceChain.chainId,
      channelId,
      portId,
      row.counterpartyChannelId,
      row.counterpartyPortId,
      counterpartyChainId,
      destChainId == null ? null : _chain(destChainId),
    );

    // Only a definite negative overrides the source-side verdict. "unreachable"
    // and "skipped" mean nothing was learned, and blocking a send because the
    // destination's public LCD is down would be its own failure mode.
    final definiteFailure =
        counterparty.status == CounterpartyCheckStatus.notFound ||
            counterparty.status == CounterpartyCheckStatus.notOpen ||
            counterparty.status == CounterpartyCheckStatus.mismatch;

    return IbcChannelCheck(
      ok: definiteFailure ? false : openResult.ok,
      state: openResult.state,
      channelId: openResult.channelId,
      portId: openResult.portId,
      counterpartyChannelId: openResult.counterpartyChannelId,
      counterpartyChainId: openResult.counterpartyChainId,
      message: definiteFailure || counterparty.status == CounterpartyCheckStatus.ok
          ? counterparty.message
          : openResult.message,
      counterparty: counterparty,
    );
  }

  /// Ask the destination chain about its half of an already-discovered channel.
  Future<CounterpartyCheck> checkCounterpartyChannel(
    String sourceChainId,
    IbcChannelOption option, {
    String? destChainId,
  }) async {
    final sourceChain = _chain(sourceChainId);
    if (sourceChain == null) {
      return _skipped('the source chain is not in the registry', null);
    }
    return _counterpartyCheck(
      sourceChain.chainId,
      option.channelId,
      option.portId,
      option.counterpartyChannelId,
      option.counterpartyPortId,
      option.counterpartyChainId,
      destChainId == null ? null : _chain(destChainId),
    );
  }

  Future<CounterpartyCheck> _counterpartyCheck(
    String sourceChainId,
    String channelId,
    String portId,
    String counterpartyChannelId,
    String counterpartyPortId,
    String? counterpartyChainId,
    ChainInfo? destChain,
  ) async {
    if (counterpartyChannelId.isEmpty) {
      return _skipped(
        'the source chain did not name a counterparty channel',
        counterpartyChainId,
      );
    }

    var chain = destChain;
    if (chain == null && counterpartyChainId != null) {
      chain = _registry.get(counterpartyChainId);
    }
    if (chain == null) {
      return _skipped(
        'the destination chain is not in the registry',
        counterpartyChainId,
      );
    }

    final client = _clientFor(chain);
    if (client == null) return _skipped(messages.noEndpoint, chain.chainId);

    _ParsedChannel? far;
    try {
      far = await _readChannel(client, counterpartyChannelId, counterpartyPortId);
    } on InterchainError catch (error) {
      if (error.code == InterchainErrorCode.aborted) rethrow;
      if (error.httpStatus != null &&
          _routeAbsentStatuses.contains(error.httpStatus)) {
        return CounterpartyCheck(
          status: CounterpartyCheckStatus.notFound,
          ok: false,
          chainId: chain.chainId,
          channelId: counterpartyChannelId,
          portId: counterpartyPortId,
          state: IbcChannelState.unknown,
          pointsBackTo: null,
          message: messages.counterpartyNotFound(chain.chainId),
        );
      }
      // Reads-disabled and every transport failure land here: nothing was
      // learned about the far side, so the source-side verdict stands.
      return CounterpartyCheck(
        status: CounterpartyCheckStatus.unreachable,
        ok: false,
        chainId: chain.chainId,
        channelId: counterpartyChannelId,
        portId: counterpartyPortId,
        state: IbcChannelState.unknown,
        pointsBackTo: null,
        message: messages.counterpartyUnreachable(chain.chainId),
      );
    }

    if (far == null) {
      return CounterpartyCheck(
        status: CounterpartyCheckStatus.notFound,
        ok: false,
        chainId: chain.chainId,
        channelId: counterpartyChannelId,
        portId: counterpartyPortId,
        state: IbcChannelState.unknown,
        pointsBackTo: null,
        message: messages.counterpartyNotFound(chain.chainId),
      );
    }

    final pointsBackTo =
        far.counterpartyChannelId.isEmpty ? null : far.counterpartyChannelId;

    if (far.state != IbcChannelState.open) {
      return CounterpartyCheck(
        status: CounterpartyCheckStatus.notOpen,
        ok: false,
        chainId: chain.chainId,
        channelId: counterpartyChannelId,
        portId: counterpartyPortId,
        state: far.state,
        pointsBackTo: pointsBackTo,
        message: messages.counterpartyNotOpen(far.state, chain.chainId),
      );
    }

    // The pair must name each other. A channel re-handshaked after an upgrade
    // can leave the old id open on one side only; funds sent into it are
    // escrowed on the source chain and never minted on the destination.
    if (far.counterpartyChannelId != channelId ||
        far.counterpartyPortId != portId) {
      return CounterpartyCheck(
        status: CounterpartyCheckStatus.mismatch,
        ok: false,
        chainId: chain.chainId,
        channelId: counterpartyChannelId,
        portId: counterpartyPortId,
        state: far.state,
        pointsBackTo: pointsBackTo,
        message: messages.counterpartyMismatch(channelId, pointsBackTo),
      );
    }

    // Last proof: the far side's own connection must track the source chain.
    // Only checked when it resolves; an unresolvable client is not evidence of a
    // mismatch.
    final farConnection = far.connectionId;
    if (farConnection != null) {
      final backChainId = await _connectionChainId(client, farConnection);
      if (backChainId != null && backChainId != sourceChainId) {
        return CounterpartyCheck(
          status: CounterpartyCheckStatus.mismatch,
          ok: false,
          chainId: chain.chainId,
          channelId: counterpartyChannelId,
          portId: counterpartyPortId,
          state: far.state,
          pointsBackTo: pointsBackTo,
          message: messages.counterpartyMismatch(sourceChainId, backChainId),
        );
      }
    }

    return CounterpartyCheck(
      status: CounterpartyCheckStatus.ok,
      ok: true,
      chainId: chain.chainId,
      channelId: counterpartyChannelId,
      portId: counterpartyPortId,
      state: far.state,
      pointsBackTo: pointsBackTo,
      message: messages.counterpartyOk(chain.chainId),
    );
  }

  /* ---------------------------------------------------------------------- *
   * Module probes
   * ---------------------------------------------------------------------- */

  /// Probe for packet-forward-middleware.
  ///
  /// A probe, not a guarantee: it asks the LCD for the module's params route. A
  /// public node may hide the route, and a chain may run the middleware without
  /// registering a query service.
  Future<ModuleSupport> detectPfmSupport(String chainId) =>
      _detectModule(InterchainModule.packetForward, chainId);

  /// Probe for ibc-hooks.
  ///
  /// Weaker than the PFM probe. When no hooks route answers this falls back to
  /// "is CosmWasm present at all", which rules the module out when wasm is
  /// missing but cannot rule it in when wasm is there.
  Future<ModuleSupport> detectIbcHooksSupport(String chainId) =>
      _detectModule(InterchainModule.ibcHooks, chainId);

  ModuleSupport _support(
    String chainId,
    InterchainModule module,
    ModuleSupportStatus status,
    String evidence,
  ) =>
      ModuleSupport(
        chainId: chainId,
        module: module,
        status: status,
        evidence: evidence,
        checkedAt: _now(),
      );

  ModuleSupport _cacheSupport(ModuleSupport value) {
    final ttl = value.status == ModuleSupportStatus.unknown
        ? _defaultModuleSupportUnknownTtl
        : _defaultModuleSupportTtl;
    _supportCache['${value.module.name}|${value.chainId}'] =
        _CacheEntry<ModuleSupport>(value, _now().add(ttl));
    return value;
  }

  Future<ModuleSupport> _detectModule(
    InterchainModule module,
    String chainId,
  ) async {
    final pinned = module == InterchainModule.packetForward
        ? _moduleSupport[chainId]?.packetForward
        : _moduleSupport[chainId]?.ibcHooks;
    if (pinned != null) {
      return _support(
        chainId,
        module,
        pinned ? ModuleSupportStatus.supported : ModuleSupportStatus.unsupported,
        'declared by the host',
      );
    }

    final cached = _supportCache['${module.name}|$chainId'];
    if (cached != null && cached.expiresAt.isAfter(_now())) return cached.value;

    final chain = _chain(chainId);
    if (chain == null) {
      return _support(chainId, module, ModuleSupportStatus.unknown,
          'chain is not in the registry');
    }
    final client = _clientFor(chain);
    if (client == null) {
      return _support(chain.chainId, module, ModuleSupportStatus.unknown,
          'chain has no REST endpoint');
    }

    // ibc-hooks executes a CosmWasm contract from inside packet handling, so a
    // chain without wasm cannot run it. The registry flag settles that without a
    // request — when the flag is there at all; the catalog generator currently
    // drops `features`, so its absence proves nothing.
    final features = chain.features;
    if (module == InterchainModule.ibcHooks &&
        features != null &&
        !features.contains('cosmwasm')) {
      return _cacheSupport(_support(chain.chainId, module,
          ModuleSupportStatus.unsupported, 'registry declares no cosmwasm feature'));
    }

    final paths = module == InterchainModule.packetForward
        ? pfmProbePaths
        : ibcHooksProbePaths;
    final probe = await _probeParams(client, paths);

    if (probe.readsDisabled) {
      // Not cached: the answer flips the moment the user turns reads on.
      return _support(
          chain.chainId, module, ModuleSupportStatus.unknown, 'live reads are off');
    }
    if (probe.hitPath != null) {
      return _cacheSupport(_support(chain.chainId, module,
          ModuleSupportStatus.supported, '${probe.hitPath} answered'));
    }

    if (module == InterchainModule.packetForward) {
      if (probe.absentPath != null) {
        return _cacheSupport(_support(chain.chainId, module,
            ModuleSupportStatus.unsupported, '${probe.absentPath} is not registered'));
      }
      return _cacheSupport(
          _support(chain.chainId, module, ModuleSupportStatus.unknown, probe.detail));
    }

    // ibc-hooks fallback. No hooks route answered, which is normal even where
    // the middleware is installed, so fall back to wasm presence: its absence
    // rules the module out, its presence rules nothing in.
    final wasm = await _probeWasm(client);
    if (wasm == _WasmProbe.absent) {
      return _cacheSupport(_support(chain.chainId, module,
          ModuleSupportStatus.unsupported, 'no CosmWasm module on this chain'));
    }
    if (wasm == _WasmProbe.present) {
      return _cacheSupport(_support(chain.chainId, module,
          ModuleSupportStatus.unknown,
          'CosmWasm is present but ibc-hooks exposes no query route'));
    }
    return _cacheSupport(_support(
        chain.chainId,
        module,
        ModuleSupportStatus.unknown,
        probe.absentPath != null
            ? '${probe.absentPath} is not registered'
            : probe.detail));
  }

  /// Probe for the CosmWasm module itself.
  ///
  /// The registry flag wins when it is there: a chain that *declares*
  /// `cosmwasm` is supported without a request, and a chain that declares a
  /// feature list without it is unsupported without a request. Only when the
  /// catalog carries no features at all — which is every chain today — does
  /// this ask the chain, and then a 404/405/501 on the wasm codes route is
  /// evidence of absence and a 200 is evidence of presence. Anything else stays
  /// `unknown`, and the caller must say "not checked" rather than pick a side.
  Future<ModuleSupport> detectCosmWasmSupport(String chainId) async {
    const module = InterchainModule.cosmWasm;
    final cached = _supportCache['${module.name}|$chainId'];
    if (cached != null && cached.expiresAt.isAfter(_now())) return cached.value;

    final chain = _chain(chainId);
    if (chain == null) {
      return _support(chainId, module, ModuleSupportStatus.unknown,
          'chain is not in the registry');
    }

    final features = chain.features;
    if (features != null) {
      final declared = features.contains('cosmwasm');
      return _cacheSupport(_support(
        chain.chainId,
        module,
        declared
            ? ModuleSupportStatus.supported
            : ModuleSupportStatus.unsupported,
        declared
            ? 'registry declares the cosmwasm feature'
            : 'registry declares no cosmwasm feature',
      ));
    }

    final client = _clientFor(chain);
    if (client == null) {
      return _support(chain.chainId, module, ModuleSupportStatus.unknown,
          'chain has no REST endpoint');
    }

    final wasm = await _probeWasm(client);
    switch (wasm) {
      case _WasmProbe.present:
        return _cacheSupport(_support(chain.chainId, module,
            ModuleSupportStatus.supported, '$_wasmProbePath answered'));
      case _WasmProbe.absent:
        return _cacheSupport(_support(chain.chainId, module,
            ModuleSupportStatus.unsupported,
            '$_wasmProbePath is not registered'));
      case _WasmProbe.unknown:
        // Cached only for the short unknown TTL: a public node that hid the
        // route this second may answer the next, and the caller renders
        // "not checked" meanwhile rather than a verdict.
        return _cacheSupport(_support(chain.chainId, module,
            ModuleSupportStatus.unknown,
            '$_wasmProbePath did not give a usable answer'));
    }
  }

  /// Try each candidate route until one answers with a `params` object.
  ///
  /// A 200 whose body has no `params` is inconclusive rather than a hit: a proxy
  /// that answers every path with `{}` would otherwise make every chain look
  /// like it runs every module.
  Future<_ProbeOutcome> _probeParams(
    LcdClient client,
    List<String> paths,
  ) async {
    String? sawAbsent;
    String? inconclusive;

    for (final path in paths) {
      try {
        final body = await client.getJson(path, _options());
        if (_asRecord(_asRecord(body)?['params']) != null) {
          return _ProbeOutcome(hitPath: path);
        }
        inconclusive = '$path answered without a params object';
      } on InterchainError catch (error) {
        if (error.code == InterchainErrorCode.aborted) rethrow;
        if (error.code == InterchainErrorCode.readsDisabled) {
          return const _ProbeOutcome(readsDisabled: true);
        }
        final status = error.httpStatus;
        if (status != null && _routeAbsentStatuses.contains(status)) {
          sawAbsent = path;
          continue;
        }
        inconclusive =
            status == null ? '$path could not be reached' : '$path answered HTTP $status';
      }
    }

    // "Absent" only when nothing muddied the picture: a single unreachable route
    // means the chain might still run the module.
    if (inconclusive == null && sawAbsent != null) {
      return _ProbeOutcome(absentPath: sawAbsent);
    }
    return _ProbeOutcome(detail: inconclusive ?? 'no probe route answered');
  }

  Future<_WasmProbe> _probeWasm(LcdClient client) async {
    try {
      final body = await client.getJson(
        _wasmProbePath,
        _options(query: {'pagination.limit': 1}),
      );
      return _asRecord(body)?['code_infos'] is List
          ? _WasmProbe.present
          : _WasmProbe.unknown;
    } on InterchainError catch (error) {
      if (error.code == InterchainErrorCode.aborted) rethrow;
      final status = error.httpStatus;
      if (status != null && _routeAbsentStatuses.contains(status)) {
        return _WasmProbe.absent;
      }
      return _WasmProbe.unknown;
    }
  }

  /// Drop every memoised connection and module answer.
  void clearCache() {
    _connectionCache.clear();
    _supportCache.clear();
  }
}

enum _WasmProbe { present, absent, unknown }

@immutable
class _ProbeOutcome {
  const _ProbeOutcome({
    this.hitPath,
    this.absentPath,
    this.readsDisabled = false,
    this.detail = '',
  });

  final String? hitPath;
  final String? absentPath;
  final bool readsDisabled;
  final String detail;
}
