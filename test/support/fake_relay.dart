import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zunia_mobile/connect/connect_crypto.dart';

String _token(int bytes) => bytesToBase64Url(randomBytes(bytes));

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

/// An in-process relay that behaves like zunia-backend for one or more
/// sessions: single-use join token, resume token, offline queues, pong,
/// paired, close codes.
class FakeRelay {
  FakeRelay._(this._server);

  static Future<FakeRelay> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = FakeRelay._(server);
    server.listen(relay._handle);
    return relay;
  }

  final HttpServer _server;
  final Map<String, RelayRoom> rooms = {};

  /// Tokens wallets connected with, in order.
  final List<String> walletTokens = [];

  int deletes = 0;

  String get url => 'ws://127.0.0.1:${_server.port}';

  RelayRoom createSession({String? verifiedOrigin = 'https://app.example.com'}) {
    final room = RelayRoom(
      sessionId: _token(16),
      dappToken: _token(32),
      joinToken: _token(32),
      verifiedOrigin: verifiedOrigin,
      expiresAt: _nowMs() + 600000,
    );
    rooms[room.sessionId] = room;
    return room;
  }

  Future<void> close() async {
    for (final room in rooms.values) {
      await room.shutdown();
    }
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == '/v1/connect/ws') return _upgrade(request);
    final match = RegExp(r'^/v1/connect/sessions/([A-Za-z0-9_-]{22})$')
        .firstMatch(request.uri.path);
    if (request.method == 'DELETE' && match != null) {
      final room = rooms[match[1]];
      final auth = request.headers.value(HttpHeaders.authorizationHeader);
      if (room == null || room.ended || auth != 'Bearer ${room.resumeToken}') {
        request.response.statusCode = HttpStatus.unauthorized;
      } else {
        deletes++;
        room.end('deleted');
        request.response.statusCode = HttpStatus.noContent;
      }
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _upgrade(HttpRequest request) async {
    final sessionId = request.uri.queryParameters['sid'];
    final role = request.uri.queryParameters['role'];
    final offered = [
      for (final value in request.headers['sec-websocket-protocol'] ?? const <String>[])
        ...value.split(',').map((p) => p.trim()),
    ];
    final token = offered
        .firstWhere((p) => p.startsWith('zunia.token.'), orElse: () => '')
        .replaceFirst('zunia.token.', '');
    if (role == 'wallet') walletTokens.add(token);
    final room = rooms[sessionId];
    String? resumeToken;
    var admitted = false;
    if (room != null && !room.ended && (role == 'dapp' || role == 'wallet')) {
      if (role == 'dapp') {
        admitted = token == room.dappToken;
      } else if (room.resumeToken != null && token == room.resumeToken) {
        admitted = true;
      } else if (room.joinToken != null && token == room.joinToken) {
        admitted = true;
        room.joinToken = null;
        resumeToken = room.resumeToken = _token(32);
      }
    }
    final ws = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: (protocols) => kConnectV2,
    );
    if (!admitted) {
      await ws.close(4401, 'unauthorized');
      return;
    }
    room!.attach(role!, ws, resumeToken);
  }
}

class RelayRoom {
  RelayRoom({
    required this.sessionId,
    required this.dappToken,
    required this.joinToken,
    required this.verifiedOrigin,
    required this.expiresAt,
  });

  final String sessionId;
  final String dappToken;
  String? joinToken;
  String? resumeToken;
  final String? verifiedOrigin;
  int expiresAt;
  bool paired = false;
  bool ended = false;

  /// Frames held for an offline side, as the relay's `queueMaxFrames`.
  int queueMaxFrames = 32;

  /// The relay's `maxPayloadBytes`: a larger frame closes the socket (1009).
  int maxPayloadBytes = 512 * 1024;

  /// Close codes the wallet's sockets were closed with by the relay.
  final List<int> walletCloses = [];

  final Map<String, WebSocket?> sockets = {'dapp': null, 'wallet': null};
  final Map<String, List<String>> queues = {'dapp': [], 'wallet': []};

