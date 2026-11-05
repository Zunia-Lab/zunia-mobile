/// The one-signature swap's own rules: the entry point Zunia signs to, the
/// memo it writes (byte for byte), and the memos it refuses to read.
///
/// The shape was simulated against osmosis-1 on 2026-11-06: SAF to allUSDC
/// through pool 3600 paid on Osmosis, and allUSDC to SAF sent back to
/// Safrochain over channel-110497.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/swap/one_signature.dart';
import 'package:zunia_mobile/swap/pool_swap.dart';

const saf = 'ibc/DBAA4846F611A7603EFCE6F9F46F4F561D48B1F492A576022F000614A17089CE';
const allUsdc =
    'factory/osmo147h5x9pcj7lm0cttlaefx6sqq5vdfnmwfcqxkmjd7exqm9gc7grqhr75m0/alloyed/allUSDC';
const holder = 'osmo1emc0hs8lp84f2dmsje9xth8r4hw655t9u422ns';

void main() {
  group('the entry point', () {
    test('is the Skip Go entry point only with its code id, label and no admin', () {
      Map<String, Object?> info({
        Object codeId = '1241',
        String label = 'Skip Swap Entry Point',
        String admin = '',
      }) => {
        'address': kSkipEntryPoint,
        'contract_info': {'code_id': codeId, 'label': label, 'admin': admin},
      };
      expect(readEntryPointInfo(info()).ready, isTrue);
      expect(readEntryPointInfo(info(codeId: '1242')).ready, isFalse);
      expect(readEntryPointInfo(info(label: 'Something else')).ready, isFalse);
      // An admin could swap the code under the address.
      final admined = readEntryPointInfo(info(admin: holder));
      expect(admined.ready, isFalse);
      expect(admined.reason, entryPointMismatch);
      expect(readEntryPointInfo(null).ready, isFalse);
    });
  });

  group('the memo', () {
    final now = DateTime.utc(2026, 11, 6, 12);
    final timeout = entryPointTimeoutNanos(now, entryPointSwapWindowMinutes);

    test('100 SAF to allUSDC paid on Osmosis, byte for byte', () {
      expect(timeout, BigInt.parse('1793967300000000000'));
      final memo = buildEntryPointMemo(
        inputDenom: saf,
        route: const PoolRoute([PoolHop('3600', allUsdc)], '99500000'),
        outputDenom: allUsdc,
        minOut: '46592',
        timeoutNanos: timeout,
        post: const EntryPointPayOnVenue(holder),
      );
      expect(
        memo,
        '{"wasm":{"contract":"$kSkipEntryPoint","msg":{"swap_and_action":{'
        '"user_swap":{"swap_exact_asset_in":{"swap_venue_name":"osmosis-poolmanager",'
        '"operations":[{"pool":"3600","denom_in":"$saf","denom_out":"$allUsdc"}]}},'
        '"min_asset":{"native":{"denom":"$allUsdc","amount":"46592"}},'
        '"timeout_timestamp":1793967300000000000,'
        '"post_swap_action":{"transfer":{"to_address":"$holder"}},'
        '"affiliates":[]}}}}',
      );
      final facts = readEntryPointMemo(memo)!;
      expect(facts.timeoutNanos, timeout);
      expect(facts.post, const EntryPointPayOnVenue(holder));
    });

    test('a delivery off Osmosis sends on over the channel, with the recovery address', () {
      final memo = buildEntryPointMemo(
        inputDenom: allUsdc,
        route: const PoolRoute([PoolHop('3600', saf)], '100000'),
        outputDenom: saf,
        minOut: '208000000',
        timeoutNanos: timeout,
        post: const EntryPointDeliver(
          sourceChannel: 'channel-110497',
          receiver: 'addr_safro1qyqszqgpqyqszqgpqyqszqgpqyqszqgpwdhzlz',
          recoverAddress: holder,
        ),
      );
      final call =
          ((jsonDecode(memo) as Map)['wasm'] as Map)['msg']['swap_and_action']
              as Map;
      expect(call['post_swap_action'], {
        'ibc_transfer': {
          'ibc_info': {
            'source_channel': 'channel-110497',
            'receiver': 'addr_safro1qyqszqgpqyqszqgpqyqszqgpqyqszqgpwdhzlz',
            'memo': '',
            'recover_address': holder,
          },
        },
      });
      expect(readEntryPointMemo(memo)!.post, isA<EntryPointDeliver>());
    });

    test('each pool takes what the previous one paid', () {
      const usdcN =
          'ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4';
      expect(
        entryPointOperations(
          saf,
          const PoolRoute([
            PoolHop('3600', allUsdc),
            PoolHop('1212', usdcN),
          ], '1000'),
        ),
        const [
          EntryPointOperation('3600', saf, allUsdc),
          EntryPointOperation('1212', allUsdc, usdcN),
        ],
      );
    });

    test('reads back only the exact shape it writes', () {
      final memo = buildEntryPointMemo(
        inputDenom: saf,
        route: const PoolRoute([PoolHop('3600', allUsdc)], '99500000'),
        outputDenom: allUsdc,
        minOut: '46592',
        timeoutNanos: timeout,
        post: const EntryPointPayOnVenue(holder),
      );
      // The contract refuses a quoted u64, so Zunia never signs one.
      expect(
        readEntryPointMemo(
          memo.replaceFirst(
            '1793967300000000000',
            '"1793967300000000000"',
          ),
        ),
        isNull,
      );
      // An affiliate takes a cut nobody reviewed.
      expect(
        readEntryPointMemo(
          memo.replaceFirst(
            '"affiliates":[]',
            '"affiliates":[{"basis_points_fee":"50","address":"$holder"}]',
          ),
        ),
        isNull,
      );
      // An unknown key is a part of the memo nobody accounted for.
      expect(
        readEntryPointMemo(
          memo.replaceFirst('"affiliates":[]', '"affiliates":[],"extra":1'),
        ),
        isNull,
      );
      expect(readEntryPointMemo('not json'), isNull);
    });

    test('refuses to write a memo it could not read back', () {
      expect(
        () => buildEntryPointMemo(
          inputDenom: saf,
          route: const PoolRoute([PoolHop('3600', allUsdc)], '1'),
          outputDenom: saf,
          minOut: '1',
          timeoutNanos: timeout,
          post: const EntryPointPayOnVenue(holder),
        ),
        throwsArgumentError,
      );
      expect(
        () => buildEntryPointMemo(
          inputDenom: saf,
          route: const PoolRoute([PoolHop('3600', allUsdc)], '1'),
          outputDenom: allUsdc,
          minOut: '0',
          timeoutNanos: timeout,
          post: const EntryPointPayOnVenue(holder),
        ),
        throwsArgumentError,
      );
    });
  });
}
