/// WalletConnect v2 for Cosmos dApps: any app or site that offers
/// WalletConnect can pick Zunia as its wallet, the way it would pick Keplr.
///
/// Proposals and requests join the same queue as Zunia Connect requests
/// ([NativeConnectService.adopt]), so they survive the lock screen and an
/// open sheet, and the user sees them one at a time with the same review
/// sheets. Signing goes through the same code as Zunia Connect.
///
/// Supported Cosmos methods (WalletConnect Cosmos RPC):
/// - `cosmos_getAccounts` → `[{algo, address, pubkey}]`, answered at once
///   with the accounts the session already shares;
/// - `cosmos_signDirect` `{signerAddress, signDoc{chainId, accountNumber,
///   authInfoBytes, bodyBytes}}` → `{signature{pub_key, signature}, signed}`;
/// - `cosmos_signAmino` `{signerAddress, signDoc}` → `{signature, signed}`;
/// - `cosmos_signArbitrary` `{signerAddress, data, encoding?}` → StdSignature
///   (not in the WalletConnect spec; the Zunia SDK and Keplr use it).
///
/// Inactive unless the build has `--dart-define=WALLETCONNECT_PROJECT_ID`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:reown_walletkit/reown_walletkit.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/config/connect_config.dart';
import 'package:zunia_mobile/connect/app_return.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/connect/sign_in.dart';
import 'package:zunia_mobile/services/connect_session_store.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';

// ---------------------------------------------------------------------------
// What the wallet needs from WalletKit, in plain Dart, so the bridge can be
// tested without a relay.
// ---------------------------------------------------------------------------

class WcPeer {
  const WcPeer({
    required this.name,
    required this.url,
    this.description = '',
    this.icons = const [],
    this.redirectNative,
    this.redirectUniversal,
  });

  final String name;
  final String url;
  final String description;
  final List<String> icons;
  final String? redirectNative;
  final String? redirectUniversal;
}

enum WcVerification { valid, invalid, unknown, scam }

/// WalletConnect's Verify API: where the request really came from.
class WcVerify {
  const WcVerify({required this.origin, required this.status});

  final String origin;
  final WcVerification status;
}

/// A namespace a dApp asks for (required or optional).
class WcNamespaceSpec {
  const WcNamespaceSpec({
    this.chains = const [],
    this.methods = const [],
    this.events = const [],
  });

  final List<String> chains;
  final List<String> methods;
  final List<String> events;
}

/// A namespace the wallet grants.
class WcNamespace {
  const WcNamespace({
    required this.chains,
    required this.accounts,
    required this.methods,
    required this.events,
  });

  final List<String> chains;

  /// `cosmos:<chainId>:<address>`.
  final List<String> accounts;
  final List<String> methods;
  final List<String> events;
}

class WcProposalEvent {
  const WcProposalEvent({
    required this.id,
    required this.pairingTopic,
    required this.peer,
    this.required = const {},
    this.optional = const {},
    this.verify,
  });

  final int id;
  final String pairingTopic;
  final WcPeer peer;
  final Map<String, WcNamespaceSpec> required;
  final Map<String, WcNamespaceSpec> optional;
  final WcVerify? verify;
}

class WcRequestEvent {
  const WcRequestEvent({
    required this.id,
    required this.topic,
    required this.method,
    required this.chainId,
    required this.params,
    this.verify,
  });

  final int id;
  final String topic;
  final String method;

  /// CAIP-2, `cosmos:<chainId>`.
  final String chainId;
  final Object? params;
  final WcVerify? verify;
}

class WcSessionInfo {
  const WcSessionInfo({
    required this.topic,
    required this.pairingTopic,
    required this.peer,
    required this.namespaces,
    required this.expiresAt,
  });

  final String topic;
  final String pairingTopic;
  final WcPeer peer;
  final Map<String, WcNamespace> namespaces;
  final DateTime expiresAt;
}

/// A JSON-RPC error as WalletConnect carries it.
class WcRpcError {
  const WcRpcError(this.code, this.message);

  final int code;
  final String message;

  static const userRejected = WcRpcError(4001, 'User rejected.');
  static const expired = WcRpcError(8000, 'Request expired before it was answered');
  static const unsupportedChains = WcRpcError(5100, 'Unsupported chains.');
  static const unsupportedMethods = WcRpcError(5101, 'Unsupported methods.');
  static const unsupportedEvents = WcRpcError(5102, 'Unsupported events.');
  static const unsupportedNamespace = WcRpcError(5104, 'Unsupported namespace key.');
  static const userDisconnected = WcRpcError(6000, 'User disconnected.');
}

abstract interface class WalletKitPort {
  Stream<WcProposalEvent> get proposals;
  Stream<int> get proposalsExpired;
  Stream<WcRequestEvent> get requests;

  /// Topics of sessions deleted by the dApp or expired.
  Stream<String> get sessionsEnded;

  List<WcProposalEvent> pendingProposals();
  List<WcRequestEvent> pendingRequests();
  Map<String, WcSessionInfo> sessions();

  Future<void> pair(Uri uri);

  /// Returns the new session's topic.
  Future<String> approve(int id, Map<String, WcNamespace> namespaces);
  Future<void> reject(int id, WcRpcError reason);
  Future<void> respond(String topic, int id, {Object? result, WcRpcError? error});
  Future<void> update(String topic, Map<String, WcNamespace> namespaces);
  Future<void> emit(String topic, String chainId, String name, Object? data);
  Future<void> disconnect(String topic, WcRpcError reason);
  Future<void> disconnectPairing(String topic);
  List<String> pairingTopics();

  /// Reopens the relay socket if it died (background, network change).
  Future<void> reconnect();
  Future<void> dispose();
}

// ---------------------------------------------------------------------------
// The service the app uses.
// ---------------------------------------------------------------------------

/// WalletConnect / Reown session surface.
abstract class WalletConnectService {
  Future<void> init();

  /// Pairs with a `wc:` URI. [sameDevice]: the URI came from a link opened on
  /// this phone, so answering returns to the dApp when it named a redirect.
  Future<void> pair(String uri, {bool sameDevice = false});
  Future<void> disconnectAll();
  Future<void> disconnectTopic(String topic);

  /// Emits WC URIs queued for pairing (deep links / QR).
  Stream<Uri> get pendingPairings;

