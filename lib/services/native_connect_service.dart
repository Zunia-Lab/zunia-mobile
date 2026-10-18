/// The wallet side of zunia.connect.v2: pairs with dApps through the relay,
/// opens their encrypted requests, and answers once the user decides.
///
/// The relay only routes; it never sees keys, accounts or what is signed.
/// What the wallet checks on its own:
/// - the origin a trusted relay saw when the site created the session
///   ([NativeDappIdentity.verifiedOrigin]), against the site the dApp claims
///   to be;
/// - the 6-digit code, the same on both screens unless keys were swapped;
/// - sign-in messages, which must name the verified origin, the chain and the
///   account the request came with.
///
/// The same queue also holds requests that arrived another way (WalletConnect)
/// through [NativeConnectService.adopt], so the user answers everything one
/// sheet at a time, oldest first.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_mobile/config/connect_config.dart';
import 'package:zunia_mobile/connect/app_return.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/connect/pairing_uri.dart';
import 'package:zunia_mobile/connect/sign_in.dart';
import 'package:zunia_mobile/services/connect_session_store.dart';

typedef ConnectSocketFactory = Future<WebSocket> Function(
  Uri url,
  List<String> protocols,
);

/// Opens a return target in the app that owns it. True when one did.
typedef ReturnLauncher = Future<bool> Function(Uri url);

Future<WebSocket> _openSocket(Uri url, List<String> protocols) {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  return WebSocket.connect(
    url.toString(),
    protocols: protocols,
    customClient: client,
  );
}

