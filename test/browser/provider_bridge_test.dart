/// The in-app browser's provider, method by method, against the rules of
/// extension 0.1.5: grants per site and chain, approvals that expire and
/// queue, the eight error codes, and signatures the kernel makes over the
/// exact bytes the prompt described.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/browser/approval_queue.dart';
import 'package:zunia_mobile/browser/dapp_provider_bridge.dart';
import 'package:zunia_mobile/browser/fee_tiers.dart';
import 'package:zunia_mobile/browser/provider_errors.dart';
import 'package:zunia_mobile/browser/site_grants.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/state/signing_settings.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

import '../support/kernel.dart';

const _phrase = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _site = 'https://app.example.com';
const _hubAddress = 'cosmos19rl4cm2hmr8afy4kldpxz3fka4jguq0auqdal4';
const _recipient = 'cosmos1jrkmdcwgq94uaamx6zax2luewlhf7u4kucx3kz';

class _FakeWallet extends ProviderWallet {
  String? currentPhrase = _phrase;
  WalletAccount? account = const WalletAccount(id: 'main', name: 'Main', index: 0);
  SigningSettings signing = const SigningSettings();
  final added = <ChainEntry>[];
  final remembered = <String>{};
  final known = <String>{};

  @override
  String? get phrase => currentPhrase;

  @override
  WalletAccount? get activeAccount => account;

  @override
  Future<void> whenUnlocked(Duration timeout) async {
    if (currentPhrase == null) {
      throw const ProviderError(ProviderErrorCode.locked, 'Zunia stayed locked, so the request was cancelled');
    }
  }

  @override
  ChainEntry? findChain(String chainId) {
    for (final c in added) {
      if (c.chainId == chainId) return c;
    }
    return ChainCatalog.instance.find(chainId);
  }

  @override
  List<ChainEntry> get chains => [...ChainCatalog.instance.all, ...added];

  @override
  bool isRegistryChain(String chainId) => ChainCatalog.instance.registryOnly.any((c) => c.chainId == chainId);

  @override
  Future<void> addChain(ChainEntry entry) async => added.add(entry);

  @override
  SigningSettings get settings => signing;

  @override
  Future<Set<String>> knownRecipients() async => {...known, ...remembered};

  @override
  Future<void> rememberRecipients(Iterable<String> addresses) async => remembered.addAll(addresses);
}

Map<String, dynamic> _sendDoc({String chainId = 'cosmoshub-4', String memo = '', String type = 'cosmos-sdk/MsgSend'}) => {
      'account_number': '12345',
      'chain_id': chainId,
      'fee': {
        'amount': [
          {'amount': '5000', 'denom': 'uatom'},
        ],
        'gas': '200000',
      },
      'memo': memo,
      'msgs': [
        {
          'type': type,
          'value': {
            'amount': [
              {'amount': '1000000', 'denom': 'uatom'},
            ],
            'from_address': _hubAddress,
            'to_address': _recipient,
          },
        },
      ],
      'sequence': '7',
    };

