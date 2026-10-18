/// Transaction messages in the one shape the kernel signs:
/// `{ "typeUrl": ..., "value": { snake_case fields, amounts as strings } }`,
/// the same envelope `@zunialab/interchain` emits for the extension.
library;

import 'dart:convert';

import 'package:zunia_mobile/crypto/amino_tx.dart';

class TxCoin {
  const TxCoin(this.denom, this.amount);

  final String denom;

  /// Base units, as a decimal string: never a double.
  final String amount;

  Map<String, String> toJson() => {'denom': denom, 'amount': amount};
}

class TxMsg {
  const TxMsg(this.typeUrl, this.value);

  final String typeUrl;
  final Map<String, dynamic> value;

  Map<String, dynamic> toJson() => {'typeUrl': typeUrl, 'value': value};

  static const sendType = '/cosmos.bank.v1beta1.MsgSend';
  static const delegateType = '/cosmos.staking.v1beta1.MsgDelegate';
  static const undelegateType = '/cosmos.staking.v1beta1.MsgUndelegate';
  static const redelegateType = '/cosmos.staking.v1beta1.MsgBeginRedelegate';
  static const withdrawRewardType =
      '/cosmos.distribution.v1beta1.MsgWithdrawDelegatorReward';
  static const voteType = '/cosmos.gov.v1beta1.MsgVote';
  static const transferType = '/ibc.applications.transfer.v1.MsgTransfer';
  static const executeContractType = '/cosmwasm.wasm.v1.MsgExecuteContract';
  static const swapExactInType =
      '/osmosis.poolmanager.v1beta1.MsgSwapExactAmountIn';
  static const splitRouteSwapType =
      '/osmosis.poolmanager.v1beta1.MsgSplitRouteSwapExactAmountIn';

  factory TxMsg.send({
    required String from,
    required String to,
    required List<TxCoin> amount,
  }) =>
      TxMsg(sendType, {
        'from_address': from,
        'to_address': to,
        'amount': [for (final c in amount) c.toJson()],
      });

  factory TxMsg.delegate({
    required String delegator,
    required String validator,
    required TxCoin amount,
  }) =>
      TxMsg(delegateType, {
        'delegator_address': delegator,
        'validator_address': validator,
        'amount': amount.toJson(),
      });

  factory TxMsg.undelegate({
    required String delegator,
    required String validator,
    required TxCoin amount,
  }) =>
      TxMsg(undelegateType, {
        'delegator_address': delegator,
        'validator_address': validator,
        'amount': amount.toJson(),
      });

  factory TxMsg.redelegate({
    required String delegator,
    required String sourceValidator,
    required String destinationValidator,
    required TxCoin amount,
  }) =>
      TxMsg(redelegateType, {
        'delegator_address': delegator,
        'validator_src_address': sourceValidator,
        'validator_dst_address': destinationValidator,
        'amount': amount.toJson(),
      });

  factory TxMsg.withdrawReward({
    required String delegator,
    required String validator,
  }) =>
      TxMsg(withdrawRewardType, {
        'delegator_address': delegator,
        'validator_address': validator,
      });

  /// [option] 1 Yes, 2 Abstain, 3 No, 4 No with veto: chains verify the
  /// number, so that is what is signed.
  factory TxMsg.vote({
    required String voter,
    required String proposalId,
    required int option,
  }) =>
      TxMsg(voteType, {
        'proposal_id': proposalId,
        'voter': voter,
        'option': option,
      });

  /// [timeoutTimestampNanos] is absolute, in nanoseconds since the epoch.
  factory TxMsg.transfer({
    required String sourcePort,
    required String sourceChannel,
    required TxCoin token,
    required String sender,
    required String receiver,
    required String timeoutTimestampNanos,
    String memo = '',
  }) =>
      TxMsg(transferType, {
        'source_port': sourcePort,
        'source_channel': sourceChannel,
        'token': token.toJson(),
        'sender': sender,
        'receiver': receiver,
        'timeout_height': const <String, dynamic>{},
        'timeout_timestamp': timeoutTimestampNanos,
        if (memo.isNotEmpty) 'memo': memo,
      });

  /// [msg] is the contract's JSON message; it travels as base64 of its UTF-8
  /// bytes, which is what the kernel reads.
  factory TxMsg.executeContract({
    required String sender,
    required String contract,
    required Map<String, dynamic> msg,
    List<TxCoin> funds = const [],
  }) =>
      TxMsg(executeContractType, {
        'sender': sender,
        'contract': contract,
        'msg': base64Encode(utf8.encode(jsonEncode(msg))),
        'funds': [for (final c in funds) c.toJson()],
      });

  /// The same message from the Amino builders older screens use.
  factory TxMsg.fromAmino(AminoMsg msg) {
    final v = msg.value;
    switch (msg.type) {
      case 'cosmos-sdk/MsgSend':
        return TxMsg(sendType, {
          'from_address': v['from_address'],
          'to_address': v['to_address'],
          'amount': v['amount'],
        });
      case 'cosmos-sdk/MsgDelegate':
        return TxMsg(delegateType, {
          'delegator_address': v['delegator_address'],
          'validator_address': v['validator_address'],
          'amount': v['amount'],
        });
      case 'cosmos-sdk/MsgUndelegate':
        return TxMsg(undelegateType, {
          'delegator_address': v['delegator_address'],
          'validator_address': v['validator_address'],
          'amount': v['amount'],
        });
      case 'cosmos-sdk/MsgWithdrawDelegationReward':
        return TxMsg(withdrawRewardType, {
          'delegator_address': v['delegator_address'],
          'validator_address': v['validator_address'],
        });
      case 'cosmos-sdk/MsgVote':
        return TxMsg(voteType, {
          'proposal_id': '${v['proposal_id']}',
          'voter': v['voter'],
          'option': v['option'],
        });
      case 'wasm/MsgExecuteContract':
        final inner = v['msg'];
        return TxMsg(executeContractType, {
          'sender': v['sender'],
          'contract': v['contract'],
          'msg': inner is String
              ? inner
              : base64Encode(utf8.encode(jsonEncode(inner))),
          'funds': v['funds'] ?? const [],
        });
      case 'cosmos-sdk/MsgTransfer':
        final height = v['timeout_height'];
        return TxMsg(transferType, {
          'source_port': v['source_port'],
          'source_channel': v['source_channel'],
          'token': v['token'],
          'sender': v['sender'],
          'receiver': v['receiver'],
          'timeout_height':
              height is Map ? height : const <String, dynamic>{},
          'timeout_timestamp': '${v['timeout_timestamp'] ?? '0'}',
          if ((v['memo'] as String? ?? '').isNotEmpty) 'memo': v['memo'],
        });
    }
    throw ArgumentError('No kernel message for Amino type ${msg.type}');
  }
}
