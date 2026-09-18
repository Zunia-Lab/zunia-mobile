import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/config/connect_config.dart';

/// First-party zunia.connect.v1 WebSocket wallet peer.
class NativeConnectService {
  NativeConnectService();

  WebSocket? _ws;
  String? _sessionId;
  NativeSessionInfo? _sessionInfo;
  Timer? _pingTimer;

  final _connectRequests = StreamController<NativeConnectRequest>.broadcast();
  final _signRequests = StreamController<NativeSignRequest>.broadcast();
  final _sessionsChanged = StreamController<void>.broadcast();

  final List<NativeActiveSession> _active = [];

  Stream<NativeConnectRequest> get pendingConnectRequests =>
      _connectRequests.stream;

  Stream<NativeSignRequest> get pendingSignRequests => _signRequests.stream;

  Stream<void> get sessionsChanged => _sessionsChanged.stream;

  List<NativeActiveSession> get activeSessions =>
      List.unmodifiable(_active);

  bool get isConnected =>
      _ws != null && _ws!.readyState == WebSocket.open;

  String? get currentSessionId => _sessionId;

  NativeSessionInfo? get currentSessionInfo => _sessionInfo;

  /// Parse `zunia://connect?sid=&k=` or https universal links.
  static NativePairingCredentials? parseConnectLink(Uri uri) {
    final isCustom = kCustomUrlSchemes.contains(uri.scheme) &&
        (uri.host == 'connect' || uri.pathSegments.contains('connect'));
    final isHttps = uri.scheme == 'https' &&
        kUniversalLinkHosts.contains(uri.host) &&
        uri.path.startsWith('/connect');
    if (!isCustom && !isHttps) return null;

    final sid = uri.queryParameters['sid'] ?? uri.queryParameters['sessionId'];
    final k = uri.queryParameters['k'] ??
        uri.queryParameters['token'] ??
        uri.queryParameters['pairingSecret'];
    if (sid == null || sid.isEmpty || k == null || k.isEmpty) return null;
    return NativePairingCredentials(sessionId: sid, pairingSecret: k);
  }

  /// Connect as role=wallet and wait for connect_request / signing.
  Future<NativeSessionInfo> connectFromDeepLink(Uri uri) async {
    final creds = parseConnectLink(uri);
    if (creds == null) {
      throw FormatException('Not a Zunia connect link: $uri');
    }
    return connect(
      sessionId: creds.sessionId,
      pairingSecret: creds.pairingSecret,
    );
  }

