/// The messages a dApp builds, in Amino mode, in the kernel's own words.
///
/// Real mainnet transactions (zunia-core's `chain-verified-dapp-messages.json`)
/// are decoded by the kernel, their LCD JSON is turned into the Amino JSON a
/// dApp would send, and the two readings must say the same thing.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/browser/sign_review.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';

import '../support/kernel.dart';

const _sender = 'cosmos19rl4cm2hmr8afy4kldpxz3fka4jguq0auqdal4';
const _other = 'cosmos1jrkmdcwgq94uaamx6zax2luewlhf7u4kucx3kz';
const _validator = 'cosmosvaloper19rl4cm2hmr8afy4kldpxz3fka4jguq0ae5egnx';
const _contract = 'cosmos1uwk8xc6q0s6t5qcpr6rht3sczu6du83xq8pwxjua0hfj5hzcnh3s4mk53k';

/// Amino name of each type URL, from the kernel's table.
const _aminoNames = {
  '/osmosis.concentratedliquidity.v1beta1.MsgCreatePosition': 'osmosis/cl-create-position',
  '/osmosis.concentratedliquidity.v1beta1.MsgAddToPosition': 'osmosis/cl-add-to-position',
  '/osmosis.concentratedliquidity.v1beta1.MsgWithdrawPosition': 'osmosis/cl-withdraw-position',
  '/osmosis.concentratedliquidity.v1beta1.MsgCollectSpreadRewards': 'osmosis/cl-col-sp-rewards',
  '/osmosis.concentratedliquidity.v1beta1.MsgCollectIncentives': 'osmosis/cl-collect-incentives',
  '/osmosis.concentratedliquidity.v1beta1.MsgTransferPositions': 'osmosis/cl-transfer-positions',
  '/osmosis.gamm.v1beta1.MsgJoinPool': 'osmosis/gamm/join-pool',
  '/osmosis.gamm.v1beta1.MsgExitPool': 'osmosis/gamm/exit-pool',
  '/osmosis.gamm.v1beta1.MsgJoinSwapExternAmountIn': 'osmosis/gamm/join-swap-extern-amount-in',
  '/osmosis.gamm.v1beta1.MsgExitSwapShareAmountIn': 'osmosis/gamm/exit-swap-share-amount-in',
  '/osmosis.gamm.v1beta1.MsgJoinSwapShareAmountOut': 'osmosis/gamm/join-swap-share-amount-out',
  '/osmosis.gamm.v1beta1.MsgExitSwapExternAmountOut': 'osmosis/gamm/exit-swap-extern-amount-out',
  '/osmosis.gamm.v1beta1.MsgSwapExactAmountIn': 'osmosis/gamm/swap-exact-amount-in',
  '/osmosis.gamm.v1beta1.MsgSwapExactAmountOut': 'osmosis/gamm/swap-exact-amount-out',
  '/osmosis.lockup.MsgLockTokens': 'osmosis/lockup/lock-tokens',
  '/osmosis.lockup.MsgBeginUnlocking': 'osmosis/lockup/begin-unlock-period-lock',
  '/osmosis.lockup.MsgBeginUnlockingAll': 'osmosis/lockup/begin-unlock-tokens',
  '/osmosis.superfluid.MsgSuperfluidDelegate': 'osmosis/superfluid-delegate',
  '/osmosis.superfluid.MsgSuperfluidUndelegate': 'osmosis/superfluid-undelegate',
  '/osmosis.superfluid.MsgLockAndSuperfluidDelegate': 'osmosis/lock-and-superfluid-delegate',
  '/osmosis.superfluid.MsgSuperfluidUnbondLock': 'osmosis/superfluid-unbond-lock',
  '/osmosis.superfluid.MsgSuperfluidUndelegateAndUnbondLock': 'osmosis/superfluid-undelegate-unbond-lock',
  '/osmosis.superfluid.MsgCreateFullRangePositionAndSuperfluidDelegate': 'osmosis/full-range-and-sf-delegate',
  '/osmosis.superfluid.MsgAddToConcentratedLiquiditySuperfluidPosition':
      'osmosis/add-to-cl-superfluid-position',
  '/cosmos.bank.v1beta1.MsgMultiSend': 'cosmos-sdk/MsgMultiSend',
  '/cosmos.staking.v1beta1.MsgCancelUnbondingDelegation': 'cosmos-sdk/MsgCancelUnbondingDelegation',
  '/cosmos.distribution.v1beta1.MsgSetWithdrawAddress': 'cosmos-sdk/MsgModifyWithdrawAddress',
  '/cosmos.distribution.v1beta1.MsgWithdrawValidatorCommission': 'cosmos-sdk/MsgWithdrawValCommission',
  '/cosmos.distribution.v1beta1.MsgFundCommunityPool': 'cosmos-sdk/MsgFundCommunityPool',
  '/cosmos.gov.v1beta1.MsgDeposit': 'cosmos-sdk/MsgDeposit',
  '/cosmos.gov.v1.MsgDeposit': 'cosmos-sdk/v1/MsgDeposit',
  '/cosmos.gov.v1beta1.MsgVoteWeighted': 'cosmos-sdk/MsgVoteWeighted',
  '/cosmos.gov.v1.MsgVoteWeighted': 'cosmos-sdk/v1/MsgVoteWeighted',
  '/cosmos.authz.v1beta1.MsgRevoke': 'cosmos-sdk/MsgRevoke',
  '/cosmos.feegrant.v1beta1.MsgRevokeAllowance': 'cosmos-sdk/MsgRevokeAllowance',
  '/cosmwasm.wasm.v1.MsgInstantiateContract': 'wasm/MsgInstantiateContract',
  '/cosmwasm.wasm.v1.MsgInstantiateContract2': 'wasm/MsgInstantiateContract2',
  '/cosmwasm.wasm.v1.MsgMigrateContract': 'wasm/MsgMigrateContract',
  '/cosmwasm.wasm.v1.MsgUpdateAdmin': 'wasm/MsgUpdateAdmin',
  '/cosmwasm.wasm.v1.MsgClearAdmin': 'wasm/MsgClearAdmin',
};

