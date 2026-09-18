/// Amino StdSignDoc + TxRaw assembly for wallet-originated txs.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zunia_mobile/crypto/proto_writer.dart';

const signModeLegacyAminoJson = 127;

typedef Coin = ({String denom, String amount});

class AminoMsg {
  const AminoMsg({required this.type, required this.value});
  final String type;
  final Map<String, dynamic> value;
}

class StdFee {
  const StdFee({required this.amount, required this.gas});
  final List<Coin> amount;
  final String gas;

  Map<String, dynamic> toJson() => {
        'amount': [
          for (final c in amount) {'amount': c.amount, 'denom': c.denom},
        ],
        'gas': gas,
      };
}

class StdSignDoc {
  const StdSignDoc({
    required this.accountNumber,
    required this.chainId,
    required this.fee,
    required this.memo,
    required this.msgs,
    required this.sequence,
  });

  final String accountNumber;
  final String chainId;
  final StdFee fee;
  final String memo;
  final List<AminoMsg> msgs;
  final String sequence;

  Map<String, dynamic> toJson() => {
        'account_number': accountNumber,
        'chain_id': chainId,
        'fee': fee.toJson(),
        'memo': memo,
        'msgs': [
          for (final m in msgs) {'type': m.type, 'value': m.value},
        ],
        'sequence': sequence,
      };
}

AminoMsg msgSend({
  required String fromAddress,
  required String toAddress,
  required List<Coin> amount,
}) =>
    AminoMsg(
      type: 'cosmos-sdk/MsgSend',
      value: {
        'from_address': fromAddress,
        'to_address': toAddress,
        'amount': [
          for (final c in amount) {'amount': c.amount, 'denom': c.denom},
        ],
      },
    );

AminoMsg msgDelegate({
  required String delegatorAddress,
  required String validatorAddress,
  required Coin amount,
}) =>
    AminoMsg(
      type: 'cosmos-sdk/MsgDelegate',
      value: {
        'delegator_address': delegatorAddress,
        'validator_address': validatorAddress,
        'amount': {'amount': amount.amount, 'denom': amount.denom},
      },
    );

AminoMsg msgWithdrawReward({
  required String delegatorAddress,
  required String validatorAddress,
}) =>
    AminoMsg(
      type: 'cosmos-sdk/MsgWithdrawDelegationReward',
      value: {
        'delegator_address': delegatorAddress,
        'validator_address': validatorAddress,
      },
    );

AminoMsg msgVote({
  required String proposalId,
  required String voter,
  required String option,
}) {
  const map = {
    'Yes': 'VOTE_OPTION_YES',
    'No': 'VOTE_OPTION_NO',
    'Veto': 'VOTE_OPTION_NO_WITH_VETO',
    'Abstain': 'VOTE_OPTION_ABSTAIN',
  };
  return AminoMsg(
    type: 'cosmos-sdk/MsgVote',
    value: {
      'proposal_id': proposalId,
      'voter': voter,
      'option': map[option] ?? 'VOTE_OPTION_YES',
    },
  );
}

/// `wasm/MsgExecuteContract`.
///
/// Added for crosschain-swap recovery: when a swap succeeds but the outbound
/// delivery fails, the output sits in the Osmosis contract and only the
/// `local_recovery_addr` can pull it out with `{"recover":{}}`. Without this
/// message the wallet could see stranded funds and do nothing about them.
///
/// `msg` is the ExecuteMsg as a JSON object in amino form; the proto encoder
/// below base64s the same bytes into field 3, which is the shape the chain
/// expects. Getting those two out of step is the classic CosmWasm signing bug,
/// so both live here.
AminoMsg msgExecuteContract({
  required String sender,
  required String contract,
  required Map<String, dynamic> msg,
  List<Coin> funds = const [],
}) =>
    AminoMsg(
      type: 'wasm/MsgExecuteContract',
      value: {
        'sender': sender,
        'contract': contract,
        'msg': msg,
        'funds': [
          for (final c in funds) {'denom': c.denom, 'amount': c.amount},
        ],
      },
    );

