/// Real claims against real chains, without a key and without moving funds.
///
/// Opt-in: runs only with `ZUNIA_LIVE=1 flutter test test/live/`. For each
/// chain it finds a real delegator with rewards on several validators, reads
/// the account the way the app does (on Safrochain, a vesting account), builds
/// the claim with the app's own plan and the kernel, and asks the chain to
/// simulate it with the fee the app would pay. Simulation checks everything a
/// broadcast checks except the signature, so a claim that passes here fails
/// only on a key, never on its messages, gas, fee, account or sequence.
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_core/zunia_core.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/services/broadcast_service.dart';
import 'package:zunia_mobile/services/staking_client.dart';
import 'package:zunia_mobile/state/staking.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';

final bool live = Platform.environment['ZUNIA_LIVE'] == '1';

/// A Safrochain continuous-vesting account (account 3684), read through the
/// app's own account query.
const safroVesting = 'addr_safro1qq98njda3rnf3xtzpzaxd38x3hfpaaa465kve2';

/// Any valid compressed secp256k1 key: simulation does not check that the key
/// belongs to the signer, only that the transaction decodes and runs.
const anyPubkey = '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';

Future<Map<String, dynamic>> getJson(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return jsonDecode(text) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<({int status, Map<String, dynamic> body})> postJson(String url, Object payload) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(payload)));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return (status: response.statusCode, body: jsonDecode(text) as Map<String, dynamic>);
  } finally {
    client.close(force: true);
  }
}

/// Whole base units of [denom] in a DecCoin list.
BigInt rewardIn(Object? coins, String denom) {
  for (final coin in (coins as List?) ?? const []) {
    if (coin is Map && coin['denom'] == denom) {
      return BigInt.parse('${coin['amount']}'.split('.').first);
    }
  }
  return BigInt.zero;
}

