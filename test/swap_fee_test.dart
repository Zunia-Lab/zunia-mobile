/// Zunia's swap commission as `lib/swap/swap_fee.dart` works it out, builds
/// it and checks it: a port of zunia-extension 0.1.5
/// `lib/__tests__/swap-fee.test.ts`, and of the swap-fee half of its
/// `release-consistency.test.ts`, run over the `swap-fee.json` this app ships.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/swap/swap_config.dart';
import 'package:zunia_mobile/swap/swap_fee.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

import 'support/swap_fixtures.dart';

final osmoTreasury = bech('osmo', 0x5a);
final hubTreasury = bech('cosmos', 0x5a);
final injTreasury = bech('inj', 0x5b);
final me = bech('osmo', 1);
final someone = bech('osmo', 7);

const _prefixes = {
  'osmosis-1': 'osmo',
  'cosmoshub-4': 'cosmos',
  'injective-1': 'inj',
  'noble-1': 'noble',
};
String? _prefixOf(String chainId) => _prefixes[chainId];

SwapFeePolicy policy([Map<String, String>? recipients, int bps = 50]) =>
    SwapFeePolicy(
      bps: bps,
      recipients:
          recipients ??
          {
            'osmosis-1': osmoTreasury,
            'cosmoshub-4': hubTreasury,
            'injective-1': injTreasury,
          },
      prefixOf: _prefixOf,
    );

SwapFee none(BigInt amount) => SwapFee.none(amount);
BigInt n(Object v) => BigInt.parse('$v');

