/// The connect screens: Connected apps, the request queue, the scanner's
/// paste path, and what the review sheet says for WalletConnect and for a
/// site that opened Zunia on this phone.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/connect/app_return.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/connect_inbox.dart';
import 'package:zunia_mobile/screens/native_request_sheets.dart';
import 'package:zunia_mobile/screens/qr_scanner_screen.dart';
import 'package:zunia_mobile/screens/sessions_screen.dart';
import 'package:zunia_mobile/services/deep_link_handler.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

const _hub = 'cosmoshub-4';
const _osmo = 'osmosis-1';
const _hubAddress = 'cosmos1lkr8xe3q2mhkjnhdlysznfhd8kjkpqrk6ammcd';
const _osmoAddress = 'osmo1lkr8xe3q2mhkjnhdlysznfhd8kjkpqrkfcwyq5';
const _sid = 'AAAAAAAAAAAAAAAAAAAAAA';

NativeDappIdentity _dapp() => const NativeDappIdentity(
  metadata: NativeDappMetadata(name: 'Example', url: 'https://app.example.com'),
  verifiedOrigin: 'https://app.example.com',
  relay: 'wss://api.zunialab.com',
);

NativeActiveSession _session({List<String> chains = const [_hub, _osmo]}) =>
    NativeActiveSession(
      sessionId: _sid,
      dapp: _dapp(),
      chains: chains,
      requestedChains: const [_hub, _osmo],
      accounts: [
        if (chains.contains(_hub))
          const NativeConnectAccount(
            chainId: _hub,
            address: _hubAddress,
            pubKey: 'AAAA',
          ),
        if (chains.contains(_osmo))
          const NativeConnectAccount(
            chainId: _osmo,
            address: _osmoAddress,
            pubKey: 'AAAA',
          ),
      ],
      online: true,
      expiresAt: DateTime.now().add(const Duration(hours: 23, minutes: 30)),
      pairedAt: DateTime.now().subtract(const Duration(minutes: 30)),
      sameDevice: true,
      returnTarget: ReturnTarget.parse('https://app.example.com/back'),
    );

class _Native extends NativeConnectService {
  _Native(this.sessions);

  List<NativeActiveSession> sessions;
  final chainCalls = <List<String>>[];
  final disconnected = <String>[];

  void changed() =>
      switchAccount(accountIndex: 0, accountsFor: (_) => const []);

  @override
  List<NativeActiveSession> get activeSessions => sessions;

  @override
  Future<void> setSessionChains(
    String sessionId,
    List<String> chains, {
    List<NativeConnectAccount> Function(List<String> chainIds)? accountsFor,
  }) async {
    chainCalls.add(chains);
    sessions = [_session(chains: chains)];
    changed();
  }

  @override
  Future<void> disconnectSession(String sessionId) async {
    disconnected.add(sessionId);
    sessions = [];
    changed();
  }

  @override
  Future<void> disconnectAll() async {
    disconnected.addAll(sessions.map((s) => s.sessionId));
    sessions = [];
    changed();
  }
}

class _WalletConnect extends StubWalletConnectService {
  _WalletConnect([this.sessions = const []]);

  final List<WcActiveSession> sessions;

  @override
  List<WcActiveSession> get activeSessions => sessions;
}

class _NoLinks implements LinkSource {
  @override
  Future<Uri?> initial() async => null;

  @override
  Stream<Uri> get links => const Stream.empty();
}

class _Answers implements ForeignRequestAnswers {
  final calls = <String>[];

  @override
  Future<void> approveConnect(
    NativeConnectRequest request, {
    required List<NativeConnectAccount> accounts,
    required int accountIndex,
  }) async => calls.add('approveConnect');

  @override
  Future<void> rejectConnect(NativeConnectRequest request) async =>
      calls.add('rejectConnect');

  @override
  Future<void> approveSign(
    NativeSignRequest request,
    Map<String, Object?> result,
  ) async => calls.add('approveSign');

  @override
  Future<void> rejectSign(
    NativeSignRequest request, {
    required String code,
    required String message,
  }) async => calls.add('rejectSign ${request.id} $code');

  @override
  Future<void> expire(NativeRequest request) async => calls.add('expire');
}

