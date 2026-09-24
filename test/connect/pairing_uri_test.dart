import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/connect/pairing_uri.dart';

void main() {
  final vectors = (jsonDecode(
    File('test/fixtures/connect-v2-vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>)['pairingUris'] as Map<String, dynamic>;

  test('reads the links the SDK builds', () {
    for (final uri in (vectors['valid'] as List).cast<String>()) {
      final parsed = parsePairingUri(uri);
      expect(parsed, isNotNull, reason: uri);
      expect(parsed!.sessionId, 'Zf3kQ9xTn2LmP8vR4sWb1A');
      expect(parsed.joinToken, '78vWrA8rgZkX-X3b2kFXbZ4xGVuugyrwkOCgVtoTI8M');
      expect(parsed.dappPublicKey, '6DGzxA3X-LUeWXgypFq8GG5l4txV91YLSJSpCTDLHjg');
      expect(parsed.relay, 'wss://api.zunialab.com');
    }
  });

  test('refuses v1 links, bad ids, http relays and other paths', () {
    for (final uri in (vectors['invalid'] as List).cast<String>()) {
      expect(parsePairingUri(uri), isNull, reason: uri);
    }
    expect(parsePairingUri('zunia://connect?sid=abc&k=secret'), isNull);
    expect(parsePairingUri('wc:abc@2?relay-protocol=irn'), isNull);
  });

  test('accepts the https form of the same link', () {
    final query = Uri.parse((vectors['valid'] as List).first as String).query;
    expect(parsePairingUri('https://zunialab.com/connect?$query'), isNotNull);
    expect(parsePairingUri('https://zunialab.com/connect/?$query'), isNotNull);
    expect(parsePairingUri('https://zunialab.com/other?$query'), isNull);
  });

  group('relay policy', () {
    const policy = RelayPolicy(trusted: ['wss://api.zunialab.com']);
    const debug = RelayPolicy(trusted: ['wss://api.zunialab.com'], allowLocal: true);

    test('trusts only the listed relays in release builds', () {
      expect(policy.trusts('wss://api.zunialab.com'), isTrue);
      expect(policy.trusts('wss://api.zunialab.com:443/'), isTrue);
      expect(policy.trusts('wss://API.zunialab.com'), isTrue);
      expect(policy.trusts('ws://api.zunialab.com'), isFalse);
      expect(policy.trusts('wss://api.zunialab.com.evil.example'), isFalse);
      expect(policy.trusts('wss://relay.evil.example'), isFalse);
      expect(policy.trusts('wss://user@api.zunialab.com'), isFalse);
      expect(policy.trusts('ws://localhost:8788'), isFalse);
    });

    test('adds this machine and the local network in debug builds', () {
      for (final relay in [
        'ws://localhost:8788',
        'ws://127.0.0.1:8788',
        'ws://10.0.2.2:8788',
        'ws://192.168.1.20:8788',
        'ws://172.20.0.5:8788',
      ]) {
        expect(debug.trusts(relay), isTrue, reason: relay);
      }
      expect(debug.trusts('ws://172.32.0.5:8788'), isFalse);
      expect(debug.trusts('ws://8.8.8.8:8788'), isFalse);
      expect(debug.trusts('wss://relay.evil.example'), isFalse);
    });
  });

  test('builds the socket and session URLs from the relay base', () {
    expect(
      relaySocketUri('wss://api.zunialab.com', 'Zf3kQ9xTn2LmP8vR4sWb1A').toString(),
      'wss://api.zunialab.com/v1/connect/ws?sid=Zf3kQ9xTn2LmP8vR4sWb1A&role=wallet',
    );
    expect(
      relaySessionUri('ws://10.0.2.2:8788/', 'Zf3kQ9xTn2LmP8vR4sWb1A').toString(),
      'http://10.0.2.2:8788/v1/connect/sessions/Zf3kQ9xTn2LmP8vR4sWb1A',
    );
  });
}
