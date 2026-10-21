/// The engine end to end with the network and the system faked: what it
/// reads, when it alerts, and what it forgets.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/notifications/chain_stream.dart';
import 'package:zunia_mobile/notifications/device_alerts.dart';
import 'package:zunia_mobile/notifications/notice_engine.dart';
import 'package:zunia_mobile/notifications/notices.dart';
import 'package:zunia_mobile/notifications/notify_prefs.dart';
import 'package:zunia_mobile/notifications/realtime_protocol.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';

const me = 'osmo1qyyq79says4nyw2qga892hrrdfchsluxsmcjh8';

const osmosis = ChainEntry(
  chainId: 'osmosis-1',
  chainName: 'Osmosis',
  bech32Prefix: 'osmo',
  coinType: 118,
  network: 'mainnet',
  coinDenom: 'OSMO',
  coinMinimalDenom: 'uosmo',
  coinDecimals: 6,
  feeDenom: 'OSMO',
  feeMinimalDenom: 'uosmo',
  feeDecimals: 6,
  rpc: 'https://rpc.osmo.test',
  rest: 'https://lcd.osmo.test',
);

class _Net {
  String rewards = '3000000';
  final asked = <String>[];

  Future<LcdResponse> fetch(Uri uri, Duration _) async {
    asked.add(uri.path);
    Object body;
    if (uri.path.endsWith('/rewards')) {
      body = {
        'rewards': <Object>[],
        'total': [
          {'denom': 'uosmo', 'amount': '$rewards.000000000000000000'},
        ],
      };
    } else if (uri.path.endsWith('/unbonding_delegations')) {
      body = {'unbonding_responses': <Object>[]};
    } else if (uri.path == '/cosmos/gov/v1/proposals') {
      body = {
        'proposals': [
          {
            'id': '901',
            'title': 'Raise the gas floor',
            'status': 'PROPOSAL_STATUS_VOTING_PERIOD',
            'voting_end_time': DateTime.now()
                .add(const Duration(days: 2))
                .toUtc()
                .toIso8601String(),
          },
        ],
        'pagination': {'next_key': null},
      };
    } else {
      return const LcdResponse(404, '{}');
    }
    return LcdResponse(200, jsonEncode(body));
  }
}

class _Streams {
  final opened = <String, void Function(TxNotice)>{};
  final streams = <String, ChainStream>{};

  ChainStream open({
    required String chainId,
    required String rpc,
    required List<Subscription> subscriptions,
    required void Function(TxNotice notice) onTx,
    required void Function(StreamState state) onState,
  }) {
    opened[chainId] = onTx;
    // A connector that never answers: no socket, no retry timer.
    final stream = ChainStream(
      chainId: chainId,
      rpc: rpc,
      subscriptions: subscriptions,
      onTx: onTx,
      connect: (_) => Completer<WebSocket>().future,
    );
    streams[chainId] = stream;
    return stream;
  }
}