AminoMsg msgIbcTransfer({
  required String sourceChannel,
  required Coin token,
  required String sender,
  required String receiver,
  required String timeoutTimestamp,
  String sourcePort = 'transfer',
  String? memo,
}) {
  final value = <String, dynamic>{
    'source_port': sourcePort,
    'source_channel': sourceChannel,
    'token': {'amount': token.amount, 'denom': token.denom},
    'sender': sender,
    'receiver': receiver,
    'timeout_timestamp': timeoutTimestamp,
  };
  if (memo != null && memo.isNotEmpty) value['memo'] = memo;
  return AminoMsg(type: 'cosmos-sdk/MsgTransfer', value: value);
}

StdFee estimateFee({
  required int gasLimit,
  required double gasPrice,
  required String denom,
}) {
  final amount = (gasLimit * gasPrice).ceil().clamp(1, 1 << 62);
  return StdFee(
    amount: [(denom: denom, amount: amount.toString())],
    gas: gasLimit.toString(),
  );
}

StdSignDoc makeStdSignDoc({
  required String chainId,
  required String accountNumber,
  required String sequence,
  required StdFee fee,
  required List<AminoMsg> msgs,
  String memo = '',
}) =>
    StdSignDoc(
      accountNumber: accountNumber,
      chainId: chainId,
      fee: fee,
      memo: memo,
      msgs: msgs,
      sequence: sequence,
    );

dynamic _sortKeysDeep(dynamic value) {
  if (value is List) return value.map(_sortKeysDeep).toList();
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {
      for (final k in keys) k: _sortKeysDeep(value[k]),
    };
  }
  return value;
}

Uint8List serializeAminoSignDoc(StdSignDoc doc) {
  final sorted = _sortKeysDeep(doc.toJson());
  return Uint8List.fromList(utf8.encode(jsonEncode(sorted)));
}

Uint8List _encodeCoin(Coin coin) =>
    ProtoWriter().string(1, coin.denom).string(2, coin.amount).intoBytes();

Uint8List _encodeAny(String typeUrl, Uint8List value) =>
    ProtoWriter().string(1, typeUrl).bytes(2, value).intoBytes();

