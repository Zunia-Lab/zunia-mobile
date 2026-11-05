/// Staking: the messages Stake, Unstake and Claim sign (and that the kernel
/// reads them back), the reads behind the Earn tab, and the APR estimate that
/// is shown only when it can be worked out honestly.
library;

import 'dart:convert';
import 'dart:io';

import 'package:bech32/bech32.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_core/zunia_core.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/screens/delegate_screen.dart';
import 'package:zunia_mobile/screens/proposal_detail_screen.dart';
import 'package:zunia_mobile/screens/validator_list_screen.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/governance_client.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/staking_client.dart';
import 'package:zunia_mobile/state/staking.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/util/amounts.dart';

import '../support/kernel.dart';

const hub = ChainEntry(
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
  rest: 'https://lcd.hub.test',
);

StakingPosition position(String validator, String? rewards, {String amount = '1000000'}) =>
    StakingPosition(
      chainId: 'cosmoshub-4',
      validatorAddress: validator,
      moniker: validator,
      identity: '',
      amount: BigInt.parse(amount),
      rewards: rewards == null ? null : BigInt.parse(rewards),
      jailed: false,
      status: 'BOND_STATUS_BONDED',
    );

Map<String, Object> validatorJson(String op, String tokens, {String rate = '0.050000000000000000', bool jailed = false}) => {
      'operator_address': op,
      'jailed': jailed,
      'status': 'BOND_STATUS_BONDED',
      'tokens': tokens,
      'min_self_delegation': '1',
      'description': {
        'moniker': 'Val $op',
        'identity': 'ABC',
        'website': 'example.com',
        'details': 'Runs nodes',
      },
      'commission': {
        'commission_rates': {'rate': rate, 'max_rate': '0.200000000000000000'},
      },
    };