TxNotice incoming(String hash, String amount) => TxNotice(
      subscriptionId: 'osmosis-1|$me|in',
      chainId: 'osmosis-1',
      address: me,
      direction: TxDirection.received,
      hash: hash,
      height: 10,
      coins: [MovedCoin('uosmo', amount)],
      action: null,
      succeeded: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Net net;
  late _Streams streams;
  late RecordingDeviceAlerts alerts;
  late NoticeEngine engine;
  var live = true;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    net = _Net();
    streams = _Streams();
    alerts = RecordingDeviceAlerts();
    live = true;
    engine = NoticeEngine(
      alerts: alerts,
      reader: ChainReader(readsAllowed: () => live, fetch: net.fetch),
      openStream: streams.open,
      observeLifecycle: false,
    );
  });

  tearDown(() => engine.dispose());

  NoticeEngineInputs unlocked({
    bool deviceAlerts = true,
    NotifyPrefs prefs = NotifyPrefs.defaults,
    int index = 0,
  }) =>
      NoticeEngineInputs(
        accounts: const [WatchedChain(osmosis, me)],
        accountIndex: index,
        liveReads: true,
        deviceAlerts: deviceAlerts,
        prefs: prefs,
      );

  test('the first look records what is there and alerts for none of it', () async {
    await engine.update(unlocked());
    expect(streams.opened.keys, ['osmosis-1']);
    expect(engine.state.running, isTrue);
    expect(engine.state.notices.map((n) => n.id), ['rewards:1']);
    expect(engine.state.unread, 1);
    expect(alerts.shown, isEmpty);
    // Governance is off by default, so the open proposal is not a notice.
    expect(engine.state.notices.any((n) => n.kind == NoticeKind.governance), isFalse);
    // Asked quietly (iOS provisional), never with a prompt.
    expect(alerts.provisionalRequests, 1);
    expect(alerts.prompts, 0);
  });

  test('a transfer seen on the socket becomes a notice and an alert', () async {
    await engine.update(unlocked());
    streams.opened['osmosis-1']!(incoming('H1', '1500000'));
    await pumpEventQueue();
    final row = engine.state.notices.firstWhere((n) => n.id == 'transfer:H1');
    expect(row.title, 'Received on Osmosis');
    expect(row.meta, '1.5 OSMO');
    expect(alerts.shown.map((n) => n.id), ['transfer:H1']);

    // The same transaction again is not a second notice or a second alert.
    streams.opened['osmosis-1']!(incoming('H1', '1500000'));
    await pumpEventQueue();
    expect(engine.state.notices.where((n) => n.id == 'transfer:H1').length, 1);
    expect(alerts.shown.length, 1);
  });

  test('device alerts off still keeps the feed, and raises nothing', () async {
    await engine.update(unlocked(deviceAlerts: false));
    streams.opened['osmosis-1']!(incoming('H2', '1'));
    await pumpEventQueue();
    expect(engine.state.notices.map((n) => n.id), contains('transfer:H2'));
    expect(alerts.shown, isEmpty);
  });

  test('marking read lowers the count and is stored', () async {
    await engine.update(unlocked());
    await engine.markRead(['rewards:1']);
    expect(engine.state.unread, 0);
    final store = await SharedPreferences.getInstance();
    expect(jsonDecode(store.getString('zunia.notices.read')!), ['rewards:1']);

    // A fresh engine reads it back.
    final again = NoticeEngine(
      alerts: alerts,
      reader: ChainReader(readsAllowed: () => true, fetch: net.fetch),
      openStream: streams.open,
      observeLifecycle: false,
    );
    addTearDown(again.dispose);
    await again.update(unlocked());
    expect(again.state.notices.single.read, isTrue);
  });

  test('locking closes every socket and forgets the account\'s arrivals', () async {
    await engine.update(unlocked());
    streams.opened['osmosis-1']!(incoming('H3', '5'));
    await pumpEventQueue();
    expect(streams.streams['osmosis-1']!.state, isNot(StreamState.closed));

    await engine.update(const NoticeEngineInputs(liveReads: true));
    expect(streams.streams['osmosis-1']!.state, StreamState.closed);
    expect(engine.state.running, isFalse);
    expect(engine.state.notices, isEmpty);
    final store = await SharedPreferences.getInstance();
    expect(store.getString('zunia.notices.arrivals'), isNull);
  });

  test('live reads off: no socket and no read at all', () async {
    live = false;
    await engine.update(
      const NoticeEngineInputs(
        accounts: [WatchedChain(osmosis, me)],
        accountIndex: 0,
        liveReads: false,
      ),
    );
    expect(streams.opened, isEmpty);
    expect(net.asked, isEmpty);
    expect(engine.state.running, isFalse);
  });

  test('governance on: an open vote is a notice with the days left', () async {
    await engine.update(
      unlocked(prefs: NotifyPrefs.defaults.copyWith(governance: true)),
    );
    final gov = engine.state.notices.firstWhere((n) => n.kind == NoticeKind.governance);
    expect(gov.id, 'gov:osmosis-1:901');
    expect(gov.title, 'Proposal 901 ends in 2d');
  });

  test('a claim seen on the next read re-arms the rewards notice', () async {
    await engine.update(unlocked());
    expect(engine.state.notices.map((n) => n.id), ['rewards:1']);
    net.rewards = '0';
    await engine.refreshNow();
    expect(engine.state.notices, isEmpty);
  });
}
