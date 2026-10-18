/// The CometBFT dialect: what the wallet subscribes to and how it reads what
/// comes back, on both attribute encodings.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/notifications/notices.dart';
import 'package:zunia_mobile/notifications/realtime_protocol.dart';

const me = 'osmo1qyyq79says4nyw2qga892hrrdfchsluxsmcjh8';
const usdc =
    'ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4';

String b64(String v) => base64.encode(utf8.encode(v));

String frame({
  required String id,
  required Map<String, List<String>> events,
  int code = 0,
}) =>
    jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'query': '…',
        'data': {
          'type': 'tendermint/event/Tx',
          'value': {
            'TxResult': {
              'height': '123',
              'result': {'code': code},
            },
          },
        },
        'events': events,
      },
    });

void main() {
  test('websocket URL from a registry RPC', () {
    expect(websocketUrl('https://rpc.osmosis.zone'), 'wss://rpc.osmosis.zone/websocket');
    expect(websocketUrl('https://rpc.example.com/'), 'wss://rpc.example.com/websocket');
    expect(websocketUrl('https://host/rpc/'), 'wss://host/rpc/websocket');
    expect(websocketUrl('http://localhost:26657'), 'ws://localhost:26657/websocket');
    expect(websocketUrl('ftp://nope'), isNull);
    expect(websocketUrl(''), isNull);
    expect(websocketUrl(null), isNull);
  });

  test('two subscriptions per chain: coins in and transactions signed', () {
    final subs = subscriptionsFor('osmosis-1', me);
    expect(subs.map((s) => s.direction), [TxDirection.received, TxDirection.sent]);
    expect(subs.first.query, "tm.event='Tx' AND transfer.recipient='$me'");
    expect(subs.last.query, "tm.event='Tx' AND message.sender='$me'");
    expect(subs.first.id, 'osmosis-1|$me|in');
    final sent = jsonDecode(subscribeFrame(subs.first)) as Map;
    expect(sent['method'], 'subscribe');
    expect((sent['params'] as Map)['query'], subs.first.query);
    // A quote in a hand-typed custom prefix cannot break the query.
    expect(subscriptionsFor('x', "a'b1x").first.query, contains("'ab1x'"));
  });

  test('coins split at the first non-digit, so IBC denoms survive', () {
    expect(parseCoins('1000uatom,25$usdc'), const [
      MovedCoin('uatom', '1000'),
      MovedCoin(usdc, '25'),
    ]);
    expect(parseCoins('5factory/osmo1abc/LAB'), const [MovedCoin('factory/osmo1abc/LAB', '5')]);
    expect(parseCoins('garbage, ,7'), isEmpty);
  });

  test('base64 attributes are decoded only when they really are base64', () {
    expect(decodeAttribute(b64('transfer.recipient')), 'transfer.recipient');
    // A bech32 address is valid base64 in shape but must not be decoded.
    expect(decodeAttribute(me), me);
    expect(decodeAttribute('sender'), 'sender');
  });

  test('a CometBFT 0.37 frame (plain attributes) becomes an arrival', () {
    final parsed = parseFrame(
      frame(
        id: 'osmosis-1|$me|in',
        events: {
          'tx.hash': ['ABC'],
          'tx.height': ['99'],
          'transfer.recipient': ['osmo1other', me, me],
          'transfer.amount': ['1uosmo', '1500000uosmo', '2000000$usdc'],
          'message.action': ['/cosmos.bank.v1beta1.MsgSend'],
        },
      ),
      'osmosis-1',
    );
    expect(parsed, isA<TxFrame>());
    final notice = (parsed as TxFrame).notice;
    expect(notice.hash, 'ABC');
    expect(notice.height, 99);
    expect(notice.direction, TxDirection.received);
    // Pairwise: the stranger's 1uosmo is not ours.
    expect(notice.coins, const [MovedCoin('uosmo', '1500000'), MovedCoin(usdc, '2000000')]);
    final arrival = arrivalFrom(notice, 42)!;
    expect(arrival.hash, 'ABC');
    expect(arrival.at, 42);
  });

  test('a CometBFT 0.34 frame (base64 attributes) reads the same', () {
    final parsed = parseFrame(
      frame(
        id: 'osmosis-1|$me|in',
        events: {
          b64('tx.hash'): ['DEF'],
          b64('transfer.recipient'): [b64(me)],
          b64('transfer.amount'): [b64('700uosmo')],
        },
      ),
      'osmosis-1',
    ) as TxFrame;
    expect(parsed.notice.hash, 'DEF');
    expect(parsed.notice.coins, const [MovedCoin('uosmo', '700')]);
  });

  test('outgoing and failed transactions are not arrivals', () {
    final sent = parseFrame(
      frame(
        id: 'osmosis-1|$me|out',
        events: {
          'tx.hash': ['OUT'],
          'transfer.sender': [me],
          'transfer.amount': ['5uosmo'],
        },
      ),
      'osmosis-1',
    ) as TxFrame;
    expect(sent.notice.direction, TxDirection.sent);
    expect(arrivalFrom(sent.notice, 1), isNull);

    final failed = parseFrame(
      frame(
        id: 'osmosis-1|$me|in',
        code: 5,
        events: {
          'tx.hash': ['BAD'],
          'transfer.recipient': [me],
          'transfer.amount': ['5uosmo'],
        },
      ),
      'osmosis-1',
    ) as TxFrame;
    expect(failed.notice.succeeded, isFalse);
    expect(arrivalFrom(failed.notice, 1), isNull);
  });

  test('acks, errors and junk are told apart, never thrown', () {
    expect(parseFrame('{"jsonrpc":"2.0","id":"x|y|in","result":{}}', 'c'), isA<AckFrame>());
    final error = parseFrame(
      '{"jsonrpc":"2.0","id":"x","error":{"message":"bad","data":"query"}}',
      'c',
    );
    expect((error as ErrorFrame).message, 'bad: query');
    expect(parseFrame('not json', 'c'), isA<IgnoredFrame>());
    expect(parseFrame('[1,2]', 'c'), isA<IgnoredFrame>());
  });

  test('backoff grows with jitter and stays under the ceiling', () {
    final low = Random(1);
    for (var attempt = 0; attempt < 30; attempt++) {
      final d = backoffDelay(attempt, low);
      expect(d.inMilliseconds, greaterThanOrEqualTo(1000));
      expect(d, lessThanOrEqualTo(maxBackoff));
    }
  });
}