void main() {
  group('the fee on a swap', () {
    test('is 50 basis points of the amount sold, with the rest swapped', () {
      // 63 OSMO: 0.315 OSMO to the treasury, 62.685 OSMO swapped.
      expect(
        policy().feeFor('osmosis-1', n(63000000)),
        SwapFee(
          bps: 50,
          fee: n(315000),
          net: n(62685000),
          recipient: osmoTreasury,
        ),
      );
      // 1 ATOM on the Hub: 0.005 ATOM there, 0.995 ATOM sent to the swap.
      expect(
        policy().feeFor('cosmoshub-4', n(1000000)),
        SwapFee(bps: 50, fee: n(5000), net: n(995000), recipient: hubTreasury),
      );
    });

    test('rounds down, so rounding only ever favours the user', () {
      expect(policy().feeFor('osmosis-1', n(1999)).fee, n(9));
      expect(policy().feeFor('osmosis-1', n(1999)).net, n(1990));
      expect(policy().feeFor('osmosis-1', n(2000)).fee, n(10));
      expect(policy().feeFor('osmosis-1', n(2001)).net, n(1991));
    });

    test('charges nothing on dust too small to carry one base unit of fee', () {
      for (final amount in [1, 2, 100, 199]) {
        expect(policy().feeFor('osmosis-1', n(amount)), none(n(amount)));
      }
      expect(
        policy().feeFor('osmosis-1', n(200)),
        SwapFee(bps: 50, fee: n(1), net: n(199), recipient: osmoTreasury),
      );
      expect(policy().feeFor('osmosis-1', n(0)), none(n(0)));
      expect(policy().feeFor('osmosis-1', n(-5000)), none(n(-5000)));
    });

    test('works in big integers at any size, far past what a double holds', () {
      expect(
        policy().feeFor('injective-1', n('1499999999999999999')),
        SwapFee(
          bps: 50,
          fee: n('7499999999999999'),
          net: n('1492500000000000000'),
          recipient: injTreasury,
        ),
      );
      final huge = BigInt.from(10).pow(40) + n(12345);
      final fee = policy().feeFor('osmosis-1', huge);
      expect(fee.fee, huge * n(50) ~/ n(10000));
      expect(fee.fee, n(5) * BigInt.from(10).pow(37) + n(61));
      expect(fee.fee + fee.net, huge);
    });

    test(
      'always splits the whole amount: fee and swap add up to what the user pays',
      () {
        for (var amount = 1; amount < 5000; amount += 7) {
          final fee = policy().feeFor('osmosis-1', n(amount));
          expect(fee.fee + fee.net, n(amount));
          expect(fee.fee, n(amount) * n(50) ~/ n(10000));
          expect(fee.net > BigInt.zero, isTrue);
        }
      },
    );

    test('charges nothing on a chain with no treasury', () {
      expect(policy().feeFor('noble-1', n(1000000)), none(n(1000000)));
      expect(
        policy(const {}).feeFor('osmosis-1', n(1000000)),
        none(n(1000000)),
      );
    });

    test(
      'charges nothing at a rate that is not a whole number of basis points below 100%',
      () {
        expect(policy(null, 25).feeFor('osmosis-1', n(1000000)).fee, n(2500));
        for (final bps in [0, -50, 10000, 20000]) {
          expect(
            policy(null, bps).feeFor('osmosis-1', n(1000000)),
            none(n(1000000)),
          );
        }
      },
    );

    test('says its rate in percent, from whole numbers', () {
      expect(feeRateText(50), '0.5%');
      expect(feeRateText(25), '0.25%');
      expect(feeRateText(5), '0.05%');
      expect(feeRateText(10), '0.1%');
      expect(feeRateText(100), '1%');
      expect(feeRateText(150), '1.5%');
    });

    test('is the same fee only when every part is', () {
      final fee = policy().feeFor('osmosis-1', n(63000000));
      SwapFee with_({int? bps, BigInt? f, BigInt? net, String? to}) => SwapFee(
        bps: bps ?? fee.bps,
        fee: f ?? fee.fee,
        net: net ?? fee.net,
        recipient: to ?? fee.recipient,
      );
      expect(fee == with_(), isTrue);
      expect(fee == with_(f: fee.fee + BigInt.one), isFalse);
      expect(fee == with_(net: fee.net - BigInt.one), isFalse);
      expect(fee == with_(to: someone), isFalse);
      expect(fee == with_(bps: 49), isFalse);
    });
  });

  group('the treasury a chain pays', () {
    test("is an address with the chain's own prefix, checksum included", () {
      expect(
        swapFeeRecipientProblem('osmosis-1', osmoTreasury, prefixOf: _prefixOf),
        isNull,
      );
      expect(
        swapFeeRecipientProblem(
          'injective-1',
          injTreasury,
          prefixOf: _prefixOf,
        ),
        isNull,
      );
      // A contract (a DAO treasury) holds 32 bytes.
      expect(
        swapFeeRecipientProblem(
          'osmosis-1',
          bech('osmo', 3, 32),
          prefixOf: _prefixOf,
        ),
        isNull,
      );
    });

    test(
      "is never another chain's address, which charges nothing rather than paying it",
      () {
        final wrong = policy({
          'cosmoshub-4': osmoTreasury,
          'injective-1': hubTreasury,
        });
        expect(
          swapFeeRecipientProblem(
            'cosmoshub-4',
            osmoTreasury,
            prefixOf: _prefixOf,
          ),
          contains("prefix osmo, not cosmoshub-4's cosmos"),
        );
        expect(wrong.recipientFor('cosmoshub-4'), isNull);
        expect(wrong.recipientFor('injective-1'), isNull);
        expect(wrong.feeFor('cosmoshub-4', n(1000000)), none(n(1000000)));
      },
    );

    test(
      'refuses a broken checksum, mixed or upper case, a wrong length and an unbundled chain',
      () {
        final flipped =
            '${osmoTreasury.substring(0, osmoTreasury.length - 1)}${osmoTreasury.endsWith('q') ? 'p' : 'q'}';
        expect(
          swapFeeRecipientProblem('osmosis-1', flipped, prefixOf: _prefixOf),
          contains('not a valid bech32'),
        );
        expect(
          swapFeeRecipientProblem(
            'osmosis-1',
            osmoTreasury.toUpperCase(),
            prefixOf: _prefixOf,
          ),
          contains('lowercase'),
        );
        expect(
          swapFeeRecipientProblem(
            'osmosis-1',
            bech('osmo', 1, 16),
            prefixOf: _prefixOf,
          ),
          contains('16 bytes'),
        );
        expect(
          swapFeeRecipientProblem('osmosis-1', '', prefixOf: _prefixOf),
          contains('not a valid bech32'),
        );
        expect(
          swapFeeRecipientProblem(
            'my-own-chain-1',
            osmoTreasury,
            prefixOf: _prefixOf,
          ),
          contains('not a chain this release bundles'),
        );
        for (final bad in [
          flipped,
          osmoTreasury.toUpperCase(),
          bech('osmo', 1, 16),
        ]) {
          expect(policy({'osmosis-1': bad}).recipientFor('osmosis-1'), isNull);
        }
      },
    );
  });

  group('the message that pays it', () {
    TxMsg paid() => buildSwapFeeMsg(
      sender: me,
      recipient: osmoTreasury,
      denom: 'uosmo',
      amount: n(315000),
    );

    test(
      "is a bank send in the kernel's MsgSend shape: from the signer, to the treasury, one coin",
      () {
        expect(paid().typeUrl, '/cosmos.bank.v1beta1.MsgSend');
        expect(bankSendTypeUrl, '/cosmos.bank.v1beta1.MsgSend');
        // The field order the amino `msgSend` writes, so the JSON reads the same.
        expect(
          jsonEncode(paid().toJson()),
          '{"typeUrl":"/cosmos.bank.v1beta1.MsgSend","value":{"from_address":"$me","to_address":"$osmoTreasury","amount":[{"denom":"uosmo","amount":"315000"}]}}',
        );
      },
    );

    test('is never built with nothing to pay or nobody to pay it', () {
      TxMsg build({
        String? sender,
        String? recipient,
        String? denom,
        BigInt? amount,
      }) => buildSwapFeeMsg(
        sender: sender ?? me,
        recipient: recipient ?? osmoTreasury,
        denom: denom ?? 'uosmo',
        amount: amount ?? BigInt.one,
      );
      expect(() => build(amount: BigInt.zero), throwsArgumentError);
      expect(() => build(amount: n(-1)), throwsArgumentError);
      expect(() => build(recipient: ''), throwsArgumentError);
      expect(() => build(sender: ''), throwsArgumentError);
      expect(() => build(denom: ''), throwsArgumentError);
    });

    test(
      'is read back exactly, and nothing it does not say is read as a fee',
      () {
        expect(
          readSwapFeeMsg(paid()),
          SwapFeeMessage(
            from: me,
            to: osmoTreasury,
            denom: 'uosmo',
            amount: '315000',
          ),
        );
        final value = paid().value;
        final coin = {'denom': 'uosmo', 'amount': '315000'};
        final unreadable = <TxMsg?>[
          null,
          TxMsg('/cosmos.bank.v1beta1.MsgMultiSend', value),
          TxMsg('/cosmwasm.wasm.v1.MsgExecuteContract', value),
          TxMsg(bankSendTypeUrl, {
            ...value,
            'amount': [
              coin,
              {'denom': 'uion', 'amount': '1'},
            ],
          }),
          TxMsg(bankSendTypeUrl, {...value, 'amount': []}),
          TxMsg(bankSendTypeUrl, {...value, 'amount': coin}),
          TxMsg(bankSendTypeUrl, {...value, 'memo': 'x'}),
          TxMsg(bankSendTypeUrl, {
            ...value,
            'amount': [
              {...coin, 'extra': 1},
            ],
          }),
          TxMsg(bankSendTypeUrl, {
            'to_address': osmoTreasury,
            'amount': [coin],
          }),
          TxMsg(bankSendTypeUrl, {...value, 'to_address': ''}),
          TxMsg(bankSendTypeUrl, {...value, 'from_address': 7}),
          for (final amount in [
            '0',
            '0315000',
            '315000.5',
            '-315000',
            '1e6',
            ' 315000',
            '',
          ])
            TxMsg(bankSendTypeUrl, {
              ...value,
              'amount': [
                {'denom': 'uosmo', 'amount': amount},
              ],
            }),
          TxMsg(bankSendTypeUrl, {
            ...value,
            'amount': [
              {'denom': 'uosmo', 'amount': 315000},
            ],
          }),
          TxMsg(bankSendTypeUrl, {
            ...value,
            'amount': [
              {'denom': '', 'amount': '315000'},
            ],
          }),
        ];
        for (final msg in unreadable) {
          expect(
            readSwapFeeMsg(msg),
            isNull,
            reason: jsonEncode(msg?.toJson()),
          );
        }
      },
    );
  });

  group("the check on a transaction's fee message", () {
    final expected = SwapFeeExpectation(
      chainId: 'osmosis-1',
      signer: me,
      denom: 'uosmo',
      amountUnits: n(63000000),
    );
    final due = policy().feeFor('osmosis-1', n(63000000));
    TxMsg send({
      String? sender,
      String? recipient,
      String? denom,
      BigInt? amount,
    }) => buildSwapFeeMsg(
      sender: sender ?? me,
      recipient: recipient ?? osmoTreasury,
      denom: denom ?? 'uosmo',
      amount: amount ?? n(315000),
    );
    List<Type> kinds(List<SwapFeeIssue> issues) => [
      for (final i in issues) i.runtimeType,
    ];

    test(
      'passes exactly the fee owed: from the signer, to the treasury, in the denom sold, for that amount',
      () {
        expect(policy().issues(send(), expected), isEmpty);
      },
    );

    test(
      'refuses a fee to another address, in another denom, of another amount or from another account',
      () {
        final elsewhere = policy().issues(send(recipient: someone), expected);
        expect(elsewhere.single, isA<SwapFeeWrongRecipient>());
        expect((elsewhere.single as SwapFeeWrongRecipient).due, due);
        expect(
          policy().issues(send(denom: 'uion'), expected).single,
          isA<SwapFeeWrongDenom>(),
        );
        for (final amount in [314999, 315001, 630000]) {
          expect(
            policy().issues(send(amount: n(amount)), expected).single,
            isA<SwapFeeWrongAmount>(),
          );
        }
        expect(
          policy().issues(send(sender: someone), expected).single,
          isA<SwapFeeWrongSender>(),
        );
        expect(
          kinds(
            policy().issues(
              send(sender: someone, recipient: someone, amount: BigInt.one),
              expected,
            ),
          ),
          [SwapFeeWrongSender, SwapFeeWrongRecipient, SwapFeeWrongAmount],
        );
      },
    );

    test(
      'refuses a fee when none is owed, and a transaction that leaves out a fee that is',
      () {
        expect(
          policy(const {}).issues(send(), expected).single,
          isA<SwapFeeNotDue>(),
        );
        final dust = SwapFeeExpectation(
          chainId: 'osmosis-1',
          signer: me,
          denom: 'uosmo',
          amountUnits: n(150),
        );
        expect(
          policy().issues(send(amount: BigInt.one), dust).single,
          isA<SwapFeeNotDue>(),
        );
        final missing = policy().issues(null, expected);
        expect(missing.single, isA<SwapFeeMissing>());
        expect((missing.single as SwapFeeMissing).due, due);
        expect(policy(const {}).issues(null, expected), isEmpty);
        expect(policy().issues(null, dust), isEmpty);
      },
    );

    test('refuses a second message it cannot read as a fee', () {
      final call = TxMsg('/cosmwasm.wasm.v1.MsgExecuteContract', {
        'sender': me,
        'contract': someone,
        'msg': 'e30=',
        'funds': <Object>[],
      });
      expect(policy().issues(call, expected).single, isA<SwapFeeUnreadable>());
      expect(
        policy(const {}).issues(call, expected).single,
        isA<SwapFeeUnreadable>(),
      );
    });

    test(
      'works the fee owed out again from the configuration, whatever the caller believes',
      () {
        expect(kinds(policy({'osmosis-1': someone}).issues(send(), expected)), [
          SwapFeeWrongRecipient,
        ]);
      },
    );
  });

  // The release-consistency checks, over the file this app ships, written
  // apart from swap_fee.dart so the release does not check the code with
  // itself.
  group("the release's swap fee (assets/data/swap-fee.json)", () {
    late SwapFeeConfig shipped;
    late List<ChainEntry> catalog;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      catalog = (await ChainCatalog.load()).registryOnly;
      shipped = SwapFeeConfig.fromJson(
        jsonDecode(await rootBundle.loadString('assets/data/swap-fee.json'))
            as Map<String, Object?>,
      );
    });

    /// Why each entry cannot be paid, as `chainId: reason`.
    List<String> treasuryProblems(Map<String, String> map) {
      final problems = <String>[];
      final rows = <({String chainId, int coinType, String hex})>[];
      for (final MapEntry(key: chainId, value: address) in map.entries) {
        ChainEntry? entry;
        for (final row in catalog) {
          if (row.chainId == chainId) entry = row;
        }
        if (entry == null) {
          problems.add('$chainId: not a bundled chain');
          continue;
        }
        final decoded = decodeBech32Address(address);
        if (decoded == null) {
          problems.add('$chainId: $address does not decode');
          continue;
        }
        if (decoded.prefix != entry.bech32Prefix) {
          problems.add(
            "$chainId: $address has the prefix ${decoded.prefix}, the chain's is ${entry.bech32Prefix}",
          );
        }
        if (address != address.toLowerCase()) {
          problems.add('$chainId: $address is not lowercase');
        }
        if (decoded.bytes.length != 20 && decoded.bytes.length != 32) {
          problems.add(
            '$chainId: $address holds ${decoded.bytes.length} bytes',
          );
        }
        rows.add((
          chainId: chainId,
          coinType: entry.coinType,
          hex: decoded.bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
        ));
      }
      for (final row in rows) {
        if (row.coinType != 60) continue;
        for (final other in rows) {
          if (other.coinType != 60 && other.hex == row.hex) {
            problems.add(
              "${row.chainId}: re-encodes ${other.chainId}'s treasury, which no coin type 60 key can spend",
            );
            break;
          }
        }
      }
      return problems;
    }

    test('is 50 basis points of the amount sold', () {
      expect(shipped.bps, 50);
    });

    test("pays only treasuries that decode with their own chain's prefix", () {
      expect(shipped.recipients, hasLength(131));
      expect(treasuryProblems(shipped.recipients), isEmpty);
      // And the wallet pays each one exactly as configured: none is dropped
      // as invalid at run time, which would silently charge nothing there.
      final live = SwapFeePolicy.fromConfig(shipped);
      for (final MapEntry(key: chainId, value: address)
          in shipped.recipients.entries) {
        expect(live.recipientFor(chainId), address, reason: chainId);
      }
    });

    test(
      'would refuse a wrong-chain, mistyped, re-encoded or unbundled treasury',
      () {
        final osmo = bech('osmo', 0x5a);
        expect(
          treasuryProblems({
            'osmosis-1': osmo,
            'cosmoshub-4': bech('cosmos', 0x5a),
            'injective-1': bech('inj', 0x5b),
          }),
          isEmpty,
        );
        expect(
          treasuryProblems({
            'osmosis-1': osmo,
            'injective-1': bech('inj', 0x5a),
          }),
          [
            "injective-1: re-encodes osmosis-1's treasury, which no coin type 60 key can spend",
          ],
        );
        expect(
          treasuryProblems({
            'cosmoshub-4': osmo,
            'osmosis-1':
                '${osmo.substring(0, osmo.length - 1)}${osmo.endsWith('q') ? 'p' : 'q'}',
            'noble-1': bech('noble', 1, 16),
            'my-chain-1': osmo,
          }).map((p) => p.split(':').first),
          ['cosmoshub-4', 'osmosis-1', 'noble-1', 'my-chain-1'],
        );
      },
    );

    test(
      'is data, not code: the fee module reads no network, storage or clock',
      () async {
        final source = await File('lib/swap/swap_fee.dart').readAsString();
        expect(
          source,
          isNot(
            matches(RegExp(r'http|SharedPreferences|DateTime\.now|rootBundle')),
          ),
        );
        expect(source, isNot(contains('osmo1gv86')));
      },
    );
  });
}