  Future<NativeSessionInfo> connect({
    required String sessionId,
    required String pairingSecret,
  }) async {
    await disconnect(reason: 'replaced');

    _sessionId = sessionId;

    final info = await _fetchSession(sessionId);
    _sessionInfo = info;

    final wsUrl = connectWalletWsUrl(
      sessionId: sessionId,
      pairingSecret: pairingSecret,
    );
    debugPrint('NativeConnectService connecting $wsUrl');

    final ws = await WebSocket.connect(wsUrl);
    _ws = ws;

    ws.listen(
      _onMessage,
      onError: (Object e) {
        debugPrint('NativeConnectService ws error: $e');
      },
      onDone: () {
        debugPrint('NativeConnectService ws closed');
        _pingTimer?.cancel();
        _ws = null;
        _removeActive(sessionId);
      },
      cancelOnError: false,
    );

    _send('hello', {
      'role': 'wallet',
      'client': 'zunia-mobile',
      'metadata': {
        'name': kWalletName,
        'url': kWalletUrl,
        'icons': [kWalletIconUrl],
      },
    });

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (isConnected) _send('ping', {});
    });

    // Surface metadata so UI can approve even if connect_request races.
    if (!_connectRequests.isClosed) {
      _connectRequests.add(
        NativeConnectRequest(
          sessionId: sessionId,
          origin: info.metadata.url,
          metadata: info.metadata,
          chains: info.chains,
          methods: info.methods,
          events: info.events,
        ),
      );
    }

    return info;
  }

  Future<NativeSessionInfo> _fetchSession(String sessionId) async {
    final url = connectSessionHttpUrl(sessionId);
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 404) {
        throw StateError('Connect session not found or expired');
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('Session lookup failed (${res.statusCode}): $body');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final meta = json['metadata'] as Map<String, dynamic>? ?? {};
      return NativeSessionInfo(
        sessionId: sessionId,
        expiresAt: (json['expiresAt'] as num?)?.toInt() ?? 0,
        metadata: NativeDappMetadata(
          name: (meta['name'] as String?) ?? 'dApp',
          url: (meta['url'] as String?) ?? '',
          description: meta['description'] as String?,
          icons: (meta['icons'] as List?)?.cast<String>() ?? const [],
        ),
        chains: (json['chains'] as List?)?.cast<String>() ?? const [],
        methods: (json['methods'] as List?)?.cast<String>() ?? const [],
        events: (json['events'] as List?)?.cast<String>() ?? const [],
        approved: json['approved'] == true,
      );
    } finally {
      client.close(force: true);
    }
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> envelope;
    try {
      final text = raw is String
          ? raw
          : utf8.decode(raw is List<int> ? raw : (raw as List).cast<int>());
      envelope = jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('NativeConnectService bad frame: $e');
      return;
    }

    final type = envelope['type'] as String? ?? '';
    final id = envelope['id'] as String?;
    final payload = envelope['payload'];
    final map = payload is Map
        ? Map<String, dynamic>.from(payload)
        : <String, dynamic>{};

    switch (type) {
      case 'hello_ok':
      case 'pong':
      case 'error':
        if (type == 'error') {
          debugPrint('NativeConnectService error: $map');
        }
        break;
      case 'connect_request':
        final meta = map['metadata'] is Map
            ? Map<String, dynamic>.from(map['metadata'] as Map)
            : <String, dynamic>{};
        final req = NativeConnectRequest(
          sessionId: _sessionId ?? '',
          origin: (map['origin'] as String?) ??
              (meta['url'] as String?) ??
              '',
          metadata: NativeDappMetadata(
            name: (meta['name'] as String?) ?? 'dApp',
            url: (meta['url'] as String?) ?? '',
            description: meta['description'] as String?,
            icons: (meta['icons'] as List?)?.cast<String>() ?? const [],
          ),
          chains: (map['chains'] as List?)?.cast<String>() ?? const [],
          methods: (map['methods'] as List?)?.cast<String>() ?? const [],
          events: (map['events'] as List?)?.cast<String>() ?? const [],
          requestId: id,
        );
        _sessionInfo = NativeSessionInfo(
          sessionId: req.sessionId,
          expiresAt: _sessionInfo?.expiresAt ?? 0,
          metadata: req.metadata,
          chains: req.chains,
          methods: req.methods,
          events: req.events,
          approved: false,
        );
        if (!_connectRequests.isClosed) _connectRequests.add(req);
        break;
      case 'sign_amino':
      case 'sign_direct':
      case 'sign_arbitrary':
        if (!_signRequests.isClosed) {
          _signRequests.add(
            NativeSignRequest(
              type: type,
              id: id ?? '',
              chainId: (map['chainId'] as String?) ?? '',
              signer: (map['signer'] as String?) ?? '',
              payload: map,
              sessionId: _sessionId ?? '',
            ),
          );
        }
        break;
      case 'disconnect':
        final sid = _sessionId;
        if (sid != null) _removeActive(sid);
        break;
      default:
        break;
    }
  }

  void _send(String type, Map<String, dynamic> payload, {String? id}) {
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.open) {
      throw StateError('Native connect WebSocket is not open');
    }
    final envelope = <String, dynamic>{
      'v': kConnectProtocolVersion,
      'type': type,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'payload': payload,
    };
    if (id != null) envelope['id'] = id;
    ws.add(jsonEncode(envelope));
  }

  /// Approve the open pairing with wallet accounts.
  Future<void> approveConnect({
    required List<NativeConnectAccount> accounts,
    List<String>? chains,
    int? sessionExpiresAt,
  }) async {
    final expires = sessionExpiresAt ??
        DateTime.now()
            .add(const Duration(seconds: kConnectPairedTtlSeconds))
            .millisecondsSinceEpoch;
    final chainIds = chains ??
        accounts.map((a) => a.chainId).toSet().toList();
    _send('connect_approve', {
      'accounts': accounts.map((a) => a.toJson()).toList(),
      'chains': chainIds,
      'sessionExpiresAt': expires,
    });

    final info = _sessionInfo;
    final sid = _sessionId;
    if (sid != null && info != null) {
      _upsertActive(
        NativeActiveSession(
          sessionId: sid,
          name: info.metadata.name,
          url: info.metadata.url,
          icons: info.metadata.icons,
          chains: chainIds,
          accounts: accounts,
        ),
      );
    }
  }

  Future<void> rejectConnect({String reason = 'User rejected'}) async {
    try {
      _send('connect_reject', {'reason': reason});
    } catch (_) {}
    await disconnect(reason: reason);
  }

  /// Reply to a pending sign request after UI / kernel signing.
  Future<void> respondSignResult({
    required String requestId,
    required Map<String, dynamic> result,
  }) async {
    _send('sign_result', result, id: requestId);
  }

  Future<void> respondSignReject({
    required String requestId,
    String reason = 'User rejected',
    String? code,
  }) async {
    _send(
      'sign_reject',
      {
        'reason': reason,
        'code': ?code,
      },
      id: requestId,
    );
  }

  Future<void> disconnect({String reason = 'user'}) async {
    _pingTimer?.cancel();
    _pingTimer = null;
    final sid = _sessionId;
    final ws = _ws;
    if (ws != null) {
      try {
        if (ws.readyState == WebSocket.open) {
          _send('disconnect', {'reason': reason});
        }
      } catch (_) {}
      try {
        await ws.close();
      } catch (_) {}
    }
    _ws = null;
    if (sid != null) {
      _removeActive(sid);
      // Best-effort HTTP teardown.
      try {
        final client = HttpClient();
        final req = await client.deleteUrl(
          Uri.parse(connectSessionHttpUrl(sid)),
        );
        await req.close();
        client.close(force: true);
      } catch (_) {}
    }
    _sessionId = null;
    _sessionInfo = null;
  }

  Future<void> disconnectSession(String sessionId) async {
    if (_sessionId == sessionId) {
      await disconnect(reason: 'user');
      return;
    }
    _removeActive(sessionId);
  }

  Future<void> disconnectAll() async {
    await disconnect(reason: 'disconnect_all');
    _active.clear();
    _notifySessions();
  }

  void _upsertActive(NativeActiveSession session) {
    _active.removeWhere((s) => s.sessionId == session.sessionId);
    _active.add(session);
    _notifySessions();
  }

  void _removeActive(String sessionId) {
    final before = _active.length;
    _active.removeWhere((s) => s.sessionId == sessionId);
    if (_active.length != before) _notifySessions();
  }

  void _notifySessions() {
    if (!_sessionsChanged.isClosed) _sessionsChanged.add(null);
  }

  Future<void> dispose() async {
    await disconnectAll();
    await _connectRequests.close();
    await _signRequests.close();
    await _sessionsChanged.close();
  }
}