Matcher _providerError(String code, [Object? message]) => isA<ProviderError>()
    .having((e) => e.code, 'code', code)
    .having((e) => e.message, 'message', message ?? anything);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWallet wallet;
  late SiteGrantStore grants;
  late ApprovalQueue queue;
  late DappProviderBridge bridge;
  late List<SiteEvent> events;
  var now = DateTime.utc(2026, 10, 18, 12);

  setUpAll(() async {
    await ChainCatalog.load();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime.utc(2026, 10, 18, 12);
    wallet = _FakeWallet();
    grants = SiteGrantStore(clock: () => now);
    queue = ApprovalQueue(clock: () => now);
    bridge = DappProviderBridge(wallet: wallet, grants: grants, approvals: queue);
    events = [];
    grants.events.listen(events.add);
  });

  tearDown(() => queue.dispose());

  Future<Object?> call(String method, [List<dynamic> args = const [], String origin = _site]) =>
      bridge.dispatch(origin: origin, method: method, args: args);

  /// Answers the request at the head of the queue once it is there.
  Future<ApprovalRequest> answer({bool approve = true, FeeTier? tier}) async {
    while (queue.current == null) {
      await Future<void>.delayed(Duration.zero);
    }
    final request = queue.current!;
    if (approve) {
      queue.resolve(request.id, ApprovalAnswer.approve(feeTier: tier));
    } else {
      queue.reject(request.id);
    }
    return request;
  }

  Future<void> connect(List<String> chains) async {
    final done = call('enable', [chains]);
    await answer();
    await done;
    await pumpEventQueue();
  }

  group('who may ask', () {
    test('only secure pages and this device', () async {
      await expectLater(call('getConnectedChains', [], 'http://evil.example'), throwsA(_providerError('ORIGIN_MISMATCH')));
      expect(await call('getConnectedChains', [], 'http://localhost:3000'), isEmpty);
      expect(await call('getConnectedChains', [], 'https://x.example'), isEmpty);
    });

    test('nothing is revealed before enable', () async {
      await expectLater(call('getKey', ['cosmoshub-4']), throwsA(_providerError('NOT_CONNECTED', 'Not authorized')));
      await expectLater(call('getAccounts', ['cosmoshub-4']), throwsA(_providerError('NOT_CONNECTED')));
      await expectLater(call('isLocked'), throwsA(_providerError('NOT_CONNECTED')));
      await expectLater(call('getKey', []), throwsA(_providerError('INVALID_PARAMS', 'chainId required')));
      await expectLater(call('enable', [<String>[]]), throwsA(_providerError('INVALID_PARAMS')));
      await expectLater(call('enable', ['nochain-9']), throwsA(_providerError('UNKNOWN_CHAIN')));
      await expectLater(call('frobnicate'), throwsA(_providerError('UNSUPPORTED')));
    });

    test('sendTx is refused: Zunia signs, the site broadcasts', () async {
      await expectLater(call('sendTx', ['cosmoshub-4', [1, 2], 'sync']), throwsA(_providerError('UNSUPPORTED')));
    });

    test('wire shape carries the code', () async {
      final wire = await bridge.handle(origin: _site, method: 'getKey', args: ['cosmoshub-4']);
      expect(wire, {'error': 'Not authorized', 'code': 'NOT_CONNECTED'});
    });
  });

  group('enable and grants', () {
    test('approval grants per site and per chain; reject says Request rejected', () async {
      final rejected = call('enable', ['cosmoshub-4']);
      final request = await answer(approve: false);
      expect(request.kind, ApprovalKind.enable);
      await expectLater(rejected, throwsA(_providerError('USER_REJECTED', 'Request rejected')));

      await connect(['cosmoshub-4']);
      expect(await call('getConnectedChains'), ['cosmoshub-4']);
      expect(await call('getConnectedChains', [], 'https://other.example'), isEmpty);
      await expectLater(call('getKey', ['osmosis-1']), throwsA(_providerError('NOT_CONNECTED')));
      // Granted chains do not prompt again.
      expect(await call('enable', ['cosmoshub-4']), isNull);
      expect(queue.pending, isEmpty);
      expect(events, [const SiteEvent(_site, ProviderEventName.chainChanged, ['cosmoshub-4'])]);
    });

    test('calls from one site share one prompt with the merged chains', () async {
      final first = call('enable', [['cosmoshub-4']]);
      final second = call('enable', ['osmosis-1']);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(queue.pending, hasLength(1));
      expect(queue.current!.chainIds, ['cosmoshub-4', 'osmosis-1']);
      await answer();
      await first;
      await second;
      expect(await call('getConnectedChains'), ['cosmoshub-4', 'osmosis-1']);
    });

    test('at most three requests wait; the fourth is refused', () async {
      final waiting = [
        for (final origin in ['https://a.example', 'https://b.example', 'https://c.example'])
          call('enable', ['cosmoshub-4'], origin).catchError((Object _) => null),
      ];
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(queue.pending, hasLength(3));
      await expectLater(
        call('enable', ['cosmoshub-4'], 'https://d.example'),
        throwsA(_providerError('INTERNAL', 'Too many pending approvals (max 3)')),
      );
      queue.rejectWhere((_) => true);
      await Future.wait(waiting);
    });

    test('a prompt nobody answers expires, with the extension\'s words', () async {
      expect(kApprovalTtl, const Duration(minutes: 5));
      final local = ApprovalQueue(ttl: const Duration(milliseconds: 40));
      final result = local
          .enqueue(kind: ApprovalKind.enable, origin: _site, chainIds: ['cosmoshub-4'], title: 't')
          .result;
      expect(local.pending, hasLength(1));
      await expectLater(result, throwsA(_providerError('USER_REJECTED', 'Request expired before it was answered')));
      expect(local.pending, isEmpty);
      local.dispose();
    });

    test('each chain lapses seven days after it was approved, and the page hears it', () async {
      await connect(['cosmoshub-4']);
      now = now.add(const Duration(days: 3));
      await connect(['osmosis-1']);
      events.clear();
      now = now.add(const Duration(days: 4, minutes: 1));
      expect(await call('getConnectedChains'), ['osmosis-1']);
      await expectLater(call('getKey', ['cosmoshub-4']), throwsA(_providerError('NOT_CONNECTED')));
      await grants.sweep();
      await pumpEventQueue();
      expect(events, [
        const SiteEvent(_site, ProviderEventName.disconnect, ['cosmoshub-4']),
        const SiteEvent(_site, ProviderEventName.chainChanged, ['osmosis-1']),
      ]);
      now = now.add(const Duration(days: 3));
      events.clear();
      await grants.sweep();
      await pumpEventQueue();
      expect(events, [const SiteEvent(_site, ProviderEventName.disconnect)]);
      expect(await grants.listActive(), isEmpty);
    });

    test('disable and revokes tell the page what it lost', () async {
      await connect(['cosmoshub-4', 'osmosis-1']);
      events.clear();
      await call('disable', ['osmosis-1']);
      await pumpEventQueue();
      expect(events, [
        const SiteEvent(_site, ProviderEventName.disconnect, ['osmosis-1']),
        const SiteEvent(_site, ProviderEventName.chainChanged, ['cosmoshub-4']),
      ]);
      events.clear();
      await call('disable');
      await pumpEventQueue();
      expect(events, [const SiteEvent(_site, ProviderEventName.disconnect)]);
      await connect(['cosmoshub-4']);
      expect(await grants.revokeAll(), [_site]);
    });

    test('the Connected sites screen sees use, the address handed out and expiry', () async {
      await connect(['cosmoshub-4']);
      final key = await call('getKey', ['cosmoshub-4']) as Map<String, Object?>;
      final grant = (await grants.listActive()).single;
      expect(grant.origin, _site);
      expect(grant.chains['cosmoshub-4']!.address, key['bech32Address']);
      expect(grant.chains['cosmoshub-4']!.expiresAt.isAtSameMomentAs(now.add(kGrantTtl)), isTrue);
      expect(grant.lastUsedAt!.isAtSameMomentAs(now), isTrue);
    }, skip: kernelSkip);
  });

  group('keys', () {
    test('getKey and getAccounts give the active account, Keplr-shaped', () async {
      await connect(['cosmoshub-4', 'evmos_9001-2']);
      final key = await call('getKey', ['cosmoshub-4']) as Map<String, Object?>;
      expect(key['name'], 'Main');
      expect(key['bech32Address'], _hubAddress);
      expect(key['address'], _hubAddress);
      expect(key['algo'], 'secp256k1');
      expect(key['isNanoLedger'], isFalse);
      expect(key.containsKey('ethereumHexAddress'), isFalse);
      expect(hexOf((key['pubKey'] as List).cast<int>()), '024f4e2ad99c34d60b9ba6283c9431a8418af8673212961f97a77b6377fcd05b62');

      final evmos = await call('getKey', ['evmos_9001-2']) as Map<String, Object?>;
      expect(evmos['algo'], 'eth_secp256k1');
      expect(evmos['bech32Address'], startsWith('evmos1'));
      expect(evmos['ethereumHexAddress'], ethereumHexAddress(evmos['bech32Address'] as String));
      expect(evmos['ethereumHexAddress'], matches(RegExp(r'^0x[0-9a-fA-F]{40}$')));

      final accounts = await call('getAccounts', ['cosmoshub-4']) as List;
      expect(accounts.single['address'], _hubAddress);
      expect(accounts.single['pubkey'], key['pubKey']);
    }, skip: kernelSkip);

    test('isLocked answers a connected site; a locked wallet that stays locked is LOCKED', () async {
      await connect(['cosmoshub-4']);
      expect(await call('isLocked'), isFalse);
      wallet.currentPhrase = null;
      expect(await call('isLocked'), isTrue);
      await expectLater(call('getKey', ['cosmoshub-4']), throwsA(_providerError('LOCKED')));
    });
  });

  group('signAmino', () {
    test('signs the bytes the prompt described, with the escapes chains rebuild', () async {
      await connect(['cosmoshub-4']);
      final doc = _sendDoc(memo: 'rent & food <3>');
      final signing = call('signAmino', ['cosmoshub-4', _hubAddress, doc]);
      final request = await answer();
      expect(request.kind, ApprovalKind.signAmino);
      expect(request.review!.messages.single.summary, 'Send 1000000 uatom to $_recipient');
      expect(request.warnings, contains('First-time recipient: $_recipient'));
      expect(request.json, contains('"memo": "rent & food <3>"'));
      expect(request.feeChoice, isNotNull);
      final result = await signing as Map<String, Object?>;
      expect(result['signed'], doc);
      final signature = result['signature'] as Map<String, Object?>;
      expect(utf8.decode(aminoSignBytes(doc)), contains(r'rent \u0026 food \u003c3\u003e'));
      expect(
        verifySecp256k1Sha256(
          signBytes: aminoSignBytes(doc),
          publicKey: base64Decode((signature['pub_key'] as Map)['value'] as String),
          signature: base64Decode(signature['signature'] as String),
        ),
        isTrue,
      );
      // Paid once through a prompt: not "first-time" again.
      expect(wallet.remembered, {_recipient});
    }, skip: kernelSkip);

    test('a fee tier the user picks is what is signed and handed back', () async {
      await connect(['cosmoshub-4']);
      final doc = _sendDoc();
      final signing = call('signAmino', ['cosmoshub-4', _hubAddress, doc]);
      final request = await answer(tier: FeeTier.high);
      final result = await signing as Map<String, Object?>;
      final signed = result['signed'] as Map<String, dynamic>;
      expect(signed['fee']['amount'], [
        {'denom': 'uatom', 'amount': request.feeChoice!.tiers[FeeTier.high]},
      ]);
      expect(signed['fee']['gas'], '200000');
      final signature = result['signature'] as Map<String, Object?>;
      expect(
        verifySecp256k1Sha256(
          signBytes: aminoSignBytes(signed),
          publicKey: base64Decode((signature['pub_key'] as Map)['value'] as String),
          signature: base64Decode(signature['signature'] as String),
        ),
        isTrue,
      );
    }, skip: kernelSkip);

    test('preferNoSetFee keeps the site fee and offers no tiers', () async {
      await connect(['cosmoshub-4']);
      final signing = call('signAmino', ['cosmoshub-4', _hubAddress, _sendDoc(), {'preferNoSetFee': true}]);
      final request = await answer(tier: FeeTier.high);
      expect(request.feeChoice, isNull);
      final result = await signing as Map<String, Object?>;
      expect((result['signed'] as Map)['fee']['amount'][0]['amount'], '5000');
    }, skip: kernelSkip);

    test('refused before any prompt: wrong chain, wrong signer, blind, too large', () async {
      await connect(['cosmoshub-4']);
      await expectLater(
        call('signAmino', ['cosmoshub-4', _hubAddress, _sendDoc(chainId: 'osmosis-1')]),
        throwsA(_providerError('INVALID_PARAMS')),
      );
      await expectLater(
        call('signAmino', ['cosmoshub-4', _recipient, _sendDoc()]),
        throwsA(_providerError('INVALID_PARAMS')),
      );
      await expectLater(
        call('signAmino', ['cosmoshub-4', _hubAddress, _sendDoc(type: 'acme/Drain')]),
        throwsA(_providerError('UNSUPPORTED', 'Blind signing disabled for unknown messages: acme/Drain')),
      );
      await expectLater(
        call('signAmino', ['cosmoshub-4', _hubAddress, _sendDoc(memo: 'x' * (4 * 1024 * 1024))]),
        throwsA(_providerError('UNSUPPORTED', 'This transaction is too large to show in full')),
      );
      expect(queue.pending, isEmpty);

      // With blind signing on, the same document reaches the prompt, flagged.
      wallet.signing = const SigningSettings(blindSigning: true);
      final signing = call('signAmino', ['cosmoshub-4', _hubAddress, _sendDoc(type: 'acme/Drain')]);
      final request = await answer(approve: false);
      expect(request.review!.messages.single.unknown, isTrue);
      expect(request.warnings, contains('Unknown or undecoded message: acme/Drain'));
      await expectLater(signing, throwsA(_providerError('USER_REJECTED')));
    }, skip: kernelSkip);

    test('switching accounts while the prompt is open signs nothing', () async {
      await connect(['cosmoshub-4']);
      final signing = call('signAmino', ['cosmoshub-4', _hubAddress, _sendDoc()]);
      while (queue.current == null) {
        await Future<void>.delayed(Duration.zero);
      }
      wallet.account = const WalletAccount(id: 'second', name: 'Second', index: 1);
      queue.resolve(queue.current!.id, const ApprovalAnswer.approve());
      await expectLater(signing, throwsA(_providerError('INVALID_PARAMS', contains('active account changed'))));
    }, skip: kernelSkip);

    test('locking while the prompt is open signs nothing', () async {
      await connect(['cosmoshub-4']);
      final signing = call('signAmino', ['cosmoshub-4', _hubAddress, _sendDoc()]);
      while (queue.current == null) {
        await Future<void>.delayed(Duration.zero);
      }
      wallet.currentPhrase = null;
      queue.resolve(queue.current!.id, const ApprovalAnswer.approve());
      await expectLater(signing, throwsA(_providerError('LOCKED', 'Wallet locked before signing')));
    }, skip: kernelSkip);
  });

  group('signDirect', () {
    final core = File('../zunia-core/tests/vectors/cosmos-signing.json');
    final cases = core.existsSync()
        ? ((jsonDecode(core.readAsStringSync()) as Map<String, dynamic>)['cases'] as List).cast<Map<String, dynamic>>()
        : const <Map<String, dynamic>>[];
    final skip = cases.isEmpty ? 'no zunia-core vectors' : kernelSkip;

    Map<String, Object?> pageDoc(String name) {
      final direct = cases.firstWhere((c) => c['name'] == name)['direct'] as Map<String, dynamic>;
      final body = bytesOfHex(direct['body_bytes_hex'] as String);
      return {
        // As a page's Uint8Array crosses the bridge.
        'bodyBytes': {for (var i = 0; i < body.length; i++) '$i': body[i]},
        'authInfoBytes': bytesOfHex(direct['auth_info_bytes_hex'] as String).toList(),
        'chainId': 'cosmoshub-4',
        'accountNumber': '12345',
      };
    }

    test('the kernel decodes, the kernel signs the same bytes', () async {
      await connect(['cosmoshub-4']);
      final signing = call('signDirect', ['cosmoshub-4', _hubAddress, pageDoc('msg_send')]);
      final request = await answer();
      expect(request.kind, ApprovalKind.signDirect);
      expect(request.review!.messages.single.type, '/cosmos.bank.v1beta1.MsgSend');
      final result = await signing as Map<String, Object?>;
      expect(result['feeChanged'], isFalse);
      final signedBytes = DirectSignDoc.fromProvider(result['signed']).signBytes;
      final golden = (cases.first['direct'] as Map)['sign_bytes_hex'];
      expect(hexOf(signedBytes), golden);
      final signature = result['signature'] as Map<String, Object?>;
      expect(
        verifySecp256k1Sha256(
          signBytes: signedBytes,
          publicKey: base64Decode((signature['pub_key'] as Map)['value'] as String),
          signature: base64Decode(signature['signature'] as String),
        ),
        isTrue,
      );
    }, skip: skip);

    test('a picked fee tier rewrites authInfoBytes, and the signature covers them', () async {
      await connect(['cosmoshub-4']);
      final signing = call('signDirect', ['cosmoshub-4', _hubAddress, pageDoc('msg_send')]);
      final request = await answer(tier: FeeTier.low);
      final result = await signing as Map<String, Object?>;
      expect(result['feeChanged'], isTrue);
      final signed = DirectSignDoc.fromProvider(result['signed']);
      final fee = authInfoFee(signed.authInfoBytes)!;
      expect(fee.amount.single, FeeCoin('uatom', request.feeChoice!.tiers[FeeTier.low]!));
      expect(fee.gas, '200000');
      final signature = result['signature'] as Map<String, Object?>;
      expect(
        verifySecp256k1Sha256(
          signBytes: signed.signBytes,
          publicKey: base64Decode((signature['pub_key'] as Map)['value'] as String),
          signature: base64Decode(signature['signature'] as String),
        ),
        isTrue,
      );
    }, skip: skip);

    test('a document for another chain is refused', () async {
      await connect(['cosmoshub-4']);
      await expectLater(
        call('signDirect', ['cosmoshub-4', _hubAddress, {...pageDoc('msg_send'), 'chainId': 'osmosis-1'}]),
        throwsA(_providerError('INVALID_PARAMS')),
      );
    }, skip: skip);
  });

  group('signArbitrary and verifyArbitrary', () {
    test('ADR-036 round trip; a tampered message does not verify', () async {
      await connect(['cosmoshub-4']);
      final signing = call('signArbitrary', ['cosmoshub-4', _hubAddress, 'hello']);
      final request = await answer();
      expect(request.messagePreview, 'hello');
      expect(request.encoding, 'utf8');
      final signature = await signing as Map<String, Object?>;
      expect(await call('verifyArbitrary', ['cosmoshub-4', _hubAddress, 'hello', signature]), isTrue);
      expect(await call('verifyArbitrary', ['cosmoshub-4', _hubAddress, 'hellO', signature]), isFalse);
      expect(
        await call('verifyArbitrary', ['cosmoshub-4', _hubAddress, utf8.encode('hello'), signature['signature']]),
        isTrue,
      );
      await expectLater(
        call('verifyArbitrary', ['cosmoshub-4', _hubAddress, 'hello']),
        throwsA(_providerError('INVALID_PARAMS')),
      );
    }, skip: kernelSkip);

    test('a transaction disguised as a message is refused', () async {
      await connect(['cosmoshub-4']);
      await expectLater(
        call('signArbitrary', ['cosmoshub-4', _hubAddress, jsonEncode(_sendDoc())]),
        throwsA(_providerError('INVALID_PARAMS')),
      );
    });

    test('a sign-in for another site is refused before any prompt', () async {
      await connect(['cosmoshub-4']);
      final text = [
        'evil.example wants you to sign in with your Cosmos account:',
        _hubAddress,
        '',
        'URI: https://evil.example',
        'Version: 1',
        'Chain ID: cosmoshub-4',
        'Nonce: 8f3k2m9QxZ',
        'Issued At: ${DateTime.now().toUtc().toIso8601String()}',
      ].join('\n');
      await expectLater(
        call('signArbitrary', ['cosmoshub-4', _hubAddress, text]),
        throwsA(_providerError('ORIGIN_MISMATCH')),
      );
      expect(queue.pending, isEmpty);
    });

    test('a sign-in for this site gets the sign-in prompt', () async {
      await connect(['cosmoshub-4']);
      final text = [
        'app.example.com wants you to sign in with your Cosmos account:',
        _hubAddress,
        '',
        'Welcome back.',
        '',
        'URI: https://app.example.com',
        'Version: 1',
        'Chain ID: cosmoshub-4',
        'Nonce: 8f3k2m9QxZ',
        'Issued At: ${DateTime.now().toUtc().toIso8601String()}',
      ].join('\n');
      final signing = call('signArbitrary', ['cosmoshub-4', _hubAddress, text]);
      final request = await answer(approve: false);
      expect(request.signIn!.domain, 'app.example.com');
      expect(request.title, 'Sign in to app.example.com');
      await expectLater(signing, throwsA(_providerError('USER_REJECTED')));
    });
  });

  group('chains', () {
    test('a suggested chain is checked, approved, then added', () async {
      final info = {
        'chainId': 'mychain-1',
        'chainName': 'My Chain',
        'rpc': 'https://rpc.mychain.example',
        'rest': 'https://rest.mychain.example/',
        'bip44': {'coinType': 118},
        'bech32Config': {'bech32PrefixAccAddr': 'my'},
        'currencies': [
          {'coinDenom': 'MY', 'coinMinimalDenom': 'umy', 'coinDecimals': 6},
        ],
        'feeCurrencies': [
          {
            'coinDenom': 'MY',
            'coinMinimalDenom': 'umy',
            'coinDecimals': 6,
            'gasPriceStep': {'low': 0.01, 'average': 0.02, 'high': 0.04},
          },
        ],
      };
      final adding = call('experimentalSuggestChain', [info]);
      final request = await answer();
      expect(request.kind, ApprovalKind.suggestChain);
      expect(request.draft!.rest, 'https://rest.mychain.example');
      await adding;
      expect(wallet.added.single.chainId, 'mychain-1');
      // Known now: nothing to ask the second time.
      expect(await call('experimentalSuggestChain', [info]), isNull);
      expect(queue.pending, isEmpty);

      await expectLater(
        call('experimentalSuggestChain', [{...info, 'chainId': 'other-1', 'rpc': 'http://rpc.example'}]),
        throwsA(_providerError('INVALID_PARAMS', 'RPC must be an https:// URL')),
      );
      await expectLater(
        call('experimentalSuggestChain', [{...info, 'chainId': 'cosmoshub-4'}]),
        throwsA(_providerError('INVALID_PARAMS', 'That chain ID is already in the registry')),
      );
    });

    test('chain infos never carry endpoints', () async {
      final infos = await call('getChainInfosWithoutEndpoints') as List;
      expect(infos, isNotEmpty);
      for (final info in infos.cast<Map<String, Object?>>()) {
        expect(info.containsKey('rpc'), isFalse);
        expect(info.containsKey('rest'), isFalse);
      }
      final hub = infos.cast<Map<String, Object?>>().firstWhere((i) => i['chainId'] == 'cosmoshub-4');
      expect((hub['bech32Config'] as Map)['bech32PrefixValAddr'], 'cosmosvaloper');
    });
  });

  test('previews: plain text whole up to 280, anything else in hex', () {
    expect(previewText(utf8.encode('line one\nline two')), 'line one\nline two');
    expect(previewText(utf8.encode('a' * 300)), '${'a' * 277}…');
    expect(previewText(utf8.encode('café')), '0x636166c3a9');
    expect(previewText(Uint8List.fromList(List<int>.filled(60, 0xff))), '0x${'ff' * 48}…');
  });

  test('unknown codes from elsewhere become INTERNAL; Connect codes survive', () {
    expect(asProviderError(StateError('boom')).code, 'INTERNAL');
    expect(asProviderError(const ProviderError('LOCKED', 'x')).code, 'LOCKED');
    expect(isProviderOrigin('https://[::1]'), isTrue);
    expect(isProviderOrigin('http://127.0.0.1:8080'), isTrue);
    expect(isProviderOrigin('http://192.168.1.2'), isFalse);
    expect(isProviderOrigin('file:///etc/passwd'), isFalse);
  });
}