  /// Frames each side sent that the relay handled, decoded.
  final Map<String, List<Map<String, dynamic>>> received = {'dapp': [], 'wallet': []};

  /// Swallows everything the wallet sends, pings included, like a link that
  /// died without either side noticing yet.
  bool blackholeWallet = false;

  static String _other(String role) => role == 'dapp' ? 'wallet' : 'dapp';

  static bool _open(WebSocket? socket) =>
      socket != null && socket.readyState == WebSocket.open;

  /// dart:io keeps reporting `open` after a local close, until the peer
  /// answers, so writes can still fail.
  static void _write(WebSocket socket, String data) {
    try {
      socket.add(data);
    } on StateError {
      // Closing.
    }
  }

  void _send(WebSocket? socket, Map<String, Object?> frame) {
    if (_open(socket)) _write(socket!, jsonEncode(frame));
  }

  void attach(String role, WebSocket ws, String? resumeToken) {
    final previous = sockets[role];
    sockets[role] = ws;
    if (previous != null) unawaited(previous.close(4000, 'replaced'));
    final peer = sockets[_other(role)];
    _send(ws, {
      't': 'welcome',
      'v': kConnectV2,
      'role': role,
      'sessionId': sessionId,
      'verifiedOrigin': verifiedOrigin,
      'paired': paired,
      'peer': peer != null,
      'expiresAt': expiresAt,
      'resumeToken': ?resumeToken,
    });
    if (previous == null) _send(peer, {'t': 'peer', 'online': true});
    for (final frame in queues[role]!) {
      _write(ws, frame);
    }
    queues[role]!.clear();
    ws.listen(
      (data) => _onFrame(role, ws, data as String),
      onDone: () {
        if (identical(sockets[role], ws)) {
          sockets[role] = null;
          _send(sockets[_other(role)], {'t': 'peer', 'online': false});
        }
      },
    );
  }

  void _onFrame(String role, WebSocket ws, String data) {
    if (!identical(sockets[role], ws) || ended) return;
    if (data.length > maxPayloadBytes) {
      if (role == 'wallet') walletCloses.add(1009);
      unawaited(ws.close(1009, 'too big'));
      return;
    }
    if (role == 'wallet' && blackholeWallet) return;
    final frame = Map<String, dynamic>.from(jsonDecode(data) as Map);
    received[role]!.add(frame);
    switch (frame['t']) {
      case 'ping':
        _send(ws, {'t': 'pong'});
      case 'hello':
        if (role == 'wallet') forward(role, data);
      case 'msg':
        forward(role, data, sender: ws);
      case 'paired':
        if (role == 'wallet') {
          paired = true;
          expiresAt = _nowMs() + 86400000;
          final ack = {'t': 'paired', 'expiresAt': expiresAt};
          _send(sockets['dapp'], ack);
          _send(ws, ack);
        }
      case 'close':
        end('closed');
    }
  }

  void forward(String from, String data, {WebSocket? sender}) {
    final to = _other(from);
    final socket = sockets[to];
    if (_open(socket)) {
      _write(socket!, data);
    } else if (queues[to]!.length >= queueMaxFrames) {
      _send(sender, {
        't': 'error',
        'code': 'QUEUE_FULL',
        'message': 'The other side is offline and its queue is full',
      });
    } else {
      queues[to]!.add(data);
    }
  }

  /// Cuts the dApp's socket without ending the session.
  Future<void> dropDapp() async {
    final socket = sockets['dapp'];
    sockets['dapp'] = null;
    _send(sockets['wallet'], {'t': 'peer', 'online': false});
    await socket?.close(1001, 'going away');
  }

  /// Delivers a frame the wallet already got, as a buggy or hostile relay might.
  void replayToWallet(String data) {
    final socket = sockets['wallet'];
    if (_open(socket)) _write(socket!, data);
  }

  /// Cuts the wallet's socket without ending the session.
  Future<void> dropWallet() async {
    final socket = sockets['wallet'];
    sockets['wallet'] = null;
    await socket?.close(1001, 'going away');
  }

