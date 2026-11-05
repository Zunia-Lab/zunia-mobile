/// Push registration: when the server is told about this device, what it is
/// told, and when it is told to forget it. Server and Firebase are faked.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/notifications/chain_stream.dart';
import 'package:zunia_mobile/notifications/device_alerts.dart';
import 'package:zunia_mobile/notifications/notice_engine.dart';
import 'package:zunia_mobile/notifications/notifications.dart';
import 'package:zunia_mobile/notifications/notify_prefs.dart';
import 'package:zunia_mobile/notifications/push_registration.dart';
import 'package:zunia_mobile/notifications/realtime_protocol.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

const osmoMe = 'osmo1qyyq79says4nyw2qga892hrrdfchsluxsmcjh8';
const safroMe = 'addr_safro1qyyq79says4nyw2qga892hrrdfchsluxsprx0e';

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

class _Backend implements PushBackend {
  final calls = <String>[];
  bool fail = false;

  @override
  Future<void> subscribe({
    required PushPlatform platform,
    required String token,
    required String locale,
    required PushPair pair,
  }) async {
    if (fail) throw const PushBackendException('down');
    calls.add('subscribe ${platform.name} $token $locale ${pair.key}');
  }

  @override
  Future<void> unsubscribe({
    required PushPlatform platform,
    required String token,
  }) async {
    if (fail) throw const PushBackendException('down');
    calls.add('unsubscribe ${platform.name} $token');
  }
}

class _Tokens implements PushTokens {
  String? current = 'token-1';
  int asked = 0;
  int deleted = 0;
  final _refreshed = StreamController<String>.broadcast();

  void rotate(String next) {
    current = next;
    _refreshed.add(next);
  }

  @override
  Future<String?> token() async {
    asked += 1;
    return current;
  }

  @override
  Stream<String> get refreshed => _refreshed.stream;

  @override
  Future<void> delete() async {
    deleted += 1;
    current = 'token-after-delete';
  }
}

const pairs = [PushPair('osmosis-1', osmoMe), PushPair('safrochain-1', safroMe)];

PushInputs on([List<PushPair> watched = pairs]) =>
    PushInputs(wanted: true, pairs: watched, locale: 'fr');

const off = PushInputs(wanted: false, pairs: pairs, locale: 'fr');

