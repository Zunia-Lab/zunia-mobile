/// Links other apps open Zunia with: where each goes, and that nothing but a
/// wake happens behind the lock screen.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/services/deep_link_handler.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';

const _sid = 'AAAAAAAAAAAAAAAAAAAAAA';
const _pair =
    'zunia://connect?v=2&sid=$_sid'
    '&t=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
    '&pk=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'
    '&r=wss%3A%2F%2Fapi.zunialab.com&ret=myapp%3A%2F%2Fdone';
const _wc =
    'wc:7f6e504bfad60b485450578e05678ed3e8e8c4751d3c6160be17160d63ec90f9@2'
    '?relay-protocol=irn&symKey=587d5484ce2a2a6ee3ba1962fdd7e8588e06200c46823bd18fbd67def96ad303';

class _Source implements LinkSource {
  _Source([this._initial]);

  final Uri? _initial;
  final controller = StreamController<Uri>();

  @override
  Future<Uri?> initial() async => _initial;

  @override
  Stream<Uri> get links => controller.stream;
}

class _Native extends NativeConnectService {
  final calls = <String>[];
  final errors = <String>[];
  Set<String> known = {_sid};

  @override
  Future<NativeConnectRequest> pair(
    String link, {
    bool sameDevice = false,
  }) async {
    calls.add('pair sameDevice=$sameDevice');
    return Completer<NativeConnectRequest>().future;
  }

  @override
  bool wake(String sessionId) {
    calls.add('wake $sessionId');
    return known.contains(sessionId);
  }

  @override
  void reportError(Object error) =>
      errors.add(error is ConnectException ? error.message : '$error');
}

class _WalletConnect extends StubWalletConnectService {
  final calls = <String>[];

  @override
  bool get isReady => true;

  @override
  Future<void> pair(String uri, {bool sameDevice = false}) async {
    calls.add('pair $uri sameDevice=$sameDevice');
  }

  @override
  Future<void> wake({String? topic}) async => calls.add('wake $topic');
}

void main() {
  late _Source source;
  late _Native native;
  late _WalletConnect wc;
  late DeepLinkHandler handler;
  late List<Uri> dapps;

  Future<void> open(String link) async {
    source.controller.add(Uri.parse(link));
    await pumpEventQueue();
  }

  setUp(() async {
    source = _Source();
    native = _Native();
    wc = _WalletConnect();
    handler = DeepLinkHandler(
      source: source,
      walletConnect: wc,
      nativeConnect: native,
    );
    dapps = [];
    handler.dappRequests.listen(dapps.add);
    await handler.start();
  });

  tearDown(() async {
    await handler.dispose();
    await source.controller.close();
  });

  group('while locked', () {
    test(
      'a pairing link waits, then pairs as same-device after unlock',
      () async {
        await open(_pair);
        expect(native.calls, isEmpty);
        await handler.attach();
        expect(native.calls, ['pair sameDevice=true']);
      },
    );

    test('a wake link brings the session up right away', () async {
      await open('zunia://connect/wake?sid=$_sid');
      expect(native.calls, ['wake $_sid']);
      await handler.attach();
      expect(native.calls, ['wake $_sid']);
    });

    test('an unknown session in a wake link is ignored silently', () async {
      await open('https://zunialab.com/connect/wake?sid=${'Z' * 22}');
      expect(native.calls, ['wake ${'Z' * 22}']);
      expect(native.errors, isEmpty);
    });

    test('a site link waits for unlock, then asks', () async {
      await open('zunia://dapp?url=https%3A%2F%2Fapp.osmosis.zone');
      expect(dapps, isEmpty);
      await handler.attach();
      await pumpEventQueue();
      expect(dapps.single.toString(), 'https://app.osmosis.zone');
    });

    test(
      'links run in the order they came, and locking again holds them again',
      () async {
        await open('zunia://wc?uri=${Uri.encodeComponent(_wc)}');
        await open(_pair);
        await handler.attach();
        expect(wc.calls, ['pair $_wc sameDevice=true']);
        expect(native.calls, ['pair sameDevice=true']);
        handler.detach();
        await open(_pair);
        expect(native.calls, hasLength(1));
      },
    );

    test('the link that launched the app counts too', () async {
      await handler.dispose();
      source = _Source(Uri.parse(_pair));
      handler = DeepLinkHandler(
        source: source,
        walletConnect: wc,
        nativeConnect: native,
      );
      await handler.start();
      expect(native.calls, isEmpty);
      await handler.attach();
      expect(native.calls, ['pair sameDevice=true']);
    });
  });

  group('unlocked', () {
    setUp(() => handler.attach());

    test('WalletConnect links in every form pair as same-device', () async {
      for (final link in [
        _wc,
        'zunia://wc?uri=${Uri.encodeComponent(_wc)}',
        'zuniamobile://wc?uri=${Uri.encodeComponent(_wc)}',
        'https://zunialab.com/wc?uri=${Uri.encodeComponent(_wc)}',
        'https://link.zunialab.com/wc?uri=${Uri.encodeComponent(_wc)}',
      ]) {
        await open(link);
      }
      expect(wc.calls, List.filled(5, 'pair $_wc sameDevice=true'));
    });

    test('a WalletConnect request redirect wakes that session', () async {
      await open('zunia://wc?requestId=1&sessionTopic=abc');
      expect(wc.calls, ['wake abc']);
    });

    test('https pairing links on Zunia hosts pair', () async {
      await open(
        _pair.replaceFirst(
          'zunia://connect',
          'https://link.zunialab.com/connect',
        ),
      );
      expect(native.calls, ['pair sameDevice=true']);
    });

    test(
      'links found inside Zunia never send the user to another app',
      () async {
        await handler.handleUri(Uri.parse(_pair));
        await handler.handleUri(Uri.parse(_wc));
        expect(native.calls, ['pair sameDevice=false']);
        expect(wc.calls, ['pair $_wc sameDevice=false']);
      },
    );

    test('damaged or old links say why; unknown ones are ignored', () async {
      await open('zunia://connect?v=1');
      await open('wc:abc@1?bridge=x');
      await open('zunia://dapp?url=http%3A%2F%2Fplain.example');
      await open('https://example.com/whatever');
      expect(native.errors, hasLength(3));
      expect(native.calls, isEmpty);
      expect(dapps, isEmpty);
    });

    test('addresses are only for the scanner', () async {
      await open('cosmos:cosmos1lkr8xe3q2mhkjnhdlysznfhd8kjkpqrk6ammcd');
      expect(native.calls, isEmpty);
      expect(native.errors, isEmpty);
    });
  });

  test('parseDappUrl keeps https only', () {
    expect(
      DeepLinkHandler.parseDappUrl(
        Uri.parse('zunia://dapp?url=https%3A%2F%2Fa.example'),
      ),
      'https://a.example',
    );
    expect(
      DeepLinkHandler.parseDappUrl(
        Uri.parse('zunia://dapp?url=http%3A%2F%2Fa.example'),
      ),
      isNull,
    );
  });
}