  void end(String reason) {
    if (ended) return;
    ended = true;
    for (final role in ['dapp', 'wallet']) {
      final socket = sockets[role];
      if (socket != null) {
        _send(socket, {'t': 'closed', 'reason': reason});
        unawaited(socket.close(4001, 'ended'));
      }
    }
  }

  Future<void> shutdown() async {
    for (final socket in sockets.values) {
      await socket?.close(1001);
    }
  }
}

/// The dApp side, sealing and opening frames like the SDK does.
class TestDapp {
  TestDapp(this.relay, this.room);

  final FakeRelay relay;
  final RelayRoom room;
  late final ConnectKeyPair keys;
  late WebSocket socket;
  ConnectCipher? cipher;
  String? verificationCode;
  final Completer<void> helloReceived = Completer<void>();
  final List<ConnectEnvelope> messages = [];
  final List<Map<String, dynamic>> control = [];
  final List<String> rawFromWallet = [];

  /// Opens the dApp socket and returns the link the wallet scans.
  Future<String> start() async {
    keys = await ConnectKeyPair.generate();
    socket = await WebSocket.connect(
      '${relay.url}/v1/connect/ws?sid=${room.sessionId}&role=dapp',
      protocols: [kConnectV2, 'zunia.token.${room.dappToken}'],
    );
    socket.listen((data) => _onData(data as String));
    return 'zunia://connect?v=2&sid=${room.sessionId}&t=${room.joinToken}'
        '&pk=${bytesToBase64Url(keys.publicKey)}&r=${Uri.encodeComponent(relay.url)}';
  }

  Future<void> _onData(String data) async {
    final frame = Map<String, dynamic>.from(jsonDecode(data) as Map);
    control.add(frame);
    if (frame['t'] == 'hello' && cipher == null) {
      final derived = await deriveConnectKeys(
        role: ConnectRole.dapp,
        sessionId: room.sessionId,
        own: keys,
        peerPublicKey: base64UrlToBytes(frame['pk'] as String),
      );
      verificationCode = derived.verificationCode;
      cipher = ConnectCipher(
        role: ConnectRole.dapp,
        sessionId: room.sessionId,
        dappToWallet: derived.dappToWallet,
        walletToDapp: derived.walletToDapp,
      );
      helloReceived.complete();
    } else if (frame['t'] == 'msg') {
      rawFromWallet.add(data);
      final envelope = cipher!.openFresh(
        SealedFrame(n: frame['n'] as String, c: frame['c'] as String),
      );
      if (envelope != null) messages.add(envelope);
    }
  }

  /// Opens a new dApp socket for the same session, as a reloaded page does.
  Future<void> reconnect() async {
    socket = await WebSocket.connect(
      '${relay.url}/v1/connect/ws?sid=${room.sessionId}&role=dapp',
      protocols: [kConnectV2, 'zunia.token.${room.dappToken}'],
    );
    socket.listen((data) => _onData(data as String));
  }

  /// Seals and sends; returns the frame as it went on the wire.
  String send(String type, {String? id, Object? payload}) {
    final sealed = cipher!.seal(type, id: id, payload: payload);
    final data = jsonEncode({'t': 'msg', 'n': sealed.n, 'c': sealed.c});
    socket.add(data);
    return data;
  }

  Future<ConnectEnvelope> waitFor(
    bool Function(ConnectEnvelope message) test, {
    Duration timeout = const Duration(seconds: 5),
  }) =>
      _poll(() {
        for (final message in messages) {
          if (test(message)) return message;
        }
        return null;
      }, timeout);

  Future<Map<String, dynamic>> waitForControl(
    String type, {
    Duration timeout = const Duration(seconds: 5),
  }) =>
      _poll(() {
        for (final frame in control) {
          if (frame['t'] == type) return frame;
        }
        return null;
      }, timeout);

  Future<void> close() => socket.close(1000);
}

Future<T> _poll<T extends Object>(T? Function() check, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final value = check();
    if (value != null) return value;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> eventually(
  bool Function() check, {
  Duration timeout = const Duration(seconds: 5),
}) =>
    _poll(() => check() ? true : null, timeout);
