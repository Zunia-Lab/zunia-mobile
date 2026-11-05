/// One live CometBFT subscription per chain: the socket half of realtime.
/// The framing and parsing live in realtime_protocol.dart.
///
/// A stream owns the socket and reopens it with jittered backoff when it
/// drops. Liveness uses WebSocket pings: a node behind a proxy often leaves a
/// dead socket "open" indefinitely, which looks exactly like a quiet chain,
/// and a ping that goes unanswered closes it so the retry path runs.
///
/// It does not decide what to subscribe to and never touches wallet state;
/// that is the notice engine's job.
library;

import 'dart:async';
import 'dart:io';

import 'package:zunia_mobile/notifications/realtime_protocol.dart';

enum StreamState { connecting, live, retrying, closed }

/// Opens a socket. Tests replace it so nothing dials out.
typedef SocketConnector = Future<WebSocket> Function(String url);

Future<WebSocket> _connect(String url) =>
    WebSocket.connect(url).timeout(const Duration(seconds: 15));

class ChainStream {
  ChainStream({
    required this.chainId,
    required String rpc,
    required this.subscriptions,
    required this.onTx,
    this.onState,
    SocketConnector? connect,
  })  : _url = websocketUrl(rpc),
        _connector = connect ?? _connect {
    unawaited(_open());
  }

  final String chainId;
  final List<Subscription> subscriptions;
  final void Function(TxNotice notice) onTx;
  final void Function(StreamState state)? onState;

  final String? _url;
  final SocketConnector _connector;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _listener;
  Timer? _retry;
  int _attempt = 0;
  bool _closed = false;
  StreamState _state = StreamState.connecting;

  StreamState get state => _state;

  void _set(StreamState next) {
    if (_state == next) return;
    _state = next;
    onState?.call(next);
  }

  Future<void> _open() async {
    final url = _url;
    if (_closed) return;
    if (url == null) {
      // No usable RPC: the engine's poll covers this chain.
      _set(StreamState.closed);
      return;
    }
    _set(_attempt == 0 ? StreamState.connecting : StreamState.retrying);
    try {
      final socket = await _connector(url);
      if (_closed) {
        await socket.close();
        return;
      }
      // An unanswered ping closes the socket, which lands in onDone below.
      socket.pingInterval = const Duration(seconds: 30);
      _socket = socket;
      _listener = socket.listen(
        _onMessage,
        onDone: () => _scheduleRetry(),
        onError: (Object _) => _scheduleRetry(),
        cancelOnError: true,
      );
      for (final subscription in subscriptions) {
        socket.add(subscribeFrame(subscription));
      }
    } on Object {
      _scheduleRetry();
    }
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    switch (parseFrame(data, chainId)) {
      case AckFrame():
        // The node accepted a subscription: the stream is live, and a later
        // drop starts its backoff from the beginning again.
        _attempt = 0;
        _set(StreamState.live);
      case TxFrame(:final notice):
        onTx(notice);
      case ErrorFrame():
        // A node that refuses the query will keep refusing it; dropping and
        // retrying with backoff keeps us from hammering it, and the poll
        // still covers the chain meanwhile.
        _scheduleRetry();
      case IgnoredFrame():
        break;
    }
  }

  void _drop() {
    unawaited(_listener?.cancel());
    _listener = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close().catchError((Object _) {}));
  }

  void _scheduleRetry() {
    if (_closed) return;
    _drop();
    _retry?.cancel();
    final delay = backoffDelay(_attempt);
    _attempt += 1;
    _set(StreamState.retrying);
    _retry = Timer(delay, () => unawaited(_open()));
  }

  void close() {
    _closed = true;
    _retry?.cancel();
    _drop();
    _set(StreamState.closed);
  }
}