/// The Amino JSON of an LCD message: no `@type`, empty fields left out, a
/// lock's duration in nanoseconds.
Object? _amino(Object? lcd, {bool top = true}) {
  if (lcd is Map) {
    final out = <String, Object?>{};
    for (final e in lcd.entries) {
      if (top && e.key == '@type') continue;
      var value = e.value;
      if (top && e.key == 'duration' && value is String && value.endsWith('s')) {
        value = '${BigInt.parse(value.substring(0, value.length - 1)) * BigInt.from(1000000000)}';
      }
      // `msg` is a contract's JSON as it is: nothing in it is omitted.
      value = e.key == 'msg' ? value : _amino(value, top: false);
      if (value == null || value == '' || (value is List && value.isEmpty)) continue;
      out[e.key as String] = value;
    }
    return out;
  }
  if (lcd is List) return [for (final item in lcd) _amino(item, top: false)];
  return lcd;
}

/// Field `number` of a protobuf message, when it is a byte field.
Uint8List _field(Uint8List data, int number) {
  var i = 0;
  while (i < data.length) {
    var key = 0;
    var shift = 0;
    while (true) {
      final b = data[i++];
      key |= (b & 0x7f) << shift;
      if (b < 0x80) break;
      shift += 7;
    }
    final wire = key & 7;
    if (wire == 2) {
      var length = 0;
      shift = 0;
      while (true) {
        final b = data[i++];
        length |= (b & 0x7f) << shift;
        if (b < 0x80) break;
        shift += 7;
      }
      if (key >> 3 == number) return Uint8List.sublistView(data, i, i + length);
      i += length;
    } else if (wire == 0) {
      while (data[i++] >= 0x80) {}
    } else {
      throw StateError('unexpected wire type $wire');
    }
  }
  throw StateError('no field $number');
}

String _canon(Object? value) {
  Object? sorted(Object? v) => v is Map
      ? {for (final k in (v.keys.toList()..sort())) k: sorted(v[k])}
      : v is List
      ? [for (final x in v) sorted(x)]
      : v;
  return jsonEncode(sorted(value));
}

/// Every bech32-looking string an Amino value names, contract messages aside.
Set<String> _addressesIn(Object? value) {
  final out = <String>{};
  void walk(Object? v, String key) {
    if (key == 'msg') return;
    if (v is String && RegExp(r'^[a-z]+1[02-9ac-hj-np-z]{38,}$').hasMatch(v)) out.add(v);
    if (v is Map) v.forEach((k, x) => walk(x, '$k'));
    if (v is List) {
      for (final x in v) {
        walk(x, key);
      }
    }
  }

  walk(value, '');
  return out;
}

ReviewMessage? _describe(String type, Map<String, Object?> value) => describeAminoMsg(type, value);

String _said(String type, Map<String, Object?> value) {
  final message = _describe(type, value);
  expect(message, isNotNull, reason: type);
  expect(message!.unknown, isFalse, reason: '$type read as unknown: ${message.summary}');
  return message.summary;
}

void _unknown(String type, Map<String, Object?> value, [String? reason]) {
  final message = _describe(type, value);
  expect(message, isNotNull, reason: reason ?? type);
  expect(message!.unknown, isTrue, reason: reason ?? type);
  expect(message.summary, 'Message $type', reason: reason ?? type);
}

Map<String, Object?> _with(Map<String, Object?> base, Map<String, Object?> changes) {
  final out = {...base};
  for (final e in changes.entries) {
    if (e.value == #drop) {
      out.remove(e.key);
    } else {
      out[e.key] = e.value;
    }
  }
  return out;
}

const _drop = #drop;

