import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:reown_walletkit/reown_walletkit.dart';
import 'package:zunia_mobile/config/connect_config.dart';

/// WalletConnect / Reown session surface.
abstract class WalletConnectService {
  Future<void> init();
  Future<void> pair(String uri);
  Future<void> disconnectAll();
  Future<void> disconnectTopic(String topic);

  /// Emits WC URIs queued for pairing (deep links / QR).
  Stream<Uri> get pendingPairings;

  /// Session proposals that need user approval.
  Stream<WcSessionProposal> get sessionProposals;

  /// Sign / request events awaiting UI.
  Stream<WcSessionRequest> get sessionRequests;

  List<WcActiveSession> get activeSessions;

  /// Register cosmos accounts (`cosmos:chainId:address`) before approving.
  void registerCosmosAccounts(List<({String chainId, String address})> accounts);

  Future<void> approveProposal(
    WcSessionProposal proposal, {
    required List<({String chainId, String address})> accounts,
  });

  Future<void> rejectProposal(WcSessionProposal proposal);

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
  });

  final String topic;
  final String name;
  final String url;
  final List<String> icons;
  final List<String> chains;
}

/// No-op implementation used until Reown is configured.
class StubWalletConnectService implements WalletConnectService {
  final _pairings = StreamController<Uri>.broadcast();
  final _proposals = StreamController<WcSessionProposal>.broadcast();
  final _requests = StreamController<WcSessionRequest>.broadcast();

  @override
  bool get isReady => false;

  @override
  Stream<Uri> get pendingPairings => _pairings.stream;

  @override
  Stream<WcSessionProposal> get sessionProposals => _proposals.stream;

  @override
  Stream<WcSessionRequest> get sessionRequests => _requests.stream;

  @override
  List<WcActiveSession> get activeSessions => const [];

  @override
  Future<void> init() async {}

