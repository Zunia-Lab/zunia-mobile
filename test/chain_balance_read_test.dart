import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/chain_client.dart';

/// The balance read is the one place where "the endpoint did not answer" used
/// to turn into "you hold nothing": `_getJson` returned null on any failure and
/// the sum of null was '0', which the send screen then reported as the user's
/// balance and refused to send against. These tests pin the three outcomes
/// apart - a number, a genuine zero, and a failure carrying why - against a
/// real loopback LCD so the HttpClient path is the one under test.
void main() {
  late HttpServer server;
  late ChainClient client;

  /// Routes by path fragment; anything unrouted answers 404 so a missed route
  /// shows up as a failing expectation rather than a hang.
  Future<void> serve(
    Map<String, FutureOr<void> Function(HttpRequest)> routes,
  ) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      for (final entry in routes.entries) {
        if (request.uri.path.contains(entry.key)) {
          await entry.value(request);
          return;
        }
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    client = ChainClient(
      enabled: true,
      // Short budget: a hung endpoint should cost a test a fraction of a
      // second, not the nine seconds the app allows a real one.
      timeout: const Duration(milliseconds: 400),
    );
  }

  FutureOr<void> Function(HttpRequest) json(Object body, {int status = 200}) {
    return (request) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(body is String ? body : jsonEncode(body));
      await request.response.close();
    };
  }

  /// Accepts the connection and never answers.
  FutureOr<void> Function(HttpRequest) hang() => (_) => Completer<void>().future;

  ChainEntry chain({String? rest}) => ChainEntry(
        chainId: 'testchain-1',
        chainName: 'Testchain',
        bech32Prefix: 'test',
        coinType: 118,
        network: 'testnet',
        coinDenom: 'TEST',
        coinMinimalDenom: 'utest',
        coinDecimals: 6,
        feeDenom: 'TEST',
        feeMinimalDenom: 'utest',
        feeDecimals: 6,
        rest: rest ?? 'http://127.0.0.1:${server.port}',
      );

  const address = 'test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq';

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  test('a funded account reads as the number the endpoint gave', () async {
    await serve({
      '/bank/': json({
        'balances': [
          {'denom': 'utest', 'amount': '500000000'},
          {'denom': 'uother', 'amount': '7'},
        ],
        'pagination': {'next_key': null},
      }),
      '/staking/': json({
        'delegation_responses': [
          {
            'balance': {'denom': 'utest', 'amount': '25000000'},
          },
        ],
      }),
      '/distribution/': json({
        'total': [
          {'denom': 'utest', 'amount': '1234.500000000000000000'},
        ],
      }),
    });

    final read = await client.balance(chain(), address);

    expect(read, isA<BalanceLoaded>());
    final balance = (read as BalanceLoaded).balance;
    expect(balance.available, '500000000');
    expect(balance.staked, '25000000');
    // Distribution totals carry a decimal tail; the chain pays the integer
    // part, so rounding up here would overstate what is claimable.
    expect(balance.rewards, '1234');
    expect(balance.otherDenoms, ['uother']);
  });

  test('an empty account reads as a genuine zero, not a failure', () async {
    await serve({
      '/bank/': json({'balances': <Object>[], 'pagination': {}}),
      '/staking/': json({'delegation_responses': <Object>[]}),
      '/distribution/': json({'total': <Object>[]}),
    });

    final read = await client.balance(chain(), address);

    expect(read, isA<BalanceLoaded>());
    final balance = (read as BalanceLoaded).balance;
    expect(balance.available, '0');
    expect(balance.staked, '0');
    expect(balance.rewards, '0');
    expect(balance.otherDenoms, isEmpty);
  });

  test('a timeout is a failure, never a zero', () async {
    await serve({
      '/bank/': hang(),
      '/staking/': json({'delegation_responses': <Object>[]}),
      '/distribution/': json({'total': <Object>[]}),
    });

    final read = await client.balance(chain(), address);

    expect(read, isA<BalanceUnavailable>());
    final failure = (read as BalanceUnavailable).failure;
    expect(failure.kind, ChainReadFailureKind.timedOut);
    expect(failure.message, contains('did not answer in time'));
    // The reason must not read as a statement about the account.
    expect(failure.message, isNot(contains('0')));
  });

  test('a rate limit is a failure carrying the status', () async {
    await serve({
      '/bank/': json({'error': 'slow down'}, status: 429),
      '/staking/': json({'delegation_responses': <Object>[]}),
      '/distribution/': json({'total': <Object>[]}),
    });

    final read = await client.balance(chain(), address);

    expect(read, isA<BalanceUnavailable>());
    final failure = (read as BalanceUnavailable).failure;
    expect(failure.kind, ChainReadFailureKind.badStatus);
    expect(failure.statusCode, 429);
    expect(failure.message, contains('HTTP 429'));
  });

  test('a body that is not JSON is a failure, not a zero', () async {
    await serve({
      '/bank/': json('<html>gateway</html>'),
      '/staking/': json({'delegation_responses': <Object>[]}),
      '/distribution/': json({'total': <Object>[]}),
    });

    final read = await client.balance(chain(), address);

    expect(read, isA<BalanceUnavailable>());
    expect(
      (read as BalanceUnavailable).failure.kind,
      ChainReadFailureKind.malformedBody,
    );
  });

  test('valid JSON in the wrong shape is a failure, not a zero', () async {
    await serve({
      // A 200 with an error envelope, which some proxies return instead of a
      // status. There is no balances array, so there is no balance to report.
      '/bank/': json({'code': 5, 'message': 'account not found'}),
      '/staking/': json({'delegation_responses': <Object>[]}),
      '/distribution/': json({'total': <Object>[]}),
    });

    final read = await client.balance(chain(), address);

    expect(read, isA<BalanceUnavailable>());
    final failure = (read as BalanceUnavailable).failure;
    expect(failure.kind, ChainReadFailureKind.malformedBody);
    expect(failure.detail, 'balances is not a list');
  });

  test('one failed leg fails the whole read rather than inventing a zero',
      () async {
    await serve({
      '/bank/': json({
        'balances': [
          {'denom': 'utest', 'amount': '500000000'},
        ],
      }),
      '/staking/': json({'delegation_responses': <Object>[]}),
      '/distribution/': json({'error': 'boom'}, status: 503),
    });

    final read = await client.balance(chain(), address);

    expect(read, isA<BalanceUnavailable>());
    expect((read as BalanceUnavailable).failure.statusCode, 503);
  });

  test('a denom absent from a truncated page is unknown, not zero', () async {
    await serve({
      // The account holds many denoms and the endpoint paged; ours could be on
      // a page we never read, so reporting 0 would be a guess.
      '/bank/': json({
        'balances': [
          {'denom': 'uother', 'amount': '5'},
        ],
        'pagination': {'next_key': 'c2Vjb25kLXBhZ2U='},
      }),
      '/staking/': json({'delegation_responses': <Object>[]}),
      '/distribution/': json({'total': <Object>[]}),
    });

    final read = await client.balance(chain(), address);

    expect(read, isA<BalanceUnavailable>());
    expect(
      (read as BalanceUnavailable).failure.kind,
      ChainReadFailureKind.incompletePage,
    );
  });

  test('a zero for this denom keeps the denoms it did see', () async {
    await serve({
      '/bank/': json({
        'balances': [
          {'denom': 'uosmo', 'amount': '900'},
          {'denom': 'ibc/ABC', 'amount': '12'},
        ],
        'pagination': {'next_key': ''},
      }),
      '/staking/': json({'delegation_responses': <Object>[]}),
      '/distribution/': json({'total': <Object>[]}),
    });

    final read = await client.balance(chain(), address);

    expect(read, isA<BalanceLoaded>());
    final balance = (read as BalanceLoaded).balance;
    expect(balance.available, '0');
    // The screen uses this to say "no TEST here, but two other denominations"
    // rather than let a misconfigured minimal denom read as an empty account.
    expect(balance.otherDenoms, ['uosmo', 'ibc/ABC']);
  });

  test('a chain with no REST endpoint says so instead of reporting zero',
      () async {
    await serve({});

    final read = await client.balance(chain(rest: ''), address);

    expect(read, isA<BalanceUnavailable>());
    expect(
      (read as BalanceUnavailable).failure.kind,
      ChainReadFailureKind.noEndpoint,
    );
  });

  test('live reads off is a reason, and nothing leaves the device', () async {
    var hits = 0;
    await serve({
      '/': (request) async {
        hits++;
        await request.response.close();
      },
    });
    final offline = ChainClient(enabled: false);
    addTearDown(offline.close);

    final read = await offline.balance(chain(), address);

    expect(read, isA<BalanceUnavailable>());
    expect(
      (read as BalanceUnavailable).failure.kind,
      ChainReadFailureKind.readsDisabled,
    );
    expect(hits, 0);
  });
}
