/// Ported from `zunia-sdk/packages/interchain/src/memo.test.ts`.
///
/// The byte-for-byte assertions are the point: these memos are read by
/// packet-forward-middleware and ibc-hooks, and a diff against
/// INTERCHAIN-SPEC.md should be empty. Where a test name matches the TS one,
/// the assertion is the same assertion.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/services/interchain/memo.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

const xcsContract = 'osmo1xcscontract';

Matcher throwsMemoError(String pattern) => throwsA(
      isA<InterchainError>()
          .having((e) => e.code, 'code', InterchainErrorCode.invalidMemo)
          .having((e) => e.message, 'message', matches(pattern)),
    );

void main() {
  group('buildForwardMemo', () {
    test('one-hop forward memo matches the PFM shape byte for byte', () {
      expect(
        buildForwardMemo(
            [const ForwardHop(channelId: 'channel-42')], 'osmo1receiver'),
        '{"forward":{"receiver":"osmo1receiver","port":"transfer",'
        '"channel":"channel-42","timeout":"10m","retries":2}}',
      );
    });

    test('two-hop forward memo reproduces the middleware README example', () {
      // Lifted from INTERCHAIN-SPEC.md section 1, minified. Key order included:
      // a diff against upstream should be empty.
      expect(
        buildForwardMemo(
          [
            const ForwardHop(channelId: 'channel-123'),
            const ForwardHop(channelId: 'channel-234'),
          ],
          'chain-d-bech32-address',
        ),
        '{"forward":{"receiver":"pfm","port":"transfer","channel":"channel-123",'
        '"timeout":"10m","retries":2,"next":{"forward":{"receiver":'
        '"chain-d-bech32-address","port":"transfer","channel":"channel-234",'
        '"timeout":"10m","retries":2}}}}',
      );
    });

    test('three-hop forward memo nests three levels and names the receiver once',
        () {
      final memo = buildForwardMemo(
        [
          const ForwardHop(channelId: 'channel-0'),
          const ForwardHop(channelId: 'channel-1'),
          const ForwardHop(channelId: 'channel-2'),
        ],
        'juno1abc',
      );
      expect(
        memo,
        '{"forward":{"receiver":"pfm","port":"transfer","channel":"channel-0",'
        '"timeout":"10m","retries":2,"next":{"forward":{"receiver":"pfm",'
        '"port":"transfer","channel":"channel-1","timeout":"10m","retries":2,'
        '"next":{"forward":{"receiver":"juno1abc","port":"transfer",'
        '"channel":"channel-2","timeout":"10m","retries":2}}}}}}',
      );
      // The real address appears exactly once, on the last hop only.
      expect('juno1abc'.allMatches(memo).length, 1);
      expect('"receiver":"pfm"'.allMatches(memo).length, 2);
    });

    test('forward memo emits the nested-object form, never the escaped string',
        () {
      final memo = buildForwardMemo(
        [
          const ForwardHop(channelId: 'channel-0'),
          const ForwardHop(channelId: 'channel-1'),
        ],
        'juno1abc',
      );
      expect(memo.contains(r'\'), isFalse, reason: memo);
      expect(memo.contains('"next":"'), isFalse, reason: memo);
    });

    test('forward timeout and retries are overridable memo-wide and per hop',
        () {
      expect(
        buildForwardMemo(
          [const ForwardHop(channelId: 'channel-7')],
          'juno1abc',
          timeout: '1h30m',
          retries: 0,
        ),
        '{"forward":{"receiver":"juno1abc","port":"transfer",'
        '"channel":"channel-7","timeout":"1h30m","retries":0}}',
      );
      expect(
        buildForwardMemo(
          [
            const ForwardHop(channelId: 'channel-7', timeout: '30s', retries: 5),
            const ForwardHop(channelId: 'channel-8', port: 'transfer-v2'),
          ],
          'juno1abc',
          timeout: '2m',
          retries: 1,
        ),
        '{"forward":{"receiver":"pfm","port":"transfer","channel":"channel-7",'
        '"timeout":"30s","retries":5,"next":{"forward":{"receiver":"juno1abc",'
        '"port":"transfer-v2","channel":"channel-8","timeout":"2m",'
        '"retries":1}}}}',
      );
    });

    test('forward memo can carry a trailing memo for the destination chain',
        () {
      expect(
        buildForwardMemo(
          [const ForwardHop(channelId: 'channel-1')],
          'osmo1contract',
          next: buildWasmHookMemoJson(
              'osmo1contract', {'do_thing': <String, Object?>{}}),
        ),
        '{"forward":{"receiver":"osmo1contract","port":"transfer",'
        '"channel":"channel-1","timeout":"10m","retries":2,"next":{"wasm":'
        '{"contract":"osmo1contract","msg":{"do_thing":{}}}}}}',
      );
    });

    test('forward memo rejects an empty or oversized hop list', () {
      expect(() => buildForwardMemo(const [], 'juno1abc'),
          throwsMemoError('at least one hop'));
      final many = [
        for (var i = 0; i < 9; i++) ForwardHop(channelId: 'channel-$i'),
      ];
      expect(() => buildForwardMemo(many, 'juno1abc'),
          throwsMemoError('more than 8 hops'));
      // The ceiling is configurable, so the same list passes when raised.
      expect(buildForwardMemo(many, 'juno1abc', maxHops: 9), isNotEmpty);
    });

    test('forward memo refuses to make the sentinel the final receiver', () {
      expect(
        () => buildForwardMemo([const ForwardHop(channelId: 'channel-1')], 'pfm'),
        throwsMemoError('intermediate sentinel'),
      );
    });

    test('forward memo rejects malformed receivers', () {
      for (final bad in ['', ' juno1abc', 'juno1abc\n', 'juno 1abc']) {
        expect(
          () => buildForwardMemo(
              [const ForwardHop(channelId: 'channel-1')], bad),
          throwsA(isA<InterchainError>()),
          reason: 'receiver ${jsonEncode(bad)} must be rejected',
        );
      }
    });

    test('forward memo rejects malformed channel and port identifiers', () {
      expect(
        () => buildForwardMemo(
            [const ForwardHop(channelId: 'channel 1')], 'juno1abc'),
        throwsMemoError('not a valid IBC identifier'),
      );
      expect(
        () => buildForwardMemo(
            [const ForwardHop(channelId: 'channel-1', port: 'a')], 'juno1abc'),
        throwsMemoError('not a valid IBC identifier'),
      );
    });

    test('forward memo rejects timeouts that Go would not parse', () {
      for (final bad in ['10', '10 m', '0s', '', 'forever']) {
        expect(
          () => buildForwardMemo(
              [const ForwardHop(channelId: 'channel-1')], 'juno1abc',
              timeout: bad),
          throwsMemoError('positive Go duration'),
          reason: 'timeout ${jsonEncode(bad)} must be rejected',
        );
      }
      // Go accepts concatenated components, so these must pass.
      for (final good in ['1h30m', '500ms', '2m30s']) {
        expect(
          buildForwardMemo(
              [const ForwardHop(channelId: 'channel-1')], 'juno1abc',
              timeout: good),
          contains('"timeout":"$good"'),
        );
      }
    });

    test('forward memo rejects retries outside the uint8 PFM decodes into', () {
      for (final bad in [-1, 256]) {
        expect(
          () => buildForwardMemo(
              [const ForwardHop(channelId: 'channel-1')], 'juno1abc',
              retries: bad),
          throwsMemoError('between 0 and 255'),
        );
      }
    });
  });

  group('ibc-hooks', () {
    test('wasm hook memo matches the ibc-hooks shape byte for byte', () {
      expect(
        buildWasmHookMemo('osmo1contract', {
          'swap': {'amount': '100'},
        }),
        '{"wasm":{"contract":"osmo1contract","msg":{"swap":{"amount":"100"}}}}',
      );
    });

    test('wasm hook memo produces exactly the two keys the middleware requires',
        () {
      final memo = jsonDecode(buildWasmHookMemo(
          'osmo1contract', {'a': <String, Object?>{}})) as Map<String, Object?>;
      final wasm = memo['wasm']! as Map<String, Object?>;
      expect(wasm.keys.toList(), ['contract', 'msg']);
    });

    test('wasm hook memo rejects an empty msg', () {
      expect(
        () => buildWasmHookMemo('osmo1contract', <String, Object?>{}),
        throwsMemoError('must name a variant'),
      );
    });

    test('wasm hook memo rejects a contract address that is not usable', () {
      for (final bad in ['', ' osmo1contract', 'osmo1contract\t']) {
        expect(
          () => buildWasmHookMemo(bad, {'a': <String, Object?>{}}),
          throwsA(isA<InterchainError>()),
        );
      }
    });

    test('wasm hook memo rejects values JSON would silently rewrite', () {
      expect(
        () => buildWasmHookMemo('osmo1contract', {
          'swap': {'amount': double.nan},
        }),
        throwsMemoError('no JSON encoding'),
      );
      expect(
        () => buildWasmHookMemo('osmo1contract', {
          'swap': {'amount': double.infinity},
        }),
        throwsMemoError('no JSON encoding'),
      );
      expect(
        () => buildWasmHookMemo('osmo1contract', {
          'swap': {'when': DateTime(2026)},
        }),
        throwsMemoError('no JSON encoding'),
      );
    });

    test('wasm hook memo rejects a cyclic msg with a useful message', () {
      final cycle = <String, Object?>{};
      cycle['self'] = cycle;
      expect(
        () => buildWasmHookMemo('osmo1contract', {'a': cycle}),
        throwsMemoError('reference cycle'),
      );
    });

    test('wasmHookReceiver returns the contract, and both legal receivers pass',
        () {
      expect(wasmHookReceiver('osmo1contract'), 'osmo1contract');
      expect(isWasmHookReceiverValid('', 'osmo1contract'), isTrue);
      expect(isWasmHookReceiverValid('osmo1contract', 'osmo1contract'), isTrue);
      expect(isWasmHookReceiverValid('osmo1someone', 'osmo1contract'), isFalse);
    });
  });

  group('crosschain swap', () {
    test('xcs swap memo reproduces the crosschain-swaps README example', () {
      expect(
        buildXcsSwapMemo(
          contract: '[XCS_ADDRESS]',
          outputDenom: 'token1',
          receiver: 'juno1receiver',
          slippage:
              const XcsTwapSlippage(slippagePercentage: '20', windowSeconds: 10),
          onFailedDelivery: const XcsDoNothing(),
        ),
        '{"wasm":{"contract":"[XCS_ADDRESS]","msg":{"osmosis_swap":'
        '{"output_denom":"token1","slippage":{"twap":{"slippage_percentage":'
        '"20","window_seconds":10}},"receiver":"juno1receiver",'
        '"on_failed_delivery":"do_nothing","next_memo":null}}}}',
      );
    });

    test('xcs swap memo omits window_seconds so the contract uses its default',
        () {
      // swaprouter reads `window: Option<u64>` and falls back to
      // `unwrap_or(3600)`. Emitting the key with a guessed value would silently
      // narrow the TWAP window and read a noisier price on a thin pool.
      final memo = jsonDecode(buildXcsSwapMemo(
        contract: xcsContract,
        outputDenom: 'uatom',
        receiver: 'cosmos1receiver',
        slippage: const XcsTwapSlippage(slippagePercentage: '5'),
        onFailedDelivery: const XcsDoNothing(),
      )) as Map<String, Object?>;
      final wasm = memo['wasm']! as Map<String, Object?>;
      final msg = wasm['msg']! as Map<String, Object?>;
      final swap = msg['osmosis_swap']! as Map<String, Object?>;
      expect(swap['slippage'], {
        'twap': {'slippage_percentage': '5'},
      });
    });

    test('xcs swap memo supports the min_output_amount slippage form', () {
      expect(
        buildXcsSwapMemo(
          contract: xcsContract,
          outputDenom: 'uatom',
          receiver: 'cosmos1receiver',
          slippage: const XcsMinOutputSlippage('100'),
          onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
        ),
        '{"wasm":{"contract":"osmo1xcscontract","msg":{"osmosis_swap":'
        '{"output_denom":"uatom","slippage":{"min_output_amount":"100"},'
        '"receiver":"cosmos1receiver","on_failed_delivery":'
        '{"local_recovery_addr":"osmo1recovery"},"next_memo":null}}}}',
      );
    });

    test('xcs swap memo chains a forward after the swap', () {
      expect(
        buildXcsSwapMemo(
          contract: xcsContract,
          outputDenom: 'ustars',
          receiver: 'juno1receiver',
          slippage: const XcsMinOutputSlippage('100'),
          onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
          nextMemo: buildForwardMemoJson(
              [const ForwardHop(channelId: 'channel-42')], 'stars1final'),
        ),
        '{"wasm":{"contract":"osmo1xcscontract","msg":{"osmosis_swap":'
        '{"output_denom":"ustars","slippage":{"min_output_amount":"100"},'
        '"receiver":"juno1receiver","on_failed_delivery":'
        '{"local_recovery_addr":"osmo1recovery"},"next_memo":{"forward":'
        '{"receiver":"stars1final","port":"transfer","channel":"channel-42",'
        '"timeout":"10m","retries":2}}}}}}',
      );
    });

    test('xcs swap memo always writes next_memo, spelled null when absent', () {
      final memo = buildXcsSwapMemo(
        contract: xcsContract,
        outputDenom: 'uosmo',
        receiver: 'osmo1receiver',
        slippage:
            const XcsTwapSlippage(slippagePercentage: '1', windowSeconds: 30),
        onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
      );
      expect(memo, contains('"next_memo":null'));
    });

    test('xcs swap memo rejects malformed slippage', () {
      XcsSlippage bad(String percentage, [int? window]) => XcsTwapSlippage(
            slippagePercentage: percentage,
            windowSeconds: window,
          );
      expect(
        () => buildXcsSwapMemo(
          contract: xcsContract,
          outputDenom: 'uosmo',
          receiver: 'osmo1receiver',
          slippage: bad('20%', 10),
          onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
        ),
        throwsMemoError('decimal string'),
      );
      expect(
        () => buildXcsSwapMemo(
          contract: xcsContract,
          outputDenom: 'uosmo',
          receiver: 'osmo1receiver',
          slippage: bad('101', 10),
          onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
        ),
        throwsMemoError('between 0 and 100'),
      );
      expect(
        () => buildXcsSwapMemo(
          contract: xcsContract,
          outputDenom: 'uosmo',
          receiver: 'osmo1receiver',
          slippage: bad('20', 0),
          onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
        ),
        throwsMemoError('positive integer'),
      );
      expect(
        () => buildXcsSwapMemo(
          contract: xcsContract,
          outputDenom: 'uosmo',
          receiver: 'osmo1receiver',
          slippage: const XcsMinOutputSlippage('1.5'),
          onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
        ),
        throwsMemoError('integer string'),
      );
    });

    test('xcs swap memo rejects a malformed denom or receiver', () {
      expect(
        () => buildXcsSwapMemo(
          contract: xcsContract,
          outputDenom: '',
          receiver: 'osmo1receiver',
          slippage: const XcsMinOutputSlippage('1'),
          onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
        ),
        throwsMemoError('non-empty'),
      );
      expect(
        () => buildXcsSwapMemo(
          contract: xcsContract,
          outputDenom: 'uosmo x',
          receiver: 'osmo1receiver',
          slippage: const XcsMinOutputSlippage('1'),
          onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
        ),
        throwsMemoError('whitespace'),
      );
    });
  });

  group('byte length', () {
    test('memoByteLength counts UTF-8 bytes, not UTF-16 units', () {
      expect(memoByteLength('abc'), 3);
      // Four bytes in UTF-8, two UTF-16 code units.
      expect(memoByteLength('\u{1F600}'), 4);
    });

    test('builders throw over the byte ceiling and never truncate', () {
      expect(
        () => buildWasmHookMemo(
          'osmo1contract',
          {'a': 'x' * 100},
          maxBytes: 50,
        ),
        throwsMemoError('over the 50-byte limit'),
      );
    });

    test('checkMemoBytes warns instead of failing between the thresholds', () {
      final report = checkMemoBytes('x' * 300, warnBytes: txMemoMaxBytes);
      expect(report.exceedsMax, isFalse);
      expect(report.exceedsWarn, isTrue);
      expect(report.warning, contains('advisory threshold'));
      expect(report.byteLength, 300);
    });
  });

  group('validateMemo', () {
    test('reports an absent memo as empty', () {
      final result = validateMemo('');
      expect(result.kind, MemoKind.empty);
      expect(result.summary, 'No memo.');
      expect(result.requiresPfm, isFalse);
      expect(result.requiresIbcHooks, isFalse);
    });

    test('reports non-JSON and non-object JSON as inert plain text', () {
      expect(validateMemo('hello').kind, MemoKind.plainText);
      expect(validateMemo('123456').kind, MemoKind.plainText);
      expect(validateMemo('[1,2]').kind, MemoKind.plainText);
    });

    test('reads back the memos this module builds', () {
      final oneHop = validateMemo(buildForwardMemo(
          [const ForwardHop(channelId: 'channel-42')], 'osmo1receiver'));
      expect(oneHop.kind, MemoKind.forward);
      expect(oneHop.requiresPfm, isTrue);
      expect(oneHop.requiresIbcHooks, isFalse);
      expect(oneHop.warnings, isEmpty);
      expect(oneHop.forward!.hops.single.channelId, 'channel-42');
      expect(oneHop.forward!.finalReceiver, 'osmo1receiver');
      expect(oneHop.forward!.hasNextMemo, isFalse);
      expect(
        oneHop.summary,
        'On arrival, forwards one more hop (channel-42) and pays osmo1receiver.',
      );

      final threeHop = validateMemo(buildForwardMemo(
        [
          const ForwardHop(channelId: 'channel-0'),
          const ForwardHop(channelId: 'channel-1'),
          const ForwardHop(channelId: 'channel-2'),
        ],
        'juno1abc',
      ));
      expect(threeHop.kind, MemoKind.forward);
      expect(threeHop.forward!.hops.length, 3);
      expect(
        threeHop.summary,
        'On arrival, forwards 3 more hops (channel-0, then channel-1, then '
        'channel-2) and pays juno1abc.',
      );
    });

    test('describes a plain contract call', () {
      final result = validateMemo(buildWasmHookMemo('osmo1contract', {
        'increment': {'by': 1},
      }));
      expect(result.kind, MemoKind.wasm);
      expect(result.requiresIbcHooks, isTrue);
      expect(result.requiresPfm, isFalse);
      expect(result.wasm!.contract, 'osmo1contract');
      expect(result.wasm!.msgKeys, ['increment']);
    });

    test('describes a crosschain swap and its recovery address', () {
      final result = validateMemo(
        buildXcsSwapMemo(
          contract: xcsContract,
          outputDenom: 'uatom',
          receiver: 'cosmos1receiver',
          slippage: const XcsTwapSlippage(
              slippagePercentage: '5', windowSeconds: 10),
          onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
        ),
        receiver: xcsContract,
      );
      expect(result.kind, MemoKind.xcs);
      expect(result.xcs!.outputDenom, 'uatom');
      expect(result.xcs!.receiver, 'cosmos1receiver');
      expect(result.xcs!.onFailedDelivery, isA<XcsLocalRecovery>());
      expect(result.summary, contains('swaps to uatom'));
      expect(result.summary, contains('10s average price'));
      expect(result.summary, contains('Recovery address'));
      expect(result.warnings, isEmpty);
    });

    test('reads back a swap whose TWAP window was left to the contract', () {
      // Regression against the TS twin, which requires `window_seconds` when
      // reading and omits it when writing: the signing screen would show
      // "Unrecognised memo" for the swap it is about to sign.
      final result = validateMemo(
        buildXcsSwapMemo(
          contract: xcsContract,
          outputDenom: 'uatom',
          receiver: 'cosmos1receiver',
          slippage: const XcsTwapSlippage(slippagePercentage: '5'),
          onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
        ),
        receiver: xcsContract,
      );
      expect(result.kind, MemoKind.xcs);
      expect(result.summary, contains("contract's default window"));
      expect(result.summary, isNot(contains('null')));
    });

    test('warns when a swap cannot recover stranded funds', () {
      final result = validateMemo(buildXcsSwapMemo(
        contract: xcsContract,
        outputDenom: 'uatom',
        receiver: 'cosmos1receiver',
        slippage: const XcsMinOutputSlippage('100'),
        onFailedDelivery: const XcsDoNothing(),
      ));
      expect(result.kind, MemoKind.xcs);
      expect(result.summary, contains('Recovery is off'));
      expect(
        result.warnings.any((w) => w.contains('cannot be recovered')),
        isTrue,
      );
    });

    test('follows a swap chained after a forward', () {
      final memo = buildForwardMemo(
        [const ForwardHop(channelId: 'channel-1')],
        xcsContract,
        next: buildXcsSwapMemoJson(
          contract: xcsContract,
          outputDenom: 'uatom',
          receiver: 'cosmos1receiver',
          slippage: const XcsMinOutputSlippage('100'),
          onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
        ),
      );
      final result = validateMemo(memo);
      expect(result.kind, MemoKind.xcs);
      expect(result.requiresPfm, isTrue);
      expect(result.requiresIbcHooks, isTrue);
      expect(result.summary, contains('forwards one more hop'));
      expect(result.summary, contains('Then swaps to uatom'));
    });

    test('cross-checks the transfer receiver against the hook contract', () {
      final memo = buildWasmHookMemo('osmo1contract', {'a': <String, Object?>{}});
      expect(validateMemo(memo, receiver: 'osmo1contract').warnings, isEmpty);
      expect(validateMemo(memo, receiver: '').warnings, isEmpty);
      expect(
        validateMemo(memo, receiver: 'osmo1someoneelse')
            .warnings
            .any((w) => w.contains('ibc-hooks will not run')),
        isTrue,
      );
    });

    test('refuses to classify a wasm object without exactly two keys', () {
      final result = validateMemo(
          '{"wasm":{"contract":"osmo1c","msg":{"a":{}},"extra":1}}');
      expect(result.kind, MemoKind.unknown);
      expect(result.requiresIbcHooks, isTrue);
      expect(result.summary, contains('Unrecognised memo'));
    });

    test('refuses a memo carrying keys alongside wasm or forward', () {
      expect(
        validateMemo('{"wasm":{"contract":"osmo1c","msg":{"a":{}}},"x":1}').kind,
        MemoKind.unknown,
      );
      expect(
        validateMemo('{"forward":{"receiver":"a","port":"transfer",'
                '"channel":"channel-1"},"x":1}')
            .kind,
        MemoKind.unknown,
      );
    });

    test('refuses a forward memo with an unreadable hop', () {
      expect(validateMemo('{"forward":{"port":"transfer",'
              '"channel":"channel-1"}}').kind,
          MemoKind.unknown);
      expect(validateMemo('{"forward":{"receiver":"a","port":"transfer",'
              '"channel":"bad channel"}}').kind,
          MemoKind.unknown);
    });

    test('warns when the final receiver is the sentinel', () {
      final result = validateMemo('{"forward":{"receiver":"pfm",'
          '"port":"transfer","channel":"channel-1"}}');
      expect(
        result.warnings.any((w) => w.contains('unrecoverable')),
        isTrue,
      );
    });

    test('reads the escaped-string form of next and says so', () {
      const inner = r'{\"forward\":{\"receiver\":\"juno1abc\",'
          r'\"port\":\"transfer\",\"channel\":\"channel-2\"}}';
      final result = validateMemo('{"forward":{"receiver":"pfm",'
          '"port":"transfer","channel":"channel-1","next":"$inner"}}');
      expect(result.kind, MemoKind.forward);
      expect(result.forward!.hops.length, 2);
      expect(
        result.warnings.any((w) => w.contains('escaped-string form')),
        isTrue,
      );
    });

    test('accepts the legacy integer-nanoseconds timeout with a warning', () {
      final result = validateMemo('{"forward":{"receiver":"juno1abc",'
          '"port":"transfer","channel":"channel-1","timeout":600000000000}}');
      expect(result.kind, MemoKind.forward);
      expect(result.forward!.hops.single.timeout, '600000000000ns');
      expect(
        result.warnings.any((w) => w.contains('legacy integer-nanoseconds')),
        isTrue,
      );
    });

    test('reports an omitted timeout or retries as null, not as a default', () {
      final result = validateMemo('{"forward":{"receiver":"juno1abc",'
          '"port":"transfer","channel":"channel-1"}}');
      expect(result.forward!.hops.single.timeout, isNull);
      expect(result.forward!.hops.single.retries, isNull);
    });

    test('flags an unrecognised field on a forward hop', () {
      final result = validateMemo('{"forward":{"receiver":"juno1abc",'
          '"port":"transfer","channel":"channel-1","sneaky":true}}');
      expect(
        result.warnings.any((w) => w.contains('unrecognised field `sneaky`')),
        isTrue,
      );
    });

    test('flags a contract message that names more than one variant', () {
      final result =
          validateMemo('{"wasm":{"contract":"osmo1c","msg":{"a":{},"b":{}}}}');
      expect(
        result.warnings.any((w) => w.contains('exactly one ExecuteMsg')),
        isTrue,
      );
    });

    test('never throws, whatever it is handed', () {
      for (final memo in <String>[
        '',
        '{',
        'null',
        '{"forward":null}',
        '{"wasm":null}',
        '{"forward":{"next":{"forward":{"next":{}}}}}',
        '{"wasm":{"contract":"","msg":{}}}',
      ]) {
        expect(() => validateMemo(memo), returnsNormally,
            reason: 'memo ${jsonEncode(memo)}');
      }
    });

    test('abbreviates long addresses in the summary but keeps them whole', () {
      const long =
          'osmo1uwk8xc6q0s6t5qcpr6rht3sczu6du83xq8pwxjua0hfj5hzcnh3sqxwvxs';
      final result = validateMemo(buildForwardMemo(
          [const ForwardHop(channelId: 'channel-1')], long));
      expect(result.summary, isNot(contains(long)));
      expect(result.summary, contains('…'));
      expect(result.forward!.finalReceiver, long);
    });
  });
}
