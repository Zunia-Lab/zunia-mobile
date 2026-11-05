/// WalletConnect v2 for Cosmos dApps, against a fake WalletKit: proposals and
/// requests join the shared queue, answers go back as JSON-RPC.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/services/connect_session_store.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';

const _phrase =
    'enlist hip relief stomach skate base shallow young switch frequent cry park';
const _hub = 'cosmoshub-4';
const _osmo = 'osmosis-1';
const _pairingTopic =
    '7f6e504bfad60b485450578e05678ed3e8e8c4751d3c6160be17160d63ec90f9';
const _wcUri =
    'wc:$_pairingTopic@2?relay-protocol=irn'
    '&symKey=587d5484ce2a2a6ee3ba1962fdd7e8588e06200c46823bd18fbd67def96ad303';

class _Response {
  _Response(this.topic, this.id, this.result, this.error);

  final String topic;
  final int id;
  final Object? result;
  final WcRpcError? error;
}

class _FakeKit implements WalletKitPort {
  final proposalEvents = StreamController<WcProposalEvent>.broadcast();
  final expiredEvents = StreamController<int>.broadcast();
  final requestEvents = StreamController<WcRequestEvent>.broadcast();
  final endedEvents = StreamController<String>.broadcast();

  final live = <String, WcSessionInfo>{};
  final proposalsById = <int, WcProposalEvent>{};
  final pending = <WcRequestEvent>[];
  final paired = <Uri>[];
  final approved = <int, Map<String, WcNamespace>>{};
  final rejected = <int, WcRpcError>{};
  final responses = <_Response>[];
  final updates = <String, Map<String, WcNamespace>>{};
  final emitted = <String>[];
  final disconnected = <String>[];
  int reconnects = 0;

  void propose(WcProposalEvent proposal) {
    proposalsById[proposal.id] = proposal;
    proposalEvents.add(proposal);
  }

  @override
  Stream<WcProposalEvent> get proposals => proposalEvents.stream;

  @override
  Stream<int> get proposalsExpired => expiredEvents.stream;

  @override
  Stream<WcRequestEvent> get requests => requestEvents.stream;

  @override
  Stream<String> get sessionsEnded => endedEvents.stream;

  @override
  List<WcProposalEvent> pendingProposals() => const [];

  @override
  List<WcRequestEvent> pendingRequests() => List.of(pending);

  @override
  Map<String, WcSessionInfo> sessions() => Map.of(live);

  @override
  Future<void> pair(Uri uri) async => paired.add(uri);

  @override
  Future<String> approve(int id, Map<String, WcNamespace> namespaces) async {
    approved[id] = namespaces;
    final proposal = proposalsById[id]!;
    final topic = 'session-$id';
    live[topic] = WcSessionInfo(
      topic: topic,
      pairingTopic: proposal.pairingTopic,
      peer: proposal.peer,
      namespaces: namespaces,
      expiresAt: DateTime.now().add(const Duration(days: 7)),
    );
    return topic;
  }

  @override
  Future<void> reject(int id, WcRpcError reason) async => rejected[id] = reason;

  @override
  Future<void> respond(
    String topic,
    int id, {
    Object? result,
    WcRpcError? error,
  }) async {
    responses.add(_Response(topic, id, result, error));
    pending.removeWhere((r) => r.id == id);
  }

  @override
  Future<void> update(String topic, Map<String, WcNamespace> namespaces) async {
    updates[topic] = namespaces;
    final s = live[topic]!;
    live[topic] = WcSessionInfo(
      topic: topic,
      pairingTopic: s.pairingTopic,
      peer: s.peer,
      namespaces: namespaces,
      expiresAt: s.expiresAt,
    );
  }

  @override
  Future<void> emit(
    String topic,
    String chainId,
    String name,
    Object? data,
  ) async => emitted.add('$topic $chainId $name ${jsonEncode(data)}');

  @override
  Future<void> disconnect(String topic, WcRpcError reason) async {
    disconnected.add(topic);
    live.remove(topic);
  }

  @override
  Future<void> disconnectPairing(String topic) async {}

  @override
  List<String> pairingTopics() => const [];

  @override
  Future<void> reconnect() async => reconnects++;

  @override
  Future<void> dispose() async {}
}