  /// Session proposals as they arrive. The app answers them through the
  /// shared request queue; this stream is kept for observers.
  Stream<WcSessionProposal> get sessionProposals;

  /// Requests as they arrive, likewise.
  Stream<WcSessionRequest> get sessionRequests;

  /// Fires when [activeSessions] change.
  Stream<void> get changes;

  List<WcActiveSession> get activeSessions;

  /// Kept for older callers; accounts are chosen when the user approves.
  void registerCosmosAccounts(List<({String chainId, String address})> accounts);

  /// Approves without the review sheet, with addresses only. Kept for older
  /// callers: such a session cannot share public keys until reconnected.
  Future<void> approveProposal(
    WcSessionProposal proposal, {
    required List<({String chainId, String address})> accounts,
  });

  Future<void> rejectProposal(WcSessionProposal proposal);

  /// Moves every session to another wallet account.
  Future<void> switchAccount({
    required int accountIndex,
    required List<NativeConnectAccount> Function(List<String> chainIds) accountsFor,
  });

  /// Limits a session to [chains]; required chains stay.
  Future<void> setSessionChains(
    String topic,
    List<String> chains, {
    List<NativeConnectAccount> Function(List<String> chainIds)? accountsFor,
  });

  /// A dApp opened Zunia for a request (`zunia://wc?requestId=&sessionTopic=`).
  Future<void> wake({String? topic});

  /// The app is in front again: the relay socket may have died.
  Future<void> resume();

  bool get isReady;

  Future<void> dispose();
}

class WcSessionProposal {
  const WcSessionProposal({
    required this.id,
    required this.name,
    required this.url,
    this.description,
    this.icons = const [],
    this.chains = const [],
    this.methods = const [],
    this.pairingTopic,
    this.generatedNamespaces,
  });

  final int id;
  final String name;
  final String url;
  final String? description;
  final List<String> icons;
  final List<String> chains;
  final List<String> methods;
  final String? pairingTopic;
  final Map<String, Namespace>? generatedNamespaces;
}

class WcSessionRequest {
  const WcSessionRequest({
    required this.id,
    required this.topic,
    required this.method,
    required this.chainId,
    required this.params,
  });

  final int id;
  final String topic;
  final String method;
  final String chainId;
  final dynamic params;
}

class WcActiveSession {
  const WcActiveSession({
    required this.topic,
    required this.name,
    required this.url,
    this.icons = const [],
    this.chains = const [],
    this.requestedChains = const [],
    this.requiredChains = const [],
    this.accounts = const [],
    this.description,
    this.verifiedOrigin,
    this.expiresAt,
    this.pairedAt,
  });

  final String topic;
  final String name;
  final String url;
  final List<String> icons;

  /// Chain ids (without `cosmos:`) the dApp may use now.
  final List<String> chains;

  /// What it asked for; the user can turn optional ones off and on.
  final List<String> requestedChains;

  /// Chains it cannot work without; they cannot be turned off.
  final List<String> requiredChains;
  final List<NativeConnectAccount> accounts;
  final String? description;

  /// Origin WalletConnect's Verify API confirmed, when it did.
  final String? verifiedOrigin;
  final DateTime? expiresAt;
  final DateTime? pairedAt;
}

/// No-op implementation used until Reown is configured.
class StubWalletConnectService implements WalletConnectService {
  final _pairings = StreamController<Uri>.broadcast();
  final _proposals = StreamController<WcSessionProposal>.broadcast();
  final _requests = StreamController<WcSessionRequest>.broadcast();
  final _changes = StreamController<void>.broadcast();

  @override
  bool get isReady => false;

  @override
  Stream<Uri> get pendingPairings => _pairings.stream;

  @override
  Stream<WcSessionProposal> get sessionProposals => _proposals.stream;

  @override
  Stream<WcSessionRequest> get sessionRequests => _requests.stream;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  List<WcActiveSession> get activeSessions => const [];

  @override
  Future<void> init() async {}

  @override
  Future<void> pair(String uri, {bool sameDevice = false}) async {
    throw const ConnectException(
      'UNSUPPORTED',
      'This build of Zunia does not have WalletConnect turned on',
    );
  }

  @override
  Future<void> disconnectAll() async {}

  @override
  Future<void> disconnectTopic(String topic) async {}

  @override
  void registerCosmosAccounts(
    List<({String chainId, String address})> accounts,
  ) {}

  @override
  Future<void> approveProposal(
    WcSessionProposal proposal, {
    required List<({String chainId, String address})> accounts,
  }) async {
    throw UnsupportedError('WalletConnect is not configured.');
  }

  @override
  Future<void> rejectProposal(WcSessionProposal proposal) async {}

  @override
  Future<void> switchAccount({
    required int accountIndex,
    required List<NativeConnectAccount> Function(List<String> chainIds) accountsFor,
  }) async {}

  @override
  Future<void> setSessionChains(
    String topic,
    List<String> chains, {
    List<NativeConnectAccount> Function(List<String> chainIds)? accountsFor,
  }) async {}

  @override
  Future<void> wake({String? topic}) async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> dispose() async {
    await _pairings.close();
    await _proposals.close();
    await _requests.close();
    await _changes.close();
  }
}

const _supportedMethods = [
  'cosmos_getAccounts',
  'cosmos_signDirect',
  'cosmos_signAmino',
  'cosmos_signArbitrary',
];

const _supportedEvents = ['accountsChanged', 'chainChanged'];

/// `wc-pairing:<topic>` keys a proposal in the shared queue; `wc:<topic>` a
/// session's requests.
const _proposalKey = 'wc-pairing:';
const _sessionKey = 'wc:';

String _bare(String caip2) =>
    caip2.startsWith('cosmos:') ? caip2.substring('cosmos:'.length) : caip2;

String? _pairingTopicOf(String wcUri) {
  final rest = wcUri.startsWith('wc:') ? wcUri.substring(3) : '';
  final at = rest.indexOf('@');
  return at <= 0 ? null : rest.substring(0, at);
}

/// Zunia's error codes to WalletConnect JSON-RPC codes the Zunia SDK and
/// other dApps read back.
WcRpcError _rpcErrorFor(String code, String message) => switch (code) {
      'USER_REJECTED' => WcRpcError(4001, message),
      'UNKNOWN_CHAIN' => WcRpcError(5100, message),
      'UNSUPPORTED' => WcRpcError(-32601, message),
      'INVALID_PARAMS' || 'ORIGIN_MISMATCH' => WcRpcError(-32602, message),
      _ => WcRpcError(-32000, message),
    };

