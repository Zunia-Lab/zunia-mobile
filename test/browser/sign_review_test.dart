/// What the signing prompt says, in both sign modes, and what it refuses.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/browser/fee_tiers.dart';
import 'package:zunia_mobile/browser/packet_memo.dart';
import 'package:zunia_mobile/browser/provider_errors.dart';
import 'package:zunia_mobile/browser/sign_review.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';

import '../support/kernel.dart';

const _sender = 'cosmos19rl4cm2hmr8afy4kldpxz3fka4jguq0auqdal4';
const _recipient = 'cosmos1jrkmdcwgq94uaamx6zax2luewlhf7u4kucx3kz';
const _validator = 'cosmosvaloper19rl4cm2hmr8afy4kldpxz3fka4jguq0ae5egnx';

const _hub = ChainEntry(
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
);

Map<String, dynamic> _doc(List<Map<String, dynamic>> msgs, {String memo = '', Object? fee}) => {
      'account_number': '7',
      'chain_id': 'cosmoshub-4',
      'fee': fee ??
          {
            'amount': [
              {'denom': 'uatom', 'amount': '5000'},
            ],
            'gas': '200000',
          },
      'memo': memo,
      'msgs': msgs,
      'sequence': '1',
    };

SignReview _amino(
  List<Map<String, dynamic>> msgs, {
  Set<String> known = const {},
  bool blind = false,
  String memo = '',
  Object? fee,
}) =>
    reviewAminoSignDoc(
      expectedChainId: 'cosmoshub-4',
      signDoc: _doc(msgs, memo: memo, fee: fee),
      context: ReviewContext(chain: _hub, knownRecipients: known, blindSigning: blind),
    );

