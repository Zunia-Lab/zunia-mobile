/// What the Zunia Connect sheets tell the user before they approve.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/connect/sign_in.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/native_request_sheets.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_ui/zunia_ui.dart';

const _signer = 'cosmos14qemq0vw6y3gc3u3e0aty2e764u4gs5le3hada';

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

void main() {
  late NativeConnectService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = NativeConnectService();
  });

  tearDown(() => service.dispose());

  Future<void> open(
    WidgetTester tester,
    Future<void> Function(BuildContext context) show,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nativeConnectProvider.overrideWithValue(service)],
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
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

  testWidgets('shows the code, the verified host and the chains', (tester) async {
    await open(tester, (c) => showNativeConnectSheet(c, request: _connect(_dapp())));
    expect(find.text('042 917'), findsOneWidget);
    expect(find.text('VERIFIED ORIGIN'), findsOneWidget);
    expect(find.text('app.example.com'), findsOneWidget);
    expect(find.text('cosmoshub-4'), findsOneWidget);
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
      signIn: parseSignInMessage(text),
    );
    await open(tester, (c) => showNativeSignSheet(c, request: request));
    expect(find.text('Sign in to app.example.com'), findsOneWidget);
    expect(find.text('Welcome back.'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.textContaining('does not move funds'), findsOneWidget);
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
      aminoDoc: {
        'chain_id': 'cosmoshub-4',
        'account_number': '7',
        'sequence': '0',
        'fee': {
          'amount': [
            {'denom': 'uatom', 'amount': '500'},
          ],
          'gas': '200000',
        },
        'msgs': [
          {
            'type': 'cosmos-sdk/MsgSend',
            'value': {'from_address': _signer, 'to_address': _signer, 'amount': []},
          },
        ],
        'memo': 'rent',
      },
    );
    await open(tester, (c) => showNativeSignSheet(c, request: request));
    expect(find.text('Approve a transaction'), findsOneWidget);
    expect(find.text('MsgSend'), findsOneWidget);
    expect(find.text('500 uatom'), findsOneWidget);
    expect(find.text('rent'), findsOneWidget);
  });
}