  @override
  Future<void> pair(String uri) async {
    throw UnsupportedError(
      'WalletConnect is not configured. Set WALLETCONNECT_PROJECT_ID.',
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
  Future<void> dispose() async {
    await _pairings.close();
    await _proposals.close();
    await _requests.close();
  }
}

/// Reown WalletKit-backed WalletConnect v2 peer.
class ReownWalletConnectService implements WalletConnectService {
  ReownWalletConnectService({String? projectId})
      : projectId = projectId ?? kWalletConnectProjectId;

  final String projectId;
  ReownWalletKit? _kit;
  bool _ready = false;
  bool _initAttempted = false;

  final _pairings = StreamController<Uri>.broadcast();
  final _proposals = StreamController<WcSessionProposal>.broadcast();
  final _requests = StreamController<WcSessionRequest>.broadcast();

  void Function(SessionProposalEvent?)? _onProposal;
  void Function(SessionRequestEvent?)? _onRequest;
  void Function(SessionDelete?)? _onDelete;

  @override
  bool get isReady => _ready && _kit != null && projectId.isNotEmpty;

  @override
  Stream<Uri> get pendingPairings => _pairings.stream;

  @override
  Stream<WcSessionProposal> get sessionProposals => _proposals.stream;

  @override
  Stream<WcSessionRequest> get sessionRequests => _requests.stream;

  ReownWalletKit? get kit => _kit;

  @override
  List<WcActiveSession> get activeSessions {
    final kit = _kit;
    if (kit == null) return const [];
    try {
      return kit.getActiveSessions().values.map((s) {
        final meta = s.peer.metadata;
        final chains = <String>{};
        for (final ns in s.namespaces.values) {
          for (final account in ns.accounts) {
            final parts = account.split(':');
            if (parts.length >= 2) {
              chains.add('${parts[0]}:${parts[1]}');
            }
          }
        }
        return WcActiveSession(
          topic: s.topic,
          name: meta.name,
          url: meta.url,
          icons: List<String>.from(meta.icons),
          chains: chains.toList(),
        );
      }).toList();
    } catch (e) {
      debugPrint('ReownWalletConnectService activeSessions: $e');
      return const [];
    }
  }

  void _requireKit() {
    if (_kit == null) {
      throw StateError(
        'ReownWalletKit is not initialized. Call init() after setting '
        'WALLETCONNECT_PROJECT_ID, and ensure platform plugins are ready.',
      );
    }
  }

  @override
  Future<void> init() async {
    if (_ready && _kit != null) return;
    if (projectId.isEmpty) {
      throw StateError('WALLETCONNECT_PROJECT_ID is empty');
    }
    if (_initAttempted && _kit == null) {
      throw StateError(
        'ReownWalletKit init previously failed. Check native setup and project id.',
      );
    }
    _initAttempted = true;
    try {
      final kit = await ReownWalletKit.createInstance(
        projectId: projectId,
        relayUrl: kWalletConnectRelayUrl,
        metadata: PairingMetadata(
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

      _onProposal = (SessionProposalEvent? args) {
        if (args == null) return;
        final meta = args.params.proposer.metadata;
        final chains = <String>[];
        final methods = <String>{};
        for (final ns in args.params.requiredNamespaces.values) {
          if (ns.chains != null) chains.addAll(ns.chains!);
          methods.addAll(ns.methods);
        }
        for (final ns in args.params.optionalNamespaces.values) {
          if (ns.chains != null) chains.addAll(ns.chains!);
          methods.addAll(ns.methods);
        }
        if (!_proposals.isClosed) {
          _proposals.add(
            WcSessionProposal(
              id: args.id,
              name: meta.name,
              url: meta.url,
              description: meta.description,
              icons: List<String>.from(meta.icons),
              chains: chains.toSet().toList(),
              methods: methods.toList(),
              pairingTopic: args.params.pairingTopic,
              generatedNamespaces: args.params.generatedNamespaces,
            ),
          );
        }
      };

      _onRequest = (SessionRequestEvent? args) {
        if (args == null || _requests.isClosed) return;
        _requests.add(
          WcSessionRequest(
            id: args.id,
            topic: args.topic,
            method: args.method,
            chainId: args.chainId,
            params: args.params,
          ),
        );
      };

      _onDelete = (_) {
        // Consumers re-read [activeSessions].
      };

      kit.onSessionProposal.subscribe(_onProposal!);
      kit.onSessionRequest.subscribe(_onRequest!);
      kit.onSessionDelete.subscribe(_onDelete!);

      _kit = kit;
      _ready = true;
      debugPrint('ReownWalletConnectService ready (project=$projectId)');
    } catch (e, st) {
      _kit = null;
      _ready = false;
      debugPrint('ReownWalletKit.init failed: $e\n$st');
      rethrow;
    }
  }

  @override
  void registerCosmosAccounts(
    List<({String chainId, String address})> accounts,
  ) {
    final kit = _kit;
    if (kit == null) return;
    for (final a in accounts) {
      final chainId = a.chainId.startsWith('cosmos:')
          ? a.chainId
          : 'cosmos:${a.chainId}';
      try {
        kit.registerAccount(
          chainId: chainId,
          accountAddress: a.address,
        );
        for (final event in kCosmosWcEvents) {
          kit.registerEventEmitter(chainId: chainId, event: event);
        }
        for (final method in kCosmosWcMethods) {
          kit.registerRequestHandler(
            chainId: chainId,
            method: method,
            handler: null,
          );
        }
      } catch (e) {
        debugPrint('registerCosmosAccounts($chainId): $e');
      }
    }
  }

  @override
  Future<void> pair(String uri) async {
    if (!isReady) await init();
    _requireKit();
    final parsed = Uri.parse(uri);
    if (!_pairings.isClosed) _pairings.add(parsed);
    await _kit!.pair(uri: parsed);
  }

  @override
  Future<void> approveProposal(
    WcSessionProposal proposal, {
    required List<({String chainId, String address})> accounts,
  }) async {
    _requireKit();
    registerCosmosAccounts(accounts);

    var namespaces = proposal.generatedNamespaces;
    if (namespaces == null || namespaces.isEmpty) {
      namespaces = _buildCosmosNamespaces(accounts, proposal);
    }
    await _kit!.approveSession(id: proposal.id, namespaces: namespaces);
  }

  Map<String, Namespace> _buildCosmosNamespaces(
    List<({String chainId, String address})> accounts,
    WcSessionProposal proposal,
  ) {
    final accountIds = accounts.map((a) {
      final chain = a.chainId.startsWith('cosmos:')
          ? a.chainId
          : 'cosmos:${a.chainId}';
      return '$chain:${a.address}';
    }).toList();
    final methods = proposal.methods.isNotEmpty
        ? proposal.methods
        : kCosmosWcMethods;
    final events = kCosmosWcEvents;
    return {
      'cosmos': Namespace(
        accounts: accountIds,
        methods: methods,
        events: events,
      ),
    };
  }

  @override
  Future<void> rejectProposal(WcSessionProposal proposal) async {
    _requireKit();
    final reason = Errors.getSdkError(Errors.USER_REJECTED).toSignError();
    await _kit!.rejectSession(id: proposal.id, reason: reason);
    final pairingTopic = proposal.pairingTopic;
    if (pairingTopic != null && pairingTopic.isNotEmpty) {
      try {
        await _kit!.core.pairing.disconnect(topic: pairingTopic);
      } catch (e) {
        debugPrint('pairing disconnect: $e');
      }
    }
  }

  @override
  Future<void> disconnectTopic(String topic) async {
    _requireKit();
    await _kit!.disconnectSession(
      topic: topic,
      reason: Errors.getSdkError(Errors.USER_DISCONNECTED).toSignError(),
    );
  }

  @override
  Future<void> disconnectAll() async {
    if (_kit == null) return;
    final sessions = List<WcActiveSession>.from(activeSessions);
    for (final s in sessions) {
      try {
        await disconnectTopic(s.topic);
      } catch (e) {
        debugPrint('disconnectAll ${s.topic}: $e');
      }
    }
    try {
      final pairings = _kit!.pairings.getAll();
      for (final p in pairings) {
        try {
          await _kit!.core.pairing.disconnect(topic: p.topic);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('disconnectAll pairings: $e');
    }
  }

  @override
  Future<void> dispose() async {
    final kit = _kit;
    if (kit != null) {
      if (_onProposal != null) {
        kit.onSessionProposal.unsubscribe(_onProposal!);
      }
      if (_onRequest != null) {
        kit.onSessionRequest.unsubscribe(_onRequest!);
      }
      if (_onDelete != null) {
        kit.onSessionDelete.unsubscribe(_onDelete!);
      }
    }
    _kit = null;
    _ready = false;
    await _pairings.close();
    await _proposals.close();
    await _requests.close();
  }
}

WalletConnectService createWalletConnectService() {
  if (kWalletConnectProjectId.isEmpty) {
    return StubWalletConnectService();
  }
  return ReownWalletConnectService();
}
