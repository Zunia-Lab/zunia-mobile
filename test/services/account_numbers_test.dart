/// Every account kind the chains in the catalog answer with, and where its
/// account number and sequence sit. A vesting account read as 0/0 had every
/// transaction it signed refused: half of Safrochain's accounts are vesting
/// accounts.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/services/broadcast_service.dart';

Map<String, dynamic> base({String number = '3684', String sequence = '12'}) => {
      'address': 'addr_safro1qq98njda3rnf3xtzpzaxd38x3hfpaaa465kve2',
      'pub_key': null,
      'account_number': number,
      'sequence': sequence,
    };

void main() {
  test('a plain BaseAccount', () {
    final body = {
      'account': {'@type': '/cosmos.auth.v1beta1.BaseAccount', ...base()},
    };
    expect(parseAccountNumbers(body), (accountNumber: '3684', sequence: '12'));
  });

  test('a continuous vesting account, as Safrochain answers it', () {
    final body = {
      'account': {
        '@type': '/cosmos.vesting.v1beta1.ContinuousVestingAccount',
        'base_vesting_account': {
          'base_account': base(),
          'original_vesting': [
            {'denom': 'usaf', 'amount': '1000000'},
          ],
          'delegated_free': [],
          'delegated_vesting': [],
          'end_time': '1793000000',
        },
        'start_time': '1760000000',
      },
    };
    expect(parseAccountNumbers(body), (accountNumber: '3684', sequence: '12'));
  });

  test('periodic, delayed and permanent-locked vesting accounts', () {
    for (final type in [
      '/cosmos.vesting.v1beta1.PeriodicVestingAccount',
      '/cosmos.vesting.v1beta1.DelayedVestingAccount',
      '/cosmos.vesting.v1beta1.PermanentLockedAccount',
    ]) {
      final body = {
        'account': {
          '@type': type,
          'base_vesting_account': {'base_account': base(number: '7', sequence: '3')},
          'vesting_periods': [],
        },
      };
      expect(parseAccountNumbers(body), (accountNumber: '7', sequence: '3'), reason: type);
    }
  });

  test('an Evmos clawback vesting account', () {
    final body = {
      'account': {
        '@type': '/evmos.vesting.v2.ClawbackVestingAccount',
        'base_vesting_account': {'base_account': base(number: '91', sequence: '0')},
        'funder_address': 'evmos1funder',
      },
    };
    expect(parseAccountNumbers(body), (accountNumber: '91', sequence: '0'));
  });

  test('Injective and Ethermint EthAccounts nest base_account', () {
    for (final type in [
      '/injective.types.v1beta1.EthAccount',
      '/ethermint.types.v1.EthAccount',
    ]) {
      final body = {
        'account': {
          '@type': type,
          'base_account': base(number: '5550', sequence: '41'),
          'code_hash': 'xdJGAYb3IzySfn2y3McDwOUAtlPKgic7e/rYBF2FpHA=',
        },
      };
      expect(parseAccountNumbers(body), (accountNumber: '5550', sequence: '41'), reason: type);
    }
  });

  test('a module account', () {
    final body = {
      'account': {
        '@type': '/cosmos.auth.v1beta1.ModuleAccount',
        'base_account': base(number: '2', sequence: '0'),
        'name': 'distribution',
        'permissions': [],
      },
    };
    expect(parseAccountNumbers(body), (accountNumber: '2', sequence: '0'));
  });

  test('numbers sent as JSON numbers', () {
    final body = {
      'account': {'@type': '/cosmos.auth.v1beta1.BaseAccount', 'account_number': 18, 'sequence': 4},
    };
    expect(parseAccountNumbers(body), (accountNumber: '18', sequence: '4'));
  });

  test('a new account has no numbers yet', () {
    expect(parseAccountNumbers({'account': null}), (accountNumber: '0', sequence: '0'));
  });

  test('an answer without numbers is refused, not guessed', () {
    expect(
      () => parseAccountNumbers({
        'account': {'@type': '/some.Account', 'address': 'x'},
      }),
      throwsA(isA<BroadcastException>()),
    );
    expect(
      () => parseAccountNumbers({
        'account': {'@type': '/cosmos.auth.v1beta1.BaseAccount', 'account_number': 'n/a', 'sequence': '1'},
      }),
      throwsA(isA<BroadcastException>()),
    );
  });
}