void main() {
  late _Backend backend;
  late _Tokens tokens;
  late MemoryPushRecordStore store;
  late DateTime now;
  late PushRegistrar registrar;

  setUp(() {
    backend = _Backend();
    tokens = _Tokens();
    store = MemoryPushRecordStore();
    now = DateTime(2026, 11, 5, 12);
    registrar = PushRegistrar(
      backend: backend,
      tokens: tokens,
      store: store,
      platform: PushPlatform.android,
      clock: () => now,
    );
  });

  tearDown(() => registrar.dispose());

  group('opt-in', () {
    test('nothing reaches the server, and no token is made, before the user opts in', () async {
      await registrar.sync(off);
      expect(backend.calls, isEmpty);
      expect(tokens.asked, 0);
      expect(store.record, isNull);
    });

    test('locked: nothing is sent and what the server holds stays', () async {
      await registrar.sync(on());
      backend.calls.clear();
      final before = store.record;
      await registrar.sync(on(const []));
      expect(backend.calls, isEmpty);
      expect(store.record, same(before));
    });

    test('inputs: wanted only with alerts, live reads, transfers and the system yes', () {
      PushInputs inputs({
        bool alerts = true,
        bool liveReads = true,
        bool transfers = true,
        AlertPermission permission = AlertPermission.granted,
      }) =>
          pushInputsOf(
            prefs: AppPreferences(alerts: alerts, liveReads: liveReads),
            notify: NotifyPrefs(transfers: transfers),
            permission: permission,
            accounts: const [ChainAccount(chain: osmosis, address: osmoMe)],
            locale: 'fr',
          );

      expect(inputs().wanted, isTrue);
      expect(inputs(permission: AlertPermission.provisional).wanted, isTrue);
      expect(inputs(alerts: false).wanted, isFalse);
      expect(inputs(liveReads: false).wanted, isFalse);
      expect(inputs(transfers: false).wanted, isFalse);
      expect(inputs(permission: AlertPermission.off).wanted, isFalse);
      expect(inputs(permission: AlertPermission.unavailable).wanted, isFalse);
      expect(inputs().pairs, [const PushPair('osmosis-1', osmoMe)]);
      expect(inputs().locale, 'fr');
    });
  });

  group('registration', () {
    test('posts every watched pair once, then stays quiet', () async {
      await registrar.sync(on());
      expect(backend.calls, [
        'subscribe android token-1 fr osmosis-1|$osmoMe',
        'subscribe android token-1 fr safrochain-1|$safroMe',
      ]);
      expect(store.record!.token, 'token-1');
      expect(
        store.record!.fingerprint,
        pushFingerprint(PushPlatform.android, 'token-1', 'fr', pairs),
      );

      backend.calls.clear();
      await registrar.sync(on());
      // The same set in another order is the same registration.
      await registrar.sync(on(pairs.reversed.toList()));
      expect(backend.calls, isEmpty);
    });

    test('an unchanged set is posted again after seven days, without a removal', () async {
      await registrar.sync(on());
      backend.calls.clear();
      now = now.add(pushRefreshInterval - const Duration(minutes: 1));
      await registrar.sync(on());
      expect(backend.calls, isEmpty);

      now = now.add(const Duration(minutes: 2));
      await registrar.sync(on());
      expect(backend.calls, [
        'subscribe android token-1 fr osmosis-1|$osmoMe',
        'subscribe android token-1 fr safrochain-1|$safroMe',
      ]);
    });

    test('a changed set clears the device first, so a dropped address stops waking it', () async {
      await registrar.sync(on());
      backend.calls.clear();
      await registrar.sync(on(const [PushPair('osmosis-1', osmoMe)]));
      expect(backend.calls, [
        'unsubscribe android token-1',
        'subscribe android token-1 fr osmosis-1|$osmoMe',
      ]);
    });

    test('a new Firebase token moves the registration to it', () async {
      await registrar.sync(on());
      backend.calls.clear();
      tokens.rotate('token-2');
      await pumpEventQueue();
      expect(backend.calls, [
        'unsubscribe android token-1',
        'subscribe android token-2 fr osmosis-1|$osmoMe',
        'subscribe android token-2 fr safrochain-1|$safroMe',
      ]);
      expect(store.record!.token, 'token-2');
    });

    test('a failure records nothing, so the next sync tries again', () async {
      backend.fail = true;
      await registrar.sync(on());
      expect(store.record, isNull);

      backend.fail = false;
      await registrar.sync(on());
      expect(backend.calls, hasLength(2));
      expect(store.record, isNotNull);
    });

    test('calls that overlap end on the latest inputs', () async {
      final first = registrar.sync(on());
      final second = registrar.sync(on(const [PushPair('osmosis-1', osmoMe)]));
      await Future.wait([first, second]);
      expect(
        store.record!.fingerprint,
        pushFingerprint(
          PushPlatform.android,
          'token-1',
          'fr',
          const [PushPair('osmosis-1', osmoMe)],
        ),
      );
      expect(backend.calls.last, 'subscribe android token-1 fr osmosis-1|$osmoMe');
    });
  });

  group('removal', () {
    test('turning notifications off removes the device and drops the token', () async {
      await registrar.sync(on());
      backend.calls.clear();
      await registrar.sync(off);
      expect(backend.calls, ['unsubscribe android token-1']);
      expect(tokens.deleted, 1);
      expect(store.record, isNull);
    });

    test('erasing the wallet removes the device', () async {
      await registrar.sync(on());
      backend.calls.clear();
      await registrar.forget();
      expect(backend.calls, ['unsubscribe android token-1']);
      expect(tokens.deleted, 1);
      expect(store.record, isNull);
    });

    test('a device that never registered sends nothing when erased', () async {
      await registrar.forget();
      expect(backend.calls, isEmpty);
      expect(tokens.deleted, 0);
      expect(tokens.asked, 0);
    });

    test('a removal that fails is retried, the record kept until it lands', () async {
      await registrar.sync(on());
      backend
        ..calls.clear()
        ..fail = true;
      await registrar.sync(off);
      expect(store.record, isNotNull);

      backend.fail = false;
      await registrar.sync(off);
      expect(backend.calls, ['unsubscribe android token-1']);
      expect(store.record, isNull);
    });
  });

  group('a push while the app runs', () {
    late List<String> moved;
    late NoticeEngine engine;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      moved = [];
      engine = NoticeEngine(
        alerts: RecordingDeviceAlerts(),
        reader: ChainReader(
          readsAllowed: () => true,
          fetch: (uri, _) async => const LcdResponse(404, '{}'),
        ),
        openStream: ({
          required String chainId,
          required String rpc,
          required List<Subscription> subscriptions,
          required void Function(TxNotice notice) onTx,
          required void Function(StreamState state) onState,
        }) =>
            ChainStream(
              chainId: chainId,
              rpc: rpc,
              subscriptions: subscriptions,
              onTx: onTx,
              // A connector that never answers: no socket, no retry timer.
              connect: (_) => Completer<WebSocket>().future,
            ),
        onBalancesMoved: moved.add,
        observeLifecycle: false,
      );
    });

    tearDown(() => engine.dispose());

    test('reads that chain again at once', () async {
      await engine.update(
        const NoticeEngineInputs(
          accounts: [WatchedChain(osmosis, osmoMe)],
          accountIndex: 0,
          liveReads: true,
        ),
      );
      engine.remoteActivity('osmosis-1');
      await pumpEventQueue();
      expect(moved, ['osmosis-1']);
    });

    test('does nothing while locked or with live reads off', () async {
      engine.remoteActivity('osmosis-1');
      await engine.update(
        const NoticeEngineInputs(
          accounts: [WatchedChain(osmosis, osmoMe)],
          accountIndex: 0,
        ),
      );
      engine.remoteActivity('osmosis-1');
      await pumpEventQueue();
      expect(moved, isEmpty);
    });
  });
}
