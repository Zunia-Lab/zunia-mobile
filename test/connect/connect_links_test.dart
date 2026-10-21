/// What each incoming link or scanned code means.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/connect/connect_links.dart';

const _sid = 'AAAAAAAAAAAAAAAAAAAAAA';
const _pairQuery =
    'v=2&sid=$_sid'
    '&t=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
    '&pk=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'
    '&r=wss%3A%2F%2Fapi.zunialab.com';
const _wc =
    'wc:7f6e504bfad60b485450578e05678ed3e8e8c4751d3c6160be17160d63ec90f9@2'
    '?relay-protocol=irn&symKey=587d5484ce2a2a6ee3ba1962fdd7e8588e06200c46823bd18fbd67def96ad303';

void main() {
  group('pairing', () {
    for (final link in [
      'zunia://connect?$_pairQuery',
      'https://zunialab.com/connect?$_pairQuery',
      'https://link.zunialab.com/connect?$_pairQuery',
      // The SDK accepts any https host for a pasted or scanned link.
      'https://dapp.example.com/connect?$_pairQuery',
      '  zunia://connect?$_pairQuery  ',
    ]) {
      test(link.trim(), () {
        final parsed = classifyLink(link);
        expect(parsed, isA<PairLink>());
        expect((parsed! as PairLink).uri.sessionId, _sid);
      });
    }
  });

  group('wake', () {
    for (final link in [
      'zunia://connect/wake?sid=$_sid',
      'zunia://connect/wake/?sid=$_sid',
      'zunia:connect/wake?sid=$_sid',
      'https://zunialab.com/connect/wake?sid=$_sid',
      'https://link.zunialab.com/connect/wake?sid=$_sid',
    ]) {
      test(link, () {
        final parsed = classifyLink(link);
        expect(parsed, isA<WakeLink>());
        expect((parsed! as WakeLink).sessionId, _sid);
      });
    }

    test('only on Zunia hosts', () {
      expect(
        classifyLink('https://evil.example/connect/wake?sid=$_sid'),
        isNull,
      );
    });

    test('a bad session id is not a wake link', () {
      expect(
        classifyLink('zunia://connect/wake?sid=short'),
        isA<UnsupportedLink>(),
      );
      expect(
        classifyLink('https://zunialab.com/connect/wake'),
        isA<UnsupportedLink>(),
      );
    });

    test('carries no secret even when the query has pairing fields', () {
      final parsed = classifyLink('zunia://connect/wake?$_pairQuery');
      expect(parsed, isA<WakeLink>());
    });
  });

  group('WalletConnect', () {
    for (final link in [
      _wc,
      'zunia://wc?uri=${Uri.encodeComponent(_wc)}',
      'zuniamobile://wc?uri=${Uri.encodeComponent(_wc)}',
      'https://zunialab.com/wc?uri=${Uri.encodeComponent(_wc)}',
      'https://link.zunialab.com/wc?uri=${Uri.encodeComponent(_wc)}',
    ]) {
      test(link.substring(0, 32), () {
        final parsed = classifyLink(link);
        expect(parsed, isA<WalletConnectPairLink>());
        expect((parsed! as WalletConnectPairLink).uri, _wc);
      });
    }

    test('version 1 is refused with a reason', () {
      expect(classifyLink('wc:abc@1?bridge=x&key=y'), isA<UnsupportedLink>());
    });

    test('a request redirect only wakes', () {
      final parsed = classifyLink(
        'zunia://wc?requestId=1700000000000123&sessionTopic=abc',
      );
      expect(parsed, isA<WalletConnectWakeLink>());
      final wake = parsed! as WalletConnectWakeLink;
      expect(wake.topic, 'abc');
      expect(wake.requestId, 1700000000000123);
      expect(classifyLink('zunia://wc'), isA<WalletConnectWakeLink>());
      expect(classifyLink('zunia://'), isA<WalletConnectWakeLink>());
    });
  });

  group('sites', () {
    test('zunia://dapp?url=https opens after confirmation', () {
      final parsed = classifyLink(
        'zunia://dapp?url=${Uri.encodeComponent('https://app.osmosis.zone/swap')}',
      );
      expect(parsed, isA<DappLink>());
      expect(
        (parsed! as DappLink).url.toString(),
        'https://app.osmosis.zone/swap',
      );
    });

    for (final target in [
      'http://app.example.com',
      'javascript:alert(1)',
      'file:///x',
      '',
    ]) {
      test('refuses $target', () {
        expect(
          classifyLink('zunia://dapp?url=${Uri.encodeComponent(target)}'),
          isA<UnsupportedLink>(),
        );
      });
    }
  });

  group('scanned only', () {
    const address = 'cosmos1lkr8xe3q2mhkjnhdlysznfhd8kjkpqrk6ammcd';

    test('a plain address', () {
      final parsed = classifyLink(address, scanned: true);
      expect(parsed, isA<AddressLink>());
      expect((parsed! as AddressLink).address, address);
    });

    test('cosmos: and JSON forms', () {
      expect(
        classifyLink('cosmos:$address', scanned: true),
        isA<AddressLink>(),
      );
      expect(
        classifyLink('{"address":"$address"}', scanned: true),
        isA<AddressLink>(),
      );
    });

    test('never from a link another app opened', () {
      expect(classifyLink(address), isNull);
    });
  });

  test('anything else is not a link', () {
    expect(classifyLink(''), isNull);
    expect(classifyLink('hello'), isNull);
    expect(classifyLink('https://example.com/'), isNull);
    expect(classifyLink('https://zunialab.com/'), isNull);
    expect(classifyLink('otherapp://connect?$_pairQuery'), isNull);
  });

  test('a damaged Zunia Connect link says so', () {
    expect(classifyLink('zunia://connect?v=1&x=y'), isA<UnsupportedLink>());
  });
}