WcProposalEvent _proposal({
  int id = 1,
  String pairingTopic = _pairingTopic,
  Map<String, WcNamespaceSpec>? required,
  Map<String, WcNamespaceSpec>? optional,
  WcVerify? verify,
  String? redirectNative,
}) => WcProposalEvent(
  id: id,
  pairingTopic: pairingTopic,
  peer: WcPeer(
    name: 'Osmosis',
    url: 'https://app.osmosis.zone',
    description: 'A DEX',
    icons: const ['https://app.osmosis.zone/icon.png'],
    redirectNative: redirectNative,
  ),
  required:
      required ??
      const {
        'cosmos': WcNamespaceSpec(
          chains: ['cosmos:$_hub'],
          methods: ['cosmos_signDirect', 'cosmos_signAmino'],
          events: ['accountsChanged'],
        ),
      },
  optional:
      optional ??
      const {
        'cosmos': WcNamespaceSpec(
          chains: ['cosmos:$_osmo', 'cosmos:juno-1'],
          methods: ['cosmos_getAccounts', 'cosmos_signArbitrary'],
          events: ['chainChanged'],
        ),
      },
  verify:
      verify ??
      const WcVerify(
        origin: 'https://app.osmosis.zone',
        status: WcVerification.valid,
      ),
);