/// One session's Zunia-side record ([WcSessionMetaStore]).
class _Meta {
  _Meta({
    required this.accountIndex,
    required this.accounts,
    required this.chains,
    required this.requestedChains,
    required this.requiredChains,
    required this.pairedAt,
    this.sameDevice = false,
    this.returnTarget,
    this.verifiedOrigin,
  });

  static _Meta? fromJson(Map<String, dynamic> json) {
    try {
      return _Meta(
        accountIndex: json['accountIndex'] as int,
        accounts: [
          for (final a in json['accounts'] as List)
            NativeConnectAccount.fromJson(Map<String, dynamic>.from(a as Map)),
        ],
        chains: List<String>.from(json['chains'] as List),
        requestedChains: List<String>.from(json['requestedChains'] as List),
        requiredChains: List<String>.from(json['requiredChains'] as List),
        pairedAt: json['pairedAt'] as int?,
        sameDevice: json['sameDevice'] == true,
        returnTarget: ReturnTarget.parse(json['returnUrl'] as String?),
        verifiedOrigin: json['verifiedOrigin'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  int accountIndex;
  List<NativeConnectAccount> accounts;
  List<String> chains;
  final List<String> requestedChains;
  final List<String> requiredChains;
  final int? pairedAt;
  final bool sameDevice;
  final ReturnTarget? returnTarget;
  final String? verifiedOrigin;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'accountIndex': accountIndex,
        'accounts': [for (final a in accounts) a.toJson()],
        'chains': chains,
        'requestedChains': requestedChains,
        'requiredChains': requiredChains,
        'pairedAt': pairedAt,
        'sameDevice': sameDevice,
        'returnUrl': returnTarget?.url,
        'verifiedOrigin': verifiedOrigin,
      };
}

/// What a proposal asked for, read once.
class _Asked {
  _Asked(this.proposal);

  final WcProposalEvent proposal;

  /// The `wc:` link was opened on this phone.
  bool sameDevice = false;
  final requiredChains = <String>[];
  final optionalChains = <String>[];
  final methods = <String>{};
  final requiredMethods = <String>{};
  final events = <String>{};
  final requiredEvents = <String>{};
  final otherRequired = <String>{};

  void read() {
    void collect(Map<String, WcNamespaceSpec> spaces, bool required) {
      for (final entry in spaces.entries) {
        final key = entry.key;
        final namespace = key.split(':').first;
        final chains = key.contains(':') ? [key] : entry.value.chains;
        if (namespace != 'cosmos') {
          if (required) otherRequired.add(namespace);
          continue;
        }
        for (final chain in chains) {
          final id = _bare(chain);
          if (id.isEmpty) continue;
          (required ? requiredChains : optionalChains).add(id);
        }
        methods.addAll(entry.value.methods);
        events.addAll(entry.value.events);
        if (required) {
          requiredMethods.addAll(entry.value.methods);
          requiredEvents.addAll(entry.value.events);
        }
      }
    }

    collect(proposal.required, true);
    collect(proposal.optional, false);
  }

  List<String> get allChains => {...requiredChains, ...optionalChains}.toList();
}

/// WalletConnect bridged into the shared request queue.
class WalletConnectBridge implements WalletConnectService, ForeignRequestAnswers {
  WalletConnectBridge({
    required Future<WalletKitPort> Function() kit,
    required NativeConnectService native,
    WcSessionMetaStore? store,
    bool Function(String chainId)? supportsChain,
    int Function()? activeAccountIndex,
    DateTime Function()? clock,
  })  : _kitFactory = kit,
        _native = native,
        _store = store ?? MemoryWcSessionMetaStore(),
        _supports = supportsChain ?? _catalogHas,
        _activeIndex = activeAccountIndex ?? (() => 0),
        _now = clock ?? DateTime.now;

  static bool _catalogHas(String chainId) =>
      ChainCatalog.isLoaded && ChainCatalog.instance.find(chainId) != null;

  final Future<WalletKitPort> Function() _kitFactory;
  final NativeConnectService _native;
  final WcSessionMetaStore _store;
  final bool Function(String chainId) _supports;
  final int Function() _activeIndex;
  final DateTime Function() _now;

  WalletKitPort? _kit;
  Future<void>? _starting;
  final _subs = <StreamSubscription<dynamic>>[];
  final Map<String, _Meta> _meta = {};
  final Map<int, _Asked> _proposals = {};

  /// Pairing topics of `wc:` URIs opened from a link on this phone.
  final Set<String> _sameDevicePairings = {};

  final _pairings = StreamController<Uri>.broadcast();
  final _proposalEvents = StreamController<WcSessionProposal>.broadcast();
  final _requestEvents = StreamController<WcSessionRequest>.broadcast();
  final _changes = StreamController<void>.broadcast();

  @override
  bool get isReady => _kit != null;

  @override
  Stream<Uri> get pendingPairings => _pairings.stream;

  @override
  Stream<WcSessionProposal> get sessionProposals => _proposalEvents.stream;

  @override
  Stream<WcSessionRequest> get sessionRequests => _requestEvents.stream;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> init() => _starting ??= _start();

  Future<void> _start() async {
    try {
      final kit = await _kitFactory();
      final saved = await _store.load().catchError((Object _) => <String, Map<String, dynamic>>{});
      for (final entry in saved.entries) {
        final meta = _Meta.fromJson(entry.value);
        if (meta != null) _meta[entry.key] = meta;
      }
      _subs
        ..add(kit.proposals.listen(_onProposal))
        ..add(kit.proposalsExpired.listen(_onProposalExpired))
        ..add(kit.requests.listen(_onRequest))
        ..add(kit.sessionsEnded.listen(_onSessionEnded));
      _kit = kit;
      // What WalletKit kept from before the app last stopped.
      final live = kit.sessions();
      _meta.removeWhere((topic, _) => !live.containsKey(topic));
      unawaited(_saveMeta());
      for (final proposal in kit.pendingProposals()) {
        _onProposal(proposal);
      }
      _adoptPendingRequests();
      _notify();
    } catch (error) {
      _starting = null;
      rethrow;
    }
  }

  Future<WalletKitPort> _ready() async {
    await init();
    return _kit!;
  }

  void _adoptPendingRequests() {
    final kit = _kit;
    if (kit == null) return;
    for (final request in kit.pendingRequests()) {
      _onRequest(request);
    }
  }

  // ---- incoming --------------------------------------------------------

  void _onProposal(WcProposalEvent proposal) {
    if (_proposals.containsKey(proposal.id)) return;
    final asked = _Asked(proposal)..read();
    final name = proposal.peer.name.isEmpty ? 'A site' : proposal.peer.name;

    WcRpcError? refusal;
    String? why;
    if (proposal.verify?.status == WcVerification.scam) {
      refusal = WcRpcError.userRejected;
      why = 'Zunia refused $name: WalletConnect lists it as a scam.';
    } else if (asked.otherRequired.isNotEmpty) {
      refusal = WcRpcError.unsupportedNamespace;
      why = '$name needs ${asked.otherRequired.join(', ')} accounts. Zunia only has Cosmos accounts.';
    } else if (!asked.requiredMethods.every(_supportedMethods.contains)) {
      refusal = WcRpcError.unsupportedMethods;
      why = '$name needs ${asked.requiredMethods.where((m) => !_supportedMethods.contains(m)).join(', ')}, which Zunia does not offer.';
    } else if (!asked.requiredEvents.every(_supportedEvents.contains)) {
      refusal = WcRpcError.unsupportedEvents;
      why = '$name needs events Zunia does not send.';
    } else if (!asked.requiredChains.every(_supports)) {
      refusal = WcRpcError.unsupportedChains;
      why = '$name needs ${asked.requiredChains.where((c) => !_supports(c)).join(', ')}, which Zunia does not support yet.';
    } else if (!asked.allChains.any(_supports)) {
      refusal = WcRpcError.unsupportedChains;
      why = '$name asked for no chain Zunia supports.';
    }
    if (refusal != null) {
      unawaited(_rejectQuietly(proposal.id, refusal));
      _native.reportError(ConnectException('UNSUPPORTED', why!));
      return;
    }

    _proposals[proposal.id] = asked;
    final sameDevice = asked.sameDevice = _sameDevicePairings.remove(proposal.pairingTopic);
    final request = NativeConnectRequest(
      sessionId: '$_proposalKey${proposal.pairingTopic}',
      id: '${proposal.id}',
      dapp: _identity(proposal.peer, proposal.verify),
      receivedAt: _now(),
      chains: [for (final c in asked.allChains) if (_supports(c)) c],
      requiredChains: asked.requiredChains,
      methods: asked.methods.toList(),
      events: asked.events.toList(),
      verificationCode: '',
      transport: ConnectTransport.walletConnect,
      returnTarget: sameDevice ? _returnOf(proposal.peer) : null,
    );
    _native.adopt(request, this);
    if (!_proposalEvents.isClosed) {
      _proposalEvents.add(WcSessionProposal(
        id: proposal.id,
        name: proposal.peer.name,
        url: proposal.peer.url,
        description: proposal.peer.description,
        icons: proposal.peer.icons,
        chains: [for (final c in asked.allChains) 'cosmos:$c'],
        methods: asked.methods.toList(),
        pairingTopic: proposal.pairingTopic,
      ));
    }
  }

  void _onProposalExpired(int id) {
    _proposals.remove(id);
    _native.withdraw((r) =>
        r is NativeConnectRequest &&
        r.transport == ConnectTransport.walletConnect &&
        r.id == '$id');
  }

  void _onSessionEnded(String topic) {
    _meta.remove(topic);
    unawaited(_saveMeta());
    _native.withdraw((r) => r.sessionId == '$_sessionKey$topic');
    _notify();
  }

  void _onRequest(WcRequestEvent event) {
    final kit = _kit;
    if (kit == null) return;
    final key = '$_sessionKey${event.topic}';
    if (_native.pendingRequests.any((r) => r.sessionId == key && r.id == '${event.id}')) {
      return;
    }
    if (!_requestEvents.isClosed) {
      _requestEvents.add(WcSessionRequest(
        id: event.id,
        topic: event.topic,
        method: event.method,
        chainId: event.chainId,
        params: event.params,
      ));
    }
    try {
      final request = _adapt(kit, event);
      if (request != null) _native.adopt(request, this);
    } on ConnectException catch (error) {
      unawaited(_respondQuietly(
        event.topic,
        event.id,
        error: _rpcErrorFor(error.code, error.message),
      ));
    } catch (error) {
      // A shape this code did not expect: still an answer, never silence.
      developer.log('request ${event.id}: $error', name: 'zunia.wc');
      unawaited(_respondQuietly(
        event.topic,
        event.id,
        error: const WcRpcError(-32602, 'Zunia could not read this request'),
      ));
    }
  }

  /// A request the user has to see, or null when it was answered right away.
  NativeSignRequest? _adapt(WalletKitPort kit, WcRequestEvent event) {
    final session = kit.sessions()[event.topic];
    if (session == null) {
      throw const ConnectException('NOT_CONNECTED', 'This session is not active');
    }
    final meta = _meta[event.topic];
    final chainId = _bare(event.chainId);
    final params = event.params is Map
        ? Map<String, dynamic>.from(event.params! as Map)
        : <String, dynamic>{};
    final shared = meta?.accounts ?? _accountsFromNamespaces(session);

    if (event.method == 'cosmos_getAccounts') {
      // Already shared with the session; nothing for the user to decide.
      unawaited(_respondQuietly(event.topic, event.id, result: [
        for (final a in shared)
          if (a.chainId == chainId && a.pubKey.isNotEmpty)
            {'algo': a.algo, 'address': a.address, 'pubkey': a.pubKey},
      ]));
      return null;
    }
    if (!_supportedMethods.contains(event.method)) {
      throw ConnectException('UNSUPPORTED', '${event.method} is not supported');
    }
    if (meta != null && !meta.chains.contains(chainId)) {
      throw ConnectException('UNKNOWN_CHAIN', '$chainId is not part of this session');
    }
    final signer = params['signerAddress'];
    if (signer is! String || !shared.any((a) => a.chainId == chainId && a.address == signer)) {
      throw const ConnectException(
        'INVALID_PARAMS',
        'The signer is not an account this session shares',
      );
    }
    final dapp = _identity(session.peer, event.verify, meta?.verifiedOrigin);
    final sameDevice = meta?.sameDevice ?? false;

    NativeSignRequest request({
      required NativeSignKind kind,
      Map<String, dynamic>? aminoDoc,
      DirectSignDoc? directDoc,
      Uint8List? data,
      SignInMessage? signIn,
    }) =>
        NativeSignRequest(
          sessionId: '$_sessionKey${event.topic}',
          id: '${event.id}',
          dapp: dapp,
          receivedAt: _now(),
          kind: kind,
          chainId: chainId,
          signer: signer,
          accountIndex: meta?.accountIndex ?? _activeIndex(),
          transport: ConnectTransport.walletConnect,
          returnTarget: sameDevice ? meta?.returnTarget : null,
          aminoDoc: aminoDoc,
          directDoc: directDoc,
          data: data,
          signIn: signIn,
        );

    switch (event.method) {
      case 'cosmos_signDirect':
        final raw = params['signDoc'];
        // Some dApps send the account number as a JSON number.
        final wire = raw is Map
            ? {
                ...Map<String, dynamic>.from(raw),
                if (raw['accountNumber'] is int) 'accountNumber': '${raw['accountNumber']}',
              }
            : raw;
        final doc = DirectSignDoc.fromWire(wire);
        if (doc.chainId != chainId) {
          throw ConnectException('INVALID_PARAMS', 'The document is for another chain than $chainId');
        }
        return request(kind: NativeSignKind.direct, directDoc: doc);
      case 'cosmos_signAmino':
        final doc = params['signDoc'];
        if (doc is! Map) {
          throw const ConnectException('INVALID_PARAMS', 'signDoc must be an object');
        }
        if (doc['chain_id'] != chainId) {
          throw ConnectException('INVALID_PARAMS', 'The document is for another chain than $chainId');
        }
        return request(kind: NativeSignKind.amino, aminoDoc: Map<String, dynamic>.from(doc));
      default:
        final data = _arbitrary(params);
        final text = _utf8OrNull(data);
        if (text != null && looksLikeSignIn(text)) {
          final message = parseSignInMessage(text);
          final origin = dapp.verifiedOrigin;
          if (origin == null || dapp.originMismatch) {
            throw const ConnectException(
              'ORIGIN_MISMATCH',
              'WalletConnect could not confirm which site this is, so it cannot ask you to sign in',
            );
          }
          checkSignInBinding(message, origin: origin, chainId: chainId, signer: signer, now: _now());
          return request(kind: NativeSignKind.signIn, data: data, signIn: message);
        }
        return request(kind: NativeSignKind.message, data: data);
    }
  }

  static Uint8List _arbitrary(Map<String, dynamic> params) {
    final data = params['data'];
    final encoding = params['encoding'] ?? 'utf8';
    if (data is! String || data.length > 128 * 1024) {
      throw const ConnectException('INVALID_PARAMS', 'data must be a string of at most 128 KiB');
    }
    if (encoding == 'utf8') return Uint8List.fromList(utf8.encode(data));
    if (encoding == 'base64') {
      try {
        return base64Decode(data);
      } on FormatException {
        throw const ConnectException('INVALID_PARAMS', 'data is not base64');
      }
    }
    throw const ConnectException('INVALID_PARAMS', 'encoding must be utf8 or base64');
  }

  static String? _utf8OrNull(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  static List<NativeConnectAccount> _accountsFromNamespaces(WcSessionInfo session) => [
        for (final account in session.namespaces['cosmos']?.accounts ?? const <String>[])
          if (account.split(':') case [_, final chain, final address])
            NativeConnectAccount(chainId: chain, address: address, pubKey: ''),
      ];

  NativeDappIdentity _identity(WcPeer peer, WcVerify? verify, [String? remembered]) {
    final metadata = NativeDappMetadata.fromWire({
      'name': peer.name,
      'url': peer.url,
      'description': peer.description,
      'icons': peer.icons,
    });
    final attested = verify == null ? null : webOrigin(verify.origin);
    final verified = switch (verify?.status) {
      WcVerification.valid || WcVerification.invalid => attested,
      _ => remembered,
    };
    return NativeDappIdentity(
      metadata: metadata,
      verifiedOrigin: verified,
      relay: 'WalletConnect',
    );
  }

  static ReturnTarget? _returnOf(WcPeer peer) =>
      ReturnTarget.parse(peer.redirectNative) ?? ReturnTarget.parse(peer.redirectUniversal);

  // ---- answers (ForeignRequestAnswers) ----------------------------------

  @override
  Future<void> approveConnect(
    NativeConnectRequest request, {
    required List<NativeConnectAccount> accounts,
    required int accountIndex,
  }) async {
    final kit = await _ready();
    final id = int.parse(request.id);
    final asked = _proposals[id];
    if (asked == null) {
      throw const ConnectException('NOT_CONNECTED', 'This request is no longer open');
    }
    final chains = [
      for (final chain in request.chains)
        if (accounts.any((a) => a.chainId == chain)) chain,
    ];
    final missing = [for (final c in request.requiredChains) if (!chains.contains(c)) c];
    if (missing.isNotEmpty) {
      throw ConnectException(
        'UNKNOWN_CHAIN',
        'Zunia has no account on ${missing.join(', ')}, which ${request.dapp.host} requires',
      );
    }
    if (chains.isEmpty) {
      throw const ConnectException(
        'UNKNOWN_CHAIN',
        'Zunia has no account on the chains this site asked for',
      );
    }
    final shared = [for (final a in accounts) if (chains.contains(a.chainId)) a];
    final methods = asked.methods.where(_supportedMethods.contains).toList();
    final events = asked.events.where(_supportedEvents.contains).toList();
    final topic = await kit.approve(id, {
      'cosmos': WcNamespace(
        chains: [for (final c in chains) 'cosmos:$c'],
        accounts: [for (final a in shared) 'cosmos:${a.chainId}:${a.address}'],
        methods: methods.isEmpty ? List.of(_supportedMethods) : methods,
        events: events.isEmpty ? List.of(_supportedEvents) : events,
      ),
    });
    _proposals.remove(id);
    _meta[topic] = _Meta(
      accountIndex: accountIndex,
      accounts: shared,
      chains: chains,
      requestedChains: request.chains,
      requiredChains: request.requiredChains,
      pairedAt: _now().millisecondsSinceEpoch,
      sameDevice: asked.sameDevice,
      returnTarget: request.returnTarget,
      verifiedOrigin: request.dapp.originMismatch ? null : request.dapp.verifiedOrigin,
    );
    await _saveMeta();
    _notify();
  }

  @override
  Future<void> rejectConnect(NativeConnectRequest request) async {
    final id = int.parse(request.id);
    final asked = _proposals.remove(id);
    await _rejectQuietly(id, WcRpcError.userRejected);
    final pairing = asked?.proposal.pairingTopic;
    if (pairing != null) {
      try {
        await (await _ready()).disconnectPairing(pairing);
      } catch (error) {
        developer.log('pairing disconnect: $error', name: 'zunia.wc');
      }
    }
  }

  @override
  Future<void> approveSign(NativeSignRequest request, Map<String, Object?> result) async {
    final kit = await _ready();
    await kit.respond(
      request.sessionId.substring(_sessionKey.length),
      int.parse(request.id),
      result: result,
    );
  }

  @override
  Future<void> rejectSign(
    NativeSignRequest request, {
    required String code,
    required String message,
  }) =>
      _respondQuietly(
        request.sessionId.substring(_sessionKey.length),
        int.parse(request.id),
        error: _rpcErrorFor(code, message),
      );

  @override
  Future<void> expire(NativeRequest request) async {
    final id = int.parse(request.id);
    if (request is NativeConnectRequest) {
      _proposals.remove(id);
      await _rejectQuietly(id, WcRpcError.expired);
      return;
    }
    await _respondQuietly(
      request.sessionId.substring(_sessionKey.length),
      id,
      error: WcRpcError.expired,
    );
  }

  Future<void> _rejectQuietly(int id, WcRpcError reason) async {
    try {
      await (await _ready()).reject(id, reason);
    } catch (error) {
      developer.log('reject $id: $error', name: 'zunia.wc');
    }
  }

  Future<void> _respondQuietly(String topic, int id, {Object? result, WcRpcError? error}) async {
    try {
      await (await _ready()).respond(topic, id, result: result, error: error);
    } catch (e) {
      developer.log('respond $id: $e', name: 'zunia.wc');
    }
  }

  // ---- the app's calls ---------------------------------------------------

  @override
  Future<void> pair(String uri, {bool sameDevice = false}) async {
    final kit = await _ready();
    final parsed = Uri.parse(uri);
    final topic = _pairingTopicOf(uri);
    if (sameDevice && topic != null) {
      _sameDevicePairings.add(topic);
      _native.armReturn('$_proposalKey$topic');
    }
    if (!_pairings.isClosed) _pairings.add(parsed);
    try {
      await kit.pair(parsed);
    } catch (error) {
      throw ConnectException(
        'PAIRING_FAILED',
        'WalletConnect could not pair: ${error.toString().split('\n').first}',
      );
    }
  }

  @override
  Future<void> wake({String? topic}) async {
    final kit = _kit;
    if (kit == null) return;
    if (topic != null && (_meta[topic]?.sameDevice ?? false)) {
      _native.armReturn('$_sessionKey$topic');
    }
    try {
      await kit.reconnect();
    } catch (error) {
      developer.log('reconnect: $error', name: 'zunia.wc');
    }
    _adoptPendingRequests();
  }

  @override
  Future<void> resume() => wake();

  @override
  List<WcActiveSession> get activeSessions {
    final kit = _kit;
    if (kit == null) return const [];
    return [
      for (final session in kit.sessions().values)
        _view(session, _meta[session.topic]),
    ];
  }

  WcActiveSession _view(WcSessionInfo session, _Meta? meta) {
    final accounts = meta?.accounts ?? _accountsFromNamespaces(session);
    final chains = meta?.chains ??
        [for (final c in session.namespaces['cosmos']?.chains ?? const <String>[]) _bare(c)];
    return WcActiveSession(
      topic: session.topic,
      name: session.peer.name.isEmpty ? 'dApp' : session.peer.name,
      url: session.peer.url,
      icons: session.peer.icons,
      description: session.peer.description.isEmpty ? null : session.peer.description,
      chains: chains,
      requestedChains: meta?.requestedChains ?? chains,
      requiredChains: meta?.requiredChains ?? chains,
      accounts: accounts,
      verifiedOrigin: meta?.verifiedOrigin,
      expiresAt: session.expiresAt,
      pairedAt: meta?.pairedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(meta!.pairedAt!),
    );
  }

  @override
  Future<void> switchAccount({
    required int accountIndex,
    required List<NativeConnectAccount> Function(List<String> chainIds) accountsFor,
  }) async {
    final kit = _kit;
    if (kit == null) return;
    final sessions = kit.sessions();
    for (final entry in _meta.entries.toList()) {
      final session = sessions[entry.key];
      if (session == null) continue;
      final meta = entry.value;
      final next = accountsFor(meta.chains);
      if (meta.accountIndex == accountIndex && _sameAccounts(next, meta.accounts)) continue;
      // A required chain without an account cannot be left out of an
      // update; keep the old account there rather than break the session.
      if (meta.requiredChains.any((c) => !next.any((a) => a.chainId == c))) continue;
      meta
        ..accountIndex = accountIndex
        ..accounts = next
        ..chains = [for (final c in meta.chains) if (next.any((a) => a.chainId == c)) c];
      await _saveMeta();
      try {
        await kit.update(entry.key, _namespaces(session, meta));
        for (final chain in meta.chains) {
          await kit.emit(entry.key, 'cosmos:$chain', 'accountsChanged', [
            for (final a in next) if (a.chainId == chain) a.address,
          ]);
        }
      } catch (error) {
        developer.log('account switch for ${entry.key}: $error', name: 'zunia.wc');
      }
    }
    _notify();
  }

  @override
  Future<void> setSessionChains(
    String topic,
    List<String> chains, {
    List<NativeConnectAccount> Function(List<String> chainIds)? accountsFor,
  }) async {
    final kit = await _ready();
    final session = kit.sessions()[topic];
    final meta = _meta[topic];
    if (session == null || meta == null) {
      throw const ConnectException('NOT_CONNECTED', 'This app is no longer connected');
    }
    final next = [for (final c in meta.requestedChains) if (chains.contains(c)) c];
    final dropped = [for (final c in meta.requiredChains) if (!next.contains(c)) c];
    if (dropped.isNotEmpty) {
      throw ConnectException(
        'INVALID_PARAMS',
        '${session.peer.name} cannot work without ${dropped.join(', ')}',
      );
    }
    if (next.isEmpty) {
      throw const ConnectException('INVALID_PARAMS', 'Keep at least one chain, or disconnect the app');
    }
    final added = [for (final c in next) if (!meta.chains.contains(c)) c];
    var accounts = [for (final a in meta.accounts) if (next.contains(a.chainId)) a];
    if (added.isNotEmpty) {
      final derived = accountsFor?.call(added) ?? const [];
      next.removeWhere((c) => added.contains(c) && !derived.any((a) => a.chainId == c));
      accounts = [...accounts, for (final a in derived) if (added.contains(a.chainId)) a];
    }
    meta
      ..chains = next
      ..accounts = accounts;
    await _saveMeta();
    _native.withdraw((r) =>
        r is NativeSignRequest && r.sessionId == '$_sessionKey$topic' && !next.contains(r.chainId));
    await kit.update(topic, _namespaces(session, meta));
    _notify();
  }

  Map<String, WcNamespace> _namespaces(WcSessionInfo session, _Meta meta) {
    final current = session.namespaces['cosmos'];
    return {
      'cosmos': WcNamespace(
        chains: [for (final c in meta.chains) 'cosmos:$c'],
        accounts: [for (final a in meta.accounts) 'cosmos:${a.chainId}:${a.address}'],
        methods: current?.methods ?? List.of(_supportedMethods),
        events: current?.events ?? List.of(_supportedEvents),
      ),
    };
  }

  @override
  void registerCosmosAccounts(List<({String chainId, String address})> accounts) {}

  @override
  Future<void> approveProposal(
    WcSessionProposal proposal, {
    required List<({String chainId, String address})> accounts,
  }) async {
    final queued = _native.pendingRequests.whereType<NativeConnectRequest>().where(
          (r) => r.transport == ConnectTransport.walletConnect && r.id == '${proposal.id}',
        );
    for (final request in queued.toList()) {
      await _native.approveConnect(
        request,
        accounts: [
          for (final a in accounts)
            NativeConnectAccount(chainId: _bare(a.chainId), address: a.address, pubKey: ''),
        ],
        accountIndex: _activeIndex(),
      );
    }
  }

  @override
  Future<void> rejectProposal(WcSessionProposal proposal) async {
    final queued = _native.pendingRequests.whereType<NativeConnectRequest>().where(
          (r) => r.transport == ConnectTransport.walletConnect && r.id == '${proposal.id}',
        );
    for (final request in queued.toList()) {
      await _native.rejectConnect(request);
    }
  }

  @override
  Future<void> disconnectTopic(String topic) async {
    final kit = await _ready();
    try {
      await kit.disconnect(topic, WcRpcError.userDisconnected);
    } finally {
      _meta.remove(topic);
      await _saveMeta();
      _native.withdraw((r) => r.sessionId == '$_sessionKey$topic');
      _notify();
    }
  }

  @override
  Future<void> disconnectAll() async {
    final kit = _kit;
    if (kit == null) return;
    for (final topic in kit.sessions().keys.toList()) {
      try {
        await disconnectTopic(topic);
      } catch (error) {
        developer.log('disconnect $topic: $error', name: 'zunia.wc');
      }
    }
    for (final pairing in kit.pairingTopics()) {
      try {
        await kit.disconnectPairing(pairing);
      } catch (_) {}
    }
  }

  Future<void> _saveMeta() async {
    try {
      await _store.save({for (final e in _meta.entries) e.key: e.value.toJson()});
    } catch (error) {
      developer.log('Could not save WalletConnect sessions: $error', name: 'zunia.wc');
    }
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static bool _sameAccounts(List<NativeConnectAccount> a, List<NativeConnectAccount> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    await _kit?.dispose();
    _kit = null;
    await _pairings.close();
    await _proposalEvents.close();
    await _requestEvents.close();
    await _changes.close();
  }
}

// ---------------------------------------------------------------------------
// Reown WalletKit behind [WalletKitPort].
// ---------------------------------------------------------------------------

class ReownWalletKitPort implements WalletKitPort {
  ReownWalletKitPort._(this._kit) {
    _kit.onSessionProposal.subscribe(_proposal);
    _kit.onProposalExpire.subscribe(_proposalExpire);
    _kit.onSessionRequest.subscribe(_request);
    _kit.onSessionDelete.subscribe(_delete);
    _kit.onSessionExpire.subscribe(_expire);
  }

  static Future<ReownWalletKitPort> create({String? projectId}) async {
    final id = projectId ?? kWalletConnectProjectId;
    if (id.isEmpty) throw StateError('WALLETCONNECT_PROJECT_ID is empty');
    final kit = await ReownWalletKit.createInstance(
      projectId: id,
      relayUrl: kWalletConnectRelayUrl,
      metadata: const PairingMetadata(
        name: kWalletName,
        description: kWalletDescription,
        url: kWalletUrl,
        icons: [kWalletIconUrl],
        redirect: Redirect(
          native: 'zunia://',
          universal: 'https://zunialab.com/wc',
        ),
      ),
    );
    return ReownWalletKitPort._(kit);
  }

  final ReownWalletKit _kit;
  final _proposals = StreamController<WcProposalEvent>.broadcast();
  final _expired = StreamController<int>.broadcast();
  final _requests = StreamController<WcRequestEvent>.broadcast();
  final _ended = StreamController<String>.broadcast();

  static WcPeer _peer(PairingMetadata m) => WcPeer(
        name: m.name,
        url: m.url,
        description: m.description,
        icons: List<String>.from(m.icons),
        redirectNative: m.redirect?.native,
        redirectUniversal: m.redirect?.universal,
      );

  static WcVerify? _verify(VerifyContext? context) {
    if (context == null) return null;
    final status = context.isScam == true
        ? WcVerification.scam
        : switch (context.validation) {
            Validation.VALID => WcVerification.valid,
            Validation.INVALID => WcVerification.invalid,
            Validation.SCAM => WcVerification.scam,
            Validation.UNKNOWN => WcVerification.unknown,
          };
    return WcVerify(origin: context.origin, status: status);
  }

  static Map<String, WcNamespaceSpec> _specs(Map<String, RequiredNamespace> spaces) => {
        for (final e in spaces.entries)
          e.key: WcNamespaceSpec(
            chains: List<String>.from(e.value.chains ?? const []),
            methods: List<String>.from(e.value.methods),
            events: List<String>.from(e.value.events),
          ),
      };

  static WcProposalEvent _fromProposal(int id, ProposalData p, VerifyContext? verify) =>
      WcProposalEvent(
        id: id,
        pairingTopic: p.pairingTopic,
        peer: _peer(p.proposer.metadata),
        required: _specs(p.requiredNamespaces),
        optional: _specs(p.optionalNamespaces),
        verify: _verify(verify),
      );

  void _proposal(SessionProposalEvent? args) {
    if (args == null || _proposals.isClosed) return;
    _proposals.add(_fromProposal(args.id, args.params, args.verifyContext));
  }

  void _proposalExpire(SessionProposalEvent? args) {
    if (args != null && !_expired.isClosed) _expired.add(args.id);
  }

  void _request(SessionRequestEvent? args) {
    if (args == null || _requests.isClosed) return;
    final stored = _kit.pendingRequests.get(args.id.toString());
    _requests.add(WcRequestEvent(
      id: args.id,
      topic: args.topic,
      method: args.method,
      chainId: args.chainId,
      params: args.params,
      verify: _verify(stored?.verifyContext),
    ));
  }

  void _delete(SessionDelete? args) {
    if (args != null && !_ended.isClosed) _ended.add(args.topic);
  }

  void _expire(SessionExpire? args) {
    if (args != null && !_ended.isClosed) _ended.add(args.topic);
  }

  @override
  Stream<WcProposalEvent> get proposals => _proposals.stream;

  @override
  Stream<int> get proposalsExpired => _expired.stream;

  @override
  Stream<WcRequestEvent> get requests => _requests.stream;

  @override
  Stream<String> get sessionsEnded => _ended.stream;

  @override
  List<WcProposalEvent> pendingProposals() => [
        for (final p in _kit.getPendingSessionProposals().values)
          _fromProposal(p.id, p, null),
      ];

  @override
  List<WcRequestEvent> pendingRequests() => [
        for (final r in _kit.getPendingSessionRequests().values)
          WcRequestEvent(
            id: r.id,
            topic: r.topic,
            method: r.method,
            chainId: r.chainId,
            params: r.params,
            verify: _verify(r.verifyContext),
          ),
      ];

  @override
  Map<String, WcSessionInfo> sessions() => {
        for (final s in _kit.getActiveSessions().values)
          s.topic: WcSessionInfo(
            topic: s.topic,
            pairingTopic: s.pairingTopic,
            peer: _peer(s.peer.metadata),
            namespaces: {
              for (final e in s.namespaces.entries)
                e.key: WcNamespace(
                  chains: List<String>.from(e.value.chains ?? const []),
                  accounts: List<String>.from(e.value.accounts),
                  methods: List<String>.from(e.value.methods),
                  events: List<String>.from(e.value.events),
                ),
            },
            expiresAt: DateTime.fromMillisecondsSinceEpoch(s.expiry * 1000),
          ),
      };

  static Map<String, Namespace> _toReown(Map<String, WcNamespace> spaces) => {
        for (final e in spaces.entries)
          e.key: Namespace(
            chains: e.value.chains,
            accounts: e.value.accounts,
            methods: e.value.methods,
            events: e.value.events,
          ),
      };

  @override
  Future<void> pair(Uri uri) async {
    await _kit.pair(uri: uri);
  }

  @override
  Future<String> approve(int id, Map<String, WcNamespace> namespaces) async {
    final response = await _kit.approveSession(id: id, namespaces: _toReown(namespaces));
    return response.topic;
  }

  @override
  Future<void> reject(int id, WcRpcError reason) => _kit.rejectSession(
        id: id,
        reason: ReownSignError(code: reason.code, message: reason.message),
      );

  @override
  Future<void> respond(String topic, int id, {Object? result, WcRpcError? error}) =>
      _kit.respondSessionRequest(
        topic: topic,
        response: JsonRpcResponse(
          id: id,
          result: error == null ? result : null,
          error: error == null ? null : JsonRpcError(code: error.code, message: error.message),
        ),
      );

  @override
  Future<void> update(String topic, Map<String, WcNamespace> namespaces) =>
      _kit.updateSession(topic: topic, namespaces: _toReown(namespaces));

  @override
  Future<void> emit(String topic, String chainId, String name, Object? data) =>
      _kit.emitSessionEvent(
        topic: topic,
        chainId: chainId,
        event: SessionEventParams(name: name, data: data),
      );

  @override
  Future<void> disconnect(String topic, WcRpcError reason) => _kit.disconnectSession(
        topic: topic,
        reason: ReownSignError(code: reason.code, message: reason.message),
      );

  @override
  Future<void> disconnectPairing(String topic) => _kit.core.pairing.disconnect(topic: topic);

  @override
  List<String> pairingTopics() => [for (final p in _kit.pairings.getAll()) p.topic];

  @override
  Future<void> reconnect() async {
    if (!_kit.core.relayClient.isConnected) await _kit.core.relayClient.connect();
  }

  @override
  Future<void> dispose() async {
    _kit.onSessionProposal.unsubscribe(_proposal);
    _kit.onProposalExpire.unsubscribe(_proposalExpire);
    _kit.onSessionRequest.unsubscribe(_request);
    _kit.onSessionDelete.unsubscribe(_delete);
    _kit.onSessionExpire.unsubscribe(_expire);
    await _proposals.close();
    await _expired.close();
    await _requests.close();
    await _ended.close();
  }
}

WalletConnectService createWalletConnectService({
  required NativeConnectService native,
  int Function()? activeAccountIndex,
}) {
  if (kWalletConnectProjectId.isEmpty) {
    return StubWalletConnectService();
  }
  return WalletConnectBridge(
    kit: () => ReownWalletKitPort.create(),
    native: native,
    store: SecureWcSessionMetaStore(),
    activeAccountIndex: activeAccountIndex,
  );
}

@visibleForTesting
String? pairingTopicOf(String wcUri) => _pairingTopicOf(wcUri);