void main() {
  group('messages', () {
    test('stake and unstake carry base units as strings', () {
      final stake = stakeMsgs(
        delegator: 'cosmos1d',
        validator: 'cosmosvaloper1v',
        denom: 'uatom',
        amount: BigInt.parse('1500000'),
      ).single;
      expect(stake.toJson(), {
        'typeUrl': '/cosmos.staking.v1beta1.MsgDelegate',
        'value': {
          'delegator_address': 'cosmos1d',
          'validator_address': 'cosmosvaloper1v',
          'amount': {'denom': 'uatom', 'amount': '1500000'},
        },
      });
      final unstake = unstakeMsgs(
        delegator: 'cosmos1d',
        validator: 'cosmosvaloper1v',
        denom: 'uatom',
        amount: BigInt.one,
      ).single;
      expect(unstake.typeUrl, '/cosmos.staking.v1beta1.MsgUndelegate');
      expect(
        () => stakeMsgs(delegator: 'a', validator: 'b', denom: 'u', amount: BigInt.zero),
        throwsArgumentError,
      );
    });

    test('claims skip nothing-to-claim, put the largest first, and batch', () {
      final rows = [
        position('v1', '10'),
        position('v2', '0'),
        position('v3', null),
        position('v4', '500'),
        for (var i = 0; i < 25; i++) position('w$i', '${i + 1}'),
      ];
      final batches = claimMsgBatches(delegator: 'cosmos1d', positions: rows);
      expect(batches.length, 2);
      expect(batches.first.length, maxClaimsPerTx);
      expect(batches.first.first.value['validator_address'], 'v4');
      expect(batches.expand((b) => b).length, 27);
      expect(
        batches.expand((b) => b).map((m) => m.value['validator_address']),
        isNot(contains('v2')),
      );
      expect(batches.first.first.typeUrl, '/cosmos.distribution.v1beta1.MsgWithdrawDelegatorReward');
      expect(claimMsgBatches(delegator: 'd', positions: [position('v', '0')]), isEmpty);
    });

    test('a claimable total is unknown when any reward is unknown', () {
      expect(claimableTotal([position('a', '5'), position('b', '7')]), BigInt.from(12));
      expect(claimableTotal([position('a', '5'), position('b', null)]), isNull);
    });

    test('MAX keeps a fee reserve when the fee is paid in the staked coin', () {
      final reserve = feeReserveFor(hub);
      // 400,000 fallback gas at the high price, rounded up.
      expect(reserve, BigInt.from(12000));
      expect(maxStakeable(BigInt.from(1000000), reserve), BigInt.from(988000));
      expect(maxStakeable(BigInt.from(100), reserve), BigInt.zero);
    });

    test('the amount form refuses what cannot be signed as typed', () {
      AmountInput a(String v) => parseAmount(v, decimals: 6);
      String? check(String v, {String pool = '2000000'}) => delegateAmountProblem(
            input: a(v),
            pool: BigInt.parse(pool),
            mode: DelegateMode.stake,
          );
      expect(check(''), isNull);
      expect(check('1.5'), isNull);
      expect(check('2.000001'), 'More than your available balance');
      expect(check('0.0000001'), 'Too many decimal places for this token');
      expect(check('0'), 'Enter more than zero');
      expect(check('abc'), 'Enter a valid amount');
      expect(
        delegateAmountProblem(input: a('3'), pool: BigInt.two, mode: DelegateMode.unstake),
        'More than you have staked here',
      );
    });

    test('the kernel reads the stake, claim and vote messages it will sign', () {
      final phrase = (jsonDecode(File('test/fixtures/registry-addresses.json').readAsStringSync())
          as Map<String, dynamic>)['mnemonic'] as String;
      final kernel = WalletKernel.instance;
      final account = kernel.deriveAddress(phrase: phrase, chain: hub);
      // An operator address the kernel will decode: this account's own key
      // under the valoper prefix.
      final words = const Bech32Codec().decode(account.address).data;
      final valoper = const Bech32Codec().encode(Bech32('cosmosvaloper', words));
      final msgs = [
        ...stakeMsgs(
          delegator: account.address,
          validator: valoper,
          denom: 'uatom',
          amount: BigInt.from(2500000),
        ),
        ...claimMsgBatches(
          delegator: account.address,
          positions: [position(valoper, '10')],
        ).single,
        ...voteMsgs(voter: account.address, proposalId: '981', option: VoteOption.no),
      ];
      final preview = kernel.core.previewTx(
        chainId: hub.chainId,
        msgs: [for (final m in msgs) m.toJson()],
        fee: TxEngine.feeFor(hub, 250000, FeeSpeed.average),
        memo: '',
        accountNumber: 1,
        sequence: 0,
        publicKeyHex: account.publicKeyHex,
        ethKeyType: false,
        mode: ZuniaSignMode.direct,
      );
      expect(preview.summaries.length, 3);
      expect(preview.summaries.first.toLowerCase(), contains('deleg'));
      expect(preview.summaries.last.toLowerCase(), contains('981'));
      expect(preview.signBytesHash, isNotEmpty);
    }, skip: kernelSkip);
  });

  group('reads', () {
    late List<Uri> asked;
    late Map<String, Object> answers;

    Future<LcdResponse> fetch(Uri uri, Duration _) async {
      asked.add(uri);
      final key = uri.path;
      final answer = answers[key];
      if (answer == null) return const LcdResponse(404, '{"message":"not found"}');
      if (answer is LcdResponse) return answer;
      return LcdResponse(200, jsonEncode(answer));
    }

    StakingClient client() =>
        StakingClient(ChainReader(readsAllowed: () => true, fetch: fetch));

    setUp(() {
      asked = [];
      answers = {};
    });

    test('the bonded set pages, shares voting power and parses terms', () async {
      var page = 0;
      Future<LcdResponse> paged(Uri uri, Duration d) async {
        asked.add(uri);
        page++;
        return LcdResponse(
          200,
          jsonEncode({
            'validators': page == 1
                ? [validatorJson('a', '300'), validatorJson('b', '100')]
                : [validatorJson('c', '600', rate: '0.100000000000000000')],
            'pagination': {'next_key': page == 1 ? 'Ag==' : null},
          }),
        );
      }

      final rows = await StakingClient(ChainReader(readsAllowed: () => true, fetch: paged))
          .validators(hub);
      expect(rows.map((v) => v.operatorAddress), ['c', 'a', 'b']);
      expect(rows.first.votingPower, 0.6);
      expect(rows.first.commission, 0.1);
      expect(rows.first.maxCommission, 0.2);
      expect(rows.first.websiteUri.toString(), 'https://example.com');
      expect(asked.last.queryParameters['pagination.key'], 'Ag==');

      expect(
        arrangeValidators(rows, sort: ValidatorSort.commission).map((v) => v.operatorAddress),
        ['a', 'b', 'c'],
      );
      expect(arrangeValidators(rows, query: 'val c').single.operatorAddress, 'c');
      expect(
        arrangeValidators(rows, sort: ValidatorSort.myStake, myStake: {'b': BigInt.one})
            .first
            .operatorAddress,
        'b',
      );
    });

    test('positions carry rewards, and unknown rewards are not zero', () async {
      answers['/cosmos/staking/v1beta1/delegations/cosmos1me'] = {
        'delegation_responses': [
          {
            'delegation': {'validator_address': 'cosmosvaloper1a'},
            'balance': {'denom': 'uatom', 'amount': '5000000'},
          },
          {
            'delegation': {'validator_address': 'cosmosvaloper1gone'},
            'balance': {'denom': 'uatom', 'amount': '7'},
          },
        ],
      };
      answers['/cosmos/distribution/v1beta1/delegators/cosmos1me/rewards'] = {
        'rewards': [
          {
            'validator_address': 'cosmosvaloper1a',
            'reward': [
              {'denom': 'uatom', 'amount': '1234.567000000000000000'},
              {'denom': 'ibc/X', 'amount': '9'},
            ],
          },
        ],
      };
      answers['/cosmos/staking/v1beta1/validators/cosmosvaloper1gone'] = {
        'validator': {
          ...validatorJson('cosmosvaloper1gone', '0', jailed: true),
          'status': 'BOND_STATUS_UNBONDING',
        },
      };
      final known = {
        'cosmosvaloper1a': StakingValidator(
          chainId: 'cosmoshub-4',
          operatorAddress: 'cosmosvaloper1a',
          moniker: 'Alpha',
          identity: '',
          commission: 0.05,
          maxCommission: 0.2,
          votingPower: 0.1,
          tokens: BigInt.one,
          minSelfDelegation: BigInt.one,
          website: '',
          details: '',
          jailed: false,
          status: 'BOND_STATUS_BONDED',
        ),
      };
      final rows = await client().positions(hub, 'cosmos1me', known: known);
      expect(rows.map((p) => p.moniker), ['Alpha', 'Val cosmosvaloper1gone']);
      expect(rows.first.rewards, BigInt.from(1234));
      expect(rows.last.rewards, BigInt.zero);
      expect(rows.last.bondState, ValidatorBondState.jailed);
      // Only the validator outside the known set was looked up.
      expect(asked.where((u) => u.path.contains('/validators/')).length, 1);

      // The rewards endpoint failing makes rewards unknown, not zero.
      answers.remove('/cosmos/distribution/v1beta1/delegators/cosmos1me/rewards');
      final unknown = await client().positions(hub, 'cosmos1me', known: known);
      expect(unknown.first.rewards, isNull);
    });

    test('a failed delegations read is an error, not "no stake"', () async {
      answers['/cosmos/staking/v1beta1/delegations/cosmos1me'] =
          const LcdResponse(503, 'busy');
      await expectLater(
        client().positions(hub, 'cosmos1me'),
        throwsA(isA<ChainReadError>().having((e) => e.kind, 'kind', ChainReadErrorKind.unreachable)),
      );
    });

    test('unbonding entries sort soonest first; params give the period', () async {
      answers['/cosmos/staking/v1beta1/delegators/cosmos1me/unbonding_delegations'] = {
        'unbonding_responses': [
          {
            'validator_address': 'cosmosvaloper1a',
            'entries': [
              {'balance': '20', 'completion_time': '2026-11-02T00:00:00Z', 'creation_height': '5'},
              {'balance': '10', 'completion_time': '2026-10-25T00:00:00Z', 'creation_height': '4'},
            ],
          },
        ],
      };
      answers['/cosmos/staking/v1beta1/params'] = {
        'params': {'unbonding_time': '1814400s', 'bond_denom': 'uatom', 'max_validators': 180},
      };
      final entries = await client().unbonding(hub, 'cosmos1me');
      expect(entries.map((e) => e.amount), [BigInt.from(10), BigInt.from(20)]);
      expect(entries.first.completionTimeRaw, '2026-10-25T00:00:00Z');
      final params = await client().params(hub);
      expect(params.unbondingTime, const Duration(days: 21));
      expect(describeDuration(params.unbondingTime!), '21 days');
      expect(params.maxValidators, 180);
    });
  });

  group('APR', () {
    test('worked out from inflation, community tax and the bonded ratio', () {
      final apr = estimateApr(
        inflation: 0.10,
        communityTax: 0.02,
        bondedTokens: BigInt.from(500),
        totalSupply: BigInt.from(1000),
        mintDenom: 'uatom',
        bondDenom: 'uatom',
      )!;
      expect(apr.bondedRatio, 0.5);
      expect(apr.apr, closeTo(0.196, 1e-9));
      expect(apr.afterCommission(0.05), closeTo(0.1862, 1e-9));
    });

    test('is not shown when the formula would not describe what stakers get', () {
      final ok = (
        inflation: 0.1,
        tax: 0.02,
        bonded: BigInt.from(500),
        supply: BigInt.from(1000),
      );
      // No standard mint module (Osmosis, Celestia): no inflation answer.
      expect(
        estimateApr(
          inflation: null,
          communityTax: ok.tax,
          bondedTokens: ok.bonded,
          totalSupply: ok.supply,
        ),
        isNull,
      );
      // Zero inflation: rewards come from somewhere the formula cannot see.
      expect(
        estimateApr(inflation: 0, communityTax: ok.tax, bondedTokens: ok.bonded, totalSupply: ok.supply),
        isNull,
      );
      // Minting another denom than the one staked.
      expect(
        estimateApr(
          inflation: ok.inflation,
          communityTax: ok.tax,
          bondedTokens: ok.bonded,
          totalSupply: ok.supply,
          mintDenom: 'ustake',
          bondDenom: 'uatom',
        ),
        isNull,
      );
      // Nonsense inputs.
      expect(
        estimateApr(inflation: ok.inflation, communityTax: ok.tax, bondedTokens: BigInt.from(2000), totalSupply: ok.supply),
        isNull,
      );
      expect(
        estimateApr(inflation: 0.9, communityTax: 0, bondedTokens: BigInt.one, totalSupply: BigInt.from(1000)),
        isNull,
      );
    });

    test('reads the five inputs, falling back to the older supply route', () async {
      final answers = <String, Object>{
        '/cosmos/mint/v1beta1/inflation': {'inflation': '0.100000000000000000'},
        '/cosmos/mint/v1beta1/params': {
          'params': {'mint_denom': 'uatom'},
        },
        '/cosmos/distribution/v1beta1/params': {
          'params': {'community_tax': '0.020000000000000000'},
        },
        '/cosmos/staking/v1beta1/pool': {
          'pool': {'bonded_tokens': '500', 'not_bonded_tokens': '1'},
        },
        '/cosmos/bank/v1beta1/supply/uatom': {
          'amount': {'denom': 'uatom', 'amount': '1000'},
        },
      };
      Future<LcdResponse> fetch(Uri uri, Duration _) async {
        final a = answers[uri.path];
        return a == null
            ? const LcdResponse(501, '{"message":"Not Implemented"}')
            : LcdResponse(200, jsonEncode(a));
      }

      final apr = await StakingClient(ChainReader(readsAllowed: () => true, fetch: fetch))
          .apr(hub, bondDenom: 'uatom');
      expect(apr!.apr, closeTo(0.196, 1e-9));

      answers.remove('/cosmos/mint/v1beta1/inflation');
      final none = await StakingClient(ChainReader(readsAllowed: () => true, fetch: fetch))
          .apr(hub, bondDenom: 'uatom');
      expect(none, isNull);
    });

    test('durations read as protobuf JSON', () {
      expect(parseProtoDuration('1209600s'), const Duration(days: 14));
      expect(parseProtoDuration('1.5s'), const Duration(milliseconds: 1500));
      expect(parseProtoDuration('soon'), isNull);
      expect(describeDuration(const Duration(days: 3, hours: 12)), '3 days 12 hours');
      expect(describeDuration(const Duration(hours: 36)), '36 hours');
    });
  });
}