void main() {
  final keyring = CosmosKeyring(_phrase);
  late _FakeKit kit;
  late NativeConnectService native;
  late MemoryWcSessionMetaStore store;
  late WalletConnectBridge bridge;
  late List<Uri> launched;
  late List<NativeConnectNotice> notices;

  NativeConnectAccount account(int index, String chain) {
    final key = keyring.key(coinType: 118, accountIndex: index);
    return NativeConnectAccount(
      chainId: chain,
      address: key.address(chain == _osmo ? 'osmo' : 'cosmos'),
      pubKey: base64Encode(key.publicKey),
    );
  }

  List<NativeConnectAccount> accountsFor(int index, List<String> chains) => [
    for (final c in chains) account(index, c),
  ];

  void build({Duration lifetime = const Duration(minutes: 5)}) {
    kit = _FakeKit();
    launched = [];
    notices = [];
    native = NativeConnectService(
      requestLifetime: lifetime,
      launcher: (uri) async {
        launched.add(uri);
        return true;
      },
    );
    native.notices.listen(notices.add);
    store = MemoryWcSessionMetaStore();
    bridge = WalletConnectBridge(
      kit: () async => kit,
      native: native,
      store: store,
      supportsChain: (chain) => chain == _hub || chain == _osmo,
    );
  }

  setUp(() async {
    build();
    await bridge.init();
  });

  tearDown(() async {
    await bridge.dispose();
    await native.dispose();
  });

  Future<NativeConnectRequest> proposed([WcProposalEvent? proposal]) async {
    kit.propose(proposal ?? _proposal());
    await pumpEventQueue();
    return native.pendingRequests.whereType<NativeConnectRequest>().single;
  }

  Future<String> connected({
    WcProposalEvent? proposal,
    List<String> chains = const [_hub, _osmo],
  }) async {
    final request = await proposed(proposal);
    await native.approveConnect(
      request,
      accounts: accountsFor(0, chains),
      accountIndex: 0,
    );
    return kit.live.keys.single;
  }

  Future<NativeSignRequest> asked(WcRequestEvent event) async {
    kit.requestEvents.add(event);
    await pumpEventQueue();
    return native.pendingRequests.whereType<NativeSignRequest>().single;
  }

  group('proposals', () {
    test(
      'wait in the shared queue and grant exactly what the user approved',
      () async {
        final request = await proposed();
        expect(request.transport, ConnectTransport.walletConnect);
        expect(request.verificationCode, isEmpty);
        expect(request.chains, [_hub, _osmo]);
        expect(request.requiredChains, [_hub]);
        expect(request.dapp.verifiedOrigin, 'https://app.osmosis.zone');
        expect(request.dapp.host, 'app.osmosis.zone');
        expect(request.transportLabel, 'WalletConnect v2');

        await native.approveConnect(
          request,
          accounts: accountsFor(0, [_hub, _osmo]),
          accountIndex: 0,
        );
        final cosmos = kit.approved[1]!['cosmos']!;
        expect(cosmos.chains, ['cosmos:$_hub', 'cosmos:$_osmo']);
        expect(cosmos.accounts, [
          'cosmos:$_hub:${account(0, _hub).address}',
          'cosmos:$_osmo:${account(0, _osmo).address}',
        ]);
        expect(
          cosmos.methods,
          unorderedEquals([
            'cosmos_signDirect',
            'cosmos_signAmino',
            'cosmos_getAccounts',
            'cosmos_signArbitrary',
          ]),
        );
        expect(
          cosmos.events,
          unorderedEquals(['accountsChanged', 'chainChanged']),
        );
        expect(native.pendingRequests, isEmpty);

        final session = bridge.activeSessions.single;
        expect(session.chains, [_hub, _osmo]);
        expect(session.requiredChains, [_hub]);
        expect(session.accounts, accountsFor(0, [_hub, _osmo]));
        expect(session.verifiedOrigin, 'https://app.osmosis.zone');
        expect(store.saved.keys.single, 'session-1');
      },
    );

    test(
      'a proposal missing a required chain at approval stays open',
      () async {
        final request = await proposed();
        await expectLater(
          native.approveConnect(
            request,
            accounts: accountsFor(0, [_osmo]),
            accountIndex: 0,
          ),
          throwsA(
            isA<ConnectException>().having(
              (e) => e.code,
              'code',
              'UNKNOWN_CHAIN',
            ),
          ),
        );
        expect(native.isPending(request), isTrue);
        expect(kit.approved, isEmpty);
        await native.rejectConnect(request);
        expect(kit.rejected[1]!.code, 4001);
      },
    );

    final refusals = <String, (WcProposalEvent, int)>{
      'non-Cosmos accounts it requires': (
        _proposal(
          required: const {
            'eip155': WcNamespaceSpec(
              chains: ['eip155:1'],
              methods: ['eth_sign'],
            ),
          },
        ),
        5104,
      ),
      'a chain Zunia does not support': (
        _proposal(
          required: const {
            'cosmos': WcNamespaceSpec(chains: ['cosmos:juno-1']),
          },
        ),
        5100,
      ),
      'a method Zunia does not offer': (
        _proposal(
          required: const {
            'cosmos': WcNamespaceSpec(
              chains: ['cosmos:$_hub'],
              methods: ['cosmos_signEthereum'],
            ),
          },
        ),
        5101,
      ),
      'a site flagged as a scam': (
        _proposal(
          verify: const WcVerify(
            origin: 'https://osm0sis.example',
            status: WcVerification.scam,
          ),
        ),
        4001,
      ),
    };
    for (final MapEntry(key: name, value: (proposal, code))
        in refusals.entries) {
      test('refuses $name without asking', () async {
        kit.propose(proposal);
        await pumpEventQueue();
        expect(native.pendingRequests, isEmpty);
        expect(kit.rejected[proposal.id]!.code, code);
        expect(notices.single.error, isTrue);
      });
    }

    test('chain keys like cosmos:osmosis-1 count as chains', () async {
      final request = await proposed(
        _proposal(
          required: const {
            'cosmos:$_osmo': WcNamespaceSpec(methods: ['cosmos_signDirect']),
          },
          optional: const {},
        ),
      );
      expect(request.requiredChains, [_osmo]);
    });

    test('an attestation for another site shows as a mismatch', () async {
      final request = await proposed(
        _proposal(
          verify: const WcVerify(
            origin: 'https://osm0sis.example',
            status: WcVerification.invalid,
          ),
        ),
      );
      expect(request.dapp.originMismatch, isTrue);
    });

    test('an expired proposal leaves the queue', () async {
      await proposed();
      kit.expiredEvents.add(1);
      await pumpEventQueue();
      expect(native.pendingRequests, isEmpty);
    });
  });

  group('requests', () {
    test(
      'cosmos_getAccounts is answered at once with the shared keys',
      () async {
        final topic = await connected();
        kit.requestEvents.add(
          WcRequestEvent(
            id: 10,
            topic: topic,
            method: 'cosmos_getAccounts',
            chainId: 'cosmos:$_hub',
            params: const {},
          ),
        );
        await pumpEventQueue();
        expect(native.pendingRequests, isEmpty);
        final response = kit.responses.single;
        expect(response.id, 10);
        expect(response.result, [
          {
            'algo': 'secp256k1',
            'address': account(0, _hub).address,
            'pubkey': account(0, _hub).pubKey,
          },
        ]);
      },
    );

    test(
      'cosmos_signDirect is reviewed like any request and answered {signature, signed}',
      () async {
        final topic = await connected();
        final key = keyring.key(coinType: 118, accountIndex: 0);
        final doc = DirectSignDoc(
          bodyBytes: base64Decode('CgQKAggB'),
          authInfoBytes: base64Decode('EgQKAggB'),
          chainId: _hub,
          accountNumber: BigInt.from(7),
        );
        final request = await asked(
          WcRequestEvent(
            id: 11,
            topic: topic,
            method: 'cosmos_signDirect',
            chainId: 'cosmos:$_hub',
            params: {
              'signerAddress': account(0, _hub).address,
              // A JSON number, as some dApps send it.
              'signDoc': {...doc.toWire(), 'accountNumber': 7},
            },
          ),
        );
        expect(request.kind, NativeSignKind.direct);
        expect(request.transport, ConnectTransport.walletConnect);
        expect(request.directDoc!.accountNumber, BigInt.from(7));

        await native.approveSign(
          request,
          signDirectResult(key, request.directDoc!),
        );
        final result = kit.responses.single.result! as Map;
        expect(result.keys, unorderedEquals(['signature', 'signed']));
        expect(result['signed'], {
          'bodyBytes': 'CgQKAggB',
          'authInfoBytes': 'EgQKAggB',
          'chainId': _hub,
          'accountNumber': '7',
        });
        expect(result, signDirectResult(key, doc));
        expect((result['signature'] as Map)['pub_key'], {
          'type': 'tendermint/PubKeySecp256k1',
          'value': account(0, _hub).pubKey,
        });
      },
    );

    test('cosmos_signAmino is answered with the document as signed', () async {
      final topic = await connected();
      final key = keyring.key(coinType: 118, accountIndex: 0);
      final doc = {
        'chain_id': _hub,
        'account_number': '7',
        'sequence': '1',
        'fee': {'amount': <Object>[], 'gas': '200000'},
        'msgs': <Object>[],
        'memo': 'wc',
      };
      final request = await asked(
        WcRequestEvent(
          id: 12,
          topic: topic,
          method: 'cosmos_signAmino',
          chainId: 'cosmos:$_hub',
          params: {'signerAddress': account(0, _hub).address, 'signDoc': doc},
        ),
      );
      expect(request.kind, NativeSignKind.amino);
      await native.approveSign(request, signAminoResult(key, request.aminoDoc));
      expect(
        jsonDecode(jsonEncode(kit.responses.single.result)),
        jsonDecode(jsonEncode(signAminoResult(key, doc))),
      );
    });

    test('refuses at once what the session does not allow', () async {
      final topic = await connected(chains: [_hub]);
      kit.requestEvents
        ..add(
          WcRequestEvent(
            id: 20,
            topic: topic,
            method: 'cosmos_signAmino',
            chainId: 'cosmos:$_hub',
            params: {
              'signerAddress': account(1, _hub).address,
              'signDoc': {'chain_id': _hub},
            },
          ),
        )
        ..add(
          WcRequestEvent(
            id: 21,
            topic: topic,
            method: 'cosmos_signAmino',
            chainId: 'cosmos:$_hub',
            params: {
              'signerAddress': account(0, _hub).address,
              'signDoc': {'chain_id': _osmo},
            },
          ),
        )
        ..add(
          WcRequestEvent(
            id: 22,
            topic: topic,
            method: 'personal_sign',
            chainId: 'cosmos:$_hub',
            params: const {},
          ),
        );
      await pumpEventQueue();
      expect(native.pendingRequests, isEmpty);
      final codes = {for (final r in kit.responses) r.id: r.error!.code};
      expect(codes, {20: -32602, 21: -32602, 22: -32601});
    });

    test('rejecting answers 4001; running out answers 8000', () async {
      await bridge.dispose();
      await native.dispose();
      build(lifetime: const Duration(milliseconds: 300));
      await bridge.init();
      final topic = await connected();
      final request = await asked(
        WcRequestEvent(
          id: 30,
          topic: topic,
          method: 'cosmos_signArbitrary',
          chainId: 'cosmos:$_hub',
          params: {'signerAddress': account(0, _hub).address, 'data': 'hello'},
        ),
      );
      expect(request.kind, NativeSignKind.message);
      await native.rejectSign(request);
      expect(kit.responses.single.error!.code, 4001);

      kit.requestEvents.add(
        WcRequestEvent(
          id: 31,
          topic: topic,
          method: 'cosmos_signArbitrary',
          chainId: 'cosmos:$_hub',
          params: {'signerAddress': account(0, _hub).address, 'data': 'later'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final expired = kit.responses.firstWhere((r) => r.id == 31);
      expect(expired.error!.code, 8000);
      expect(expired.error!.message, 'Request expired before it was answered');
      expect(native.pendingRequests, isEmpty);
    });

    test('a session the dApp deleted takes its requests with it', () async {
      final topic = await connected();
      await asked(
        WcRequestEvent(
          id: 40,
          topic: topic,
          method: 'cosmos_signArbitrary',
          chainId: 'cosmos:$_hub',
          params: {'signerAddress': account(0, _hub).address, 'data': 'x'},
        ),
      );
      kit.live.remove(topic);
      kit.endedEvents.add(topic);
      await pumpEventQueue();
      expect(native.pendingRequests, isEmpty);
      expect(store.saved, isEmpty);
    });

    test(
      'requests WalletKit kept from before a restart are queued again',
      () async {
        final topic = await connected();
        kit.pending.add(
          WcRequestEvent(
            id: 50,
            topic: topic,
            method: 'cosmos_signArbitrary',
            chainId: 'cosmos:$_hub',
            params: {'signerAddress': account(0, _hub).address, 'data': 'kept'},
          ),
        );
        final restarted = WalletConnectBridge(
          kit: () async => kit,
          native: native,
          store: store,
          supportsChain: (chain) => chain == _hub || chain == _osmo,
        );
        await restarted.init();
        final request = native.pendingRequests
            .whereType<NativeSignRequest>()
            .single;
        expect(request.id, '50');
        expect(request.accountIndex, 0);
        await restarted.dispose();
      },
    );
  });

  group('the session', () {
    test('switching account updates it and says so on each chain', () async {
      final topic = await connected();
      await bridge.switchAccount(
        accountIndex: 1,
        accountsFor: (chains) => accountsFor(1, chains),
      );
      expect(kit.updates[topic]!['cosmos']!.accounts, [
        'cosmos:$_hub:${account(1, _hub).address}',
        'cosmos:$_osmo:${account(1, _osmo).address}',
      ]);
      expect(kit.emitted, [
        '$topic cosmos:$_hub accountsChanged ["${account(1, _hub).address}"]',
        '$topic cosmos:$_osmo accountsChanged ["${account(1, _osmo).address}"]',
      ]);
      expect(
        bridge.activeSessions.single.accounts,
        accountsFor(1, [_hub, _osmo]),
      );
    });

    test(
      'optional chains can be turned off and on; required ones stay',
      () async {
        final topic = await connected();
        await expectLater(
          bridge.setSessionChains(topic, [_osmo]),
          throwsA(
            isA<ConnectException>().having(
              (e) => e.code,
              'code',
              'INVALID_PARAMS',
            ),
          ),
        );
        await bridge.setSessionChains(topic, [_hub]);
        expect(kit.updates[topic]!['cosmos']!.chains, ['cosmos:$_hub']);
        expect(bridge.activeSessions.single.chains, [_hub]);
        await bridge.setSessionChains(topic, [
          _hub,
          _osmo,
        ], accountsFor: (chains) => accountsFor(0, chains));
        expect(kit.updates[topic]!['cosmos']!.accounts, hasLength(2));
      },
    );

    test('disconnecting tells the dApp and forgets the session', () async {
      final topic = await connected();
      await bridge.disconnectTopic(topic);
      expect(kit.disconnected, [topic]);
      expect(bridge.activeSessions, isEmpty);
      expect(store.saved, isEmpty);
    });
  });

  group('same device', () {
    test('a dApp that opened Zunia on this phone gets the user back', () async {
      await bridge.pair(_wcUri, sameDevice: true);
      expect(kit.paired.single.toString(), _wcUri);
      final request = await proposed(
        _proposal(redirectNative: 'dappgame://wc'),
      );
      expect(request.returnLabel, 'Return to dappgame');
      await native.approveConnect(
        request,
        accounts: accountsFor(0, [_hub]),
        accountIndex: 0,
      );
      expect(launched, [Uri.parse('dappgame://wc')]);

      // Later, the dApp opens zunia://wc?requestId=&sessionTopic= for a request.
      final topic = kit.live.keys.single;
      await bridge.wake(topic: topic);
      expect(kit.reconnects, 1);
      final sign = await asked(
        WcRequestEvent(
          id: 60,
          topic: topic,
          method: 'cosmos_signArbitrary',
          chainId: 'cosmos:$_hub',
          params: {'signerAddress': account(0, _hub).address, 'data': 'x'},
        ),
      );
      await native.rejectSign(sign);
      expect(launched, hasLength(2));
    });

    test(
      'a scanned WalletConnect code never sends the user anywhere',
      () async {
        await bridge.pair(_wcUri);
        final request = await proposed(
          _proposal(redirectNative: 'dappgame://wc'),
        );
        expect(request.returnTarget, isNull);
        await native.approveConnect(
          request,
          accounts: accountsFor(0, [_hub]),
          accountIndex: 0,
        );
        expect(launched, isEmpty);
      },
    );
  });
}