Future<bool> _launchExternal(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// The relay closes a socket (code 1009) that sends a larger frame.
const int kRelayMaxFrameBytes = 512 * 1024;

final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _chainIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
final _hidden = RegExp(r'[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', unicode: true);

const _maxArbitraryLength = 128 * 1024;
const _maxPendingPerSession = 16;
const _maxUnacked = 64;

/// What the extension says when a prompt runs out; the SDK reads this exact
/// wording as a timeout rather than a refusal.
const _expiredPayload = {
  'code': 'USER_REJECTED',
  'message': 'Request expired before it was answered',
};

/// dart:io keeps reporting `open` after a close starts, until the peer
/// answers, so a write can still fail.
bool _write(WebSocket? socket, String data) {
  if (socket == null || socket.readyState != WebSocket.open) return false;
  try {
    socket.add(data);
    return true;
  } on StateError {
    return false;
  }
}

List<String> _strings(Object? value) =>
    value is List ? [for (final v in value) if (v is String) v] : const [];

String? _utf8OrNull(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// Length of `{"t":"msg","n":<16>,"c":<base64url(plaintext + tag)>}`.
int _sealedFrameLength(int plaintextBytes) =>
    41 + ((plaintextBytes + 16) * 4 + 2) ~/ 3;

/// The largest signature a `result` can carry: an Ethermint key type name
/// and a 65-byte signature, so the estimate errs on the large side.
const _largestSignature = {
  'pub_key': {
    'type': 'ethermint/PubKeyEthSecp256k1____________',
    'value': '____________________________________________',
  },
  'signature':
      '____________________________________________________________________________________________',
};

/// What a site says about itself in its connect request. Unverified.
class NativeDappMetadata {
  const NativeDappMetadata({
    required this.name,
    required this.url,
    this.description,
    this.icons = const [],
  });

  factory NativeDappMetadata.fromWire(Object? value) {
    final map = value is Map ? value : const <String, Object?>{};
    String? text(Object? raw, int max) {
      if (raw is! String) return null;
      final clean = raw.replaceAll(_hidden, '').trim();
      if (clean.isEmpty) return null;
      return clean.length > max ? clean.substring(0, max) : clean;
    }

    final icons = map['icons'];
    return NativeDappMetadata(
      name: text(map['name'], 80) ?? 'Unknown site',
      url: text(map['url'], 512) ?? '',
      description: text(map['description'], 300),
      icons: [
        if (icons is List)
          for (final icon in icons.take(4))
            if (icon is String && icon.startsWith('https://') && icon.length <= 1024)
              icon,
      ],
    );
  }

  static const unknown = NativeDappMetadata(name: 'Unknown site', url: '');

  final String name;
  final String url;
  final String? description;
  final List<String> icons;

  Map<String, Object?> toJson() => {
        'name': name,
        'url': url,
        'description': ?description,
        'icons': icons,
      };
}

/// Who is on the other end of a session.
class NativeDappIdentity {
  const NativeDappIdentity({
    required this.metadata,
    required this.verifiedOrigin,
    required this.relay,
  });

  final NativeDappMetadata metadata;

  /// Origin of the page that created the session, as the relay saw it in the
  /// `Origin` header (WalletConnect: as its Verify API attested it). Null when
  /// nothing confirmed it.
  final String? verifiedOrigin;

  final String relay;

  String? get declaredOrigin => webOrigin(metadata.url);

  /// The site claims to be somewhere other than where the relay saw it.
  bool get originMismatch =>
      verifiedOrigin != null &&
      declaredOrigin != null &&
      declaredOrigin != verifiedOrigin;

  /// What to call the site: the verified host when there is one.
  String get host {
    final verified = verifiedOrigin;
    if (verified != null) return webHost(verified) ?? verified;
    final declared = declaredOrigin;
    if (declared != null) return webHost(declared) ?? declared;
    return metadata.name;
  }
}

class NativeConnectAccount {
  const NativeConnectAccount({
    required this.chainId,
    required this.address,
    required this.pubKey,
    this.algo = 'secp256k1',
    this.name,
  });

  factory NativeConnectAccount.fromJson(Map<String, dynamic> json) =>
      NativeConnectAccount(
        chainId: json['chainId'] as String,
        address: json['address'] as String,
        pubKey: json['pubKey'] as String,
        algo: json['algo'] as String? ?? 'secp256k1',
        name: json['name'] as String?,
      );

  final String chainId;
  final String address;

  /// Compressed public key, base64.
  final String pubKey;
  final String algo;
  final String? name;

  Map<String, Object?> toJson() => {
        'chainId': chainId,
        'address': address,
        'algo': algo,
        'pubKey': pubKey,
        'name': ?name,
      };

  @override
  bool operator ==(Object other) =>
      other is NativeConnectAccount &&
      other.chainId == chainId &&
      other.address == address &&
      other.pubKey == pubKey &&
      other.algo == algo &&
      other.name == name;

  @override
  int get hashCode => Object.hash(chainId, address, pubKey, algo, name);
}

/// How a request reached the wallet.
enum ConnectTransport { zuniaConnect, walletConnect }

/// Something a site asked for and the user has to decide.
sealed class NativeRequest {
  NativeRequest({
    required this.sessionId,
    required this.id,
    required this.dapp,
    required this.receivedAt,
    this.transport = ConnectTransport.zuniaConnect,
    this.returnTarget,
  });

  final String sessionId;
  final String id;
  final NativeDappIdentity dapp;
  final DateTime receivedAt;
  final ConnectTransport transport;

  /// Where answering takes the user: set when the site or app opened Zunia
  /// on this phone and named a way back.
  final ReturnTarget? returnTarget;

  String get transportLabel => switch (transport) {
        ConnectTransport.zuniaConnect => 'Zunia Connect, end-to-end encrypted',
        ConnectTransport.walletConnect => 'WalletConnect v2',
      };

  /// `Return to app.example.com`, for the sheet.
  String? get returnLabel => returnTarget?.prompt;
}

final class NativeConnectRequest extends NativeRequest {
  NativeConnectRequest({
    required super.sessionId,
    required super.id,
    required super.dapp,
    required super.receivedAt,
    required this.chains,
    required this.methods,
    required this.events,
    required this.verificationCode,
    super.transport,
    super.returnTarget,
    this.requiredChains = const [],
  });

  final List<String> chains;
  final List<String> methods;
  final List<String> events;

  /// Chains the site cannot work without (WalletConnect required namespaces).
  final List<String> requiredChains;

  /// Also on the site's screen; different digits mean someone is in between.
  /// Empty for WalletConnect, which has no such code.
  final String verificationCode;

  String get expiryLabel => switch (transport) {
        ConnectTransport.zuniaConnect => '24 hours after approval',
        ConnectTransport.walletConnect => '7 days after approval',
      };
}

enum NativeSignKind { amino, direct, message, signIn }

final class NativeSignRequest extends NativeRequest {
  NativeSignRequest({
    required super.sessionId,
    required super.id,
    required super.dapp,
    required super.receivedAt,
    required this.kind,
    required this.chainId,
    required this.signer,
    required this.accountIndex,
    super.transport,
    super.returnTarget,
    this.aminoDoc,
    this.directDoc,
    this.data,
    this.signIn,
  });

  final NativeSignKind kind;
  final String chainId;
  final String signer;

  /// Wallet account the signer belonged to when the request arrived.
  final int accountIndex;

  final Map<String, dynamic>? aminoDoc;
  final DirectSignDoc? directDoc;
  final Uint8List? data;
  final SignInMessage? signIn;

  /// The message as text, when it is valid UTF-8.
  String? get text {
    final bytes = data;
    return bytes == null ? null : _utf8OrNull(bytes);
  }
}

class NativeActiveSession {
  const NativeActiveSession({
    required this.sessionId,
    required this.dapp,
    required this.chains,
    required this.accounts,
    required this.online,
    required this.expiresAt,
    this.requestedChains = const [],
    this.pairedAt,
    this.sameDevice = false,
    this.returnTarget,
  });

  final String sessionId;
  final NativeDappIdentity dapp;

  /// Chains the site may use now.
  final List<String> chains;

  /// Chains the site asked for; the user can turn any of them back on.
  final List<String> requestedChains;
  final List<NativeConnectAccount> accounts;

  /// The site's side is connected to the relay right now.
  final bool online;
  final DateTime expiresAt;
  final DateTime? pairedAt;

  /// Paired from a link opened on this phone, not a scanned code.
  final bool sameDevice;
  final ReturnTarget? returnTarget;

  String get name => dapp.metadata.name;
  String get url => dapp.verifiedOrigin ?? dapp.metadata.url;
  List<String> get icons => dapp.metadata.icons;
}

class NativeConnectNotice {
  const NativeConnectNotice(this.message, {this.error = false, this.returnTarget});

  final String message;
  final bool error;

  /// Offer a "Return" button that opens this, when the user may want to go
  /// back to the site but did not arrive from it just now.
  final ReturnTarget? returnTarget;
}

/// Answers a request that came another way than Zunia Connect.
abstract interface class ForeignRequestAnswers {
  Future<void> approveConnect(
    NativeConnectRequest request, {
    required List<NativeConnectAccount> accounts,
    required int accountIndex,
  });

  Future<void> rejectConnect(NativeConnectRequest request);

  Future<void> approveSign(NativeSignRequest request, Map<String, Object?> result);

  Future<void> rejectSign(
    NativeSignRequest request, {
    required String code,
    required String message,
  });

  /// Nobody answered within the request lifetime.
  Future<void> expire(NativeRequest request);
}

class NativeConnectService {
  NativeConnectService({
    ConnectSessionStore? store,
    RelayPolicy? relayPolicy,
    ConnectSocketFactory? socketFactory,
    HttpClient Function()? httpClient,
    DateTime Function()? clock,
    ReturnLauncher? launcher,
    this.walletName = kWalletName,
    this.heartbeat = const Duration(seconds: 20),
    this.deadAfter = const Duration(seconds: 45),
    this.reconnectMin = const Duration(seconds: 1),
    this.reconnectMax = const Duration(seconds: 30),
    this.pairingTimeout = const Duration(seconds: 30),
    this.probeTimeout = const Duration(seconds: 3),
    this.requestLifetime = const Duration(minutes: 5),
    this.maxFrameBytes = kRelayMaxFrameBytes,
  })  : _store = store ?? MemoryConnectSessionStore(),
        _policy = relayPolicy ?? connectRelayPolicy(),
        _socket = socketFactory ?? _openSocket,
        _http = httpClient ?? HttpClient.new,
        _now = clock ?? DateTime.now,
        _launch = launcher ?? _launchExternal;

  final ConnectSessionStore _store;
  final RelayPolicy _policy;
  final ConnectSocketFactory _socket;
  final HttpClient Function() _http;
  final DateTime Function() _now;
  final ReturnLauncher _launch;
  final String walletName;
  final Duration heartbeat;
  final Duration deadAfter;
  final Duration reconnectMin;
  final Duration reconnectMax;
  final Duration pairingTimeout;

  /// How long a ping on resume or wake may go unanswered before the socket
  /// is replaced.
  final Duration probeTimeout;

  /// The SDK stops waiting for an answer after five minutes; the wallet tells
  /// it when a request ran out rather than leaving it to guess.
  final Duration requestLifetime;

  /// The relay's frame limit. Answers that would not fit are replaced by an
  /// error before they are queued, so they never loop through reconnects.
  final int maxFrameBytes;

  final Map<String, _Session> _sessions = {};
  final List<NativeRequest> _pending = [];
  final Map<NativeRequest, ForeignRequestAnswers> _foreign = {};

  /// Sessions whose link brought Zunia to the front for what waits now:
  /// answering their last request goes straight back to the site or app.
  final Set<String> _armed = {};
  final _changes = StreamController<void>.broadcast();
  final _notices = StreamController<NativeConnectNotice>.broadcast();
  final _random = Random();
  Future<void> _queue = Future.value();
  Timer? _expiryTimer;
  bool _restored = false;
  bool _disposed = false;

  /// Fires when [pendingRequests] or [activeSessions] change.
  Stream<void> get changes => _changes.stream;

  /// Things to tell the user: a site disconnected, pairing failed.
  Stream<NativeConnectNotice> get notices => _notices.stream;

  /// Oldest first. The UI shows them one at a time. Requests past their
  /// lifetime are answered as expired before the list is returned.
  List<NativeRequest> get pendingRequests {
    _expireDue();
    return List.unmodifiable(_pending);
  }

  bool isPending(NativeRequest request) => _pending.contains(request);

  /// Came another way than Zunia Connect ([adopt]).
  bool isForeign(NativeRequest request) => _foreign.containsKey(request);

  List<NativeActiveSession> get activeSessions => [
        for (final s in _sessions.values)
          if (s.approved && !s.ended) s.view(),
      ];

  NativeActiveSession? session(String sessionId) {
    final s = _sessions[sessionId];
    return s == null || !s.approved || s.ended ? null : s.view();
  }

  static bool isPairingLink(String value) => parsePairingUri(value) != null;

  /// Starts pairing from a scanned or opened link. Completes once the site's
  /// connect request is waiting in [pendingRequests]. Throws
  /// [ConnectException] when the link, the relay or the site is not usable.
  ///
  /// [sameDevice]: the link was opened on this phone (a deep link or app
  /// link), so its `ret` target is where answering takes the user.
  Future<NativeConnectRequest> pair(String link, {bool sameDevice = false}) async {
    final uri = parsePairingUri(link);
    if (uri == null) {
      throw const ConnectException(
        'INVALID_PARAMS',
        'This is not a Zunia pairing code',
      );
    }
    if (!_policy.trusts(uri.relay)) {
      throw ConnectException(
        'UNTRUSTED_RELAY',
        'This code uses a relay Zunia does not trust (${uri.relayUri.host}), '
            'so pairing did not start',
      );
    }
    if (_sessions.containsKey(uri.sessionId)) {
      throw const ConnectException(
        'ALREADY_PAIRED',
        'This code was already scanned',
      );
    }
    final keyPair = await ConnectKeyPair.generate();
    final Uint8List dappKey;
    try {
      dappKey = base64UrlToBytes(uri.dappPublicKey);
    } on FormatException {
      throw const ConnectException('INVALID_PARAMS', 'The pairing code is damaged');
    }
    final keys = await deriveConnectKeys(
      role: ConnectRole.wallet,
      sessionId: uri.sessionId,
      own: keyPair,
      peerPublicKey: dappKey,
    );
    final session = _Session(
      sessionId: uri.sessionId,
      relay: uri.relay,
      keys: keys,
      joinToken: uri.joinToken,
      keyPair: keyPair,
    )
      ..sameDevice = sameDevice
      ..returnTarget = uri.returnTarget;
    final request = Completer<NativeConnectRequest>();
    session.pairing = request;
    _sessions[uri.sessionId] = session;
    if (sameDevice) _armed.add(uri.sessionId);
    try {
      await _open(session);
    } catch (_) {
      _end(session, reason: 'unreachable');
    }
    return request.future.timeout(
      pairingTimeout,
      onTimeout: () {
        unawaited(_close(session));
        throw const ConnectException(
          'TIMEOUT',
          'The site did not answer. Ask it for a new code and try again.',
        );
      },
    );
  }

  /// A wake link for [sessionId] arrived: bring its socket up now so what the
  /// site sent shows at once. Returns false, and does nothing, for a session
  /// this phone does not have; a wake link never pairs anything.
  bool wake(String sessionId) {
    final s = _sessions[sessionId];
    if (s == null || s.ended) return false;
    if (s.sameDevice) _armed.add(sessionId);
    _reopenNow(s);
    _notify();
    return true;
  }

  /// [key] is a request's [NativeRequest.sessionId] whose link brought the
  /// app to the front (WalletConnect uses this for its own sessions).
  void armReturn(String key) => _armed.add(key);

  /// The app went to the background: a later answer was not prompted by a
  /// link, so it should not jump to another app.
  void onBackground() => _armed.clear();

  /// Shows [error] to the user, for failures the caller does not display itself.
  void reportError(Object error) {
    final message = error is ConnectException
        ? error.message
        : 'Pairing failed. Ask the site for a new code.';
    _notice(NativeConnectNotice(message, error: true));
  }

  /// Queues a request that arrived another way (WalletConnect), answered
  /// through [answers] when the user decides.
  void adopt(NativeRequest request, ForeignRequestAnswers answers) {
    if (_disposed || _pending.contains(request)) return;
    _pending.add(request);
    _foreign[request] = answers;
    _scheduleExpiry();
    _notify();
  }

  /// Drops foreign requests the other side withdrew or that can no longer be
  /// answered (session deleted, proposal expired).
  void withdraw(bool Function(NativeRequest request) test) {
    final gone = [for (final r in _pending) if (_foreign.containsKey(r) && test(r)) r];
    if (gone.isEmpty) return;
    for (final r in gone) {
      _pending.remove(r);
      _foreign.remove(r);
    }
    _scheduleExpiry();
    _notify();
  }

  Future<void> approveConnect(
    NativeConnectRequest request, {
    required List<NativeConnectAccount> accounts,
    required int accountIndex,
  }) async {
    final foreign = _foreign[request];
    if (foreign != null) {
      _requirePending(request);
      // Kept open on failure, so the user can still reject.
      await foreign.approveConnect(
        request,
        accounts: accounts,
        accountIndex: accountIndex,
      );
      _settle(request);
      _afterAnswer(request);
      return;
    }
    final s = _live(request);
    final chains = [
      for (final chain in request.chains)
        if (accounts.any((a) => a.chainId == chain)) chain,
    ];
    if (chains.isEmpty) {
      throw const ConnectException(
        'UNKNOWN_CHAIN',
        'Zunia has no account on the chains this site asked for',
      );
    }
    _pending.remove(request);
    _scheduleExpiry();
    s.approved = true;
    s.requestedChains = List.of(request.chains);
    s.chains = chains;
    s.accounts = [for (final a in accounts) if (chains.contains(a.chainId)) a];
    s.accountIndex = accountIndex;
    s.pairedAt = _now().millisecondsSinceEpoch;
    s.keyPair = null;
    await _reply(
      s,
      'connect_approve',
      id: request.id,
      payload: {
        'accounts': [for (final a in s.accounts) a.toJson()],
        'chains': chains,
        'wallet': {'name': walletName},
      },
    );
    _control(s, const {'t': 'paired'});
    _notify();
    _afterAnswer(request);
  }

  Future<void> rejectConnect(NativeConnectRequest request) async {
    final foreign = _foreign[request];
    if (foreign != null) {
      _settle(request);
      try {
        await foreign.rejectConnect(request);
      } catch (error) {
        developer.log('Could not reject: $error', name: 'zunia.connect');
      }
      _afterAnswer(request);
      return;
    }
    _pending.remove(request);
    _scheduleExpiry();
    final s = _sessions[request.sessionId];
    if (s == null || s.ended) {
      _notify();
      return;
    }
    await _reply(
      s,
      'connect_reject',
      id: request.id,
      payload: const {'code': 'USER_REJECTED', 'message': 'The user declined'},
    );
    _afterAnswer(request);
    await _close(s);
  }

  Future<void> approveSign(
    NativeSignRequest request,
    Map<String, Object?> result,
  ) async {
    final foreign = _foreign[request];
    if (foreign != null) {
      _requirePending(request);
      await foreign.approveSign(request, result);
      _settle(request);
      _afterAnswer(request);
      return;
    }
    final s = _live(request);
    _pending.remove(request);
    _scheduleExpiry();
    _notify();
    await _reply(s, 'result', id: request.id, payload: result);
    _afterAnswer(request);
  }

  Future<void> rejectSign(
    NativeSignRequest request, {
    String code = 'USER_REJECTED',
    String message = 'The user declined',
  }) async {
    final foreign = _foreign[request];
    if (foreign != null) {
      _settle(request);
      try {
        await foreign.rejectSign(request, code: code, message: message);
      } catch (error) {
        developer.log('Could not reject: $error', name: 'zunia.connect');
      }
      _afterAnswer(request);
      return;
    }
    _pending.remove(request);
    _scheduleExpiry();
    _notify();
    final s = _sessions[request.sessionId];
    if (s == null || s.ended) return;
    await _reply(
      s,
      'error',
      id: request.id,
      payload: {'code': code, 'message': message},
    );
    _afterAnswer(request);
  }

  /// Moves every approved site to another wallet account. [accountsFor]
  /// derives that account on the chains a session shares.
  Future<void> switchAccount({
    required int accountIndex,
    required List<NativeConnectAccount> Function(List<String> chainIds) accountsFor,
  }) async {
    for (final s in _sessions.values.toList()) {
      if (!s.approved || s.ended) continue;
      final next = accountsFor(s.chains);
      if (s.accountIndex == accountIndex && _sameAccounts(next, s.accounts)) {
        continue;
      }
      s.accounts = next;
      s.accountIndex = accountIndex;
      await _reply(
        s,
        'accounts_changed',
        payload: {
          'accounts': [for (final a in next) a.toJson()],
        },
      );
    }
    _notify();
  }

  /// Limits what a site may use to [chains], a non-empty subset of the
  /// chains it asked for, and tells it (`chains_changed`, then
  /// `accounts_changed` when a chain came back). [accountsFor] derives the
  /// accounts on chains being turned back on.
  Future<void> setSessionChains(
    String sessionId,
    List<String> chains, {
    List<NativeConnectAccount> Function(List<String> chainIds)? accountsFor,
  }) async {
    final s = _sessions[sessionId];
    if (s == null || !s.approved || s.ended) {
      throw const ConnectException('NOT_CONNECTED', 'This site is no longer connected');
    }
    final next = [
      for (final chain in s.requestedChains)
        if (chains.contains(chain)) chain,
    ];
    if (next.isEmpty) {
      throw const ConnectException(
        'INVALID_PARAMS',
        'Keep at least one chain, or disconnect the site',
      );
    }
    final added = [for (final c in next) if (!s.chains.contains(c)) c];
    var accounts = [for (final a in s.accounts) if (next.contains(a.chainId)) a];
    if (added.isNotEmpty) {
      final derived = accountsFor?.call(added) ?? const [];
      final usable = {for (final a in derived) if (added.contains(a.chainId)) a.chainId};
      next.removeWhere((c) => added.contains(c) && !usable.contains(c));
      accounts = [
        ...accounts,
        for (final a in derived) if (usable.contains(a.chainId)) a,
      ];
    }
    if (_sameStrings(next, s.chains)) return;
    final reallyAdded = added.where(next.contains).isNotEmpty;
    s.chains = next;
    s.accounts = accounts;
    // Requests for a chain the site lost cannot be signed any more.
    for (final r in _pending.toList()) {
      if (r is NativeSignRequest &&
          r.sessionId == sessionId &&
          !next.contains(r.chainId)) {
        _pending.remove(r);
        unawaited(_reply(
          s,
          'error',
          id: r.id,
          payload: {'code': 'UNKNOWN_CHAIN', 'message': '${r.chainId} is no longer part of this session'},
        ));
      }
    }
    _scheduleExpiry();
    await _reply(s, 'chains_changed', payload: {'chains': next});
    if (reallyAdded) {
      await _reply(
        s,
        'accounts_changed',
        payload: {
          'accounts': [for (final a in accounts) a.toJson()],
        },
      );
    }
    _notify();
  }

  Future<void> disconnectSession(String sessionId) async {
    final s = _sessions[sessionId];
    if (s != null) await _close(s);
  }

  Future<void> disconnectAll() async {
    for (final s in _sessions.values.toList()) {
      await _close(s);
    }
  }

  /// Reopens the sessions saved before the app last stopped.
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    List<Map<String, dynamic>> rows;
    try {
      rows = await _store.load();
    } catch (_) {
      rows = const [];
    }
    final now = _now().millisecondsSinceEpoch;
    for (final row in rows) {
      final s = _Session.fromJson(row);
      if (s == null ||
          s.expiresAt <= now ||
          !_policy.trusts(s.relay) ||
          _sessions.containsKey(s.sessionId)) {
        continue;
      }
      // A frame the relay refused for its size would be refused again.
      s.unacked.removeWhere((f) => f.data.length > maxFrameBytes);
      _sessions[s.sessionId] = s;
      unawaited(_reconnect(s));
    }
    // Rewrites older rows in the current layout.
    _save();
    _notify();
  }

  /// The app came back to the foreground: sockets may have died meanwhile,
  /// and requests may have run out.
  void resume() {
    for (final s in _sessions.values.toList()) {
      if (s.ended) continue;
      _reopenNow(s);
    }
    _expireDue();
  }

  /// Stops sockets and timers. Saved sessions stay saved.
  Future<void> dispose() async {
    _disposed = true;
    _expiryTimer?.cancel();
    for (final s in _sessions.values) {
      s.reconnectTimer?.cancel();
      s.heartbeatTimer?.cancel();
      s.probeTimer?.cancel();
      final socket = s.socket;
      s.socket = null;
      unawaited(s.subscription?.cancel());
      if (socket != null) unawaited(_quietClose(socket));
    }
    await _queue;
    await _changes.close();
    await _notices.close();
  }

  _Session _live(NativeRequest request) {
    final s = _sessions[request.sessionId];
    if (s == null || s.ended || !_pending.contains(request)) {
      throw const ConnectException(
        'NOT_CONNECTED',
        'This request is no longer open',
      );
    }
    return s;
  }

  void _requirePending(NativeRequest request) {
    if (!_pending.contains(request)) {
      throw const ConnectException(
        'NOT_CONNECTED',
        'This request is no longer open',
      );
    }
  }

  void _settle(NativeRequest request) {
    _pending.remove(request);
    _foreign.remove(request);
    _scheduleExpiry();
    _notify();
  }

  /// After the user answered: back to the site or app that opened Zunia for
  /// this, once nothing else from it waits. Only when a link brought Zunia to
  /// the front for it; otherwise the user was here already, and only hears
  /// that they can go back.
  void _afterAnswer(NativeRequest request) {
    final target = request.returnTarget;
    if (target == null || _disposed) return;
    if (_pending.any((r) => r.sessionId == request.sessionId)) return;
    if (_armed.remove(request.sessionId)) {
      unawaited(_openReturn(target));
    } else {
      _notice(NativeConnectNotice(
        'Done. You can go back to ${target.label}.',
        returnTarget: target,
      ));
    }
  }

  Future<void> _openReturn(ReturnTarget target) async {
    try {
      if (await _launch(target.uri)) return;
    } catch (error) {
      developer.log('Could not open the return link: $error', name: 'zunia.connect');
    }
    _notice(NativeConnectNotice(
      'Done. Switch back to ${target.label} to continue.',
    ));
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (_pending.isEmpty || _disposed) return;
    var oldest = _pending.first.receivedAt;
    for (final r in _pending) {
      if (r.receivedAt.isBefore(oldest)) oldest = r.receivedAt;
    }
    final due = oldest.add(requestLifetime).difference(_now());
    _expiryTimer = Timer(
      due.isNegative ? Duration.zero : due + const Duration(milliseconds: 1),
      _expireDue,
    );
  }

  /// Answers every request older than [requestLifetime] as expired.
  void _expireDue() {
    if (_disposed) return;
    final cutoff = _now().subtract(requestLifetime);
    final due = [for (final r in _pending) if (!r.receivedAt.isAfter(cutoff)) r];
    for (final request in due) {
      _pending.remove(request);
      final foreign = _foreign.remove(request);
      if (foreign != null) {
        unawaited(foreign.expire(request).catchError((Object error) {
          developer.log('Could not expire: $error', name: 'zunia.connect');
        }));
        continue;
      }
      final s = _sessions[request.sessionId];
      if (s == null || s.ended) continue;
      if (request is NativeConnectRequest) {
        unawaited(
          _reply(s, 'connect_reject', id: request.id, payload: _expiredPayload)
              .then((_) => _close(s)),
        );
      } else {
        unawaited(_reply(s, 'error', id: request.id, payload: _expiredPayload));
      }
    }
    if (due.isNotEmpty) _notify();
    _scheduleExpiry();
  }

  Future<void> _open(_Session s) async {
    if (s.ended || _disposed) return;
    final token = s.resumeToken ?? s.joinToken;
    if (token == null) {
      _end(s, reason: 'expired', notify: true);
      return;
    }
    s.reconnectTimer?.cancel();
    final socket = await _socket(
      relaySocketUri(s.relay, s.sessionId),
      [kConnectV2, 'zunia.token.$token'],
    );
    if (s.ended || _disposed) {
      unawaited(_quietClose(socket));
      return;
    }
    final previous = s.socket;
    if (previous != null && !identical(previous, socket)) {
      unawaited(s.subscription?.cancel());
      unawaited(_quietClose(previous));
    }
    s.socket = socket;
    s.lastFrameAt = _now();
    s.pingMark = null;
    s.welcomed = false;
    s.subscription = socket.listen(
      (data) => _onFrame(s, socket, data),
      onDone: () => _onClosed(s, socket),
      onError: (Object _) {},
      cancelOnError: false,
    );
    s.heartbeatTimer?.cancel();
    s.heartbeatTimer = Timer.periodic(heartbeat, (_) => _beat(s));
  }

  Future<void> _reconnect(_Session s) async {
    if (s.connecting) return;
    s.connecting = true;
    try {
      await _open(s);
    } catch (_) {
      _scheduleReconnect(s);
    } finally {
      s.connecting = false;
    }
  }

  void _scheduleReconnect(_Session s, {bool slow = false}) {
    if (s.ended || _disposed) return;
    if (s.expiresAt > 0 && s.expiresAt <= _now().millisecondsSinceEpoch) {
      _end(s, reason: 'expired', notify: true);
      return;
    }
    s.attempts += 1;
    var delay = reconnectMin * pow(2, min(s.attempts - 1, 10));
    if (delay > reconnectMax || slow) delay = reconnectMax;
    s.reconnectTimer?.cancel();
    s.reconnectTimer = Timer(
      delay * (0.8 + _random.nextDouble() * 0.4),
      () => _reconnect(s),
    );
  }

  /// Forgets the current socket without waiting for its close handshake,
  /// which never completes on a dead network, and reconnects.
  void _drop(_Session s) {
    final socket = s.socket;
    if (socket == null) return;
    s.socket = null;
    s.heartbeatTimer?.cancel();
    unawaited(s.subscription?.cancel());
    unawaited(_quietClose(socket));
    _scheduleReconnect(s);
  }

  /// Gets a live socket as soon as possible. Without one, it connects now
  /// rather than after the backoff. With one, it pings, and reconnects at
  /// once if nothing comes back within [probeTimeout] instead of waiting for
  /// the dead-link timeout: iOS freezes sockets in the background without
  /// closing them. A socket that answers is kept, so nothing the relay is
  /// delivering on it is lost.
  void _reopenNow(_Session s) {
    if (s.ended || _disposed) return;
    final socket = s.socket;
    if (socket == null) {
      s.reconnectTimer?.cancel();
      s.attempts = 0;
      unawaited(_reconnect(s));
      return;
    }
    final asked = _now();
    _write(socket, '{"t":"ping"}');
    s.probeTimer?.cancel();
    s.probeTimer = Timer(probeTimeout, () {
      if (s.ended || _disposed || !identical(s.socket, socket)) return;
      if (s.lastFrameAt.isAfter(asked)) return;
      s.socket = null;
      s.heartbeatTimer?.cancel();
      unawaited(s.subscription?.cancel());
      unawaited(_quietClose(socket));
      s.reconnectTimer?.cancel();
      s.attempts = 0;
      unawaited(_reconnect(s));
    });
  }

  void _beat(_Session s) {
    final socket = s.socket;
    if (socket == null) return;
    if (_now().difference(s.lastFrameAt) > deadAfter) {
      _drop(s);
      return;
    }
    // The relay handles a socket's frames in order, so its pong confirms
    // every frame written before the ping. Frames resent on welcome come
    // after it, which is why marking waits for the welcome.
    if (s.welcomed) s.pingMark ??= s.sentCount;
    _write(socket, '{"t":"ping"}');
  }

  void _onClosed(_Session s, WebSocket socket) {
    if (!identical(s.socket, socket)) return;
    s.socket = null;
    s.heartbeatTimer?.cancel();
    if (s.ended || _disposed) return;
    switch (socket.closeCode) {
      case 4001:
        _end(s, reason: 'closed', notify: true);
      case 4401:
        _end(s, reason: s.resumeToken == null ? 'used' : 'expired', notify: true);
      case 4000:
        _end(s, reason: 'replaced', notify: true);
      case 1009:
        // A frame was over the relay's limit, which is lower than this build
        // expected. Resending it would only close the next socket the same
        // way, so drop it, tell the site, and keep under that size from now.
        _onFrameRefused(s);
        if (s.resumeToken == null) {
          _end(s, reason: 'unreachable');
        } else {
          _scheduleReconnect(s);
        }
      default:
        if (s.resumeToken == null) {
          _end(s, reason: 'unreachable');
        } else {
          _scheduleReconnect(s, slow: socket.closeCode == 4008);
        }
    }
  }

  void _onFrame(_Session s, WebSocket socket, Object? data) {
    if (!identical(s.socket, socket) || s.ended) return;
    s.lastFrameAt = _now();
    if (data is! String) return;
    final Object? frame;
    try {
      frame = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (frame is! Map) return;
    switch (frame['t']) {
      case 'welcome':
        _onWelcome(s, socket, frame);
      case 'peer':
        s.online = frame['online'] == true;
        if (s.online && s.holdForPeer) {
          // The site is back and its queue drained into it: send what the
          // relay refused, in order. Copies it already has are dropped by
          // their sequence numbers.
          s.holdForPeer = false;
          for (final pending in s.unacked) {
            _write(socket, pending.data);
          }
        }
        _notify();
      case 'msg':
        final n = frame['n'];
        final c = frame['c'];
        if (n is String && c is String) _onSealed(s, SealedFrame(n: n, c: c));
      case 'paired':
        s.pairedAcknowledged = true;
        final expiresAt = frame['expiresAt'];
        if (expiresAt is int) s.expiresAt = expiresAt;
        if (s.approved) _save();
      case 'pong':
        final mark = s.pingMark;
        if (mark != null) {
          // While the relay refuses frames for an offline site, a pong says
          // nothing about delivery: keep them for the resend.
          if (!s.holdForPeer) s.unacked.removeWhere((f) => f.index <= mark);
          s.pingMark = null;
          if (s.approved) _save();
        }
      case 'closed':
        _end(
          s,
          reason: frame['reason'] == 'expired' ? 'expired' : 'closed',
          notify: true,
        );
      case 'error':
        if (frame['code'] == 'QUEUE_FULL') {
          _onQueueFull(s);
        } else {
          developer.log(
            'The relay refused a frame: ${frame['code']}',
            name: 'zunia.connect',
          );
        }
    }
  }

  /// The relay closed the socket over a frame's size: the largest frame it
  /// has not confirmed is the one.
  void _onFrameRefused(_Session s) {
    if (s.unacked.isEmpty) return;
    var largest = s.unacked.first;
    for (final f in s.unacked) {
      if (f.data.length > largest.data.length) largest = f;
    }
    s.unacked.remove(largest);
    s.frameLimit = largest.data.length - 1;
    developer.log(
      'The relay refused a ${largest.data.length}-byte frame',
      name: 'zunia.connect',
    );
    final id = largest.id;
    if (id != null) {
      unawaited(_reply(
        s,
        largest.type == 'connect_approve' ? 'connect_reject' : 'error',
        id: id,
        payload: _tooLarge(s.frameLimit!),
      ));
    }
    _notice(NativeConnectNotice(
      'The answer for ${s.identity.host} was too large to send. The site was '
      'told so.',
      error: true,
    ));
  }

  static Map<String, Object?> _tooLarge(int limit) => {
        'code': 'INVALID_PARAMS',
        'message': 'The answer is larger than the relay accepts '
            '(${limit ~/ 1024} KiB)',
      };

  /// The site is offline and the relay holds as much for it as it will: the
  /// last answer was not queued. Keep it, and everything after it, until the
  /// site is back.
  void _onQueueFull(_Session s) {
    if (s.holdForPeer) return;
    s.holdForPeer = true;
    if (s.approved || s.pairing != null) {
      _notice(NativeConnectNotice(
        '${s.identity.host} is offline. Zunia will send your answer when it is '
        'back; keep its page open.',
        error: true,
      ));
    }
  }

  void _onWelcome(_Session s, WebSocket socket, Map<dynamic, dynamic> frame) {
    if (frame['v'] != kConnectV2 ||
        frame['role'] != 'wallet' ||
        frame['sessionId'] != s.sessionId) {
      _end(s, reason: 'unreachable', notify: true);
      return;
    }
    final resumeToken = frame['resumeToken'];
    if (resumeToken is String && _tokenPattern.hasMatch(resumeToken)) {
      s.resumeToken = resumeToken;
      s.joinToken = null;
    }
    if (s.resumeToken == null) {
      _end(s, reason: 'unreachable', notify: true);
      return;
    }
    final origin = frame['verifiedOrigin'];
    s.verifiedOrigin = origin is String && webOrigin(origin) == origin ? origin : null;
    final expiresAt = frame['expiresAt'];
    if (expiresAt is int) s.expiresAt = expiresAt;
    s.online = frame['peer'] == true;
    if (s.online) s.holdForPeer = false;
    if (frame['paired'] == true) s.pairedAcknowledged = true;
    s.attempts = 0;
    s.welcomed = true;
    final publicKey = s.keyPair?.publicKey;
    if (!s.helloSent && publicKey != null) {
      _write(socket, jsonEncode({'t': 'hello', 'pk': bytesToBase64Url(publicKey)}));
      s.helloSent = true;
    }
    if (!s.holdForPeer) {
      for (final pending in s.unacked) {
        _write(socket, pending.data);
      }
    }
    if (s.approved && !s.pairedAcknowledged) _write(socket, '{"t":"paired"}');
    if (s.approved) _save();
    _notify();
  }

  void _onSealed(_Session s, SealedFrame frame) {
    final ConnectEnvelope? message;
    try {
      message = s.cipher.openFresh(frame);
    } on ConnectException {
      developer.log('Dropped a frame that failed to decrypt', name: 'zunia.connect');
      return;
    }
    if (message == null) return;
    if (s.approved) _save();
    try {
      _onMessage(s, message);
    } on ConnectException catch (error) {
      final id = message.id;
      if (id == null) return;
      final payload = {'code': error.code, 'message': error.message};
      if (message.type == 'connect_request') {
        final pairing = s.pairing;
        s.pairing = null;
        if (pairing != null && !pairing.isCompleted) pairing.completeError(error);
        unawaited(
          _reply(s, 'connect_reject', id: id, payload: payload)
              .then((_) => _close(s)),
        );
      } else {
        unawaited(_reply(s, 'error', id: id, payload: payload));
      }
    }
  }

  void _onMessage(_Session s, ConnectEnvelope message) {
    final raw = message.payload;
    final payload = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final id = message.id;
    switch (message.type) {
      case 'connect_request':
        _onConnectRequest(s, id, payload);
      case 'get_accounts':
        if (id == null) return;
        if (!s.approved) {
          throw const ConnectException('NOT_CONNECTED', 'Pairing is not approved yet');
        }
        final wanted = _strings(payload['chainIds']);
        unawaited(
          _reply(
            s,
            'result',
            id: id,
            payload: [
              for (final a in s.accounts)
                if (wanted.isEmpty || wanted.contains(a.chainId)) a.toJson(),
            ],
          ),
        );
      case 'sign_amino' || 'sign_direct' || 'sign_arbitrary':
        _onSignRequest(s, message.type, id, payload);
      default:
        if (id != null) {
          throw ConnectException('UNSUPPORTED', '${message.type} is not supported');
        }
    }
  }

  void _onConnectRequest(_Session s, String? id, Map<String, dynamic> payload) {
    if (id == null || s.approved || s.connectRequestId != null) return;
    final chains = _strings(payload['chains'])
        .where(_chainIdPattern.hasMatch)
        .toSet()
        .take(32)
        .toList();
    if (chains.isEmpty) {
      throw const ConnectException('INVALID_PARAMS', 'The site asked for no chains');
    }
    s.metadata = NativeDappMetadata.fromWire(payload['metadata']);
    s.connectRequestId = id;
    final request = NativeConnectRequest(
      sessionId: s.sessionId,
      id: id,
      dapp: s.identity,
      receivedAt: _now(),
      chains: chains,
      methods: _strings(payload['methods']),
      events: _strings(payload['events']),
      verificationCode: s.keys.verificationCode,
      returnTarget: s.sameDevice ? s.returnTarget : null,
    );
    _pending.add(request);
    _scheduleExpiry();
    final pairing = s.pairing;
    s.pairing = null;
    if (pairing != null && !pairing.isCompleted) pairing.complete(request);
    _notify();
  }

  void _onSignRequest(
    _Session s,
    String type,
    String? id,
    Map<String, dynamic> payload,
  ) {
    if (id == null) return;
    if (!s.approved) {
      throw const ConnectException('NOT_CONNECTED', 'Pairing is not approved yet');
    }
    if (_pending.any((r) => r.sessionId == s.sessionId && r.id == id)) return;
    final waiting = _pending
        .whereType<NativeSignRequest>()
        .where((r) => r.sessionId == s.sessionId)
        .length;
    if (waiting >= _maxPendingPerSession) {
      throw const ConnectException(
        'INTERNAL',
        'Too many requests are waiting for approval',
      );
    }
    final chainId = payload['chainId'];
    final signer = payload['signer'];
    if (chainId is! String || signer is! String) {
      throw const ConnectException('INVALID_PARAMS', 'chainId and signer are required');
    }
    if (!s.chains.contains(chainId)) {
      throw ConnectException('UNKNOWN_CHAIN', '$chainId is not part of this session');
    }
    if (!s.accounts.any((a) => a.chainId == chainId && a.address == signer)) {
      throw const ConnectException(
        'INVALID_PARAMS',
        'The signer is not an account this session shares',
      );
    }
    NativeSignRequest request({
      required NativeSignKind kind,
      Map<String, dynamic>? aminoDoc,
      DirectSignDoc? directDoc,
      Uint8List? data,
      SignInMessage? signIn,
    }) =>
        NativeSignRequest(
          sessionId: s.sessionId,
          id: id,
          dapp: s.identity,
          receivedAt: _now(),
          kind: kind,
          chainId: chainId,
          signer: signer,
          accountIndex: s.accountIndex,
          returnTarget: s.sameDevice ? s.returnTarget : null,
          aminoDoc: aminoDoc,
          directDoc: directDoc,
          data: data,
          signIn: signIn,
        );

    final NativeSignRequest next;
    switch (type) {
      case 'sign_amino':
        final doc = payload['signDoc'];
        if (doc is! Map) {
          throw const ConnectException('INVALID_PARAMS', 'signDoc must be an object');
        }
        if (doc['chain_id'] != chainId) {
          throw ConnectException(
            'INVALID_PARAMS',
            'The document is for another chain than $chainId',
          );
        }
        _checkAnswerFits(id, {'signed': doc, 'signature': _largestSignature});
        next = request(
          kind: NativeSignKind.amino,
          aminoDoc: Map<String, dynamic>.from(doc),
        );
      case 'sign_direct':
        final doc = DirectSignDoc.fromWire(payload['signDoc']);
        if (doc.chainId != chainId) {
          throw ConnectException(
            'INVALID_PARAMS',
            'The document is for another chain than $chainId',
          );
        }
        _checkAnswerFits(id, {'signed': doc.toWire(), 'signature': _largestSignature});
        next = request(kind: NativeSignKind.direct, directDoc: doc);
      default:
        final data = _arbitraryData(payload);
        final text = _utf8OrNull(data);
        if (text != null && looksLikeSignIn(text)) {
          final message = parseSignInMessage(text);
          final origin = s.verifiedOrigin;
          if (origin == null) {
            throw const ConnectException(
              'ORIGIN_MISMATCH',
              'The relay could not tell which site this is, so it cannot ask you to sign in',
            );
          }
          checkSignInBinding(
            message,
            origin: origin,
            chainId: chainId,
            signer: signer,
            now: _now(),
          );
          next = request(kind: NativeSignKind.signIn, data: data, signIn: message);
        } else {
          next = request(kind: NativeSignKind.message, data: data);
        }
    }
    _pending.add(next);
    _scheduleExpiry();
    _notify();
  }

  /// Refuses, before the user is asked, a document whose signed answer
  /// (which carries the document back) would be over the relay's frame limit.
  void _checkAnswerFits(String id, Map<String, Object?> result) {
    final plaintext = utf8.encode(jsonEncode({
      'seq': 9007199254740991,
      'type': 'result',
      'id': id,
      'payload': result,
    }));
    if (_sealedFrameLength(plaintext.length) > maxFrameBytes) {
      throw ConnectException(
        'INVALID_PARAMS',
        'This document is too large to sign over Zunia Connect: the signed '
            'answer would be over the relay limit of ${maxFrameBytes ~/ 1024} KiB',
      );
    }
  }

  Uint8List _arbitraryData(Map<String, dynamic> payload) {
    final data = payload['data'];
    final encoding = payload['encoding'] ?? 'utf8';
    if (data is! String || data.length > _maxArbitraryLength) {
      throw const ConnectException(
        'INVALID_PARAMS',
        'data must be a string of at most 128 KiB',
      );
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

  /// Seals and sends in order. For an approved session the new sequence
  /// number is saved before the frame leaves, so a restart never reuses one.
  /// An answer too large for the relay is replaced by an error saying so: the
  /// relay would close the socket on it, and the resend after every
  /// reconnect would close the next one too.
  Future<void> _reply(
    _Session s,
    String type, {
    String? id,
    Object? payload,
  }) =>
      _serial(() async {
        if (s.ended) return;
        final limit = min(maxFrameBytes, s.frameLimit ?? maxFrameBytes);
        var sentType = type;
        var data = _sealed(s, type, id: id, payload: payload);
        if (data.length > limit) {
          developer.log(
            'An answer of ${data.length} bytes is over the relay limit',
            name: 'zunia.connect',
          );
          if (id == null) return;
          sentType = type == 'connect_approve' ? 'connect_reject' : 'error';
          data = _sealed(s, sentType, id: id, payload: _tooLarge(limit));
          _notice(NativeConnectNotice(
            'The answer for ${s.identity.host} was too large to send. The site '
            'was told so.',
            error: true,
          ));
        }
        s.unacked.add(_Outgoing(++s.sentCount, data, type: sentType, id: id));
        if (s.unacked.length > _maxUnacked) s.unacked.removeAt(0);
        if (s.approved) await _persist();
        if (!s.holdForPeer) _write(s.socket, data);
      });

  String _sealed(_Session s, String type, {String? id, Object? payload}) {
    final frame = s.cipher.seal(type, id: id, payload: payload);
    return jsonEncode({'t': 'msg', 'n': frame.n, 'c': frame.c});
  }

  void _control(_Session s, Map<String, Object?> frame) {
    _write(s.socket, jsonEncode(frame));
  }

  /// Ends the session for both sides.
  Future<void> _close(_Session s) async {
    if (s.ended) return;
    await _queue;
    final sent = _write(s.socket, jsonEncode({'t': 'close', 'reason': 'wallet'}));
    if (!sent && s.resumeToken != null) await _deleteRemote(s);
    _end(s, reason: 'wallet');
  }

  Future<void> _deleteRemote(_Session s) async {
    final client = _http();
    try {
      final request = await client
          .deleteUrl(relaySessionUri(s.relay, s.sessionId))
          .timeout(const Duration(seconds: 5));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${s.resumeToken}');
      final response = await request.close().timeout(const Duration(seconds: 5));
      await response.drain<void>();
    } catch (_) {
      // The relay forgets the session when it expires anyway.
    } finally {
      client.close(force: true);
    }
  }

  void _end(_Session s, {required String reason, bool notify = false}) {
    if (s.ended) return;
    s.ended = true;
    s.reconnectTimer?.cancel();
    s.heartbeatTimer?.cancel();
    s.probeTimer?.cancel();
    final socket = s.socket;
    s.socket = null;
    unawaited(s.subscription?.cancel());
    if (socket != null) unawaited(_quietClose(socket));
    _sessions.remove(s.sessionId);
    _armed.remove(s.sessionId);
    _pending.removeWhere((r) => r.sessionId == s.sessionId && !_foreign.containsKey(r));
    _scheduleExpiry();
    final pairing = s.pairing;
    s.pairing = null;
    if (pairing != null && !pairing.isCompleted) {
      pairing.completeError(_pairingError(reason));
    }
    if (s.approved) {
      _save();
      if (notify) {
        _notice(NativeConnectNotice(_endMessage(s.identity.host, reason)));
      }
    }
    _notify();
  }

  static ConnectException _pairingError(String reason) => switch (reason) {
        'used' || 'expired' => const ConnectException(
            'SESSION_EXPIRED',
            'This code expired or was already used. Ask the site for a new one.',
          ),
        'closed' => const ConnectException(
            'DISCONNECTED',
            'The site cancelled the pairing',
          ),
        'wallet' => const ConnectException('USER_REJECTED', 'Pairing cancelled'),
        _ => const ConnectException(
            'NETWORK',
            'Could not reach the relay. Check the connection and scan a new code.',
          ),
      };

  static String _endMessage(String host, String reason) => switch (reason) {
        'expired' => 'The session with $host expired',
        'replaced' => 'The session with $host continued on another device',
        _ => '$host disconnected',
      };

  Future<void> _quietClose(WebSocket socket) async {
    try {
      await socket.close(1000).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Already gone.
    }
  }

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  void _save() {
    unawaited(_serial(_persist));
  }

  Future<void> _persist() async {
    final rows = [
      for (final s in _sessions.values)
        if (s.approved && !s.ended) s.toJson(),
    ];
    try {
      await _store.save(rows);
    } catch (error) {
      developer.log('Could not save sessions: $error', name: 'zunia.connect');
    }
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _notice(NativeConnectNotice notice) {
    if (!_notices.isClosed) _notices.add(notice);
  }

  static bool _sameAccounts(
    List<NativeConnectAccount> a,
    List<NativeConnectAccount> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Outgoing {
  const _Outgoing(this.index, this.data, {this.type, this.id});

  final int index;
  final String data;

  /// What the frame answers, while the app runs (not saved).
  final String? type;
  final String? id;
}

class _Session {
  _Session({
    required this.sessionId,
    required this.relay,
    required this.keys,
    this.joinToken,
    this.resumeToken,
    this.keyPair,
    int sendSeq = 0,
    int receiveSeq = 0,
  }) : cipher = ConnectCipher(
          role: ConnectRole.wallet,
          sessionId: sessionId,
          dappToWallet: keys.dappToWallet,
          walletToDapp: keys.walletToDapp,
          sendSeq: sendSeq,
          receiveSeq: receiveSeq,
        );

  final String sessionId;
  final String relay;
  final ConnectSessionKeys keys;
  final ConnectCipher cipher;
  String? joinToken;
  String? resumeToken;
  ConnectKeyPair? keyPair;
  String? verifiedOrigin;
  int expiresAt = 0;
  int? pairedAt;
  NativeDappMetadata metadata = NativeDappMetadata.unknown;
  List<String> requestedChains = const [];
  List<String> chains = const [];
  List<NativeConnectAccount> accounts = const [];
  int accountIndex = 0;
  bool sameDevice = false;
  ReturnTarget? returnTarget;
  bool approved = false;
  bool pairedAcknowledged = false;
  bool helloSent = false;
  bool welcomed = false;
  bool online = false;
  bool ended = false;
  bool connecting = false;

  /// The relay refused a frame because the site is offline and its queue is
  /// full: hold everything until the site is back.
  bool holdForPeer = false;

  /// Learned from a relay that closed a socket over a frame's size.
  int? frameLimit;
  String? connectRequestId;
  Completer<NativeConnectRequest>? pairing;

  WebSocket? socket;
  StreamSubscription<dynamic>? subscription;
  Timer? heartbeatTimer;
  Timer? reconnectTimer;
  Timer? probeTimer;
  DateTime lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  int attempts = 0;

  /// Sealed frames the relay has not confirmed yet, resent after a reconnect.
  final List<_Outgoing> unacked = [];
  int sentCount = 0;
  int? pingMark;

  NativeDappIdentity get identity => NativeDappIdentity(
        metadata: metadata,
        verifiedOrigin: verifiedOrigin,
        relay: relay,
      );

  NativeActiveSession view() => NativeActiveSession(
        sessionId: sessionId,
        dapp: identity,
        chains: List.unmodifiable(chains),
        requestedChains: List.unmodifiable(
          requestedChains.isEmpty ? chains : requestedChains,
        ),
        accounts: List.unmodifiable(accounts),
        online: online,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
        pairedAt: pairedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(pairedAt!),
        sameDevice: sameDevice,
        returnTarget: returnTarget,
      );

  Map<String, dynamic> toJson() => {
        'v': kConnectSessionSchema,
        'sessionId': sessionId,
        'relay': relay,
        'resumeToken': resumeToken,
        'verifiedOrigin': verifiedOrigin,
        'expiresAt': expiresAt,
        'pairedAt': pairedAt,
        'dappToWallet': bytesToBase64Url(keys.dappToWallet),
        'walletToDapp': bytesToBase64Url(keys.walletToDapp),
        'verificationCode': keys.verificationCode,
        'sendSeq': cipher.sendSeq,
        'receiveSeq': cipher.receiveSeq,
        'metadata': metadata.toJson(),
        'requestedChains': requestedChains,
        'chains': chains,
        'accounts': [for (final a in accounts) a.toJson()],
        'accountIndex': accountIndex,
        'paired': pairedAcknowledged,
        'sameDevice': sameDevice,
        'returnUrl': returnTarget?.url,
        'unacked': [for (final f in unacked.take(16)) f.data],
      };

  static _Session? fromJson(Map<String, dynamic> raw) {
    final json = upgradeConnectSessionRow(raw);
    if (json == null) return null;
    try {
      final session = _Session(
        sessionId: json['sessionId'] as String,
        relay: json['relay'] as String,
        resumeToken: json['resumeToken'] as String,
        keys: ConnectSessionKeys(
          dappToWallet: base64UrlToBytes(json['dappToWallet'] as String),
          walletToDapp: base64UrlToBytes(json['walletToDapp'] as String),
          verificationCode: json['verificationCode'] as String,
        ),
        sendSeq: json['sendSeq'] as int,
        receiveSeq: json['receiveSeq'] as int,
      )
        ..verifiedOrigin = json['verifiedOrigin'] as String?
        ..expiresAt = json['expiresAt'] as int
        ..pairedAt = json['pairedAt'] as int?
        ..metadata = NativeDappMetadata.fromWire(json['metadata'])
        ..chains = _strings(json['chains'])
        ..requestedChains = _strings(json['requestedChains'])
        ..accounts = [
          for (final a in json['accounts'] as List)
            NativeConnectAccount.fromJson(Map<String, dynamic>.from(a as Map)),
        ]
        ..accountIndex = json['accountIndex'] as int
        ..pairedAcknowledged = json['paired'] == true
        ..sameDevice = json['sameDevice'] == true
        ..returnTarget = ReturnTarget.parse(json['returnUrl'] as String?)
        ..approved = true
        ..helloSent = true;
      for (final data in _strings(json['unacked'])) {
        session.unacked.add(_Outgoing(++session.sentCount, data));
      }
      return session;
    } catch (_) {
      return null;
    }
  }
}