class NativePairingCredentials {
  const NativePairingCredentials({
    required this.sessionId,
    required this.pairingSecret,
  });

  final String sessionId;
  final String pairingSecret;
}

class NativeDappMetadata {
  const NativeDappMetadata({
    required this.name,
    required this.url,
    this.description,
    this.icons = const [],
  });

  final String name;
  final String url;
  final String? description;
  final List<String> icons;
}

class NativeSessionInfo {
  const NativeSessionInfo({
    required this.sessionId,
    required this.expiresAt,
    required this.metadata,
    required this.chains,
    required this.methods,
    required this.events,
    required this.approved,
  });

  final String sessionId;
  final int expiresAt;
  final NativeDappMetadata metadata;
  final List<String> chains;
  final List<String> methods;
  final List<String> events;
  final bool approved;
}

class NativeConnectRequest {
  const NativeConnectRequest({
    required this.sessionId,
    required this.origin,
    required this.metadata,
    required this.chains,
    required this.methods,
    required this.events,
    this.requestId,
  });

  final String sessionId;
  final String origin;
  final NativeDappMetadata metadata;
  final List<String> chains;
  final List<String> methods;
  final List<String> events;
  final String? requestId;
}

class NativeConnectAccount {
  const NativeConnectAccount({
    required this.chainId,
    required this.address,
    required this.algo,
    required this.pubkey,
    this.name,
  });

  final String chainId;
  final String address;
  final String algo;
  final String pubkey;
  final String? name;

  Map<String, dynamic> toJson() => {
        'chainId': chainId,
        'address': address,
        'algo': algo,
        'pubkey': pubkey,
        if (name != null) 'name': name,
      };
}

class NativeSignRequest {
  const NativeSignRequest({
    required this.type,
    required this.id,
    required this.chainId,
    required this.signer,
    required this.payload,
    required this.sessionId,
  });

  /// `sign_amino` | `sign_direct` | `sign_arbitrary`
  final String type;
  final String id;
  final String chainId;
  final String signer;
  final Map<String, dynamic> payload;
  final String sessionId;
}

class NativeActiveSession {
  const NativeActiveSession({
    required this.sessionId,
    required this.name,
    required this.url,
    this.icons = const [],
    this.chains = const [],
    this.accounts = const [],
  });

  final String sessionId;
  final String name;
  final String url;
  final List<String> icons;
  final List<String> chains;
  final List<NativeConnectAccount> accounts;
}
