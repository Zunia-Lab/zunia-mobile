import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/activity/activity_model.dart';
import 'package:zunia_mobile/activity/bundled_links.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';

import '../support/catalog.dart';

/// History rows, the detail and the filters, against the extension's own
/// cases (lib/__tests__/chain-queries.test.ts, 0.1.5).
const me = 'osmo1qyqszqgpqyqszqgpqyqszqgpqyqszqgpjnp7du';
const other = 'osmo1zgq2rswzqupqyqs3dqsdgq2rswzqupqyqs5c7ms0';
const hubSender = 'cosmos1qyqszqgpqyqszqgpqyqszqgpqyqszqgpgq2rsw';
const voucher = 'ibc/0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF';
const osmoTreasury = 'osmo1tfd95kj6tfd95kj6tfd95kj6tfd95kj6kvmlwa';
const xcs = 'osmo1uwk8xc6q0s6t5qcpr6rht3sczu6du83xq8pwxjua0hfj5hzcnh3sqxwvxs';

String short(String address) => '${address.substring(0, 12)}…${address.substring(address.length - 6)}';

Map<String, Object?> recvPacket(String receiver, String denom, String amount) => {
      '@type': '/ibc.core.channel.v1.MsgRecvPacket',
      'packet': {
        'destination_channel': 'channel-0',
        'data': base64.encode(utf8.encode(jsonEncode({
          'denom': denom,
          'amount': amount,
          'sender': hubSender,
          'receiver': receiver,
        }))),
      },
    };

const updateClient = {'@type': '/ibc.core.client.v1.MsgUpdateClient', 'client_id': '07-tendermint-1'};

Map<String, Object?> send(String from, String to, String denom, String amount) => {
      '@type': '/cosmos.bank.v1beta1.MsgSend',
      'from_address': from,
      'to_address': to,
      'amount': [
        {'denom': denom, 'amount': amount},
      ],
    };