void main() {
  group('amino in the kernel words', () {
    test('a send names amount and recipient, and a new recipient is flagged', () {
      final review = _amino([
        {
          'type': 'cosmos-sdk/MsgSend',
          'value': {
            'from_address': _sender,
            'to_address': _recipient,
            'amount': [
              {'denom': 'uatom', 'amount': '1500000'},
            ],
          },
        },
      ]);
      expect(review.messages.single.summary, 'Send 1500000 uatom to $_recipient');
      expect(review.messages.single.recipient, _recipient);
      expect(review.warnings, contains('First-time recipient: $_recipient'));
      expect(review.resolved.single, ['= 1.5 ATOM · native on Cosmos Hub · verified by registry']);
      expect(review.fees, [('Fee', '0.005 ATOM'), ('Gas', '200,000')]);
      expect(review.requiresBlindSigning, isFalse);

      final known = _amino([
        {
          'type': 'cosmos-sdk/MsgSend',
          'value': {
            'from_address': _sender,
            'to_address': _recipient,
            'amount': [
              {'denom': 'uatom', 'amount': '1'},
            ],
          },
        },
      ], known: {_recipient});
      expect(known.warnings, isEmpty);
    });

    test('staking, votes and swaps read as the kernel writes them', () {
      final review = _amino([
        {
          'type': 'cosmos-sdk/MsgDelegate',
          'value': {
            'delegator_address': _sender,
            'validator_address': _validator,
            'amount': {'denom': 'uatom', 'amount': '1000'},
          },
        },
        {
          'type': 'cosmos-sdk/MsgVote',
          'value': {'proposal_id': '1058', 'voter': _sender, 'option': 3},
        },
        {
          'type': 'cosmos-sdk/MsgVote',
          'value': {'proposal_id': '1058', 'voter': _sender, 'option': 9},
        },
        {
          'type': 'osmosis/poolmanager/swap-exact-amount-in',
          'value': {
            'sender': _sender,
            'routes': [
              {'pool_id': '1', 'token_out_denom': 'uosmo'},
              {'pool_id': '3586', 'token_out_denom': 'uusdc'},
            ],
            'token_in': {'denom': 'uatom', 'amount': '100'},
            'token_out_min_amount': '90',
          },
        },
      ], blind: true);
      expect(review.messages.map((m) => m.summary), [
        'Delegate 1000 uatom to $_validator',
        'Vote No on proposal 1058',
        'Vote on proposal 1058 with an unrecognised option',
        'Swap 100 uatom for at least 90 uusdc through pools 1 → 3586',
      ]);
      expect(review.messages[2].unknown, isTrue);
      // Blind signing on: the unknown message is allowed, and still named.
      expect(review.requiresBlindSigning, isFalse);
      expect(review.warnings, contains('Unknown or undecoded message: cosmos-sdk/MsgVote'));
    });

    test('an unknown message is refused with blind signing off, naming its type', () {
      final review = _amino([
        {'type': 'acme/DoSomething', 'value': {}},
        {'type': 'acme/DoSomething', 'value': {}},
        {'type': 'cosmos-sdk/MsgFancy', 'value': {}},
      ]);
      expect(review.requiresBlindSigning, isTrue);
      expect(review.messages.first.unknown, isTrue);
      // A type with "Msg" in it keeps the generic line without the gate.
      expect(review.messages.last.unknown, isFalse);
      expect(review.warnings, contains(kBlindSigningOffWarning));
      final refusal = blindSigningRefusal(review);
      expect(refusal.code, ProviderErrorCode.unsupported);
      expect(refusal.message, 'Blind signing disabled for unknown messages: acme/DoSomething');
    });

    test('a transfer with a packet memo says where the memo sends the tokens', () {
      final memo = jsonEncode({
        'forward': {'receiver': 'stride1abc', 'port': 'transfer', 'channel': 'channel-5'},
      });
      final review = _amino([
        {
          'type': 'cosmos-sdk/MsgTransfer',
          'value': {
            'source_port': 'transfer',
            'source_channel': 'channel-141',
            'token': {'denom': 'uatom', 'amount': '10'},
            'sender': _sender,
            'receiver': 'osmo1receiver',
            'timeout_height': {},
            'timeout_timestamp': '1791310044063818800',
            'memo': memo,
          },
        },
      ], known: {'osmo1receiver'});
      expect(review.messages.single.summary, 'IBC transfer 10 uatom to osmo1receiver over channel-141');
      expect(review.warnings, [
        kPacketMemoNotice,
        'The packet memo forwards the tokens from the receiving chain over channel-5 to stride1abc.',
      ]);
    });

    test('a contract action is quoted only when it is a plain name', () {
      final plain = _amino([
        {
          'type': 'wasm/MsgExecuteContract',
          'value': {
            'sender': _sender,
            'contract': _recipient,
            'msg': {
              'swap': {'min': '1'},
            },
            'funds': [
              {'denom': 'uatom', 'amount': '5'},
            ],
          },
        },
      ]);
      expect(plain.messages.single.summary, 'Execute "swap" on $_recipient sending 5 uatom');
      expect(plain.messages.single.unknown, isFalse);

      final hidden = _amino([
        {
          'type': 'wasm/MsgExecuteContract',
          'value': {
            'sender': _sender,
            'contract': _recipient,
            'msg': {
              'swap\u202e': {'min': '1'},
            },
          },
        },
      ]);
      expect(hidden.messages.single.summary, 'Execute a contract call on $_recipient that Zunia could not read');
      expect(hidden.messages.single.unknown, isTrue);
      expect(hidden.requiresBlindSigning, isTrue);
    });

    test('a CW721 transfer names the token, the collection and the new owner', () {
      final review = _amino([
        {
          'type': 'wasm/MsgExecuteContract',
          'value': {
            'sender': _sender,
            'contract': _recipient,
            'msg': {
              'transfer_nft': {'recipient': _sender, 'token_id': '42'},
            },
            'funds': [],
          },
        },
      ]);
      expect(
        review.messages.single.summary,
        'Give away NFT 42 from collection $_recipient to $_sender',
      );
      expect(review.messages.single.recipient, _sender);

      final withCoins = _amino([
        {
          'type': 'wasm/MsgExecuteContract',
          'value': {
            'sender': _sender,
            'contract': _recipient,
            'msg': {
              'transfer_nft': {'recipient': _sender, 'token_id': '42'},
            },
            'funds': [
              {'denom': 'uatom', 'amount': '9'},
            ],
          },
        },
      ], known: {_sender});
      expect(withCoins.messages.single.summary, endsWith('to $_sender sending 9 uatom'));
      expect(withCoins.warnings, contains(kCw721FundsWarning));
    });

    test('every fee coin is named, and a fee nothing names stays raw', () {
      final review = _amino(
        [
          {
            'type': 'cosmos-sdk/MsgSend',
            'value': {'from_address': _sender, 'to_address': _recipient, 'amount': []},
          },
        ],
        known: {_recipient},
        fee: {
          'amount': [
            {'denom': 'uatom', 'amount': '1234567'},
            {'denom': 'ibc/ABCDEF', 'amount': '3'},
          ],
          'gas': '90000',
        },
      );
      expect(review.fees.first, ('Fee', '1.234567 ATOM + 3 ibc/ABCDEF'));
    });
  });

  group('fee tiers', () {
    test('offered only for one coin in the fee denom, unless the site says not to', () {
      const fee = TxFee([FeeCoin('uatom', '5000')], '200000');
      final choice = feeChoiceFor(_hub, fee, preferNoSetFee: false)!;
      expect(choice.site, '5000');
      expect(choice.tiers, {FeeTier.low: '1000', FeeTier.average: '5000', FeeTier.high: '6000'});
      expect(feeChoiceFor(_hub, fee, preferNoSetFee: true), isNull);
      expect(
        feeChoiceFor(_hub, const TxFee([FeeCoin('uatom', '1'), FeeCoin('uosmo', '1')], '1'), preferNoSetFee: false),
        isNull,
      );
      expect(feeChoiceFor(_hub, const TxFee([FeeCoin('uosmo', '1')], '1'), preferNoSetFee: false), isNull);
      expect(feeChoiceFor(_hub, const TxFee([FeeCoin('uatom', '1')], '0'), preferNoSetFee: false), isNull);
    });

    test('an amino fee change keeps gas, payer and granter', () {
      final doc = _doc([], fee: {
        'amount': [
          {'denom': 'uatom', 'amount': '5000'},
        ],
        'gas': '200000',
        'granter': 'cosmos1granter',
      });
      final next = withAminoFee(doc, const FeeCoin('uatom', '6000'));
      expect(next['fee'], {
        'amount': [
          {'denom': 'uatom', 'amount': '6000'},
        ],
        'gas': '200000',
        'granter': 'cosmos1granter',
      });
      expect(doc['fee']['amount'][0]['amount'], '5000');
    });

    test('a direct fee change rewrites the fee coin and nothing else', () {
      final core = File('../zunia-core/tests/vectors/cosmos-signing.json');
      final authInfo = bytesOfHex(
        ((jsonDecode(core.readAsStringSync())['cases'] as List).first['direct'] as Map)['auth_info_bytes_hex']
            as String,
      );
      final before = authInfoFee(authInfo)!;
      expect(before.amount.single, const FeeCoin('uatom', '5000'));
      expect(before.gas, '200000');
      final after = withAuthInfoFee(authInfo, const FeeCoin('uatom', '6000'));
      final read = authInfoFee(after)!;
      expect(read.amount.single, const FeeCoin('uatom', '6000'));
      expect(read.gas, '200000');
      // The signer infos (field 1) come through byte for byte.
      expect(readProtoFields(after).first.raw, readProtoFields(authInfo).first.raw);
    }, skip: File('../zunia-core/tests/vectors/cosmos-signing.json').existsSync() ? false : 'no zunia-core');
  });

  group('refusals', () {
    test('a transaction too large to show whole is refused, never cut', () {
      final big = _doc([], memo: 'x' * (kPreviewMaxChars + 1));
      expect(
        () => previewJson(big),
        throwsA(
          isA<ProviderError>()
              .having((e) => e.code, 'code', ProviderErrorCode.unsupported)
              .having((e) => e.message, 'message', 'This transaction is too large to show in full'),
        ),
      );
      expect(previewJson(_doc([])), contains('"chain_id": "cosmoshub-4"'));
    });

    test('a document for another chain is refused', () {
      expect(
        () => reviewAminoSignDoc(
          expectedChainId: 'osmosis-1',
          signDoc: _doc([]),
          context: const ReviewContext(),
        ),
        throwsA(isA<ProviderError>().having((e) => e.code, 'code', ProviderErrorCode.invalidParams)),
      );
    });
  });

  group('direct, decoded by the kernel', () {
    final core = File('../zunia-core/tests/vectors/cosmos-signing.json');
    final cases = core.existsSync()
        ? ((jsonDecode(core.readAsStringSync()) as Map<String, dynamic>)['cases'] as List).cast<Map<String, dynamic>>()
        : const <Map<String, dynamic>>[];

    test('a send reads the same as its amino form', () {
      final send = cases.firstWhere((c) => c['name'] == 'msg_send');
      final review = reviewDirectSignBytes(
        expectedChainId: 'cosmoshub-4',
        signBytes: bytesOfHex((send['direct'] as Map)['sign_bytes_hex'] as String),
        context: const ReviewContext(chain: _hub),
      );
      expect(review.messages.single.summary, 'Send 1000000 uatom to $_recipient');
      expect(review.messages.single.type, '/cosmos.bank.v1beta1.MsgSend');
      expect(review.messages.single.recipient, _recipient);
      expect(review.fee!.amount.single, const FeeCoin('uatom', '5000'));
      expect(review.warnings, ['First-time recipient: $_recipient']);
      expect(directPreviewJson(review), contains('"chainId": "cosmoshub-4"'));
    }, skip: cases.isEmpty ? 'no zunia-core' : kernelSkip);

    test('every golden decodes on the chain it names, and none reads as unknown', () {
      for (final c in cases) {
        final review = reviewDirectSignBytes(
          expectedChainId: 'cosmoshub-4',
          signBytes: bytesOfHex((c['direct'] as Map)['sign_bytes_hex'] as String),
          context: const ReviewContext(chain: _hub),
        );
        expect(review.messages, isNotEmpty, reason: c['name'] as String);
        expect(review.hasUnknown, isFalse, reason: c['name'] as String);
        expect(review.requiresBlindSigning, isFalse, reason: c['name'] as String);
      }
    }, skip: cases.isEmpty ? 'no zunia-core' : kernelSkip);

    test('garbage bytes are refused, not described', () {
      expect(
        () => reviewDirectSignBytes(
          expectedChainId: 'cosmoshub-4',
          signBytes: DirectSignDoc.fromProvider({
            'bodyBytes': [0x0a, 0xff, 0xff],
            'authInfoBytes': <int>[],
            'chainId': 'cosmoshub-4',
            'accountNumber': '1',
          }).signBytes,
          context: const ReviewContext(),
        ),
        throwsA(isA<ProviderError>()),
      );
    }, skip: kernelSkip);
  });

  group('packet memo', () {
    test('names forwards and hooks, refuses double spellings', () {
      expect(packetMemoNote('just a note'), isNull);
      expect(packetMemoNote('{}'), isNull);
      expect(
        packetMemoNote(jsonEncode({
          'wasm': {'contract': 'osmo1contract', 'msg': {}},
        })),
        'The packet memo hands the tokens to contract osmo1contract on the receiving chain.',
      );
      expect(
        packetMemoNote(jsonEncode({
          'forward': {
            'receiver': 'a1',
            'channel': 'channel-1',
            'next': jsonEncode({
              'forward': {'receiver': 'b1', 'channel': 'channel-2'},
            }),
          },
        })),
        'The packet memo forwards the tokens from the receiving chain over channel-1 to a1, then over channel-2 to b1.',
      );
      // Go reads "Receiver" as "receiver" too: which one wins is not ours to guess.
      expect(
        packetMemoNote('{"forward":{"receiver":"a1","Receiver":"b1","channel":"channel-1"}}'),
        kPacketMemoUnreadable,
      );
      expect(packetMemoNote('{"forward":{"receiver":"a1","channel":"chan"}}'), kPacketMemoUnreadable);
      expect(
        packetMemoNote('{"forward":{"receiver":"a1","channel":"channel-1"},"wasm":{"contract":"c"}}'),
        kPacketMemoUnreadable,
      );
      // Go folds the Kelvin sign and the long s, but only for the fields it reads.
      expect(
        packetMemoNote('{"wasm":{"contract":"c1","\u212aey":1,"contract\u017f":2}}'),
        'The packet memo hands the tokens to contract c1 on the receiving chain.',
      );
    });
  });

  test('coins are named from the chain registry, exactly', () {
    expect(isBankSpelling('ibc/ABC'), isTrue);
    expect(isBankSpelling('ibc/abc'), isFalse);
    expect(exactCoinText(_hub, '1000000', 'uatom'), '1 ATOM');
    expect(exactCoinText(_hub, '1000000', 'ibc/abc'), '1000000 ibc/abc');
    expect(exactCoinText(null, '5', 'uatom'), '5 uatom');
    expect(WalletKernel.normalizePhrase(' A  b '), 'a b');
  });
}