void main() {
  final vectors = File('../zunia-core/tests/vectors/chain-verified-dapp-messages.json');
  final cases = vectors.existsSync()
      ? ((jsonDecode(vectors.readAsStringSync()) as Map<String, dynamic>)['cases'] as List)
            .cast<Map<String, dynamic>>()
      : const <Map<String, dynamic>>[];

  group('real mainnet transactions', () {
    test('Amino reads every one as the kernel reads its bytes', () {
      expect(cases.length, 55);
      final types = <String>{};
      for (final c in cases) {
        final typeUrl = c['typeUrl'] as String;
        final name = '$typeUrl ${c['hash']}';
        types.add(typeUrl);

        final raw = base64.decode(c['tx'] as String);
        final signBytes = DirectSignDoc.fromWire({
          'bodyBytes': base64.encode(_field(raw, 1)),
          'authInfoBytes': base64.encode(_field(raw, 2)),
          'chainId': c['chainId'],
          'accountNumber': '1',
        }).signBytes;
        final decoded = WalletKernel.instance.decodeDirect(signBytes);
        final kernel = adaptKernelPayload(decoded).messages[c['msgIndex'] as int];
        expect(kernel.type, typeUrl, reason: name);
        expect(kernel.unknown, isFalse, reason: name);

        final lcd = c['lcd'] as Map<String, dynamic>;
        final value = _amino(lcd) as Map<String, Object?>;
        final type = _aminoNames[typeUrl]!;
        final amino = _describe(type, value);
        expect(amino, isNotNull, reason: name);
        expect(amino!.unknown, isFalse, reason: '$name: ${amino.summary}');
        expect(amino.type, type, reason: name);
        expect(amino.summary, kernel.summary, reason: name);
        expect(amino.recipient, kernel.recipient, reason: name);
        if (kernel.detail != null) {
          expect(_canon(amino.detail), _canon(kernel.detail), reason: name);
        } else {
          expect(amino.detail, isNull, reason: name);
        }

        // Every address the message names, for a transaction of one message
        // (the kernel lists them across the whole transaction).
        if ((decoded['messages'] as List).length == 1) {
          expect(_addressesIn(value), (decoded['addresses'] as List).cast<String>().toSet(), reason: name);
        }
      }
      expect(types.length, 30);
    }, skip: cases.isEmpty ? 'no zunia-core' : kernelSkip);

    test(
      'the kernel hands the new detail kinds through to the prompt',
      () {
        final seen = <String>{};
        for (final c in cases) {
          final raw = base64.decode(c['tx'] as String);
          final signBytes = DirectSignDoc.fromWire({
            'bodyBytes': base64.encode(_field(raw, 1)),
            'authInfoBytes': base64.encode(_field(raw, 2)),
            'chainId': c['chainId'],
            'accountNumber': '1',
          }).signBytes;
          final message = adaptKernelPayload(
            WalletKernel.instance.decodeDirect(signBytes),
          ).messages[c['msgIndex'] as int];
          final kind = message.detail?['kind'];
          if (kind != null) seen.add('$kind');
          final json = directPreviewJson(
            SignReview(
              chainId: c['chainId'] as String,
              messages: [message],
              fees: const [],
              warnings: const [],
              requiresBlindSigning: false,
            ),
          );
          if (kind == 'multi-send') {
            for (final side in ['inputs', 'outputs']) {
              for (final entry in message.detail![side] as List) {
                expect(json, contains((entry as Map)['address'] as String));
              }
            }
          }
          if (kind == 'instantiate-contract') {
            expect(json, contains('"label": ${jsonEncode(message.detail!['label'])}'));
          }
          if (kind == 'migrate-contract') expect(json, contains('"codeId"'));
        }
        expect(seen, {'multi-send', 'instantiate-contract', 'migrate-contract'});
      },
      skip: cases.isEmpty ? 'no zunia-core' : kernelSkip,
    );
  });

  group('types without a mainnet sample', () {
    test('say what the kernel says', () {
      expect(
        _said('osmosis/gamm/join-swap-share-amount-out', {
          'sender': _sender,
          'pool_id': '3600',
          'token_in_denom': 'uosmo',
          'share_out_amount': '5000000',
          'token_in_max_amount': '100000',
        }),
        'Join pool 3600 with uosmo alone, paying at most 100000 uosmo for exactly 5000000 gamm/pool/3600 shares',
      );
      expect(
        _said('osmosis/gamm/exit-swap-extern-amount-out', {
          'sender': _sender,
          'pool_id': '1',
          'token_out': {'denom': 'uosmo', 'amount': '1000'},
          'share_in_max_amount': '77',
        }),
        'Exit pool 1 receiving exactly 1000 uosmo alone, burning at most 77 gamm/pool/1 shares',
      );
      expect(
        _said('osmosis/lockup/begin-unlock-tokens', {'owner': _sender}),
        'Begin unlocking every lock owned by $_sender',
      );
      expect(
        _said('osmosis/superfluid-delegate', {'sender': _sender, 'lock_id': '42', 'val_addr': _validator}),
        'Superfluid-delegate lock 42 to validator $_validator',
      );
      expect(
        _said('osmosis/lock-and-superfluid-delegate', {
          'sender': _sender,
          'coins': [
            {'denom': 'gamm/pool/1', 'amount': '5'},
          ],
          'val_addr': _validator,
        }),
        'Lock 5 gamm/pool/1 and superfluid-delegate it to validator $_validator',
      );
      expect(
        _said('osmosis/full-range-and-sf-delegate', {
          'sender': _sender,
          'coins': [
            {'denom': 'uosmo', 'amount': '10'},
          ],
          'val_addr': _validator,
          'pool_id': '1',
        }),
        'Create a full-range concentrated liquidity position in pool 1 with 10 uosmo and superfluid-delegate it to validator $_validator',
      );
      expect(
        _said('osmosis/add-to-cl-superfluid-position', {
          'position_id': '9',
          'sender': _sender,
          'token_desired0': {'denom': 'uosmo', 'amount': '10'},
          'token_desired1': {'denom': 'uatom', 'amount': '0'},
        }),
        'Add 10 uosmo and 0 uatom to superfluid concentrated liquidity position 9',
      );
      final clear = _describe('wasm/MsgClearAdmin', {'sender': _sender, 'contract': _contract})!;
      expect(clear.summary, 'Clear the admin of contract $_contract, so nobody can migrate it again');
      expect(clear.recipient, isNull);
      expect(clear.unknown, isFalse);
    });

    test('a weighted vote reads both gov versions, with 18-place weights', () {
      for (final type in ['cosmos-sdk/MsgVoteWeighted', 'cosmos-sdk/v1/MsgVoteWeighted']) {
        final vote = {
          'proposal_id': '7',
          'voter': _sender,
          'options': [
            {'option': type.contains('v1') ? 'VOTE_OPTION_YES' : 1, 'weight': '0.700000000000000000'},
            {'option': type.contains('v1') ? 'VOTE_OPTION_NO_WITH_VETO' : 4, 'weight': '0.3'},
          ],
        };
        expect(
          _said(type, vote),
          'Vote Yes 0.700000000000000000, No with veto 0.300000000000000000 on proposal 7',
        );
        // Weights that do not make 1, a weight of 0, an option twice, an
        // option outside the enum, no options: unknown.
        _unknown(
          type,
          _with(vote, {
            'options': [
              {'option': 1, 'weight': '0.600000000000000000'},
            ],
          }),
          'sum',
        );
        _unknown(
          type,
          _with(vote, {
            'options': [
              {'option': 1, 'weight': '1.000000000000000000'},
              {'option': 2, 'weight': '0.000000000000000000'},
            ],
          }),
          'zero weight',
        );
        _unknown(
          type,
          _with(vote, {
            'options': [
              {'option': 1, 'weight': '0.500000000000000000'},
              {'option': 1, 'weight': '0.500000000000000000'},
            ],
          }),
          'duplicate option',
        );
        _unknown(
          type,
          _with(vote, {
            'options': [
              {'option': 9, 'weight': '1.000000000000000000'},
            ],
          }),
          'enum',
        );
        _unknown(type, _with(vote, {'options': <Object>[]}), 'empty');
        _unknown(type, _with(vote, {'proposal_id': '0'}), 'proposal 0');
      }
    });

    test('a lock reads its duration in whole seconds', () {
      final lock = {
        'owner': _sender,
        'duration': '86400000000000',
        'coins': [
          {'denom': 'gamm/pool/1', 'amount': '5'},
        ],
      };
      expect(_said('osmosis/lockup/lock-tokens', lock), 'Lock 5 gamm/pool/1 for 86400 seconds');
      _unknown('osmosis/lockup/lock-tokens', _with(lock, {'duration': '86400000000001'}), 'sub-second');
      _unknown('osmosis/lockup/lock-tokens', _with(lock, {'duration': '0'}), 'zero');
      _unknown('osmosis/lockup/lock-tokens', _with(lock, {'duration': _drop}), 'absent');
      _unknown('osmosis/lockup/lock-tokens', _with(lock, {'coins': _drop}), 'no coins');
    });

    test('both amino names of a superfluid unbond read the same', () {
      final value = {
        'sender': _sender,
        'lock_id': '3',
        'coin': {'denom': 'gamm/pool/1', 'amount': '9'},
      };
      for (final type in [
        'osmosis/superfluid-undelegate-unbond-lock',
        'osmosis/sf-undelegate-and-unbond-lock',
      ]) {
        expect(_said(type, value), 'Superfluid-undelegate lock 3 and unbond 9 gamm/pool/1 from it');
        _unknown(type, _with(value, {'lock_id': '0'}));
      }
      expect(describedAminoTypes, contains('osmosis/sf-undelegate-and-unbond-lock'));
    });
  });

  group('amino leaves out what is empty', () {
    test(
      'an exit with no minimum, a begin-unlock of a whole lock, an instantiate with no admin or funds',
      () {
        expect(
          _said('osmosis/gamm/exit-pool', {'sender': _sender, 'pool_id': '2', 'share_in_amount': '10'}),
          'Exit pool 2 by burning 10 gamm/pool/2 shares, with no minimum amount out',
        );
        expect(
          _said('osmosis/gamm/exit-pool', {
            'sender': _sender,
            'pool_id': '2',
            'share_in_amount': '10',
            'token_out_mins': [
              {'denom': 'uosmo', 'amount': '4'},
              {'denom': 'uatom', 'amount': '5'},
            ],
          }),
          'Exit pool 2 by burning 10 gamm/pool/2 shares, receiving at least 4 uosmo, 5 uatom',
        );
        expect(
          _said('osmosis/lockup/begin-unlock-period-lock', {'owner': _sender, 'ID': '8'}),
          'Begin unlocking all the tokens of lock 8',
        );
        final instantiate = _describe('wasm/MsgInstantiateContract', {
          'sender': _sender,
          'code_id': '12',
          'label': 'pair',
          'msg': {'x': 1},
        })!;
        expect(instantiate.summary, 'Instantiate code 12 as a new contract with no admin');
        expect(instantiate.recipient, isNull);
        expect(instantiate.detail, {
          'kind': 'instantiate-contract',
          'codeId': '12',
          'label': 'pair',
          'admin': null,
          'msg': {'x': 1},
          'funds': <Object>[],
        });
      },
    );

    test('an instantiate names its admin and funds, and its salt in hex', () {
      final value = {
        'sender': _sender,
        'admin': _other,
        'code_id': '12',
        'label': 'pair',
        'msg': {'x': 1},
        'funds': [
          {'denom': 'uatom', 'amount': '7'},
        ],
        'salt': base64.encode([1, 2, 255]),
        'fix_msg': true,
      };
      final two = _describe('wasm/MsgInstantiateContract2', value)!;
      expect(
        two.summary,
        'Instantiate code 12 as a new contract at a salt-derived address with admin $_other, sending 7 uatom',
      );
      expect(two.recipient, _other);
      expect(two.detail!['salt'], '0102ff');
      expect(two.detail!['fixMsg'], isTrue);
      _unknown('wasm/MsgInstantiateContract2', _with(value, {'salt': _drop}), 'no salt');
      _unknown('wasm/MsgInstantiateContract2', _with(value, {'salt': ''}), 'empty salt');
      _unknown(
        'wasm/MsgInstantiateContract2',
        _with(value, {'salt': base64.encode(List.filled(65, 1))}),
        'long salt',
      );
      final one = _describe('wasm/MsgInstantiateContract', value)!;
      expect(one.summary, 'Instantiate code 12 as a new contract with admin $_other, sending 7 uatom');
      expect(one.detail!.containsKey('salt'), isFalse);
    });
  });

  group('unknown on the kernel\'s conditions', () {
    final create = {
      'pool_id': '3600',
      'sender': _sender,
      'lower_tick': '-100',
      'upper_tick': '200',
      'tokens_provided': [
        {'denom': 'uosmo', 'amount': '5'},
        {'denom': 'uatom', 'amount': '6'},
      ],
      'token_min_amount0': '1',
      'token_min_amount1': '0',
    };

    test('a concentrated liquidity position', () {
      expect(
        _said('osmosis/cl-create-position', create),
        'Create a concentrated liquidity position in pool 3600 between ticks -100 and 200 with 5 uosmo, 6 uatom, '
        "accepting at least 1 of the pool's token0 and 0 of its token1",
      );
      _unknown('osmosis/cl-create-position', _with(create, {'pool_id': '0'}), 'pool 0');
      _unknown('osmosis/cl-create-position', _with(create, {'lower_tick': '200'}), 'equal ticks');
      _unknown('osmosis/cl-create-position', _with(create, {'lower_tick': '300'}), 'descending ticks');
      _unknown('osmosis/cl-create-position', _with(create, {'lower_tick': -100}), 'tick not a string');
      _unknown('osmosis/cl-create-position', _with(create, {'tokens_provided': <Object>[]}), 'no coins');
      _unknown('osmosis/cl-create-position', _with(create, {'tokens_provided': _drop}), 'absent coins');
      _unknown(
        'osmosis/cl-create-position',
        _with(create, {
          'tokens_provided': [
            {'denom': 'uosmo', 'amount': '5'},
            {'denom': 'uosmo', 'amount': '6'},
          ],
        }),
        'duplicate denom',
      );
      _unknown(
        'osmosis/cl-create-position',
        _with(create, {
          'tokens_provided': [
            {'denom': 'u', 'amount': '5'},
          ],
        }),
        'invalid denom',
      );
      _unknown(
        'osmosis/cl-create-position',
        _with(create, {
          'tokens_provided': [
            {'denom': 'uosmo', 'amount': '0'},
          ],
        }),
        'zero coin',
      );
      _unknown('osmosis/cl-create-position', _with(create, {'token_min_amount0': _drop}), 'absent minimum');
      _unknown('osmosis/cl-create-position', _with(create, {'sender': 'osmo$_sender'}), 'bad sender');
    });

    test('positions, liquidity and a transfer', () {
      expect(
        _said('osmosis/cl-withdraw-position', {
          'position_id': '5',
          'sender': _sender,
          'liquidity_amount': '1234.5',
        }),
        'Withdraw 1234.500000000000000000 liquidity units (the message names no denom) from concentrated liquidity position 5',
      );
      _unknown('osmosis/cl-withdraw-position', {
        'position_id': '5',
        'sender': _sender,
        'liquidity_amount': '0.000000000000000000',
      });
      _unknown('osmosis/cl-withdraw-position', {
        'position_id': '0',
        'sender': _sender,
        'liquidity_amount': '1',
      });
      expect(
        _said('osmosis/cl-col-sp-rewards', {
          'position_ids': ['5'],
          'sender': _sender,
        }),
        'Collect the spread rewards of concentrated liquidity position 5',
      );
      expect(
        _said('osmosis/cl-collect-incentives', {
          'position_ids': ['5', '6', '7'],
          'sender': _sender,
        }),
        'Collect the incentives of concentrated liquidity positions 5, 6, 7',
      );
      for (final ids in [
        <Object>[],
        ['0'],
        ['5', '5'],
        [5],
      ]) {
        _unknown('osmosis/cl-collect-incentives', {'position_ids': ids, 'sender': _sender}, '$ids');
      }
      _unknown('osmosis/cl-collect-incentives', {'sender': _sender}, 'absent ids');
      final transfer = _describe('osmosis/cl-transfer-positions', {
        'position_ids': ['5', '6'],
        'sender': _sender,
        'new_owner': _other,
      })!;
      expect(transfer.summary, 'Transfer concentrated liquidity positions 5, 6 to $_other');
      expect(transfer.recipient, _other);
      // An address of another chain is not an owner on this one.
      _unknown('osmosis/cl-transfer-positions', {
        'position_ids': ['5'],
        'sender': _sender,
        'new_owner': 'osmo1jrkmdcwgq94uaamx6zax2luewlhf7u4k8k4yzj',
      });
      expect(
        _said('osmosis/cl-add-to-position', {
          'position_id': '9',
          'sender': _sender,
          'amount0': '5',
          'amount1': '0',
          'token_min_amount0': '1',
          'token_min_amount1': '0',
        }),
        "Add 5 of the pool's token0 and 0 of its token1 to concentrated liquidity position 9, using at least 1 and 0 of them; the message names no denoms",
      );
      _unknown('osmosis/cl-add-to-position', {
        'position_id': '9',
        'sender': _sender,
        'amount0': '0',
        'amount1': '0',
        'token_min_amount0': '0',
        'token_min_amount1': '0',
      });
    });

    test('classic pools', () {
      final join = {
        'sender': _sender,
        'pool_id': '3',
        'share_out_amount': '100',
        'token_in_maxs': [
          {'denom': 'uosmo', 'amount': '5'},
        ],
      };
      expect(
        _said('osmosis/gamm/join-pool', join),
        'Join pool 3 for exactly 100 gamm/pool/3 shares, paying at most 5 uosmo',
      );
      _unknown('osmosis/gamm/join-pool', _with(join, {'pool_id': '0'}));
      _unknown('osmosis/gamm/join-pool', _with(join, {'share_out_amount': '0'}));
      _unknown('osmosis/gamm/join-pool', _with(join, {'token_in_maxs': _drop}));
      _unknown('osmosis/gamm/join-swap-extern-amount-in', {
        'sender': _sender,
        'pool_id': '3',
        'token_in': {'denom': 'uosmo', 'amount': '0'},
        'share_out_min_amount': '1',
      });
      _unknown('osmosis/gamm/exit-swap-share-amount-in', {
        'sender': _sender,
        'pool_id': '3',
        'token_out_denom': 'u',
        'share_in_amount': '1',
        'token_out_min_amount': '1',
      });
      // The gamm swaps say what the poolmanager's say.
      final swap = {
        'sender': _sender,
        'routes': [
          {'pool_id': '1', 'token_out_denom': 'uosmo'},
          {'pool_id': '3586', 'token_out_denom': 'uusdc'},
        ],
        'token_in': {'denom': 'uatom', 'amount': '100'},
        'token_out_min_amount': '90',
      };
      expect(
        _said('osmosis/gamm/swap-exact-amount-in', swap),
        'Swap 100 uatom for at least 90 uusdc through pools 1 → 3586',
      );
      _unknown('osmosis/gamm/swap-exact-amount-in', _with(swap, {'token_out_min_amount': '0'}));
      expect(
        _said('osmosis/gamm/swap-exact-amount-out', {
          'sender': _sender,
          'routes': [
            {'pool_id': '1', 'token_in_denom': 'uatom'},
          ],
          'token_in_max_amount': '100',
          'token_out': {'denom': 'uosmo', 'amount': '90'},
        }),
        'Swap at most 100 uatom for exactly 90 uosmo through pool 1',
      );
    });

    test('lockups and superfluid staking', () {
      _unknown('osmosis/lockup/begin-unlock-period-lock', {'owner': _sender, 'ID': '0'});
      _unknown('osmosis/lockup/begin-unlock-period-lock', {'owner': _sender});
      expect(
        _said('osmosis/lockup/begin-unlock-period-lock', {
          'owner': _sender,
          'ID': '8',
          'coins': [
            {'denom': 'gamm/pool/1', 'amount': '3'},
          ],
        }),
        'Begin unlocking 3 gamm/pool/1 from lock 8',
      );
      _unknown('osmosis/superfluid-delegate', {'sender': _sender, 'lock_id': '0', 'val_addr': _validator});
      // A validator is a 20-byte address, not a contract's.
      _unknown('osmosis/superfluid-delegate', {'sender': _sender, 'lock_id': '1', 'val_addr': _contract});
      _unknown('osmosis/superfluid-delegate', {'sender': _sender, 'lock_id': '1'});
      _unknown('osmosis/superfluid-undelegate', {'sender': _sender, 'lock_id': '0'});
      _unknown('osmosis/superfluid-unbond-lock', {'sender': _sender});
      expect(
        _said('osmosis/superfluid-unbond-lock', {'sender': _sender, 'lock_id': '4'}),
        'Superfluid-unbond lock 4',
      );
      expect(
        _said('osmosis/superfluid-undelegate', {'sender': _sender, 'lock_id': '4'}),
        'Superfluid-undelegate lock 4',
      );
      _unknown('osmosis/full-range-and-sf-delegate', {
        'sender': _sender,
        'coins': [
          {'denom': 'uosmo', 'amount': '10'},
        ],
        'val_addr': _validator,
        'pool_id': '0',
      });
      _unknown('osmosis/add-to-cl-superfluid-position', {
        'position_id': '9',
        'sender': _sender,
        'token_desired0': {'denom': 'uosmo', 'amount': '0'},
        'token_desired1': {'denom': 'uatom', 'amount': '0'},
      });
      _unknown('osmosis/add-to-cl-superfluid-position', {
        'position_id': '9',
        'sender': _sender,
        'token_desired0': {'denom': 'uosmo', 'amount': '1'},
      });
    });

    test('the Cosmos SDK messages', () {
      expect(
        _said('cosmos-sdk/MsgCancelUnbondingDelegation', {
          'delegator_address': _sender,
          'validator_address': _validator,
          'amount': {'denom': 'uatom', 'amount': '5'},
          'creation_height': '100',
        }),
        'Cancel the unbonding of 5 uatom from $_validator, created at height 100',
      );
      for (final height in ['0', '-1', 100]) {
        _unknown('cosmos-sdk/MsgCancelUnbondingDelegation', {
          'delegator_address': _sender,
          'validator_address': _validator,
          'amount': {'denom': 'uatom', 'amount': '5'},
          'creation_height': height,
        }, 'height $height');
      }
      final withdraw = _describe('cosmos-sdk/MsgModifyWithdrawAddress', {
        'delegator_address': _sender,
        'withdraw_address': _other,
      })!;
      expect(withdraw.summary, 'Set the address that receives your staking rewards to $_other');
      expect(withdraw.recipient, _other);
      expect(
        _said('cosmos-sdk/MsgWithdrawValCommission', {'validator_address': _validator}),
        'Withdraw the commission of validator $_validator',
      );
      expect(
        _said('cosmos-sdk/MsgFundCommunityPool', {
          'depositor': _sender,
          'amount': [
            {'denom': 'uatom', 'amount': '5'},
          ],
        }),
        'Fund the community pool with 5 uatom',
      );
      _unknown('cosmos-sdk/MsgFundCommunityPool', {'depositor': _sender});
      for (final type in ['cosmos-sdk/MsgDeposit', 'cosmos-sdk/v1/MsgDeposit']) {
        expect(
          _said(type, {
            'proposal_id': '12',
            'depositor': _sender,
            'amount': [
              {'denom': 'uatom', 'amount': '5'},
            ],
          }),
          'Deposit 5 uatom on proposal 12',
        );
        _unknown(type, {
          'proposal_id': '0',
          'depositor': _sender,
          'amount': [
            {'denom': 'uatom', 'amount': '5'},
          ],
        });
      }
      expect(
        _said('cosmos-sdk/MsgRevoke', {
          'granter': _sender,
          'grantee': _other,
          'msg_type_url': '/cosmos.bank.v1beta1.MsgSend',
        }),
        'Revoke the authorization given to $_other for /cosmos.bank.v1beta1.MsgSend',
      );
      for (final url in ['cosmos.bank.v1beta1.MsgSend', '/a b', '/a\u{202e}b', '']) {
        _unknown('cosmos-sdk/MsgRevoke', {'granter': _sender, 'grantee': _other, 'msg_type_url': url}, url);
      }
      expect(
        _said('cosmos-sdk/MsgRevokeAllowance', {'granter': _sender, 'grantee': _other}),
        'Revoke the fee allowance given to $_other',
      );
    });

    test('a multi-send', () {
      final send = {
        'inputs': [
          {
            'address': _sender,
            'coins': [
              {'denom': 'uatom', 'amount': '10'},
            ],
          },
        ],
        'outputs': [
          {
            'address': _other,
            'coins': [
              {'denom': 'uatom', 'amount': '4'},
            ],
          },
          {
            'address': _sender,
            'coins': [
              {'denom': 'uatom', 'amount': '6'},
            ],
          },
        ],
      };
      final said = _describe('cosmos-sdk/MsgMultiSend', send)!;
      expect(
        said.summary,
        'Send 4 uatom to $_other; 6 uatom to $_sender in one multi-send paid by $_sender (10 uatom)',
      );
      // The one output that is not an input.
      expect(said.recipient, _other);
      expect(said.detail!['kind'], 'multi-send');
      // Two such outputs: no single recipient stands for the payment.
      final two = _describe('cosmos-sdk/MsgMultiSend', {
        'inputs': send['inputs'],
        'outputs': [
          {
            'address': _other,
            'coins': [
              {'denom': 'uatom', 'amount': '4'},
            ],
          },
          {
            'address': _contract,
            'coins': [
              {'denom': 'uatom', 'amount': '6'},
            ],
          },
        ],
      });
      expect(two!.unknown, isFalse);
      expect(two.recipient, isNull);
      expect(two.detail!['kind'], 'multi-send');
      // Not balanced, nothing in, nothing out: unknown.
      _unknown(
        'cosmos-sdk/MsgMultiSend',
        _with(send, {
          'outputs': [(send['outputs'] as List).first],
        }),
        'unbalanced',
      );
      _unknown('cosmos-sdk/MsgMultiSend', _with(send, {'inputs': _drop}), 'no input');
      _unknown('cosmos-sdk/MsgMultiSend', _with(send, {'outputs': <Object>[]}), 'no output');
      _unknown(
        'cosmos-sdk/MsgMultiSend',
        _with(send, {
          'inputs': [
            {
              'address': _sender,
              'coins': [
                {'denom': 'uosmo', 'amount': '10'},
              ],
            },
          ],
        }),
        'another denom',
      );
    });

    test('contract messages', () {
      final instantiate = {
        'sender': _sender,
        'code_id': '12',
        'label': 'pair',
        'msg': {'x': 1},
      };
      _unknown('wasm/MsgInstantiateContract', _with(instantiate, {'code_id': '0'}), 'code 0');
      _unknown('wasm/MsgInstantiateContract', _with(instantiate, {'label': _drop}), 'no label');
      _unknown('wasm/MsgInstantiateContract', _with(instantiate, {'label': ''}), 'empty label');
      _unknown('wasm/MsgInstantiateContract', _with(instantiate, {'msg': 'not json'}), 'msg not JSON');
      _unknown('wasm/MsgInstantiateContract', _with(instantiate, {'msg': _drop}), 'no msg');
      _unknown(
        'wasm/MsgInstantiateContract',
        _with(instantiate, {'admin': 'osmo1jrkmdcwgq94uaamx6zax2luewlhf7u4k8k4yzj'}),
        'foreign admin',
      );
      _unknown(
        'wasm/MsgInstantiateContract',
        _with(instantiate, {
          'funds': [
            {'denom': 'uatom', 'amount': '0'},
          ],
        }),
        'zero funds',
      );
      final migrate = {'sender': _sender, 'contract': _contract, 'code_id': '4', 'msg': <String, Object?>{}};
      final said = _describe('wasm/MsgMigrateContract', migrate)!;
      expect(said.summary, 'Migrate contract $_contract to code 4');
      expect(said.detail, {
        'kind': 'migrate-contract',
        'contract': _contract,
        'codeId': '4',
        'msg': <String, Object?>{},
      });
      _unknown('wasm/MsgMigrateContract', _with(migrate, {'code_id': '0'}));
      _unknown('wasm/MsgMigrateContract', _with(migrate, {'msg': _drop}));
      final admin = _describe('wasm/MsgUpdateAdmin', {
        'sender': _sender,
        'new_admin': _other,
        'contract': _contract,
      })!;
      expect(admin.summary, 'Make $_other the admin of contract $_contract');
      expect(admin.recipient, _other);
      _unknown('wasm/MsgUpdateAdmin', {'sender': _sender, 'new_admin': _other});
      _unknown('wasm/MsgClearAdmin', {'sender': _sender, 'contract': 'cosmos1x'});
    });
  });

  group('never described, as in the kernel', () {
    test('stay unknown in Amino too, whatever shape they come in', () {
      for (final type in [
        'cosmos-sdk/MsgGrant',
        'cosmos-sdk/MsgExec',
        'cosmos-sdk/MsgGrantAllowance',
        'wasm/MsgStoreCode',
        'cosmos-sdk/MsgSubmitProposal',
        'cosmos-sdk/v1/MsgSubmitProposal',
        'osmosis/smartaccount/add-authenticator',
        'osmosis/smartaccount/remove-authenticator',
        'osmosis/smartaccount/set-active-state',
      ]) {
        _unknown(type, {'granter': _sender, 'grantee': _other});
        expect(describedAminoTypes, isNot(contains(type)));
        final review = reviewAminoSignDoc(
          expectedChainId: 'cosmoshub-4',
          signDoc: {
            'chain_id': 'cosmoshub-4',
            'msgs': [
              {'type': type, 'value': {}},
            ],
          },
          context: const ReviewContext(),
        );
        expect(review.requiresBlindSigning, isTrue, reason: type);
        expect(review.messages.single.unknown, isTrue, reason: type);
      }
    });
  });

  group('the prompt', () {
    SignReview review(String type, Map<String, Object?> value, {Set<String> known = const {}}) =>
        reviewAminoSignDoc(
          expectedChainId: 'cosmoshub-4',
          signDoc: {
            'chain_id': 'cosmoshub-4',
            'msgs': [
              {'type': type, 'value': value},
            ],
          },
          context: ReviewContext(knownRecipients: known),
        );

    test('a new owner, withdraw address, admin or output is a first-time recipient', () {
      final cases = {
        'osmosis/cl-transfer-positions': {
          'position_ids': ['5'],
          'sender': _sender,
          'new_owner': _other,
        },
        'cosmos-sdk/MsgModifyWithdrawAddress': {'delegator_address': _sender, 'withdraw_address': _other},
        'wasm/MsgUpdateAdmin': {'sender': _sender, 'new_admin': _other, 'contract': _contract},
        'wasm/MsgInstantiateContract': {
          'sender': _sender,
          'admin': _other,
          'code_id': '1',
          'label': 'x',
          'msg': <String, Object?>{},
        },
        'cosmos-sdk/MsgMultiSend': {
          'inputs': [
            {
              'address': _sender,
              'coins': [
                {'denom': 'uatom', 'amount': '1'},
              ],
            },
          ],
          'outputs': [
            {
              'address': _other,
              'coins': [
                {'denom': 'uatom', 'amount': '1'},
              ],
            },
          ],
        },
      };
      for (final e in cases.entries) {
        expect(review(e.key, e.value).warnings, contains('First-time recipient: $_other'), reason: e.key);
        expect(review(e.key, e.value, known: {_other}).warnings, isEmpty, reason: e.key);
      }
    });

    test('a demoted message needs blind signing', () {
      final r = review('osmosis/cl-collect-incentives', {
        'position_ids': ['0'],
        'sender': _sender,
      });
      expect(r.requiresBlindSigning, isTrue);
      expect(
        blindSigningRefusal(r).message,
        'Blind signing disabled for unknown messages: osmosis/cl-collect-incentives',
      );
    });

    test('the new details reach the raw transaction in Amino mode', () {
      final r = review('wasm/MsgMigrateContract', {
        'sender': _sender,
        'contract': _contract,
        'code_id': '4',
        'msg': {'migrate': {}},
      });
      final json = previewJson([for (final m in r.messages) m.toJson()]);
      expect(json, contains('"kind": "migrate-contract"'));
      expect(json, contains('"codeId": "4"'));
    });
  });
}