void main() {
  setUpAll(loadBundledData);

  group('pickMessage', () {
    test('finds the delivery to this account inside a relayer transaction', () {
      final mine = recvPacket(me, 'uatom', '2000000');
      final picked = pickMessage([updateClient, recvPacket(other, 'uatom', '1'), mine], me);
      expect(identical(picked, mine), isTrue);
    });

    test('skips relayer upkeep for the message the transaction is about', () {
      final message = <String, Object?>{'@type': '/cosmos.bank.v1beta1.MsgSend', 'from_address': me};
      expect(identical(pickMessage([updateClient, message], me), message), isTrue);
      expect(pickMessage([updateClient], me), updateClient);
    });
  });

  group('describeMessage', () {
    test('reads an IBC delivery to this account with the coin it carried', () {
      final described = describeMessage(recvPacket(me, 'transfer/channel-141/uosmo', '2500000'), me, 'osmosis-1');
      expect(described.kind, ActivityKind.ibc);
      expect(described.symbol, 'OSMO');
      expect(described.amount, '2500000');
      expect(described.summary, 'Receive 2.5 OSMO over IBC from ${short(hubSender)} on channel-0');
    });

    test('describes a delivery to someone else as relaying, with no amount', () {
      final described = describeMessage(recvPacket(other, 'uatom', '1'), me, 'osmosis-1');
      expect(described.kind, ActivityKind.other);
      expect(described.amount, isNull);
      expect(described.summary, 'Deliver an IBC packet on channel-0');
    });

    test('does not price a voucher it cannot name in the native coin', () {
      final described = describeMessage(send(me, other, voucher, '42'), me, 'osmosis-1');
      expect(described.kind, ActivityKind.sent);
      expect(described.amount, '-42');
      expect(described.denom, voucher);
      expect(described.decimals, 0);
      expect(described.decimalsKnown, isFalse);
      expect(described.symbol, isNot('OSMO'));
    });

    test('names an IBC client update instead of leaving the row unmarked', () {
      final described = describeMessage(updateClient, me, 'osmosis-1');
      expect(described.kind, ActivityKind.other);
      expect(described.title, 'Update Client');
      expect(described.summary, contains('07-tendermint-1'));
    });

    test('names governance votes', () {
      final described = describeMessage(
        {'@type': '/cosmos.gov.v1beta1.MsgVote', 'proposal_id': '912', 'option': 'VOTE_OPTION_NO_WITH_VETO'},
        me,
        'osmosis-1',
      );
      expect(described.summary, 'Vote no with veto on proposal #912');
      expect(described.kind, ActivityKind.governance);
    });

    test('names a send by its identity, so USDC.n is never Axelar USDC', () {
      final described = describeMessage(
        send(me, other, 'ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4', '12340000'),
        me,
        'osmosis-1',
      );
      expect(described.title, 'Send USDC.n');
      expect(described.summary, 'Send 12.34 USDC.n to ${short(other)}');
    });
  });

  group("a swap's Zunia fee", () {
    const fees = {'osmosis-1': osmoTreasury};
    final swapCall = <String, Object?>{
      '@type': '/cosmwasm.wasm.v1.MsgExecuteContract',
      'sender': me,
      'contract': xcs,
      'msg': {
        'osmosis_swap': {'output_denom': 'uatom', 'receiver': hubSender, 'on_failed_delivery': 'do_nothing'},
      },
      'funds': [
        {'denom': 'uosmo', 'amount': '62685000'},
      ],
    };

    test('reads a send to the treasury inside a swap as Zunia fee', () {
      final fee = send(me, osmoTreasury, 'uosmo', '315000');
      final described = describeMessage(fee, me, 'osmosis-1', swapTx: true, feeRecipients: fees);
      expect(described.title, 'Zunia fee');
      expect(described.zuniaFee, isTrue);
      expect(described.amount, '-315000');
      expect(described.summary, 'Zunia fee: 0.315 OSMO to ${short(osmoTreasury)}');
    });

    test('leaves every other send a send', () {
      final fee = send(me, osmoTreasury, 'uosmo', '315000');
      expect(describeMessage(fee, me, 'osmosis-1', feeRecipients: fees).title, 'Send OSMO');
      expect(
        describeMessage(send(me, other, 'uosmo', '1'), me, 'osmosis-1', swapTx: true, feeRecipients: fees).title,
        'Send OSMO',
      );
      expect(describeMessage(fee, me, 'osmosis-1', swapTx: true).title, 'Send OSMO');
    });

    test('finds a swap whichever way it was signed, and nothing else', () {
      expect(isSwapTx([swapCall, send(me, osmoTreasury, 'uosmo', '1')]), isTrue);
      expect(
        isSwapTx([
          {
            '@type': '/ibc.applications.transfer.v1.MsgTransfer',
            'memo': jsonEncode({
              'wasm': {
                'contract': xcs,
                'msg': {'osmosis_swap': {}},
              },
            }),
          },
        ]),
        isTrue,
      );
      expect(
        isSwapTx([
          {
            '@type': '/osmosis.poolmanager.v1beta1.MsgSwapExactAmountIn',
            'token_in': {'denom': 'uosmo', 'amount': '1'},
          },
        ]),
        isTrue,
      );
      expect(isSwapTx([send(me, other, 'uosmo', '1')]), isFalse);
    });

    test('a swap transaction lists its fee as its own line in the detail', () {
      final detail = parseTxDetail(
        {
          'tx': {
            'body': {
              'memo': '',
              'messages': [swapCall, send(me, osmoTreasury, 'uosmo', '315000')],
            },
            'auth_info': {
              'fee': {
                'amount': [
                  {'denom': 'uosmo', 'amount': '5000'},
                ],
              },
            },
          },
          'tx_response': {'txhash': 'ABC', 'code': 0, 'timestamp': '2026-09-01T10:00:00Z'},
        },
        'osmosis-1',
        me,
        feeRecipients: fees,
      )!;
      expect(detail.swap, isTrue);
      expect(detail.zuniaFees, hasLength(1));
      expect(detail.zuniaFees.single.amount, '-315000');
    });
  });

  group('parseTxDetail', () {
    Map<String, Object?> body(int code, [String rawLog = '']) => {
          'tx': {
            'body': {
              'memo': 'rent',
              'messages': [
                {
                  '@type': '/ibc.applications.transfer.v1.MsgTransfer',
                  'source_channel': 'channel-0',
                  'receiver': hubSender,
                  'token': {'denom': 'uosmo', 'amount': '1000000'},
                },
              ],
            },
            'auth_info': {
              'fee': {
                'amount': [
                  {'denom': 'uosmo', 'amount': '5000'},
                ],
              },
            },
          },
          'tx_response': {
            'txhash': 'ABC',
            'height': '123456',
            'code': code,
            'raw_log': rawLog,
            'timestamp': '2026-09-01T10:00:00Z',
            'gas_wanted': '200000',
            'gas_used': '150000',
            'events': [
              {
                'type': 'send_packet',
                'attributes': [
                  {'key': 'packet_sequence', 'value': '7'},
                  {'key': 'packet_src_port', 'value': 'transfer'},
                  {'key': 'packet_src_channel', 'value': 'channel-0'},
                  {'key': 'packet_dst_port', 'value': 'transfer'},
                  {'key': 'packet_dst_channel', 'value': 'channel-141'},
                ],
              },
            ],
          },
        };

    test('reads the real fee, gas, memo, messages and the packets sent', () {
      final detail = parseTxDetail(body(0), 'osmosis-1', me)!;
      expect(detail.success, isTrue);
      expect(detail.error, isNull);
      expect(detail.memo, 'rent');
      expect(detail.height, '123456');
      expect(detail.timestamp, DateTime.parse('2026-09-01T10:00:00Z'));
      expect(detail.gasUsed, '150000');
      expect(detail.gasWanted, '200000');
      expect(detail.fee, hasLength(1));
      expect(
        formatTokenAmount(detail.fee.single.amount, detail.fee.single.scale, TokenAmountVariant.confirm, unit: true),
        '0.005 OSMO',
      );
      final message = detail.messages.single;
      expect(message.type, 'MsgTransfer');
      expect(message.described.title, 'Send OSMO over IBC');
      expect(message.described.summary, 'Send 1 OSMO over IBC to ${short(hubSender)} on channel-0');
      expect(detail.packets, hasLength(1));
      expect(detail.packets.single.sourceChannelId, 'channel-0');
    });

    test("keeps the chain's reason for a failure and no packets", () {
      final detail = parseTxDetail(body(5, 'insufficient funds'), 'osmosis-1', me)!;
      expect(detail.success, isFalse);
      expect(detail.error, 'insufficient funds');
      expect(detail.packets, isEmpty);
    });

    test('returns null for a body with no transaction in it', () {
      expect(parseTxDetail({'code': 5, 'message': 'tx not found'}, 'osmosis-1', me), isNull);
    });
  });

  group('history rows', () {
    ActivityItem row(Map<String, Object?> message, {int code = 0}) => activityFromTxResponse(
          {
            'txhash': 'H',
            'code': code,
            'timestamp': '2026-09-01T10:00:00Z',
            'tx': {
              'body': {
                'messages': [message],
              },
            },
          },
          'osmosis-1',
          me,
        )!;

    test('carry a signed amount in the coin the title names', () {
      final sent = row(send(me, other, 'uosmo', '1500000'));
      expect(activityAmountText(sent), '-1.5 OSMO');
      final received = row(send(other, me, 'uosmo', '1500000'));
      expect(activityAmountText(received), '+1.5 OSMO');
      expect(activityAmountText(received, hidden: true), maskedAmount);
      final unnamed = row(send(me, other, voucher, '12340000'));
      expect(activityAmountText(unnamed), '-12340000 base units ibc/0123…ABCDEF');
    });

    test('a failed transaction reads as failed', () {
      expect(row(send(me, other, 'uosmo', '1'), code: 13).success, isFalse);
    });

    test('fall under the filters the screen offers', () {
      final sent = row(send(me, other, 'uosmo', '1'));
      final received = row(send(other, me, 'uosmo', '1'));
      final ibcOut = row({
        '@type': '/ibc.applications.transfer.v1.MsgTransfer',
        'source_channel': 'channel-0',
        'receiver': hubSender,
        'token': {'denom': 'uosmo', 'amount': '1'},
      });
      final ibcIn = row(recvPacket(me, 'transfer/channel-141/uosmo', '1'));
      final claim = row({'@type': '/cosmos.distribution.v1beta1.MsgWithdrawDelegatorReward', 'validator_address': 'v'});
      final stake = row({
        '@type': '/cosmos.staking.v1beta1.MsgDelegate',
        'validator_address': 'v',
        'amount': {'denom': 'uosmo', 'amount': '1'},
      });
      final vote = row({'@type': '/cosmos.gov.v1beta1.MsgVote', 'proposal_id': '1', 'option': 'VOTE_OPTION_YES'});

      List<ActivityItem> under(ActivityFilter filter) => [
            for (final item in [sent, received, ibcOut, ibcIn, claim, stake, vote])
              if (activityMatches(item, filter)) item,
          ];
      expect(under(ActivityFilter.all), hasLength(7));
      expect(under(ActivityFilter.sent), [sent, ibcOut]);
      expect(under(ActivityFilter.received), [received, ibcIn]);
      expect(under(ActivityFilter.ibc), [ibcOut, ibcIn]);
      expect(under(ActivityFilter.staking), [claim, stake]);
      expect(under(ActivityFilter.claim), [claim]);
      expect(under(ActivityFilter.governance), [vote]);
      expect(under(ActivityFilter.swap), isEmpty);
      expect(activitySearchMatches(sent, 'osmo send'), isTrue);
      expect(activitySearchMatches(sent, 'atom'), isFalse);
    });
  });

  group('explorer links', () {
    setUp(() => setBundledLinks(
          explorers: {'osmosis-1': 'https://www.mintscan.io/osmosis/transactions/{hash}'},
          treasuries: {
            'osmosis-1': osmoTreasury,
            'cosmoshub-4': osmoTreasury,
            'not-a-chain': osmoTreasury,
          },
        ));

    test('fill the registry template and encode the hash', () {
      expect(explorerTxUrl('osmosis-1', 'ABC123'), 'https://www.mintscan.io/osmosis/transactions/ABC123');
      expect(explorerTxUrl('osmosis-1', 'a/b'), 'https://www.mintscan.io/osmosis/transactions/a%2Fb');
      expect(explorerTxUrl('unknown-1', 'ABC'), isNull);
    });

    test('a treasury counts only under its own chain prefix', () {
      expect(swapFeeRecipients, {'osmosis-1': osmoTreasury});
    });
  });
}
