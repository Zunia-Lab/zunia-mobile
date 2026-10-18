/// Zunia Connect v2 beyond the happy path: requests that run out, chain
/// changes, answers too large for the relay, a site whose queue is full, and
/// the way back to a site that opened Zunia on the same phone.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/connect/pairing_uri.dart';
import 'package:zunia_mobile/services/connect_session_store.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';

import '../support/fake_relay.dart';

const _phrase =
    'enlist hip relief stomach skate base shallow young switch frequent cry park';
const _hub = 'cosmoshub-4';
const _osmo = 'osmosis-1';
const _back = 'https://app.example.com/back?x=1';

void main() {
  late FakeRelay relay;
  late MemoryConnectSessionStore store;
  late List<Uri> launched;
  final services = <NativeConnectService>[];
  final dapps = <TestDapp>[];
  final keyring = CosmosKeyring(_phrase);

  NativeConnectAccount account(int index, {String chain = _hub}) {
    final key = keyring.key(coinType: 118, accountIndex: index);
    return NativeConnectAccount(
      chainId: chain,
      address: key.address(chain == _osmo ? 'osmo' : 'cosmos'),
      pubKey: base64Encode(key.publicKey),
      name: 'Account ${index + 1}',
    );
  }

  NativeConnectService newService({
    Duration reconnectMin = const Duration(milliseconds: 50),
    Duration requestLifetime = const Duration(minutes: 5),
    int maxFrameBytes = kRelayMaxFrameBytes,
  }) {
    final service = NativeConnectService(
      store: store,
      relayPolicy: RelayPolicy(trusted: [relay.url]),
      heartbeat: const Duration(milliseconds: 100),
      deadAfter: const Duration(seconds: 2),
      reconnectMin: reconnectMin,
      reconnectMax: reconnectMin * 4,
      pairingTimeout: const Duration(seconds: 3),
      probeTimeout: const Duration(milliseconds: 300),
      requestLifetime: requestLifetime,
      maxFrameBytes: maxFrameBytes,
      launcher: (uri) async {
        launched.add(uri);
        return true;
      },
    );
    services.add(service);
    return service;
  }

  setUp(() async {
    relay = await FakeRelay.start();
    store = MemoryConnectSessionStore();
    launched = [];
  });

  tearDown(() async {
    for (final service in services) {
      await service.dispose();
    }
    services.clear();
    for (final dapp in dapps) {
      await dapp.close();
    }
    dapps.clear();
    await relay.close();
  });

  Future<({TestDapp dapp, RelayRoom room, NativeConnectRequest request})>
  startPairing(
    NativeConnectService service, {
    List<String> chains = const [_hub],
    String? ret,
    bool sameDevice = false,
  }) async {
    final room = relay.createSession();
    final dapp = TestDapp(relay, room);
    dapps.add(dapp);
    var link = await dapp.start();
    if (ret != null) link += '&ret=${Uri.encodeComponent(ret)}';
    final pairing = service.pair(link, sameDevice: sameDevice);
    await dapp.helloReceived.future.timeout(const Duration(seconds: 5));
    dapp.send(
      'connect_request',
      id: 'connect-1',
      payload: {
        'metadata': {'name': 'Example', 'url': 'https://app.example.com'},
        'chains': chains,
        'methods': ['sign_amino', 'sign_direct', 'sign_arbitrary'],
        'events': ['accounts_changed', 'chains_changed'],
      },
    );
    return (dapp: dapp, room: room, request: await pairing);
  }

  Future<({TestDapp dapp, RelayRoom room})> paired(
    NativeConnectService service, {
    List<NativeConnectAccount>? accounts,
    List<String> chains = const [_hub],
    String? ret,
    bool sameDevice = false,
  }) async {
    final p = await startPairing(
      service,
      chains: chains,
      ret: ret,
      sameDevice: sameDevice,
    );
    await service.approveConnect(
      p.request,
      accounts: accounts ?? [account(0)],
      accountIndex: 0,
    );
    await p.dapp.waitFor((m) => m.type == 'connect_approve');
    await eventually(() => p.room.paired);
    return (dapp: p.dapp, room: p.room);
  }

  void askToSign(TestDapp dapp, String id, {String data = 'hello'}) {
    dapp.send(
      'sign_arbitrary',
      id: id,
      payload: {
        'chainId': _hub,
        'signer': account(0).address,
        'data': data,
        'encoding': 'utf8',
      },
    );
  }

  Map<String, dynamic> payloadOf(ConnectEnvelope message) =>
      Map<String, dynamic>.from(message.payload! as Map);

  group('requests that run out', () {
    test(
      'an unanswered request is answered as expired, in the extension\'s words',
      () async {
        final service = newService(
          requestLifetime: const Duration(milliseconds: 400),
        );
        final (:dapp, room: _) = await paired(service);
        askToSign(dapp, 'late');
        await eventually(() => service.pendingRequests.isNotEmpty);

        final answer = await dapp.waitFor((m) => m.id == 'late');
        expect(answer.type, 'error');
        expect(payloadOf(answer), {
          'code': 'USER_REJECTED',
          'message': 'Request expired before it was answered',
        });
        expect(service.pendingRequests, isEmpty);
      },
    );

    test(
      'an unanswered connect request is refused and the pairing closed',
      () async {
        final service = newService(
          requestLifetime: const Duration(milliseconds: 400),
        );
        final p = await startPairing(service);
        final reject = await p.dapp.waitFor((m) => m.type == 'connect_reject');
        expect(
          payloadOf(reject)['message'],
          'Request expired before it was answered',
        );
        await eventually(() => p.room.ended);
        expect(service.pendingRequests, isEmpty);
      },
    );

    test(
      'answering after it ran out says the request is no longer open',
      () async {
        final service = newService(
          requestLifetime: const Duration(milliseconds: 300),
        );
        final (:dapp, room: _) = await paired(service);
        askToSign(dapp, 's');
        await eventually(() => service.pendingRequests.isNotEmpty);
        final request = service.pendingRequests.single as NativeSignRequest;
        await dapp.waitFor((m) => m.id == 's');
        await expectLater(
          service.approveSign(request, const {'signature': 'x'}),
          throwsA(
            isA<ConnectException>().having(
              (e) => e.code,
              'code',
              'NOT_CONNECTED',
            ),
          ),
        );
        expect(dapp.messages.where((m) => m.id == 's'), hasLength(1));
      },
    );
  });

  group('chains', () {
    test(
      'narrowing sends chains_changed; widening also re-sends the accounts',
      () async {
        final service = newService();
        final both = [account(0), account(0, chain: _osmo)];
        final (:dapp, :room) = await paired(
          service,
          chains: [_hub, _osmo],
          accounts: both,
        );
        expect(service.activeSessions.single.requestedChains, [_hub, _osmo]);

        await service.setSessionChains(room.sessionId, [_osmo]);
        final narrowed = await dapp.waitFor((m) => m.type == 'chains_changed');
        expect(payloadOf(narrowed), {
          'chains': [_osmo],
        });
        expect(service.activeSessions.single.chains, [_osmo]);
        expect(service.activeSessions.single.accounts, [
          account(0, chain: _osmo),
        ]);
        expect(store.saved.single['chains'], [_osmo]);
        expect(store.saved.single['requestedChains'], [_hub, _osmo]);

        // A request for the chain it lost is refused at once.
        dapp.send(
          'sign_amino',
          id: 'gone',
          payload: {
            'chainId': _hub,
            'signer': account(0).address,
            'signDoc': {'chain_id': _hub},
          },
        );
        expect(
          payloadOf(await dapp.waitFor((m) => m.id == 'gone'))['code'],
          'UNKNOWN_CHAIN',
        );

        await service.setSessionChains(
          room.sessionId,
          [_hub, _osmo],
          accountsFor: (chains) => [
            for (final c in chains) account(0, chain: c),
          ],
        );
        await dapp.waitFor(
          (m) =>
              m.type == 'chains_changed' &&
              (payloadOf(m)['chains'] as List).length == 2,
        );
        final accounts = await dapp.waitFor(
          (m) => m.type == 'accounts_changed',
        );
        expect([
          for (final a in payloadOf(accounts)['accounts'] as List)
            (a as Map)['chainId'],
        ], unorderedEquals([_hub, _osmo]));
        expect(service.activeSessions.single.chains, [_hub, _osmo]);
      },
    );

    test('a pending request on a chain turned off is refused', () async {
      final service = newService();
      final both = [account(0), account(0, chain: _osmo)];
      final (:dapp, :room) = await paired(
        service,
        chains: [_hub, _osmo],
        accounts: both,
      );
      askToSign(dapp, 'waiting');
      await eventually(() => service.pendingRequests.isNotEmpty);
      await service.setSessionChains(room.sessionId, [_osmo]);
      expect(
        payloadOf(await dapp.waitFor((m) => m.id == 'waiting'))['code'],
        'UNKNOWN_CHAIN',
      );
      expect(service.pendingRequests, isEmpty);
    });

    test(
      'at least one chain stays, and only chains the site asked for',
      () async {
        final service = newService();
        final (dapp: _, :room) = await paired(service);
        await expectLater(
          service.setSessionChains(room.sessionId, const []),
          throwsA(
            isA<ConnectException>().having(
              (e) => e.code,
              'code',
              'INVALID_PARAMS',
            ),
          ),
        );
        await expectLater(
          service.setSessionChains(room.sessionId, const ['juno-1']),
          throwsA(isA<ConnectException>()),
        );
        expect(service.activeSessions.single.chains, [_hub]);
      },
    );
  });

  group('frame size', () {
    test(
      'refuses a document whose signed answer would not fit, before asking',
      () async {
        final service = newService(maxFrameBytes: 4096);
        final (:dapp, room: _) = await paired(service);
        dapp.send(
          'sign_amino',
          id: 'big',
          payload: {
            'chainId': _hub,
            'signer': account(0).address,
            'signDoc': {
              'chain_id': _hub,
              'account_number': '1',
              'sequence': '0',
              'fee': {'amount': <Object>[], 'gas': '1'},
              'msgs': <Object>[],
              'memo': 'm' * 4000,
            },
          },
        );
        final answer = await dapp.waitFor((m) => m.id == 'big');
        expect(payloadOf(answer)['code'], 'INVALID_PARAMS');
        expect(payloadOf(answer)['message'], contains('too large'));
        expect(service.pendingRequests, isEmpty);
      },
    );

    test(
      'an answer over the limit becomes an error and is never resent',
      () async {
        final service = newService(maxFrameBytes: 4096);
        final notices = <NativeConnectNotice>[];
        service.notices.listen(notices.add);
        final (:dapp, :room) = await paired(service);
        askToSign(dapp, 'huge');
        await eventually(() => service.pendingRequests.isNotEmpty);
        final request = service.pendingRequests.single as NativeSignRequest;
        await service.approveSign(request, {'signature': 's' * 6000});

        final answer = await dapp.waitFor((m) => m.id == 'huge');
        expect(answer.type, 'error');
        expect(
          payloadOf(answer)['message'],
          contains('larger than the relay accepts'),
        );
        expect(notices.where((n) => n.error), isNotEmpty);

        await room.dropWallet();
        await eventually(() => room.sockets['wallet'] != null);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(dapp.messages.where((m) => m.id == 'huge'), hasLength(1));
        expect(room.walletCloses, isEmpty);
      },
    );

    test(
      'a frame the relay closed the socket over is dropped, not resent in a loop',
      () async {
        final service = newService();
        final (:dapp, :room) = await paired(service);
        room.maxPayloadBytes = 2048;
        askToSign(dapp, 'over');
        await eventually(() => service.pendingRequests.isNotEmpty);
        final request = service.pendingRequests.single as NativeSignRequest;
        await service.approveSign(request, {'signature': 's' * 3000});
        await eventually(() => room.walletCloses.isNotEmpty);
        // Reconnects, and does not send it again.
        await eventually(() => room.sockets['wallet'] != null);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(room.walletCloses, hasLength(1));
        // The site hears why instead of waiting for its timeout.
        final answer = await dapp.waitFor((m) => m.id == 'over');
        expect(answer.type, 'error');
        expect(payloadOf(answer)['code'], 'INVALID_PARAMS');
        dapp.send(
          'get_accounts',
          id: 'after',
          payload: {
            'chainIds': [_hub],
          },
        );
        expect((await dapp.waitFor((m) => m.id == 'after')).type, 'result');
      },
    );
  });

  test(
    'when the site is offline and its queue is full, the answer waits for it',
    () async {
      final service = newService();
      final notices = <NativeConnectNotice>[];
      service.notices.listen(notices.add);
      final (:dapp, :room) = await paired(service);
      await room.dropDapp();
      await eventually(() => !service.activeSessions.single.online);
      room.queueMaxFrames = 0;

      await service.switchAccount(
        accountIndex: 1,
        accountsFor: (_) => [account(1)],
      );
      await eventually(() => notices.isNotEmpty);
      expect(notices.single.message, contains('is offline'));
      expect(notices.single.error, isTrue);
      // Pongs while the site is away do not count as delivery.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      room.queueMaxFrames = 32;
      await dapp.reconnect();
      final changed = await dapp.waitFor((m) => m.type == 'accounts_changed');
      expect(payloadOf(changed)['accounts'], [account(1).toJson()]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        dapp.messages.where((m) => m.type == 'accounts_changed'),
        hasLength(1),
      );
    },
  );

  group('same device', () {
    test(
      'a session paired from a link remembers it and its way back',
      () async {
        final service = newService();
        final (dapp: _, room: _) = await paired(
          service,
          ret: _back,
          sameDevice: true,
        );
        final saved = store.saved.single;
        expect(saved['v'], 2);
        expect(saved['sameDevice'], isTrue);
        expect(saved['returnUrl'], _back);
        expect(saved['pairedAt'], isA<int>());
        final session = service.activeSessions.single;
        expect(session.sameDevice, isTrue);
        expect(session.returnTarget!.label, 'app.example.com');
      },
    );

    test('rows saved by 0.1.0 builds upgrade to the current layout', () async {
      final first = newService();
      final (:dapp, :room) = await paired(first);
      await first.dispose();
      services.remove(first);
      final v1 = Map<String, dynamic>.from(store.saved.single)
        ..['v'] = 1
        ..remove('sameDevice')
        ..remove('returnUrl')
        ..remove('pairedAt')
        ..remove('requestedChains');
      store.saved = [v1];

      final second = newService();
      await second.restore();
      final session = second.activeSessions.single;
      expect(session.sessionId, room.sessionId);
      expect(session.sameDevice, isFalse);
      expect(session.returnTarget, isNull);
      expect(session.requestedChains, [_hub]);
      await eventually(() => store.saved.single['v'] == 2);
      expect(store.saved.single['requestedChains'], [_hub]);
      dapp.send(
        'get_accounts',
        id: 'q',
        payload: {
          'chainIds': [_hub],
        },
      );
      expect((await dapp.waitFor((m) => m.id == 'q')).type, 'result');
    });

    test('upgrades v1 rows and drops rows it does not know', () {
      final v1 = {
        'v': 1,
        'sessionId': 'x',
        'chains': ['a', 'b'],
      };
      final up = upgradeConnectSessionRow(v1)!;
      expect(up['v'], kConnectSessionSchema);
      expect(up['sameDevice'], isFalse);
      expect(up['returnUrl'], isNull);
      expect(up['requestedChains'], ['a', 'b']);
      expect(upgradeConnectSessionRow({'v': 3}), isNull);
      expect(upgradeConnectSessionRow({'sessionId': 'x'}), isNull);
    });

    test(
      'answering the connect request a link brought up goes back at once',
      () async {
        final service = newService();
        final p = await startPairing(service, ret: _back, sameDevice: true);
        expect(p.request.returnLabel, 'Return to app.example.com');
        await service.approveConnect(
          p.request,
          accounts: [account(0)],
          accountIndex: 0,
        );
        expect(launched, [Uri.parse(_back)]);
      },
    );

    test('rejecting goes back too', () async {
      final service = newService();
      final p = await startPairing(service, ret: _back, sameDevice: true);
      await service.rejectConnect(p.request);
      expect(launched, [Uri.parse(_back)]);
    });

    test('a scanned code never sends the user to another app', () async {
      final service = newService();
      final notices = <NativeConnectNotice>[];
      service.notices.listen(notices.add);
      final p = await startPairing(service, ret: _back);
      expect(p.request.returnTarget, isNull);
      await service.approveConnect(
        p.request,
        accounts: [account(0)],
        accountIndex: 0,
      );
      askToSign(p.dapp, 's');
      await eventually(() => service.pendingRequests.isNotEmpty);
      await service.rejectSign(
        service.pendingRequests.single as NativeSignRequest,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(launched, isEmpty);
      expect(notices.where((n) => n.returnTarget != null), isEmpty);
    });

    test(
      'a wake link arms the way back; without one the user only hears they can go',
      () async {
        final service = newService();
        final notices = <NativeConnectNotice>[];
        service.notices.listen(notices.add);
        final (:dapp, :room) = await paired(
          service,
          ret: _back,
          sameDevice: true,
        );
        launched.clear();

        // The site sends a request and opens zunia://connect/wake?sid=...
        askToSign(dapp, 'one');
        expect(service.wake(room.sessionId), isTrue);
        await eventually(() => service.pendingRequests.isNotEmpty);
        final first = service.pendingRequests.single as NativeSignRequest;
        expect(first.returnLabel, 'Return to app.example.com');
        await service.approveSign(first, const {'signature': 'sig'});
        expect(launched, [Uri.parse(_back)]);

        // No wake this time: the user was already in Zunia.
        askToSign(dapp, 'two');
        await eventually(() => service.pendingRequests.isNotEmpty);
        await service.approveSign(
          service.pendingRequests.single as NativeSignRequest,
          const {'signature': 'sig'},
        );
        expect(launched, hasLength(1));
        await eventually(() => notices.any((n) => n.returnTarget != null));
        expect(notices.last.returnTarget!.url, _back);
      },
    );

    test(
      'goes back only after the last waiting request from the site',
      () async {
        final service = newService();
        final (:dapp, :room) = await paired(
          service,
          ret: _back,
          sameDevice: true,
        );
        launched.clear();
        askToSign(dapp, 'a');
        askToSign(dapp, 'b');
        service.wake(room.sessionId);
        await eventually(() => service.pendingRequests.length == 2);
        final [a, b] = service.pendingRequests.cast<NativeSignRequest>();
        await service.approveSign(a, const {'signature': 'sig'});
        expect(launched, isEmpty);
        await service.rejectSign(b);
        expect(launched, [Uri.parse(_back)]);
      },
    );

    test('leaving the app disarms the way back', () async {
      final service = newService();
      final (:dapp, :room) = await paired(
        service,
        ret: _back,
        sameDevice: true,
      );
      launched.clear();
      askToSign(dapp, 'a');
      service.wake(room.sessionId);
      await eventually(() => service.pendingRequests.isNotEmpty);
      service.onBackground();
      await service.approveSign(
        service.pendingRequests.single as NativeSignRequest,
        const {'signature': 'sig'},
      );
      expect(launched, isEmpty);
    });
  });

  group('wake links', () {
    test('an unknown session is ignored and nothing is contacted', () async {
      final service = newService();
      expect(service.wake('A' * 22), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(relay.walletTokens, isEmpty);
    });

    test(
      'brings a dropped socket back at once instead of after the backoff',
      () async {
        final service = newService(reconnectMin: const Duration(seconds: 20));
        final (:dapp, :room) = await paired(service);
        final before = relay.walletTokens.length;
        await room.dropWallet();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        askToSign(dapp, 'w');
        expect(service.wake(room.sessionId), isTrue);
        await eventually(() => relay.walletTokens.length > before);
        await eventually(() => service.pendingRequests.isNotEmpty);
        expect((service.pendingRequests.single as NativeSignRequest).id, 'w');
      },
    );
  });

  test(
    'a wake on a socket that stopped answering replaces it quickly',
    () async {
      final service = newService(reconnectMin: const Duration(seconds: 20));
      final (:dapp, :room) = await paired(service);
      final before = relay.walletTokens.length;
      room.blackholeWallet = true;
      expect(service.wake(room.sessionId), isTrue);
      await eventually(() => relay.walletTokens.length > before);
      room.blackholeWallet = false;
      askToSign(dapp, 'after-wake');
      await eventually(() => service.pendingRequests.isNotEmpty);
    },
  );

  test('a wake on a live socket keeps it', () async {
    final service = newService();
    final (dapp: _, :room) = await paired(service);
    final before = relay.walletTokens.length;
    service.wake(room.sessionId);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(relay.walletTokens.length, before);
  });

  group('requests from elsewhere', () {
    NativeSignRequest foreignRequest(String id) => NativeSignRequest(
      sessionId: 'wc:topic',
      id: id,
      dapp: const NativeDappIdentity(
        metadata: NativeDappMetadata(name: 'WC app', url: 'https://wc.example'),
        verifiedOrigin: null,
        relay: 'WalletConnect',
      ),
      receivedAt: DateTime.now(),
      kind: NativeSignKind.message,
      chainId: _hub,
      signer: account(0).address,
      accountIndex: 0,
      transport: ConnectTransport.walletConnect,
      data: utf8.encode('hi'),
    );

    test(
      'join the same queue and are answered through their own channel',
      () async {
        final service = newService();
        final answers = _RecordingAnswers();
        final (:dapp, room: _) = await paired(service);
        askToSign(dapp, 'native');
        await eventually(() => service.pendingRequests.isNotEmpty);
        final foreign = foreignRequest('1');
        service.adopt(foreign, answers);
        expect(service.pendingRequests.map((r) => r.id), ['native', '1']);
        expect(service.isForeign(foreign), isTrue);

        await service.approveSign(foreign, const {'signature': 'sig'});
        expect(answers.calls, ['approveSign 1']);
        expect(service.isPending(foreign), isFalse);

        final second = foreignRequest('2');
        service.adopt(second, answers);
        await service.rejectSign(second);
        expect(answers.calls.last, 'rejectSign 2 USER_REJECTED');
        expect(dapp.messages.where((m) => m.id == '1' || m.id == '2'), isEmpty);
      },
    );

    test('a failed answer keeps the request open', () async {
      final service = newService();
      final answers = _RecordingAnswers()..fail = true;
      final foreign = foreignRequest('3');
      service.adopt(foreign, answers);
      await expectLater(
        service.approveSign(foreign, const {}),
        throwsA(isA<StateError>()),
      );
      expect(service.isPending(foreign), isTrue);
    });

    test('expire with the rest, and can be withdrawn', () async {
      final service = newService(
        requestLifetime: const Duration(milliseconds: 300),
      );
      final answers = _RecordingAnswers();
      service.adopt(foreignRequest('4'), answers);
      await eventually(() => answers.calls.contains('expire 4'));
      expect(service.pendingRequests, isEmpty);

      final other = newService();
      other.adopt(foreignRequest('5'), answers);
      other.withdraw((r) => r.id == '5');
      expect(other.pendingRequests, isEmpty);
    });
  });
}

class _RecordingAnswers implements ForeignRequestAnswers {
  final calls = <String>[];
  bool fail = false;

  void _record(String call) {
    if (fail) throw StateError('offline');
    calls.add(call);
  }

  @override
  Future<void> approveConnect(
    NativeConnectRequest request, {
    required List<NativeConnectAccount> accounts,
    required int accountIndex,
  }) async => _record('approveConnect ${request.id}');

  @override
  Future<void> rejectConnect(NativeConnectRequest request) async =>
      _record('rejectConnect ${request.id}');

  @override
  Future<void> approveSign(
    NativeSignRequest request,
    Map<String, Object?> result,
  ) async => _record('approveSign ${request.id}');

  @override
  Future<void> rejectSign(
    NativeSignRequest request, {
    required String code,
    required String message,
  }) async => _record('rejectSign ${request.id} $code');

  @override
  Future<void> expire(NativeRequest request) async =>
      _record('expire ${request.id}');
}