ThemeData _theme(TargetPlatform platform) =>
    ZuniaTheme.dark().copyWith(platform: platform);

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  required List<Override> overrides,
  TargetPlatform platform = TargetPlatform.iOS,
  Size size = const Size(320, 640),
  double textScale = 1.3,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: _theme(platform),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Connected apps', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets(
        'lists sessions with status and expiry at 320dp, large text (${platform.name})',
        (tester) async {
          final native = _Native([_session()]);
          final wc = _WalletConnect([
            WcActiveSession(
              topic: 'topic-1',
              name: 'Osmosis',
              url: 'https://app.osmosis.zone',
              chains: const [_osmo],
              requestedChains: const [_osmo],
              requiredChains: const [_osmo],
              expiresAt: DateTime.now().add(const Duration(days: 6, hours: 1)),
            ),
          ]);
          await _pump(
            tester,
            const SessionsScreen(),
            platform: platform,
            overrides: [
              nativeConnectProvider.overrideWithValue(native),
              walletConnectProvider.overrideWithValue(wc),
            ],
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Example'), findsOneWidget);
          expect(find.text('Osmosis'), findsOneWidget);
          expect(
            find.textContaining('online · expires in 23 h'),
            findsOneWidget,
          );
          expect(find.textContaining('expires in 6 days'), findsOneWidget);
          expect(find.text('Disconnect all'), findsOneWidget);
        },
      );
    }

    testWidgets(
      'session detail turns chains off and on, and disconnects after asking',
      (tester) async {
        final native = _Native([_session()]);
        await _pump(
          tester,
          const SessionsScreen(),
          overrides: [
            nativeConnectProvider.overrideWithValue(native),
            walletConnectProvider.overrideWithValue(_WalletConnect()),
          ],
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Example'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('This phone'), findsOneWidget);
        expect(find.text('app.example.com'), findsWidgets);
        await tester.scrollUntilVisible(
          find.text(_osmo),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byType(ZuniaAdaptiveSwitch), findsNWidgets(2));

        // Osmosis is the second switch.
        await tester.ensureVisible(find.byType(ZuniaAdaptiveSwitch).last);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(ZuniaAdaptiveSwitch).last);
        await tester.pumpAndSettle();
        expect(native.chainCalls, [
          [_hub],
        ]);
        // The last chain cannot be turned off.
        final switches = tester
            .widgetList<ZuniaAdaptiveSwitch>(find.byType(ZuniaAdaptiveSwitch))
            .toList();
        expect(switches.first.value, isTrue);
        expect(switches.first.onChanged, isNull);

        await tester.ensureVisible(find.text('Disconnect'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Disconnect'));
        await tester.pumpAndSettle();
        expect(find.text('Disconnect Example?'), findsOneWidget);
        await tester.tap(find.text('Disconnect').last);
        await tester.pumpAndSettle();
        expect(native.disconnected, [_sid]);
      },
    );

    testWidgets('nothing connected shows how to pair', (tester) async {
      await _pump(
        tester,
        const SessionsScreen(),
        platform: TargetPlatform.android,
        overrides: [
          nativeConnectProvider.overrideWithValue(_Native([])),
          walletConnectProvider.overrideWithValue(_WalletConnect()),
        ],
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('No connected apps'), findsOneWidget);
      expect(find.text('Pair a device'), findsOneWidget);
    });

    test('expires in', () {
      final now = DateTime(2026, 10, 18, 12);
      expect(
        expiresIn(now.add(const Duration(hours: 23, minutes: 59)), now),
        'in 23 h',
      );
      expect(expiresIn(now.add(const Duration(minutes: 5)), now), 'in 5 min');
      expect(expiresIn(now.add(const Duration(days: 6)), now), 'in 6 days');
      expect(
        expiresIn(now.subtract(const Duration(seconds: 1)), now),
        'expired',
      );
    });
  });

  group('review sheets', () {
    Future<void> open(
      WidgetTester tester,
      Future<void> Function(BuildContext) show,
    ) async {
      await _pump(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        // The sheets' key-value rows (zunia_ui) do not wrap; the test font is
        // wide, so they get the same room as in the sheets' own tests.
        size: const Size(800, 600),
        textScale: 1,
        overrides: [
          nativeConnectProvider.overrideWithValue(NativeConnectService()),
        ],
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('Zunia Connect asks to check the code and names the way back', (
      tester,
    ) async {
      await open(
        tester,
        (c) => showNativeConnectSheet(
          c,
          request: NativeConnectRequest(
            sessionId: _sid,
            id: 'c',
            dapp: _dapp(),
            receivedAt: DateTime.now(),
            chains: const [_hub],
            methods: const [],
            events: const [],
            verificationCode: '042917',
            returnTarget: ReturnTarget.parse('https://app.example.com/back'),
          ),
        ),
      );
      expect(find.text('042 917'), findsOneWidget);
      expect(
        find.textContaining('Check this code matches the site'),
        findsOneWidget,
      );
      expect(find.text('Return to app.example.com'), findsOneWidget);
      expect(find.text('24 hours after approval'), findsOneWidget);
    });

    testWidgets('WalletConnect shows no code and says what it is', (
      tester,
    ) async {
      await open(
        tester,
        (c) => showNativeConnectSheet(
          c,
          request: NativeConnectRequest(
            sessionId: 'wc-pairing:x',
            id: '1',
            dapp: _dapp(),
            receivedAt: DateTime.now(),
            chains: const [_hub],
            methods: const [],
            events: const [],
            verificationCode: '',
            transport: ConnectTransport.walletConnect,
          ),
        ),
      );
      expect(find.textContaining('Check this code'), findsNothing);
      expect(find.text('WalletConnect v2'), findsOneWidget);
      expect(find.text('7 days after approval'), findsOneWidget);
    });
  });

  group('the queue', () {
    NativeSignRequest message(String id) => NativeSignRequest(
      sessionId: 'wc:topic',
      id: id,
      dapp: _dapp(),
      receivedAt: DateTime.now(),
      kind: NativeSignKind.message,
      chainId: _hub,
      signer: _hubAddress,
      accountIndex: 0,
      transport: ConnectTransport.walletConnect,
      data: Uint8List.fromList(utf8.encode('hello $id')),
    );

    Future<NativeConnectService> pumpInbox(
      WidgetTester tester, {
      String? phrase = 'phrase',
    }) async {
      final native = NativeConnectService();
      final wc = _WalletConnect();
      await _pump(
        tester,
        const ConnectInbox(child: Scaffold(body: Text('home'))),
        size: const Size(390, 844),
        textScale: 1,
        overrides: [
          nativeConnectProvider.overrideWithValue(native),
          walletConnectProvider.overrideWithValue(wc),
          deepLinkHandlerProvider.overrideWithValue(
            DeepLinkHandler(
              source: _NoLinks(),
              walletConnect: wc,
              nativeConnect: native,
            ),
          ),
          phraseProvider.overrideWith((ref) => phrase),
        ],
      );
      return native;
    }

    Future<void> settle(WidgetTester tester) async {
      // The sheets animate in and out; a request's sheet has nothing that
      // runs forever, but pumpAndSettle can wait on the text cursor.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// Cancels the service's expiry timer; awaiting its stream closes would
    /// stall in the test's fake clock.
    void stop(NativeConnectService native) => unawaited(native.dispose());

    testWidgets(
      'shows one request at a time, oldest first; dismissing rejects',
      (tester) async {
        final native = await pumpInbox(tester);
        final answers = _Answers();
        native
          ..adopt(message('1'), answers)
          ..adopt(message('2'), answers);
        await settle(tester);
        expect(find.text('hello 1'), findsOneWidget);
        expect(find.text('hello 2'), findsNothing);

        await tester.tap(find.text('Reject'));
        await settle(tester);
        expect(answers.calls, ['rejectSign 1 USER_REJECTED']);
        expect(find.text('hello 2'), findsOneWidget);

        // Swiping the sheet away is a no as well.
        await tester.tapAt(const Offset(20, 20));
        await settle(tester);
        expect(answers.calls.last, 'rejectSign 2 USER_REJECTED');
        expect(native.pendingRequests, isEmpty);
        stop(native);
      },
    );

    testWidgets(
      'requests that arrived before unlock show once the wallet opens',
      (tester) async {
        final early = NativeConnectService();
        final answers = _Answers();
        early.adopt(message('early'), answers);
        final wc = _WalletConnect();
        await _pump(
          tester,
          const ConnectInbox(child: Scaffold(body: Text('home'))),
          size: const Size(390, 844),
          textScale: 1,
          overrides: [
            nativeConnectProvider.overrideWithValue(early),
            walletConnectProvider.overrideWithValue(wc),
            deepLinkHandlerProvider.overrideWithValue(
              DeepLinkHandler(
                source: _NoLinks(),
                walletConnect: wc,
                nativeConnect: early,
              ),
            ),
            phraseProvider.overrideWith((ref) => 'phrase'),
          ],
        );
        await settle(tester);
        expect(find.text('hello early'), findsOneWidget);
        stop(early);
      },
    );

    testWidgets('nothing shows while there is no unlocked phrase', (
      tester,
    ) async {
      final native = await pumpInbox(tester, phrase: null);
      native.adopt(message('1'), _Answers());
      await settle(tester);
      expect(find.text('hello 1'), findsNothing);
      stop(native);
    });

    testWidgets('a notice with a way back offers Return', (tester) async {
      final native = await pumpInbox(tester);
      native.reportError(Exception('x'));
      await settle(tester);
      expect(find.byType(SnackBar), findsOneWidget);
      stop(native);
    });
  });

  group('scanner', () {
    Future<List<String?>> pumpScanner(
      WidgetTester tester,
      String clipboard, {
      bool extractAddress = false,
    }) async {
      final results = <String?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pump(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => results.add(
                await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) =>
                        QrScannerScreen(extractAddress: extractAddress),
                  ),
                ),
              ),
              child: const Text('scan'),
            ),
          ),
        ),
        overrides: const [],
      );
      await tester.tap(find.text('scan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      return results;
    }

    Future<void> paste(WidgetTester tester) async {
      await tester.tap(find.text('Paste a link').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('takes a pasted pairing link', (tester) async {
      const link = 'zunia://connect/wake?sid=$_sid';
      final results = await pumpScanner(tester, link);
      expect(tester.takeException(), isNull);
      await paste(tester);
      expect(results, [link]);
    });

    testWidgets('says why it ignores a pasted link it cannot use', (
      tester,
    ) async {
      final results = await pumpScanner(tester, 'https://example.com/hello');
      await paste(tester);
      expect(results, isEmpty);
      expect(find.text('Zunia does not recognise this code'), findsOneWidget);
    });

    testWidgets('address mode pops the address', (tester) async {
      final results = await pumpScanner(
        tester,
        'cosmos:$_hubAddress',
        extractAddress: true,
      );
      await paste(tester);
      expect(results, [_hubAddress]);
    });
  });
}
