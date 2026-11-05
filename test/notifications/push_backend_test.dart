/// What the app sends Zunia's push server, byte for byte, against a loopback
/// server. Kept apart from the widget binding, which fakes every HttpClient.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/config/connect_config.dart';
import 'package:zunia_mobile/notifications/push_registration.dart';

class _Seen {
  const _Seen(this.method, this.path, this.contentType, this.body);

  final String method;
  final String path;
  final String? contentType;
  final Object? body;
}

void main() {
  late HttpServer server;
  late List<_Seen> seen;
  var status = 200;

  setUp(() async {
    seen = [];
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final raw = await utf8.decodeStream(request);
      seen.add(
        _Seen(
          request.method,
          request.uri.path,
          request.headers.contentType?.mimeType,
          raw.isEmpty ? null : jsonDecode(raw),
        ),
      );
      request.response.statusCode = status;
      request.response.write('{"ok":${status == 200}}');
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  HttpPushBackend backend() =>
      HttpPushBackend(Uri.parse('http://127.0.0.1:${server.port}'));

  test('subscribe posts one pair as the server expects', () async {
    await backend().subscribe(
      platform: PushPlatform.android,
      token: 'fcm-token-123',
      locale: 'fr',
      pair: const PushPair('osmosis-1', 'osmo1qyyq79says4nyw2qga892hrrdfchsluxsmcjh8'),
    );
    expect(seen, hasLength(1));
    expect(seen.single.method, 'POST');
    expect(seen.single.path, '/v1/devices/subscribe');
    expect(seen.single.contentType, 'application/json');
    expect(seen.single.body, {
      'platform': 'android',
      'pushToken': 'fcm-token-123',
      'locale': 'fr',
      'prefs': <String, Object>{},
      'chainId': 'osmosis-1',
      'address': 'osmo1qyyq79says4nyw2qga892hrrdfchsluxsmcjh8',
    });
  });

  test('unsubscribe deletes the device by platform and token', () async {
    await backend().unsubscribe(platform: PushPlatform.ios, token: 'fcm-token-123');
    expect(seen.single.method, 'DELETE');
    expect(seen.single.path, '/v1/devices/unsubscribe');
    expect(seen.single.body, {'platform': 'ios', 'pushToken': 'fcm-token-123'});
  });

  test('a refusal is an error, so nothing is recorded as registered', () async {
    status = 400;
    await expectLater(
      backend().subscribe(
        platform: PushPlatform.ios,
        token: 'fcm-token-123',
        locale: 'en',
        pair: const PushPair('cosmoshub-4', 'cosmos1qyyq79says4nyw2qga892hrrdfchslux9h8tvx'),
      ),
      throwsA(isA<PushBackendException>()),
    );
  });

  test('the push server is the Connect relay host over HTTPS', () {
    expect(zuniaBackendBase(), Uri.parse('https://api.zunialab.com'));
    expect(
      zuniaBackendBase().resolve('/v1/devices/subscribe').toString(),
      'https://api.zunialab.com/v1/devices/subscribe',
    );
  });
}