/// A delegator with rewards on at least [minValidators] validators and enough
/// spendable fee coin, plus its positions.
Future<({String delegator, List<StakingPosition> positions})> findDelegator(
  ChainEntry chain, {
  int minValidators = 2,
}) async {
  final rest = chain.rest!;
  final denom = chain.coinMinimalDenom;
  final validators = await getJson(
    '$rest/cosmos/staking/v1beta1/validators?status=BOND_STATUS_BONDED&pagination.limit=8',
  );
  for (final validator in (validators['validators'] as List).cast<Map<String, dynamic>>()) {
    final delegations = await getJson(
      '$rest/cosmos/staking/v1beta1/validators/${validator['operator_address']}/delegations?pagination.limit=40',
    );
    for (final row in ((delegations['delegation_responses'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()) {
      final delegator = (row['delegation'] as Map)['delegator_address'] as String;
      final rewards = await getJson('$rest/cosmos/distribution/v1beta1/delegators/$delegator/rewards');
      final perValidator = ((rewards['rewards'] as List?) ?? const []).cast<Map<String, dynamic>>();
      final positions = [
        for (final r in perValidator)
          if (rewardIn(r['reward'], denom) > BigInt.zero)
            StakingPosition(
              chainId: chain.chainId,
              validatorAddress: r['validator_address'] as String,
              moniker: r['validator_address'] as String,
              identity: '',
              amount: BigInt.one,
              rewards: rewardIn(r['reward'], denom),
              jailed: false,
              status: 'BOND_STATUS_BONDED',
            ),
      ];
      if (positions.length < minValidators) continue;
      final balance = await getJson(
        '$rest/cosmos/bank/v1beta1/spendable_balances/$delegator/by_denom?denom=${Uri.encodeQueryComponent(denom)}',
      );
      final spendable = BigInt.tryParse('${(balance['balance'] as Map?)?['amount'] ?? '0'}') ?? BigInt.zero;
      if (spendable < BigInt.from(10).pow(chain.coinDecimals) ~/ BigInt.from(20)) continue;
      return (delegator: delegator, positions: positions);
    }
  }
  throw StateError('no delegator with rewards on $minValidators validators on ${chain.chainId}');
}

/// The node's minimum price for [denom], 0 when it publishes none.
Future<double> minimumGasPrice(ChainEntry chain, String denom) async {
  final config = await getJson('${chain.rest}/cosmos/base/node/v1beta1/config');
  final raw = '${config['minimum_gas_price'] ?? ''}';
  for (final part in raw.split(',')) {
    final match = RegExp(r'^([0-9.]+)(.+)$').firstMatch(part.trim());
    if (match != null && match.group(2) == denom) return double.parse(match.group(1)!);
  }
  return 0;
}

String hexOf(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late ZuniaCore core;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await ChainCatalog.load();
    // The test binding answers every HTTP request with 400; these talk to
    // real nodes.
    HttpOverrides.global = null;
    core = WalletKernel.instance.core;
  });

  test('a Safrochain vesting account reads with its real number', () async {
    final account = await BroadcastService.instance.fetchAccount(
      chainId: 'safrochain-1',
      address: safroVesting,
    );
    expect(account.accountNumber, '3684');
    expect(int.parse(account.sequence), greaterThanOrEqualTo(12));
  }, skip: live ? false : 'set ZUNIA_LIVE=1');

  for (final chainId in ['safrochain-1', 'cosmoshub-4', 'osmosis-1', 'injective-1']) {
    test('$chainId: a multi-validator claim simulates with the fee the app pays', () async {
      final chain = ChainCatalog.instance.find(chainId)!;
      final found = await findDelegator(chain);
      final plan = claimPlan(delegator: found.delegator, positions: found.positions);
      expect(plan.isEmpty, isFalse);

      final account = await BroadcastService.instance.fetchAccount(
        chainId: chainId,
        address: found.delegator,
      );
      final raw = await getJson('${chain.rest}/cosmos/auth/v1beta1/accounts/${found.delegator}');
      final onChainKey = _pubkeyOf(raw);
      final msgs = [for (final m in plan.msgs) m.toJson()];

      Future<({int status, Map<String, dynamic> body})> simulate(ZuniaFee fee, int sequence) {
        final tx = core.buildSimulateTx(
          chainId: chainId,
          msgs: msgs,
          fee: fee,
          accountNumber: int.parse(account.accountNumber),
          sequence: sequence,
          publicKeyHex: onChainKey ?? anyPubkey,
          ethKeyType: chain.usesEthKeySign,
          ethPubKeyTypeUrl: chain.ethKeyTypeUrl,
        );
        return postJson(
          '${chain.rest}/cosmos/tx/v1beta1/simulate',
          {'tx_bytes': base64Encode(_bytes(tx))},
        );
      }

      // 1. The quote's simulation, as TxEngine.quote sends it.
      final quoted = await simulate(
        ZuniaFee(amount: const [], gasLimit: fallbackGasLimit),
        int.parse(account.sequence),
      );
      expect(quoted.status, 200, reason: '${quoted.body['message']}');
      final used = int.parse('${(quoted.body['gas_info'] as Map)['gas_used']}');
      final gasLimit = (used * defaultGasAdjustment).ceil();

      // 2. The final form: the fee the app would sign, at the cheapest speed.
      final fee = TxEngine.feeFor(chain, gasLimit, FeeSpeed.low);
      final signed = await simulate(fee, int.parse(account.sequence));
      expect(signed.status, 200, reason: '${signed.body['message']}');

      // 3. The fee meets the node's floor, and the no-simulation fallback
      //    would have covered what the claim really used.
      final denom = fee.amount.single.denom;
      final floor = await minimumGasPrice(chain, denom);
      final paid = BigInt.parse(fee.amount.single.amount);
      final required = BigInt.from((floor * gasLimit).ceil());
      expect(paid >= required, isTrue, reason: 'paid $paid $denom, node wants $required');
      expect(fallbackGasFor(plan.msgs.length), greaterThanOrEqualTo(used));

      // 4. A stale sequence is refused with words the engine reads back.
      final stale = await simulate(fee, int.parse(account.sequence) + 7);
      expect(stale.status, isNot(200));
      final message = '${stale.body['message']}';
      expect(isSequenceMismatch(message), isTrue, reason: message);
      expect(expectedSequenceOf(message), int.parse(account.sequence), reason: message);

      // ignore: avoid_print
      print('$chainId: ${plan.msgs.length} claims, gas $used → limit $gasLimit, '
          'fee $paid $denom (node floor $required), fallback ${fallbackGasFor(plan.msgs.length)}, '
          'account ${account.accountNumber}/${account.sequence}');
    }, skip: live ? false : 'set ZUNIA_LIVE=1', timeout: const Timeout(Duration(minutes: 3)));
  }
}

String? _pubkeyOf(Map<String, dynamic> body) {
  Map<String, dynamic>? find(Object? node, int depth) {
    if (node is! Map || depth > 4) return null;
    final map = node.cast<String, dynamic>();
    if (map['pub_key'] is Map) return (map['pub_key'] as Map).cast<String, dynamic>();
    for (final value in map.values) {
      final found = find(value, depth + 1);
      if (found != null) return found;
    }
    return null;
  }

  final key = find(body['account'], 0)?['key'];
  return key is String ? hexOf(base64Decode(key)) : null;
}

List<int> _bytes(String hex) => [
      for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ];