({String typeUrl, Uint8List value}) _encodeMsgProto(AminoMsg msg) {
  final v = msg.value;
  switch (msg.type) {
    case 'cosmos-sdk/MsgSend':
      final amount = (v['amount'] as List<dynamic>? ?? const [])
          .map(
            (c) => (
              denom: (c as Map)['denom'] as String,
              amount: c['amount'] as String,
            ),
          )
          .toList();
      return (
        typeUrl: '/cosmos.bank.v1beta1.MsgSend',
        value: ProtoWriter()
            .string(1, v['from_address'] as String? ?? '')
            .string(2, v['to_address'] as String? ?? '')
            .repeatedMessage(3, [for (final c in amount) _encodeCoin(c)])
            .intoBytes(),
      );
    case 'cosmos-sdk/MsgDelegate':
      final amount = v['amount'] as Map;
      return (
        typeUrl: '/cosmos.staking.v1beta1.MsgDelegate',
        value: ProtoWriter()
            .string(1, v['delegator_address'] as String? ?? '')
            .string(2, v['validator_address'] as String? ?? '')
            .messageAlways(
              3,
              _encodeCoin((
                denom: amount['denom'] as String,
                amount: amount['amount'] as String,
              )),
            )
            .intoBytes(),
      );
    case 'cosmos-sdk/MsgWithdrawDelegationReward':
      return (
        typeUrl: '/cosmos.distribution.v1beta1.MsgWithdrawDelegatorReward',
        value: ProtoWriter()
            .string(1, v['delegator_address'] as String? ?? '')
            .string(2, v['validator_address'] as String? ?? '')
            .intoBytes(),
      );
    case 'cosmos-sdk/MsgVote':
      const options = {
        'VOTE_OPTION_YES': 1,
        'VOTE_OPTION_ABSTAIN': 2,
        'VOTE_OPTION_NO': 3,
        'VOTE_OPTION_NO_WITH_VETO': 4,
      };
      final option = options[v['option']] ?? 0;
      return (
        typeUrl: '/cosmos.gov.v1beta1.MsgVote',
        value: ProtoWriter()
            .uint64(1, BigInt.parse(v['proposal_id'] as String? ?? '0'))
            .string(2, v['voter'] as String? ?? '')
            .int32(3, option)
            .intoBytes(),
      );
    case 'cosmos-sdk/MsgTransfer':
      final token = v['token'] as Map;
      return (
        typeUrl: '/ibc.applications.transfer.v1.MsgTransfer',
        value: ProtoWriter()
            .string(1, v['source_port'] as String? ?? 'transfer')
            .string(2, v['source_channel'] as String? ?? '')
            .messageAlways(
              3,
              _encodeCoin((
                denom: token['denom'] as String,
                amount: token['amount'] as String,
              )),
            )
            .string(4, v['sender'] as String? ?? '')
            .string(5, v['receiver'] as String? ?? '')
            .messageAlways(6, ProtoWriter().intoBytes())
            .uint64(
              7,
              BigInt.parse(v['timeout_timestamp'] as String? ?? '0'),
            )
            .string(8, v['memo'] as String? ?? '')
            .intoBytes(),
      );
    case 'wasm/MsgExecuteContract':
      final funds = (v['funds'] as List<dynamic>? ?? const [])
          .map(
            (c) => (
              denom: (c as Map)['denom'] as String,
              amount: c['amount'] as String,
            ),
          )
          .toList();
      return (
        typeUrl: '/cosmwasm.wasm.v1.MsgExecuteContract',
        value: ProtoWriter()
            .string(1, v['sender'] as String? ?? '')
            .string(2, v['contract'] as String? ?? '')
            // Field 3 is `bytes`: the same JSON the amino doc carries, encoded
            // as UTF-8. Amino spells it as an object and proto as bytes, and
            // they must be the same bytes or the signature covers a different
            // message than the one the chain executes.
            .bytes(3, Uint8List.fromList(utf8.encode(jsonEncode(v['msg']))))
            .repeatedMessage(5, [for (final c in funds) _encodeCoin(c)])
            .intoBytes(),
      );
    default:
      throw StateError('Unsupported amino message: ${msg.type}');
  }
}

Uint8List assembleAminoTxRaw({
  required StdSignDoc signDoc,
  required Uint8List pubKey,
  required Uint8List signature,
}) {
  if (signature.length != 64) {
    throw ArgumentError('Signature must be 64-byte compact secp256k1 r||s');
  }
  final anys = [
    for (final msg in signDoc.msgs)
      () {
        final encoded = _encodeMsgProto(msg);
        return _encodeAny(encoded.typeUrl, encoded.value);
      }(),
  ];
  final body =
      ProtoWriter().repeatedMessage(1, anys).string(2, signDoc.memo).intoBytes();

  final feeCoins = [
    for (final c in signDoc.fee.amount) _encodeCoin(c),
  ];
  final fee = ProtoWriter()
      .repeatedMessage(1, feeCoins)
      .uint64(2, BigInt.parse(signDoc.fee.gas))
      .intoBytes();

  final pubkeyInner = ProtoWriter().bytes(1, pubKey).intoBytes();
  final pubkeyAny =
      _encodeAny('/cosmos.crypto.secp256k1.PubKey', pubkeyInner);
  final single =
      ProtoWriter().int32(1, signModeLegacyAminoJson).intoBytes();
  final modeInfo = ProtoWriter().messageAlways(1, single).intoBytes();
  final signerInfo = ProtoWriter()
      .message(1, pubkeyAny)
      .message(2, modeInfo)
      .uint64(3, BigInt.parse(signDoc.sequence))
      .intoBytes();
  final authInfo = ProtoWriter()
      .repeatedMessage(1, [signerInfo])
      .message(2, fee)
      .intoBytes();

  return ProtoWriter()
      .bytes(1, body)
      .bytes(2, authInfo)
      .repeatedMessage(3, [signature])
      .intoBytes();
}

String defaultIbcTimeoutNs({int minutes = 10}) {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final ns = BigInt.from(nowMs) * BigInt.from(1000000) +
      BigInt.from(minutes) * BigInt.from(60) * BigInt.from(1000000000);
  return ns.toString();
}
