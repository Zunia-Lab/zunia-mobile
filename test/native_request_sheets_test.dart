/// What the dApp prompts tell the user before they approve: Zunia Connect's
/// sheets and the in-app browser's, on both platforms, at 320dp with large text.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/browser/approval_queue.dart';
import 'package:zunia_mobile/browser/fee_tiers.dart';
import 'package:zunia_mobile/browser/sign_review.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/sign_in.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/native_request_sheets.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_ui/zunia_ui.dart';

const _signer = 'cosmos14qemq0vw6y3gc3u3e0aty2e764u4gs5le3hada';
const _recipient = 'cosmos1jrkmdcwgq94uaamx6zax2luewlhf7u4kucx3kz';

const _hub = ChainEntry(
  chainId: 'cosmoshub-4',
  chainName: 'Cosmos Hub',
  bech32Prefix: 'cosmos',
  coinType: 118,
  network: 'mainnet',
  coinDenom: 'ATOM',
  coinMinimalDenom: 'uatom',
  coinDecimals: 6,
  feeDenom: 'ATOM',
  feeMinimalDenom: 'uatom',
  feeDecimals: 6,
  gasPriceStep: {'low': 0.005, 'average': 0.025, 'high': 0.03},
);

NativeDappIdentity _dapp({
  String? verifiedOrigin = 'https://app.example.com',
  String url = 'https://app.example.com',
}) =>
    NativeDappIdentity(
      metadata: NativeDappMetadata(name: 'Example', url: url),
      verifiedOrigin: verifiedOrigin,
      relay: 'wss://api.zunialab.com',
    );

NativeConnectRequest _connect(NativeDappIdentity dapp) => NativeConnectRequest(
      sessionId: 'session',
      id: 'connect-1',
      dapp: dapp,
      receivedAt: DateTime.now(),
      chains: const ['cosmoshub-4'],
      methods: const [],
      events: const [],
      verificationCode: '042917',
    );

Map<String, dynamic> _sendDoc({String type = 'cosmos-sdk/MsgSend'}) => {
      'chain_id': 'cosmoshub-4',
      'account_number': '7',
      'sequence': '0',
      'fee': {
        'amount': [
          {'denom': 'uatom', 'amount': '5000'},
        ],
        'gas': '200000',
      },
      'msgs': [
        {
          'type': type,
          'value': {
            'from_address': _signer,
            'to_address': _recipient,
            'amount': [
              {'denom': 'uatom', 'amount': '1234'},
            ],
          },
        },
      ],
      'memo': 'rent',
    };

