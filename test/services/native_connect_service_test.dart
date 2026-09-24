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
const _chain = 'cosmoshub-4';

typedef _Pairing = ({
  TestDapp dapp,
  RelayRoom room,
  String link,
  NativeConnectRequest request,
});

void main() {
  late FakeRelay relay;
  late MemoryConnectSessionStore store;
  final services = <NativeConnectService>[];
  final dapps = <TestDapp>[];
  final keyring = CosmosKeyring(_phrase);

  NativeConnectAccount account(int index) {
    final key = keyring.key(coinType: 118, accountIndex: index);
    return NativeConnectAccount(
      chainId: _chain,
      address: key.address('cosmos'),
      pubKey: base64Encode(key.publicKey),
      name: 'Account ${index + 1}',
    );
  }

  NativeConnectService newService({
    Duration reconnectMin = const Duration(milliseconds: 50),
    Duration pairingTimeout = const Duration(seconds: 3),
  }) {
    final service = NativeConnectService(
      store: store,
      relayPolicy: RelayPolicy(trusted: [relay.url]),
      heartbeat: const Duration(milliseconds: 100),
      deadAfter: const Duration(seconds: 2),
      reconnectMin: reconnectMin,
      reconnectMax: reconnectMin * 4,
      pairingTimeout: pairingTimeout,
    );
    services.add(service);
    return service;
  }

  setUp(() async {
    relay = await FakeRelay.start();
    store = MemoryConnectSessionStore();
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

  Future<_Pairing> startPairing(
    NativeConnectService service, {
    String? origin = 'https://app.example.com',
    String url = 'https://app.example.com',
  }) async {
    final room = relay.createSession(verifiedOrigin: origin);
    final dapp = TestDapp(relay, room);
    dapps.add(dapp);
    final link = await dapp.start();
    final pairing = service.pair(link);
    await dapp.helloReceived.future.timeout(const Duration(seconds: 5));
    dapp.send(
      'connect_request',
      id: 'connect-1',
      payload: {
        'metadata': {'name': 'Example', 'url': url},
        'chains': [_chain],
        'methods': ['sign_amino', 'sign_direct', 'sign_arbitrary'],
        'events': ['accounts_changed'],
      },
    );
    return (dapp: dapp, room: room, link: link, request: await pairing);
  }

  Future<({TestDapp dapp, RelayRoom room})> paired(
    NativeConnectService service, {
    String? origin = 'https://app.example.com',
  }) async {
    final p = await startPairing(service, origin: origin);
    await service.approveConnect(p.request, accounts: [account(0)], accountIndex: 0);
    await p.dapp.waitFor((m) => m.type == 'connect_approve');
    await eventually(() => p.room.paired);
    return (dapp: p.dapp, room: p.room);
  }

  String signIn(String domain, String uri) {
    final now = DateTime.now().toUtc();
    final issuedAt =
        DateTime.utc(now.year, now.month, now.day, now.hour, now.minute, now.second);
    return [
      '$domain wants you to sign in with your Cosmos account:',
      account(0).address,
      '',
      'URI: $uri',
      'Version: 1',
      'Chain ID: $_chain',
      'Nonce: 8f3k2m9QxZ',
      'Issued At: ${issuedAt.toIso8601String()}',
    ].join('\n');
  }

  Map<String, dynamic> errorOf(ConnectEnvelope message) {
    expect(message.type, 'error');
    return Map<String, dynamic>.from(message.payload! as Map);
  }

  test('pairs, shows the site\'s code and the origin the relay saw', () async {
    final service = newService();
    final p = await startPairing(service);
    expect(p.request.verificationCode, matches(RegExp(r'^\d{6}$')));
    expect(p.request.verificationCode, p.dapp.verificationCode);
    expect(p.request.dapp.verifiedOrigin, 'https://app.example.com');
    expect(p.request.dapp.originMismatch, isFalse);
    expect(p.request.chains, [_chain]);
    expect(service.pendingRequests, [p.request]);

    await service.approveConnect(p.request, accounts: [account(0)], accountIndex: 0);
    final approve = await p.dapp.waitFor((m) => m.type == 'connect_approve');
    expect(approve.id, 'connect-1');
    final payload = approve.payload! as Map;
    expect(payload['chains'], [_chain]);
    expect(payload['accounts'], [account(0).toJson()]);
    expect(payload['wallet'], {'name': 'Zunia'});
    await eventually(() => p.room.paired);

    expect(service.pendingRequests, isEmpty);
    expect(service.activeSessions.single.dapp.host, 'app.example.com');
    expect(store.saved.single['resumeToken'], p.room.resumeToken);
  });

  test('flags a site that claims to be somewhere else', () async {
    final p = await startPairing(newService(), url: 'https://wallet-login.example.net');
    expect(p.request.dapp.originMismatch, isTrue);
    expect(p.request.dapp.host, 'app.example.com');
  });

  test('refuses a relay it does not trust without contacting it', () async {
    final service = NativeConnectService(
      relayPolicy: RelayPolicy(trusted: ['wss://api.zunialab.com']),
    );
    services.add(service);
    final room = relay.createSession();
    final dapp = TestDapp(relay, room);
    dapps.add(dapp);
    final link = await dapp.start();
    await expectLater(
      service.pair(link),
      throwsA(isA<ConnectException>().having((e) => e.code, 'code', 'UNTRUSTED_RELAY')),
    );
    expect(relay.walletTokens, isEmpty);
  });

  test('a pairing code works once', () async {
    final p = await startPairing(newService());
    await expectLater(
      newService().pair(p.link),
      throwsA(isA<ConnectException>().having((e) => e.code, 'code', 'SESSION_EXPIRED')),
    );
  });

  test('rejecting the connection tells the site and ends the session', () async {
    final service = newService();
    final p = await startPairing(service);
    await service.rejectConnect(p.request);
    final reject = await p.dapp.waitFor((m) => m.type == 'connect_reject');
    expect((reject.payload! as Map)['code'], 'USER_REJECTED');
    await p.dapp.waitForControl('closed');
    expect(service.pendingRequests, isEmpty);
    expect(store.saved, isEmpty);
  });

  test('gives up when the site never asks to connect', () async {
    final service = newService(pairingTimeout: const Duration(milliseconds: 300));
    final room = relay.createSession();
    final dapp = TestDapp(relay, room);
    dapps.add(dapp);
    final link = await dapp.start();
    await expectLater(
      service.pair(link),
      throwsA(isA<ConnectException>().having((e) => e.code, 'code', 'TIMEOUT')),
    );
    await eventually(() => room.ended);
  });

  test('answers get_accounts and returns what the user signs', () async {
    final service = newService();
    final (:dapp, room: _) = await paired(service);

    dapp.send('get_accounts', id: 'a1', payload: {
      'chainIds': [_chain],
    });
    final accounts = await dapp.waitFor((m) => m.id == 'a1');
    expect(accounts.type, 'result');
    expect(accounts.payload, [account(0).toJson()]);

    final doc = {
      'chain_id': _chain,
      'account_number': '7',
      'sequence': '0',
      'fee': {
        'amount': [
          {'denom': 'uatom', 'amount': '500'},
        ],
        'gas': '200000',
      },
      'msgs': [
        {
          'type': 'cosmos-sdk/MsgSend',
          'value': {
            'from_address': account(0).address,
            'to_address': account(1).address,
            'amount': [
              {'denom': 'uatom', 'amount': '1'},
            ],
          },
        },
      ],
      'memo': 'a < b & c',
    };
    dapp.send('sign_amino', id: 's1', payload: {
      'chainId': _chain,
      'signer': account(0).address,
      'signDoc': doc,
    });
    await eventually(() => service.pendingRequests.isNotEmpty);
    final request = service.pendingRequests.single as NativeSignRequest;
    expect(request.kind, NativeSignKind.amino);
    expect(request.accountIndex, 0);

    final key = keyring.key(coinType: 118, accountIndex: 0);
    await service.approveSign(request, signAminoResult(key, request.aminoDoc));
    final result = await dapp.waitFor((m) => m.id == 's1');
    expect(result.type, 'result');
    expect(result.payload, jsonDecode(jsonEncode(signAminoResult(key, doc))));
    expect(service.pendingRequests, isEmpty);

    dapp.send('sign_arbitrary', id: 's2', payload: {
      'chainId': _chain,
      'signer': account(0).address,
      'data': 'hello',
      'encoding': 'utf8',
    });
    await eventually(() => service.pendingRequests.isNotEmpty);
    final message = service.pendingRequests.single as NativeSignRequest;
    expect(message.kind, NativeSignKind.message);
    expect(message.text, 'hello');
    await service.rejectSign(message);
    expect(errorOf(await dapp.waitFor((m) => m.id == 's2'))['code'], 'USER_REJECTED');
  });

  test('refuses requests outside the session before asking the user', () async {
    final service = newService();
    final (:dapp, room: _) = await paired(service);

    dapp.send('sign_amino', id: 'x1', payload: {
      'chainId': 'osmosis-1',
      'signer': account(0).address,
      'signDoc': {'chain_id': 'osmosis-1'},
    });
    dapp.send('sign_amino', id: 'x2', payload: {
      'chainId': _chain,
      'signer': account(1).address,
      'signDoc': {'chain_id': _chain},
    });
    dapp.send('sign_amino', id: 'x3', payload: {
      'chainId': _chain,
      'signer': account(0).address,
      'signDoc': {'chain_id': 'osmosis-1'},
    });
    dapp.send('teleport', id: 'x4');

    expect(errorOf(await dapp.waitFor((m) => m.id == 'x1'))['code'], 'UNKNOWN_CHAIN');
    expect(errorOf(await dapp.waitFor((m) => m.id == 'x2'))['code'], 'INVALID_PARAMS');
    expect(errorOf(await dapp.waitFor((m) => m.id == 'x3'))['code'], 'INVALID_PARAMS');
    expect(errorOf(await dapp.waitFor((m) => m.id == 'x4'))['code'], 'UNSUPPORTED');
    expect(service.pendingRequests, isEmpty);
  });

  test('only asks to sign in to the site the relay saw', () async {
    final service = newService();
    final (:dapp, room: _) = await paired(service);

    dapp.send('sign_arbitrary', id: 'in1', payload: {
      'chainId': _chain,
      'signer': account(0).address,
      'data': signIn('app.example.com', 'https://app.example.com'),
      'encoding': 'utf8',
    });
    await eventually(() => service.pendingRequests.isNotEmpty);
    final request = service.pendingRequests.single as NativeSignRequest;
    expect(request.kind, NativeSignKind.signIn);
    expect(request.signIn!.domain, 'app.example.com');

    dapp.send('sign_arbitrary', id: 'in2', payload: {
      'chainId': _chain,
      'signer': account(0).address,
      'data': signIn('evil.example.com', 'https://evil.example.com'),
      'encoding': 'utf8',
    });
    expect(errorOf(await dapp.waitFor((m) => m.id == 'in2'))['code'], 'ORIGIN_MISMATCH');
    expect(service.pendingRequests, hasLength(1));
  });

  test('refuses sign-in when the relay saw no origin', () async {
    final service = newService();
    final (:dapp, room: _) = await paired(service, origin: null);
    dapp.send('sign_arbitrary', id: 'in', payload: {
      'chainId': _chain,
      'signer': account(0).address,
      'data': signIn('app.example.com', 'https://app.example.com'),
      'encoding': 'utf8',
    });
    expect(errorOf(await dapp.waitFor((m) => m.id == 'in'))['code'], 'ORIGIN_MISMATCH');
    expect(service.pendingRequests, isEmpty);
  });

  test('tells the site when the account changes', () async {
    final service = newService();
    final (:dapp, room: _) = await paired(service);
    await service.switchAccount(accountIndex: 1, accountsFor: (_) => [account(1)]);
    final changed = await dapp.waitFor((m) => m.type == 'accounts_changed');
    expect((changed.payload! as Map)['accounts'], [account(1).toJson()]);
    expect(service.activeSessions.single.accounts, [account(1)]);
    expect(store.saved.single['accountIndex'], 1);
  });

  test('reconnects with the resume token and receives what waited', () async {
    final service = newService();
    final (:dapp, :room) = await paired(service);
    await room.dropWallet();
    dapp.send('get_accounts', id: 'q1', payload: {
      'chainIds': [_chain],
    });
    expect((await dapp.waitFor((m) => m.id == 'q1')).type, 'result');
    expect(relay.walletTokens.length, greaterThanOrEqualTo(2));
    expect(relay.walletTokens.skip(1), everyElement(room.resumeToken));
  });

  test('resends replies the relay never confirmed; the site sees them once', () async {
    final service = newService();
    final (:dapp, :room) = await paired(service);
    room.blackholeWallet = true;
    dapp.send('get_accounts', id: 'r1', payload: {
      'chainIds': [_chain],
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(dapp.messages.where((m) => m.id == 'r1'), isEmpty);

    room.blackholeWallet = false;
    await room.dropWallet();
    await dapp.waitFor((m) => m.id == 'r1');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(dapp.messages.where((m) => m.id == 'r1'), hasLength(1));
  });

  test('ignores frames delivered twice and frames it cannot open', () async {
    final service = newService();
    final (:dapp, :room) = await paired(service);
    final frame = dapp.send('sign_arbitrary', id: 'd1', payload: {
      'chainId': _chain,
      'signer': account(0).address,
      'data': 'hello',
      'encoding': 'utf8',
    });
    await eventually(() => service.pendingRequests.length == 1);
    room.replayToWallet(frame);
    room.replayToWallet(jsonEncode({'t': 'msg', 'n': 'AAAAAAAAAAAAAAAA', 'c': 'AAAA'}));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(service.pendingRequests, hasLength(1));
    expect(service.activeSessions, hasLength(1));
  });

  test('picks approved sessions back up after a restart', () async {
    final first = newService();
    final (:dapp, :room) = await paired(first);
    await first.dispose();
    services.remove(first);

    final second = newService();
    await second.restore();
    expect(second.activeSessions.single.sessionId, room.sessionId);
    expect(second.activeSessions.single.dapp.verifiedOrigin, 'https://app.example.com');
    dapp.send('get_accounts', id: 'after', payload: {
      'chainIds': [_chain],
    });
    final answer = await dapp.waitFor((m) => m.id == 'after');
    expect(answer.payload, [account(0).toJson()]);
  });

  test('the site ending the session removes it and says so', () async {
    final service = newService();
    final notices = <NativeConnectNotice>[];
    service.notices.listen(notices.add);
    final (:dapp, room: _) = await paired(service);
    dapp.socket.add(jsonEncode({'t': 'close'}));
    await eventually(() => service.activeSessions.isEmpty);
    await eventually(() => notices.isNotEmpty);
    expect(notices.single.message, 'app.example.com disconnected');
    await eventually(() => store.saved.isEmpty);
  });

  test('disconnecting in the wallet ends the session for the site', () async {
    final service = newService();
    final (:dapp, :room) = await paired(service);
    await service.disconnectSession(room.sessionId);
    await dapp.waitForControl('closed');
    expect(room.ended, isTrue);
    expect(service.activeSessions, isEmpty);
    await eventually(() => store.saved.isEmpty);
  });

  test('disconnecting while offline deletes the session over HTTP', () async {
    final service = newService(reconnectMin: const Duration(seconds: 10));
    final (:dapp, :room) = await paired(service);
    await room.dropWallet();
    await eventually(() => room.sockets['wallet'] == null);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await service.disconnectSession(room.sessionId);
    expect(relay.deletes, 1);
    await dapp.waitForControl('closed');
    expect(service.activeSessions, isEmpty);
  });
}
