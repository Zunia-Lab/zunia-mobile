/// What the engine does when a node refuses, repeats or loses a broadcast:
/// claims failed with "sequence" errors, and a claim that went through could
/// be reported as failed and sent again. Signs with the host kernel; skipped
/// without it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/services/broadcast_service.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

import '../support/kernel.dart';

const validator = 'addr_safrovaloper1q4c4p0n66crlkgagr76mjtnmt4d8pdlq8knm5z';

/// Answers the account query, then replays [script] one broadcast at a time:
/// a [BroadcastResult] is returned, anything else is thrown.
class ScriptedBroadcast implements BroadcastService {
  ScriptedBroadcast(this.script, {this.sequence = '12'});

  final List<Object> script;
  final String sequence;
  final sent = <String>[];

  @override
  Future<({String accountNumber, String sequence})> fetchAccount({
    required String chainId,
    required String address,
  }) async =>
      (accountNumber: '3684', sequence: sequence);

  @override
  Future<BroadcastResult> broadcast({
    required String chainId,
    required String txBytesBase64,
    String mode = 'BROADCAST_MODE_SYNC',
  }) async {
    sent.add(txBytesBase64);
    final next = script.removeAt(0);
    if (next is BroadcastResult) return next;
    throw next;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String hashOf(String base64Tx) => sha256.convert(base64Decode(base64Tx)).toString().toUpperCase();

void main() {
  final phrase =
      (jsonDecode(File('test/fixtures/registry-addresses.json').readAsStringSync())
          as Map<String, dynamic>)['mnemonic'] as String;
  late ChainEntry chain;
  late String signer;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await ChainCatalog.load();
    chain = ChainCatalog.instance.find('safrochain-1')!;
    if (WalletKernel.instance.isAvailable) {
      signer = WalletKernel.instance
          .deriveAddress(phrase: phrase, chain: chain, accountIndex: 0)
          .address;
    }
  });

  setUp(SequenceFloor.instance.clear);

  Future<String> claim(TxEngine engine) async {
    final msgs = [TxMsg.withdrawReward(delegator: signer, validator: validator)];
    // No network in tests: the simulation is refused and the quote falls back
    // to the fixed gas limit, which is all this needs.
    final quote = await engine.quote(
      phrase: phrase,
      accountIndex: 0,
      chain: chain,
      signer: signer,
      msgs: msgs,
    );
    return engine.signAndBroadcast(phrase: phrase, accountIndex: 0, quote: quote);
  }

  BroadcastException mismatch(int expected, int got) => BroadcastException(
        'account sequence mismatch, expected $expected, got $got: incorrect account sequence',
        txhash: 'X',
        code: 32,
      );

  test('follows the sequence the chain names, more than once', () async {
    final fake = ScriptedBroadcast([
      mismatch(13, 12),
      mismatch(14, 13),
      const BroadcastResult(txhash: 'ABC', code: 0, rawLog: ''),
    ]);
    final hash = await claim(TxEngine(broadcast: fake));
    expect(hash, 'ABC');
    expect(fake.sent, hasLength(3));
    // The next transaction starts after the one that went through.
    expect(SequenceFloor.instance.atLeast('safrochain-1', signer, 0), 15);
  }, skip: kernelSkip);

  test('a remembered sequence the chain no longer expects is dropped', () async {
    // An earlier claim was remembered as sequence 20 but never landed.
    SequenceFloor.instance.remember('safrochain-1', signer, 21);
    final fake = ScriptedBroadcast([
      mismatch(12, 21),
      const BroadcastResult(txhash: 'DEF', code: 0, rawLog: ''),
    ]);
    expect(await claim(TxEngine(broadcast: fake)), 'DEF');
    expect(SequenceFloor.instance.atLeast('safrochain-1', signer, 0), 13);
  }, skip: kernelSkip);

  test('gives up with the chain words after the retries', () async {
    final fake = ScriptedBroadcast([
      for (var i = 0; i <= maxSequenceRetries; i++) mismatch(30 + i, 29 + i),
    ]);
    await expectLater(claim(TxEngine(broadcast: fake)), throwsA(isA<TxException>()));
    expect(fake.sent, hasLength(maxSequenceRetries + 1));
  }, skip: kernelSkip);

  test('the same bytes already in the mempool are this transaction', () async {
    final fake = ScriptedBroadcast([
      BroadcastException('tx already exists in cache', txhash: '', code: 19),
    ]);
    final hash = await claim(TxEngine(broadcast: fake));
    expect(hash, hashOf(fake.sent.single));
  }, skip: kernelSkip);

  test('a lost answer is looked up before it is called a failure', () async {
    final found = ScriptedBroadcast([TimeoutException('no answer')]);
    final hash = await claim(TxEngine(broadcast: found, inclusionCheck: (_, _) async => true));
    expect(hash, hashOf(found.sent.single));

    final missing = ScriptedBroadcast([const SocketException('reset')]);
    final error = await claim(
      TxEngine(broadcast: missing, inclusionCheck: (_, _) async => false),
    ).then<Object?>((_) => null, onError: (Object e) => e);
    expect(error, isA<TxException>());
    final refused = error! as TxException;
    expect(refused.txhash, hashOf(missing.sent.single));
    expect(refused.message, contains('check Activity'));
  }, skip: kernelSkip);

  test('a refusal that is not about the sequence is shown at once', () async {
    final fake = ScriptedBroadcast([
      BroadcastException('insufficient fee', txhash: 'X', code: 13),
    ]);
    await expectLater(claim(TxEngine(broadcast: fake)), throwsA(isA<TxException>()));
    expect(fake.sent, hasLength(1));
  }, skip: kernelSkip);

  test('recognises a duplicate by its code or its words', () {
    expect(isAlreadyInMempool('whatever', code: 19), isTrue);
    expect(isAlreadyInMempool('tx already exists in cache'), isTrue);
    expect(isAlreadyInMempool('insufficient fee', code: 13), isFalse);
  });

  test('a refusal of the transaction itself stops the review', () {
    expect(
      isExecutionRefusal(
        'failed to execute message; message index: 0: no delegation for (address, validator) tuple',
      ),
      isTrue,
    );
    expect(isExecutionRefusal('spendable balance 10usaf is smaller than 400usaf: insufficient funds'), isTrue);
    expect(isExecutionRefusal('HTTP 502'), isFalse);
    expect(isExecutionRefusal('the node did not answer'), isFalse);
  });

  test('the no-simulation gas grows with the claims', () {
    expect(fallbackGasFor(1), fallbackGasLimit);
    expect(fallbackGasFor(3), 3 * fallbackGasPerMessage);
    // 20 Cosmos Hub claims use about 6.4M gas.
    expect(fallbackGasFor(20), greaterThanOrEqualTo(6400000));
  });

  test('SequenceFloor.trust replaces a higher floor', () {
    final floor = SequenceFloor();
    floor.remember('safrochain-1', 'addr_safro1me', 21);
    floor.trust('safrochain-1', 'addr_safro1me', 12);
    expect(floor.atLeast('safrochain-1', 'addr_safro1me', 0), 12);
  });
}