void main() {
  late NativeConnectService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = NativeConnectService();
  });

  tearDown(() => service.dispose());

  Future<void> open(
    WidgetTester tester,
    Future<void> Function(BuildContext context) show, {
    TargetPlatform platform = TargetPlatform.android,
    Size size = const Size(390, 844),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nativeConnectProvider.overrideWithValue(service)],
        child: MaterialApp(
          theme: ZuniaTheme.dark().copyWith(platform: platform),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => show(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('Zunia Connect', () {
    testWidgets('shows the code, the verified host and the chains', (tester) async {
      await open(tester, (c) => showNativeConnectSheet(c, request: _connect(_dapp())));
      expect(find.text('042 917'), findsOneWidget);
      expect(find.text('VERIFIED ORIGIN'), findsOneWidget);
      expect(find.text('app.example.com'), findsOneWidget);
      expect(find.text('cosmoshub-4'), findsOneWidget);
      expect(find.text('CONNECTION REQUEST'), findsOneWidget);
      expect(find.text('This site is not where it says'), findsNothing);
    });

    testWidgets('warns when the site claims to be somewhere else', (tester) async {
      final dapp = _dapp(url: 'https://wallet-login.example.net');
      await open(tester, (c) => showNativeConnectSheet(c, request: _connect(dapp)));
      expect(find.text('ORIGIN MISMATCH'), findsOneWidget);
      expect(find.text('This site is not where it says'), findsOneWidget);
      expect(find.textContaining('wallet-login.example.net'), findsOneWidget);
    });

    testWidgets('says so when the relay saw no origin', (tester) async {
      final dapp = _dapp(verifiedOrigin: null);
      await open(tester, (c) => showNativeConnectSheet(c, request: _connect(dapp)));
      expect(find.text('ORIGIN UNKNOWN'), findsOneWidget);
      expect(find.text('Origin not confirmed'), findsOneWidget);
    });

    testWidgets('rejecting closes the sheet', (tester) async {
      await open(tester, (c) => showNativeConnectSheet(c, request: _connect(_dapp())));
      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();
      expect(find.text('042 917'), findsNothing);
    });

    testWidgets('sign-in names the site and says what it does not do', (tester) async {
      final text = [
        'app.example.com wants you to sign in with your Cosmos account:',
        _signer,
        '',
        'Welcome back.',
        '',
        'URI: https://app.example.com',
        'Version: 1',
        'Chain ID: cosmoshub-4',
        'Nonce: 8f3k2m9QxZ',
        'Issued At: 2026-09-24T10:00:00.000Z',
      ].join('\n');
      final request = NativeSignRequest(
        sessionId: 'session',
        id: 'sign-1',
        dapp: _dapp(),
        receivedAt: DateTime.now(),
        kind: NativeSignKind.signIn,
        chainId: 'cosmoshub-4',
        signer: _signer,
        accountIndex: 0,
        data: Uint8List.fromList(text.codeUnits),
        signIn: parseSignInMessage(text),
      );
      await open(tester, (c) => showNativeSignSheet(c, request: request));
      expect(find.text('Sign in to app.example.com'), findsOneWidget);
      expect(find.text('Welcome back.'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.textContaining('no funds move'), findsOneWidget);
      // The signed text is one tap away, whole.
      await tester.tap(find.text('Show the signed message'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nonce: 8f3k2m9QxZ'), findsOneWidget);
    });

    testWidgets('a transaction is summarized before signing', (tester) async {
      final request = NativeSignRequest(
        sessionId: 'session',
        id: 'sign-2',
        dapp: _dapp(),
        receivedAt: DateTime.now(),
        kind: NativeSignKind.amino,
        chainId: 'cosmoshub-4',
        signer: _signer,
        accountIndex: 0,
        aminoDoc: _sendDoc(),
      );
      await open(tester, (c) => showNativeSignSheet(c, request: request));
      expect(find.text('SIGNATURE REQUEST'), findsOneWidget);
      expect(find.text('Send 1234 uatom'), findsOneWidget);
      expect(find.textContaining(_recipient), findsWidgets);
      expect(find.text('5000 uatom'), findsOneWidget);
      expect(find.textContaining('First-time recipient'), findsOneWidget);
      expect(find.text('rent'), findsNothing);
      await tester.ensureVisible(find.text('Transaction details'));
      await tester.tap(find.text('Transaction details'));
      await tester.pumpAndSettle();
      expect(find.text('rent'), findsOneWidget);
      // Zunia Connect carries no sign options: the site's fee stands.
      expect(find.text('Medium'), findsNothing);
    });

    testWidgets('an undecodable message is refused before any sheet opens', (tester) async {
      final request = NativeSignRequest(
        sessionId: 'session',
        id: 'sign-3',
        dapp: _dapp(),
        receivedAt: DateTime.now(),
        kind: NativeSignKind.amino,
        chainId: 'cosmoshub-4',
        signer: _signer,
        accountIndex: 0,
        aminoDoc: _sendDoc(type: 'acme/Drain'),
      );
      await open(tester, (c) => showNativeSignSheet(c, request: request));
      expect(find.text('Reject'), findsNothing);
      expect(
        find.textContaining('Blind signing disabled for unknown messages: acme/Drain'),
        findsOneWidget,
      );
    });
  });

  group('in-app browser', () {
    late ApprovalQueue queue;

    setUp(() => queue = ApprovalQueue());
    tearDown(() => queue.dispose());

    ({String id, Future<ApprovalAnswer> result}) enqueueSign({bool unknown = false}) {
      final doc = _sendDoc(type: unknown ? 'acme/Drain' : 'cosmos-sdk/MsgSend');
      final review = reviewAminoSignDoc(
        expectedChainId: 'cosmoshub-4',
        signDoc: doc,
        context: ReviewContext(chain: _hub, blindSigning: unknown),
      );
      final queued = queue.enqueue(
        kind: ApprovalKind.signAmino,
        origin: 'https://app.osmosls.zone',
        chainIds: const ['cosmoshub-4'],
        title: 'Sign transaction on cosmoshub-4',
        signer: _signer,
        review: review,
        feeChoice: feeChoiceFor(_hub, aminoFeeOf(doc), preferNoSetFee: false),
        json: previewJson(doc),
        warnings: [
          'The address resembles osmosis.zone but is a different site (osmosls.zone). Check it carefully.',
          ...review.warnings,
        ],
      );
      // A test that rejects does not leave the error unheard.
      queued.result.ignore();
      return queued;
    }

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('a connection prompt at 320dp, large text, on ${platform.name}', (tester) async {
        final queued = queue.enqueue(
          kind: ApprovalKind.enable,
          origin: 'https://app.osmosis.zone',
          chainIds: const ['cosmoshub-4', 'osmosis-1'],
          title: 'Connect',
        );
        await open(
          tester,
          (c) => showBrowserApprovalSheet(
            c,
            request: queue.current!,
            queue: queue,
            accountName: 'Main',
            accountAddress: _signer,
          ),
          platform: platform,
          size: const Size(320, 640),
          textScale: 1.3,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('app.osmosis.zone'), findsOneWidget);
        expect(find.text('This site can see your address. It cannot move funds.'), findsOneWidget);
        expect(find.textContaining(RegExp(r'^[45]:\d\d$')), findsOneWidget);
        await tester.tap(find.text('Connect'));
        await tester.pumpAndSettle();
        final answer = await queued.result;
        expect(answer.approved, isTrue);
        expect(find.text('Connect'), findsNothing);
      });

      testWidgets('a transaction prompt at 320dp, large text, on ${platform.name}', (tester) async {
        final queued = enqueueSign();
        await open(
          tester,
          (c) => showBrowserApprovalSheet(c, request: queue.current!, queue: queue, accountName: 'Main'),
          platform: platform,
          size: const Size(320, 640),
          textScale: 1.3,
        );
        expect(tester.takeException(), isNull);
        // The lookalike banner, the headline, the fee in ATOM, the tier picker.
        expect(find.text("This site's address looks suspicious"), findsOneWidget);
        expect(find.text('Send 1234 uatom'), findsOneWidget);
        expect(find.text('= 0.001234 ATOM · native on Cosmos Hub · verified by registry'), findsOneWidget);
        expect(find.text('0.005 ATOM'), findsOneWidget);
        // iOS spells the segments as written, Android in capitals.
        final high = find.text(platform == TargetPlatform.iOS ? 'High' : 'HIGH');
        await tester.ensureVisible(high);
        await tester.tap(high);
        await tester.pumpAndSettle();
        expect(find.text('0.006 ATOM'), findsOneWidget);
        expect(find.text(FeeTier.high.hint), findsOneWidget);
        await tester.tap(find.text('Approve'));
        await tester.pumpAndSettle();
        final answer = await queued.result;
        expect(answer.approved, isTrue);
        expect(answer.feeTier, FeeTier.high);
      });
    }

    testWidgets('closing the prompt without an answer rejects the request', (tester) async {
      final queued = enqueueSign();
      Object? error;
      queued.result.catchError((Object e) {
        error = e;
        return const ApprovalAnswer(approved: false);
      });
      await open(
        tester,
        (c) => showBrowserApprovalSheet(c, request: queue.current!, queue: queue, accountName: 'Main'),
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(queue.pending, isEmpty);
      expect(error.toString(), 'Request rejected');
    });

    testWidgets('unknown messages are red and named, with blind signing on', (tester) async {
      enqueueSign(unknown: true);
      await open(
        tester,
        (c) => showBrowserApprovalSheet(c, request: queue.current!, queue: queue, accountName: 'Main'),
      );
      expect(find.text('Approve 1 message'), findsOneWidget);
      expect(find.text('Message acme/Drain'), findsOneWidget);
      expect(find.textContaining('Unknown or undecoded message: acme/Drain'), findsOneWidget);
      await tester.ensureVisible(find.text('Raw transaction'));
      await tester.tap(find.text('Raw transaction'));
      await tester.pumpAndSettle();
      expect(find.textContaining('"type": "acme/Drain"'), findsOneWidget);
      queue.rejectWhere((_) => true);
    });
  });
}
