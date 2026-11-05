// Live end-to-end checks against the production relay (wss://api.zunialab.com).
// They create real, short-lived relay sessions, so they run only on request:
//
//   ZUNIA_LIVE=1 flutter test test/e2e/live_connect_test.dart
//
// The wallet side is the app's own Zunia Connect code (NativeConnectService),
// approving everything with the public test phrase. The dApp side is, per
// test: the published zunia_sdk from pub.dev, or a pairing link read from a
// file (written by the npm SDK script or taken from the live dashboard's QR).
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/connect/wallet_signer.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/services/connect_session_store.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_sdk/zunia_sdk.dart' as sdk;

import '../support/kernel.dart';

const _phrase = 'abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon about';
const _hubAddress = 'cosmos19rl4cm2hmr8afy4kldpxz3fka4jguq0auqdal4';

final bool _live = Platform.environment['ZUNIA_LIVE'] == '1';

/// A phone that says yes: the app's Connect service, answering every request
/// as ConnectInbox would after the user approved.
///
/// [approveAfter] holds the connect answer, as a person comparing the six
/// digits would. With [declineTransactions] a transaction is signed (proof the
/// app can), checked, and then refused, so nothing reaches a chain.
class AutoWallet {
  AutoWallet({this.approveAfter = Duration.zero, this.declineTransactions = false}) {
    _sub = service.changes.listen((_) => unawaited(_drain()));
  }

  final Duration approveAfter;
  final bool declineTransactions;
  final service = NativeConnectService(store: MemoryConnectSessionStore());
  final _handled = <NativeRequest>{};
  final approvedSigns = <String>[];
  final declinedTransactions = <String>[];
  late final StreamSubscription<void> _sub;
  String? verificationCode;

  Future<NativeConnectRequest> pair(String link) async {
    final request = await service.pair(link);
    verificationCode = request.verificationCode;
    unawaited(_drain());
    return request;
  }

  Future<void> _drain() async {
    for (final request in service.pendingRequests) {
      if (!_handled.add(request)) continue;
      switch (request) {
        case NativeConnectRequest():
          await Future<void>.delayed(approveAfter);
          await service.approveConnect(
            request,
            accounts: connectAccountsFor(
              phrase: _phrase,
              accountIndex: 0,
              chainIds: request.chains,
              accountName: 'E2E',
            ),
            accountIndex: 0,
          );
        case NativeSignRequest(kind: NativeSignKind.amino || NativeSignKind.direct)
            when declineTransactions:
          declinedTransactions.add(_checkTransaction(request));
          await service.rejectSign(request);
        case NativeSignRequest():
          approvedSigns.add(request.kind.name);
          await service.approveSign(request, signNativeRequest(request, phrase: _phrase));
      }
    }
  }

  Future<void> dispose() async {
    await _sub.cancel();
    await service.dispose();
  }
}

/// Signs [request] as the phone would and checks the signature against the
/// bytes the chain verifies. Returns what was asked, for the log.
String _checkTransaction(NativeSignRequest request) {
  final result = signNativeRequest(request, phrase: _phrase);
  final signature = result['signature']! as Map<String, Object?>;
  final pubKey = (signature['pub_key']! as Map<String, Object?>)['value']! as String;
  final amino = request.kind == NativeSignKind.amino;
  final valid = verifySecp256k1Sha256(
    signBytes: amino ? aminoSignBytes(request.aminoDoc) : request.directDoc!.signBytes,
    publicKey: base64Decode(pubKey),
    signature: base64Decode(signature['signature']! as String),
  );
  final types = amino
      ? [for (final m in request.aminoDoc!['msgs'] as List) (m as Map)['type']]
      : [
          for (final m in WalletKernel.instance.decodeDirect(request.directDoc!.signBytes)['messages'] as List)
            (m as Map)['typeUrl'],
        ];
  return '${request.kind.name} ${request.chainId} ${types.join('+')} '
      'signature=${valid ? 'valid' : 'INVALID'}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // flutter_test answers every HTTP request with 400; these tests need the
    // real relay.
    HttpOverrides.global = null;
    await ChainCatalog.load();
  });

  final skip = !_live
      ? 'set ZUNIA_LIVE=1 to talk to the production relay'
      : kernelSkip;

  test('zunia_sdk 0.1.1 from pub.dev pairs with the app over the live relay and gets a valid signature', () async {
    final dapp = sdk.ZuniaConnectClient(
      metadata: const sdk.ZuniaDappMetadata(name: 'Zunia live check', url: 'https://zunialab.com'),
      openWallet: sdk.ZuniaOpenWallet.never,
      observeAppLifecycle: false,
    );
    final wallet = AutoWallet();
    addTearDown(() async {
      await dapp.disconnect().catchError((_) {});
      dapp.dispose();
      await wallet.dispose();
    });

    final link = dapp.pairings.first.then((p) => p.uri);
    final codes = dapp.verificationCodes.first;
    final connected = dapp.connect(chains: ['cosmoshub-4']);
    await wallet.pair(await link.timeout(const Duration(seconds: 20)));
    await connected.timeout(const Duration(seconds: 30));

    // Both screens show the same six digits.
    expect(await codes, wallet.verificationCode);
    expect(dapp.accounts.single.address, _hubAddress);

    final message = 'Zunia live check ${DateTime.now().toUtc().toIso8601String()}';
    final signature = await dapp
        .signArbitrary('cosmoshub-4', _hubAddress, message)
        .timeout(const Duration(seconds: 30));
    expect(wallet.approvedSigns, ['message']);
    expect(
      verifyAdr36(
        signer: _hubAddress,
        data: utf8.encode(message),
        publicKey: base64Decode(signature.pubKey),
        signature: base64Decode(signature.signature),
      ),
      isTrue,
    );
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('a pairing link from a file (npm SDK or the live dashboard) is approved by the app', () async {
    final path = Platform.environment['ZUNIA_PAIR_FILE'];
    if (path == null) {
      markTestSkipped('set ZUNIA_PAIR_FILE to a file the dApp writes its pairing link to');
      return;
    }
    final file = File(path);
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (!file.existsSync() || file.readAsStringSync().trim().isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('no pairing link appeared in $path');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final env = Platform.environment;
    final wallet = AutoWallet(
      approveAfter: Duration(seconds: int.tryParse(env['ZUNIA_APPROVE_AFTER_SECONDS'] ?? '') ?? 0),
      declineTransactions: env['ZUNIA_DECLINE_TX'] == '1',
    );
    addTearDown(wallet.dispose);
    final request = await wallet.pair(file.readAsStringSync().trim());
    // The code the dApp shows: printed so a person (or the script) compares.
    // ignore: avoid_print
    print('ZUNIA_CODE=${request.verificationCode} ORIGIN=${request.dapp.verifiedOrigin}');
    File('$path.code').writeAsStringSync(request.verificationCode);

    // Keep answering for as long as the dApp asks (sign requests included).
    final hold = int.tryParse(env['ZUNIA_HOLD_SECONDS'] ?? '') ?? 60;
    await Future<void>.delayed(Duration(seconds: hold));
    // ignore: avoid_print
    print('ZUNIA_SIGNED=${wallet.approvedSigns.join(',')}');
    for (final tx in wallet.declinedTransactions) {
      // ignore: avoid_print
      print('ZUNIA_DECLINED=$tx');
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 6)));
}
