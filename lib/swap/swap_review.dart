/// What a reviewed swap signs, and the checks that it signs that and nothing
/// else.
///
/// Port of the message half of zunia-extension 0.1.5
/// `entrypoints/popup/screens/SwapScreen.tsx`: the messages each path signs
/// ([swapTxMsgs], [poolSwapTxMsgs]), what those messages say read back from
/// the messages themselves ([readSwapMessage], `readPoolSwapMsg`,
/// `readSwapFeeMsg`), everything they do that the review did not say
/// ([swapTermsProblems], [poolSwapTermsProblems]), whether the review still
/// stands ([reviewDrift]), and why the Sign button is off ([swapSignBlock]).
///
/// Message order, the same as the extension:
/// - contract path: `[swap, fee?]`, the swap being a `MsgTransfer` whose memo
///   calls the contract, or a `MsgExecuteContract` on Osmosis;
/// - pools: `[poolmanager swap, fee?, MsgTransfer?]`.
///
/// With no fee due the transaction is exactly the swap's own messages, byte
/// for byte what it was before the commission existed.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:zunia_mobile/services/interchain/memo.dart';
import 'package:zunia_mobile/services/interchain/swap.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/swap/pool_swap.dart';
import 'package:zunia_mobile/swap/swap_amounts.dart';
import 'package:zunia_mobile/swap/swap_assets.dart';
import 'package:zunia_mobile/swap/swap_fee.dart';
import 'package:zunia_mobile/swap/swap_path.dart';
import 'package:zunia_mobile/swap/swap_tokens.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

const String executeContractTypeUrl = '/cosmwasm.wasm.v1.MsgExecuteContract';

/// Said, and signing refused, when the message cannot be read whole.
const String unreadableSwap =
    'Zunia could not read what this swap message does, so it will not ask you to sign it.';

/// Said, and signing refused, when the transaction carries more than the swap
/// and its fee.
const String extraMessages =
    'This transaction carries more than the swap and the Zunia fee, so Zunia will not ask you to sign it.';

/// Said, and signing refused, when the transfer after the swap cannot be read.
const String unreadableDelivery =
    "Zunia could not read the transfer that sends the swap's output on, so it will not ask you to sign it.";

/// The `by Zunia-wallet` tag every default memo ends with.
const String zuniaWalletTag = 'by Zunia-wallet';

String _short(String address) => address.length > 22
    ? '${address.substring(0, 10)}…${address.substring(address.length - 8)}'
    : address;

String _shortDenom(String denom) {
  if (denom.startsWith('ibc/') && denom.length > 12) {
    return 'ibc/${denom.substring(4, 10)}…';
  }
  if (denom.startsWith('factory/')) return denom.split('/').last;
  return denom.length > 24 ? '${denom.substring(0, 20)}…' : denom;
}

/* -------------------------------------------------------------------------- *
 * Reviews
 * -------------------------------------------------------------------------- */

/// A price for a reviewed swap, or why there is none, and when it came.
@immutable
class SwapPrice {
  const SwapPrice({this.quote, this.error, this.code, required this.at});

  final OsmosisSwapQuote? quote;
  final String? error;

  /// Which known reason [error] is.
  final String? code;
  final DateTime at;
}

/// Whether a price is missing or older than a quote lives, at [now].
bool priceExpired(SwapPrice price, DateTime now, Duration ttl) =>
    price.quote == null || now.difference(price.at) >= ttl;

/// What prices a contract plan again: its venue denoms, the amount and the
/// slippage. The memo carries a TWAP tolerance rather than a minimum, so a
/// new price never changes the message.
@immutable
class VenueQuoteInput {
  const VenueQuoteInput({
    required this.contract,
    required this.venueInputDenom,
    required this.venueOutputDenom,
    required this.amountBaseUnits,
    required this.slippagePercent,
  });

  final String contract;
  final String venueInputDenom;
  final String venueOutputDenom;
  final String amountBaseUnits;
  final double slippagePercent;
}

/// The transfer that sends a `pool-deliver` swap's floor on: one direct hop,
/// no memo, over a channel the planner checked.
@immutable
class PoolDelivery {
  const PoolDelivery({
    required this.sourceChannel,
    required this.destChainId,
    required this.arrivalDenom,
    this.port = 'transfer',
  });

  final String sourceChannel;
  final String port;
  final String destChainId;

  /// What arrives on [destChainId]: exactly the To row's denom.
  final String arrivalDenom;

  /// The plan the packet tracker follows.
  RoutePlan planFor(
    String venueChainId,
    String venueOutputDenom,
    int timeoutMinutes,
  ) => RoutePlan(
    sourceChainId: venueChainId,
    destChainId: destChainId,
    inputDenom: venueOutputDenom,
    outputDenom: arrivalDenom,
    hops: [
      RouteHop(
        chainId: venueChainId,
        channelId: sourceChannel,
        port: port,
        counterpartyChainId: destChainId,
        kind: RouteHopKind.transfer,
      ),
    ],
    memo: '',
    warnings: const [],
    estimatedDurationSeconds: 60,
    requiresPfm: false,
    requiresIbcHooks: false,
  );

  @override
  bool operator ==(Object other) =>
      other is PoolDelivery &&
      other.sourceChannel == sourceChannel &&
      other.port == port &&
      other.destChainId == destChainId &&
      other.arrivalDenom == arrivalDenom;

  @override
  int get hashCode =>
      Object.hash(sourceChannel, port, destChainId, arrivalDenom);
}

/// The swap as the user reviewed it, captured when the confirm screen opens.
/// The form keeps moving underneath; the confirm screen draws only from this
/// and signs only the messages built from it.
@immutable
sealed class SwapReview {
  const SwapReview({
    required this.id,
    required this.from,
    required this.to,
    required this.amountUnits,
    required this.fee,
    required this.planKey,
    required this.signer,
    required this.recipient,
    required this.price,
  });

  /// Tells one review from the next, so a late price never lands on another.
  final int id;
  final SwapAsset from;
  final SwapAsset to;

  /// Base units spent in all: the amount typed (or Max), the fee included.
  final BigInt amountUnits;

  /// The Zunia fee on [amountUnits]; the swap sells `fee.net`.
  final SwapFee fee;
  final String planKey;

  /// The account that signs.
  final String signer;

  /// Where the output ends up.
  final String recipient;
  final SwapPrice price;

  SwapPath get path;
}

/// A swap through the crosschain-swaps contract.
final class ContractSwapReview extends SwapReview {
  const ContractSwapReview({
    required super.id,
    required super.from,
    required super.to,
    required super.amountUnits,
    required super.fee,
    required super.planKey,
    required super.signer,
    required super.recipient,
    required super.price,
    required this.plan,
    required this.receiver,
    required this.requote,
    required this.recoveryAddress,
    required this.contract,
    required this.contractLabel,
    required this.ownAddresses,
  });

  /// The plan the message was built from, and the one tracking follows.
  final RoutePlan plan;

  /// The ICS20 receiver: the contract, as ibc-hooks requires.
  final String receiver;
  final VenueQuoteInput requote;

  /// `local_recovery_addr`: this wallet's address on Osmosis.
  final String recoveryAddress;

  /// The contract the venue check verified on chain.
  final String contract;
  final String? contractLabel;

  /// This wallet's own address on the other chains the route crosses.
  final Map<String, String> ownAddresses;

  bool get venueOrigin =>
      plan.hops.isNotEmpty && plan.hops.first.kind == RouteHopKind.swap;

  @override
  SwapPath get path => SwapPath.contract;

  ContractSwapReview withPrice(SwapPrice next) => ContractSwapReview(
    id: id,
    from: from,
    to: to,
    amountUnits: amountUnits,
    fee: fee,
    planKey: planKey,
    signer: signer,
    recipient: recipient,
    price: next,
    plan: plan,
    receiver: receiver,
    requote: requote,
    recoveryAddress: recoveryAddress,
    contract: contract,
    contractLabel: contractLabel,
    ownAddresses: ownAddresses,
  );
}

/// A swap in Osmosis's own pools, the `pool` and `pool-deliver` paths. The
/// floor is a number in the message, so a new price is a new message.
final class PoolSwapReview extends SwapReview {
  const PoolSwapReview({
    required super.id,
    required super.from,
    required super.to,
    required super.amountUnits,
    required super.fee,
    required super.planKey,
    required super.signer,
    required super.recipient,
    required super.price,
    required this.poolPath,
    required this.venueOutputDenom,
    required this.slippagePercent,
    required this.routes,
    required this.minOut,
    required this.delivery,
  });

  final SwapPath poolPath;

  /// What the swap buys, as Osmosis names it.
  final String venueOutputDenom;
  final double slippagePercent;

  /// The router's order for `fee.net`.
  final List<PoolRoute> routes;

  /// `token_out_min_amount`, and what a delivery sends on.
  final String minOut;

  /// The checked transfer that sends [minOut] on; null for `pool`.
  final PoolDelivery? delivery;

  @override
  SwapPath get path => poolPath;

  PoolSwapReview withPrice({
    required SwapPrice price,
    required List<PoolRoute> routes,
    required String minOut,
  }) => PoolSwapReview(
    id: id,
    from: from,
    to: to,
    amountUnits: amountUnits,
    fee: fee,
    planKey: planKey,
    signer: signer,
    recipient: recipient,
    price: price,
    poolPath: poolPath,
    venueOutputDenom: venueOutputDenom,
    slippagePercent: slippagePercent,
    routes: routes,
    minOut: minOut,
    delivery: delivery,
  );
}

/* -------------------------------------------------------------------------- *
 * The messages
 * -------------------------------------------------------------------------- */

/// Nanoseconds since the epoch, [minutes] from [now].
String ibcTimeoutNanos(DateTime now, int minutes) =>
    ((BigInt.from(now.microsecondsSinceEpoch) +
                BigInt.from(minutes) * BigInt.from(60000000)) *
            BigInt.from(1000))
        .toString();

/// The execute body of a venue-origin swap: the plan keeps the same
/// `{wasm:{contract,msg}}` an inbound packet would carry, and only
/// `osmosis_swap` is accepted.
({String contract, Map<String, Object?> msg})? venueSwapExecute(String memo) {
  Object? parsed;
  try {
    parsed = jsonDecode(memo);
  } on FormatException {
    return null;
  }
  if (parsed is! Map<String, Object?>) return null;
  final wasm = parsed['wasm'];
  if (wasm is! Map<String, Object?>) return null;
  final contract = wasm['contract'];
  final msg = wasm['msg'];
  if (contract is! String || contract.trim().isEmpty) return null;
  if (msg is! Map<String, Object?>) return null;
  if (msg.length != 1 || msg.keys.first != 'osmosis_swap') return null;
  return (contract: contract, msg: msg);
}

/// The one message a contract plan asks the user to sign. An inbound route is
/// a `MsgTransfer`: the channel from `hops[0]`, the receiver the contract, the
/// memo verbatim. A plan that starts with the swap itself is one
/// `MsgExecuteContract` on the venue with the input coin attached.
TxMsg buildContractSwapMsg({
  required RoutePlan plan,
  required String receiver,
  required String sender,
  required String amount,
  required int timeoutMinutes,
  required DateTime now,
}) {
  final hop = plan.hops.first;
  if (hop.kind == RouteHopKind.swap) {
    final execute = venueSwapExecute(plan.memo);
    if (execute == null) {
      throw ArgumentError(
        'Zunia will not build a contract call that is not osmosis_swap.',
      );
    }
    return TxMsg.executeContract(
      sender: sender,
      contract: execute.contract,
      msg: execute.msg,
      funds: [TxCoin(plan.inputDenom, amount)],
    );
  }
  return TxMsg.transfer(
    sourcePort: hop.port.isEmpty ? 'transfer' : hop.port,
    sourceChannel: hop.channelId,
    token: TxCoin(plan.inputDenom, amount),
    sender: sender,
    receiver: receiver,
    timeoutTimestampNanos: ibcTimeoutNanos(now, timeoutMinutes),
    memo: plan.memo,
  );
}

/// What a reviewed contract swap signs, in order: the swap for what is left
/// after the fee, then the bank send that pays the fee, when one is due.
List<TxMsg> swapTxMsgs({
  required RoutePlan plan,
  required String receiver,
  required String sender,
  required String denom,
  required SwapFee fee,
  required int timeoutMinutes,
  required DateTime now,
}) {
  final swap = buildContractSwapMsg(
    plan: plan,
    receiver: receiver,
    sender: sender,
    amount: fee.net.toString(),
    timeoutMinutes: timeoutMinutes,
    now: now,
  );
  if (!fee.charged) return [swap];
  return [
    swap,
    buildSwapFeeMsg(
      sender: sender,
      recipient: fee.recipient!,
      denom: denom,
      amount: fee.fee,
    ),
  ];
}

/// What a reviewed pool swap signs, in order: the swap of what is left after
/// the fee along the router's routes for at least [minOut]; the fee, when one
/// is due; and for `pool-deliver` the transfer of exactly [minOut] to the
/// To's chain. The transfer comes last because it spends what the swap pays.
List<TxMsg> poolSwapTxMsgs({
  required String sender,
  required String denom,
  required List<PoolRoute> routes,
  required String minOut,
  required SwapFee fee,
  required PoolDelivery? delivery,
  required String recipient,
  required int timeoutMinutes,
  required DateTime now,
}) {
  final msgs = <TxMsg>[
    buildPoolSwapMsg(
      sender: sender,
      denom: denom,
      routes: routes,
      minOut: minOut,
    ),
  ];
  if (fee.charged) {
    msgs.add(
      buildSwapFeeMsg(
        sender: sender,
        recipient: fee.recipient!,
        denom: denom,
        amount: fee.fee,
      ),
    );
  }
  if (delivery != null) {
    final outputDenom = routes.first.hops.last.tokenOutDenom;
    msgs.add(
      TxMsg.transfer(
        sourcePort: delivery.port,
        sourceChannel: delivery.sourceChannel,
        token: TxCoin(outputDenom, minOut),
        sender: sender,
        receiver: recipient,
        timeoutTimestampNanos: ibcTimeoutNanos(now, timeoutMinutes),
      ),
    );
  }
  return msgs;
}

/* -------------------------------------------------------------------------- *
 * What the signed contract message says
 * -------------------------------------------------------------------------- */

/// The swap a contract message asks for, read from the bytes that are signed.
@immutable
class SwapMessageFacts {
  const SwapMessageFacts({
    required this.contractCall,
    required this.sold,
    required this.contract,
    required this.transferReceiver,
    required this.forwardsIn,
    required this.swap,
    required this.forwardsOut,
    required this.warnings,
  });

  /// One `MsgExecuteContract` on Osmosis rather than an ICS20 transfer.
  final bool contractCall;

  /// What leaves the wallet: the call's one coin, or the transfer's token.
  final PoolCoin sold;
  final String contract;

  /// The transfer's ICS20 receiver; null for a contract call.
  final String? transferReceiver;
  final List<ForwardHopInfo> forwardsIn;
  final XcsSwapInfo swap;

  /// Where `next_memo` forwards the output after the swap.
  final ForwardMemoInfo? forwardsOut;
  final List<String> warnings;
}

PoolCoin? _coin(Object? value) {
  if (value is! Map) return null;
  final denom = value['denom'];
  final amount = value['amount'];
  return denom is String &&
          denom.isNotEmpty &&
          amount is String &&
          RegExp(r'^\d+$').hasMatch(amount)
      ? PoolCoin(denom, amount)
      : null;
}

/// The UTF-8 text of standard padded base64, only when encoding it again
/// gives back the same string: the bytes read here are the bytes signed.
String? _base64Utf8(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    final text = utf8.decode(base64.decode(raw));
    return base64.encode(utf8.encode(text)) == raw ? text : null;
  } on FormatException {
    return null;
  }
}

/// What [text] parses to, only when serializing it gives back [text] exactly.
Object? _canonicalJson(String? text) {
  if (text == null) return null;
  try {
    final parsed = jsonDecode(text);
    return jsonEncode(parsed) == text ? parsed : null;
  } on FormatException {
    return null;
  }
}

const Set<String> _swapFields = {
  'output_denom',
  'slippage',
  'receiver',
  'on_failed_delivery',
  'next_memo',
};
const Set<String> _twapFields = {'slippage_percentage', 'window_seconds'};

bool _onlyFields(Object? value, Set<String> fields) =>
    value is Map && value.keys.every(fields.contains);

({
  String contract,
  List<ForwardHopInfo> forwardsIn,
  XcsSwapInfo swap,
  ForwardMemoInfo? forwardsOut,
  List<String> warnings,
})?
_readXcs(String memo, {String? receiver}) {
  final inspection = validateMemo(memo, receiver: receiver);
  final swap = inspection.xcs;
  final wasm = inspection.wasm;
  if (inspection.kind != MemoKind.xcs || swap == null || wasm == null) {
    return null;
  }
  final body = wasm.msg['osmosis_swap'];
  if (body is! Map || !_onlyFields(body, _swapFields)) return null;
  final slippage = body['slippage'];
  final twap = slippage is Map ? slippage['twap'] : null;
  if (twap != null && !_onlyFields(twap, _twapFields)) return null;
  final next = body['next_memo'];
  final warnings = [...inspection.warnings];
  ForwardMemoInfo? forwardsOut;
  if (next != null) {
    if (next is! Map) return null;
    final after = validateMemo(jsonEncode(next));
    final forward = after.forward;
    if (after.kind != MemoKind.forward ||
        forward == null ||
        forward.hasNextMemo) {
      return null;
    }
    forwardsOut = forward;
    warnings.addAll(after.warnings);
  }
  return (
    contract: swap.contract,
    forwardsIn: inspection.forward?.hops ?? const <ForwardHopInfo>[],
    swap: swap,
    forwardsOut: forwardsOut,
    warnings: warnings,
  );
}

/// Read what a swap message will do, from the message itself: a contract
/// call's base64 `msg`, or a transfer's packet memo. Null for any other
/// message, and for one any part of which cannot be read whole.
SwapMessageFacts? readSwapMessage(TxMsg? msg) {
  if (msg == null) return null;
  final value = msg.value;
  if (msg.typeUrl == executeContractTypeUrl) {
    final contract = value['contract'];
    final funds = value['funds'];
    if (contract is! String || contract.isEmpty) return null;
    if (funds is! List || funds.length != 1) return null;
    final sold = _coin(funds.first);
    final body = _canonicalJson(_base64Utf8(value['msg']));
    if (sold == null || body is! Map<String, Object?>) return null;
    final read = _readXcs(
      jsonEncode({
        'wasm': {'contract': contract, 'msg': body},
      }),
    );
    if (read == null) return null;
    return SwapMessageFacts(
      contractCall: true,
      sold: sold,
      contract: read.contract,
      transferReceiver: null,
      forwardsIn: read.forwardsIn,
      swap: read.swap,
      forwardsOut: read.forwardsOut,
      warnings: read.warnings,
    );
  }
  if (msg.typeUrl == transferTypeUrl) {
    final sold = _coin(value['token']);
    final memo = value['memo'];
    final receiver = value['receiver'];
    if (sold == null || memo is! String || receiver is! String) return null;
    if (_canonicalJson(memo) == null) return null;
    final read = _readXcs(memo, receiver: receiver);
    if (read == null) return null;
    return SwapMessageFacts(
      contractCall: false,
      sold: sold,
      contract: read.contract,
      transferReceiver: receiver,
      forwardsIn: read.forwardsIn,
      swap: read.swap,
      forwardsOut: read.forwardsOut,
      warnings: read.warnings,
    );
  }
  return null;
}

/// The chain on which [address] is this wallet's own, as far as the review
/// knows; null when it is none of them.
String? ownerOf(
  String address,
  ContractSwapReview review,
  String venueChainId,
) {
  if (address == review.recipient) return review.to.chainId;
  if (address == review.recoveryAddress) return venueChainId;
  for (final entry in review.ownAddresses.entries) {
    if (entry.value == address) return entry.key;
  }
  return null;
}

/// One way a transaction's fee message is not the fee the review shows, in
/// the words the confirm screen shows.
String swapFeeProblem(
  SwapFeeIssue issue,
  SwapReview review,
  SwapTokenBook book,
) {
  final from = review.from;
  String amount(String units, String denom) {
    final identity = denom == from.denom
        ? from.identity
        : book.identityOf(from.chainId, denom);
    return identity.decimalsKnown
        ? '${swapFieldText(BigInt.parse(units), identity)} ${identity.ticker}'
        : swapTickerAmount(units, identity);
  }

  return switch (issue) {
    SwapFeeUnreadable() =>
      "Zunia could not read the transaction's second message as its fee, so it will not ask you to sign it.",
    SwapFeeNotDue(:final paid) =>
      'Zunia charges no fee on this swap, yet the transaction pays ${amount(paid.amount, paid.denom)} to ${_short(paid.to)}.',
    SwapFeeMissing(:final due) =>
      'The transaction leaves out the ${amount(due.fee.toString(), from.denom)} Zunia fee this review shows.',
    SwapFeeWrongSender(:final paid) =>
      'The Zunia fee would be paid from ${_short(paid.from)}, not from the account signing this swap.',
    SwapFeeWrongRecipient(:final paid) =>
      "The Zunia fee would go to ${_short(paid.to)}, which is not Zunia's fee address on ${from.chainName}.",
    SwapFeeWrongDenom(:final paid) =>
      'The Zunia fee is paid in ${_shortDenom(paid.denom)}, not in the ${from.ticker} you sell.',
    SwapFeeWrongAmount(:final paid, :final due) =>
      'The Zunia fee is ${amount(paid.amount, paid.denom)}, not the ${amount(due.fee.toString(), from.denom)} you reviewed.',
  };
}

List<String> _feeProblems({
  required SwapReview review,
  required TxMsg? feeMsg,
  required String chainId,
  required String signer,
  required SwapFeePolicy policy,
  required SwapTokenBook book,
}) {
  final problems = <String>[];
  // The fee the review shows must be the fee Zunia charges here, worked out
  // again from the configuration; the bank send must pay exactly it.
  final due = policy.feeFor(chainId, review.amountUnits);
  if (review.fee != due) {
    problems.add(
      'The Zunia fee in this review is not the one Zunia charges on ${review.from.chainName}, so Zunia will not ask you to sign it.',
    );
  }
  final issues = policy.issues(
    feeMsg,
    SwapFeeExpectation(
      chainId: chainId,
      signer: signer,
      denom: review.from.denom,
      amountUnits: review.amountUnits,
    ),
  );
  problems.addAll(issues.map((issue) => swapFeeProblem(issue, review, book)));
  return problems;
}

/// Everything a contract swap's transaction does that the review did not say;
/// any of it refuses the signature. Empty when it is exactly the swap message
/// and, when a fee is due, the one bank send that pays it.
List<String> swapTermsProblems(
  SwapMessageFacts? facts,
  ContractSwapReview review, {
  required String chainId,
  required String signerAddress,
  required List<TxMsg> msgs,
  required SwapFeePolicy policy,
  required SwapTokenBook book,
  required String venueChainId,
}) {
  if (facts == null) return const [unreadableSwap];
  if (msgs.length > 2) return const [extraMessages];
  final from = review.from;
  final to = review.to;
  final problems = <String>[];
  if (chainId != from.chainId || facts.sold.denom != from.denom) {
    problems.add(
      'The message spends ${_shortDenom(facts.sold.denom)}, not the ${from.ticker} on ${from.chainName} you reviewed.',
    );
  } else if (facts.sold.amount != review.fee.net.toString()) {
    problems.add(
      'The message spends ${swapTickerAmount(facts.sold.amount, from.identity)}, not the ${swapTickerAmount(review.fee.net, from.identity)} you reviewed.',
    );
  }
  if (facts.contract != review.contract) {
    problems.add(
      'The message calls ${_short(facts.contract)}, not the swap contract Zunia verified on Osmosis.',
    );
  }
  if (!facts.contractCall) {
    // ibc-hooks runs the call only when the packet reaching Osmosis is
    // addressed to the contract; anything else just delivers the tokens there.
    final lands = facts.forwardsIn.isNotEmpty
        ? facts.forwardsIn.last.receiver
        : facts.transferReceiver ?? '';
    if (!isWasmHookReceiverValid(lands, facts.contract)) {
      problems.add(
        'The transfer is not addressed to the swap contract, so the swap would not run and the tokens would land somewhere else.',
      );
    }
  }
  final expected = to.chainId == venueChainId
      ? to.denom
      : to.identity.osmosisDenom;
  if (expected != null && expected != facts.swap.outputDenom) {
    problems.add(
      'The contract would buy ${book.identityOf(venueChainId, facts.swap.outputDenom).ticker}, not the ${to.ticker} you picked.',
    );
  }
  final payee = facts.forwardsOut?.finalReceiver ?? facts.swap.receiver;
  if (payee != review.recipient) {
    problems.add(
      'The swap would pay ${_short(payee)}, which is not your address on ${to.chainName}.',
    );
  } else if (facts.forwardsOut != null &&
      ownerOf(facts.swap.receiver, review, venueChainId) == null) {
    problems.add(
      'On the way, the swap would pay ${_short(facts.swap.receiver)}, which is not one of this wallet\'s addresses.',
    );
  }
  final failed = facts.swap.onFailedDelivery;
  if (failed is! XcsLocalRecovery) {
    problems.add(
      'The swap sets no recovery address, so output stranded by a failed delivery could never be claimed back.',
    );
  } else if (failed.address != review.recoveryAddress) {
    problems.add(
      'The recovery address ${_short(failed.address)} is not your address on Osmosis.',
    );
  }
  problems.addAll(
    _feeProblems(
      review: review,
      feeMsg: msgs.length > 1 ? msgs[1] : null,
      chainId: chainId,
      signer: signerAddress,
      policy: policy,
      book: book,
    ),
  );
  return problems;
}

/// Everything the transfer after a `pool-deliver` swap does that the review
/// did not say.
List<String> poolDeliveryProblems(
  DeliveryTransferFacts? transfer,
  PoolSwapReview review, {
  required String signerAddress,
  required DateTime now,
  required SwapTokenBook book,
  required String venueChainId,
}) {
  final delivery = review.delivery;
  if (transfer == null || delivery == null) return const [unreadableDelivery];
  final bought = book.identityOf(venueChainId, review.venueOutputDenom);
  final problems = <String>[];
  if (transfer.sender != signerAddress) {
    problems.add(
      'The transfer would leave ${_short(transfer.sender)}, not the account the swap pays.',
    );
  }
  if (transfer.receiver != review.recipient) {
    problems.add(
      'The transfer would pay ${_short(transfer.receiver)}, which is not your address on ${review.to.chainName}.',
    );
  }
  if (transfer.token.denom != review.venueOutputDenom) {
    problems.add(
      'The transfer sends ${_shortDenom(transfer.token.denom)}, not the ${review.to.ticker} the swap buys.',
    );
  } else if (transfer.token.amount != review.minOut) {
    problems.add(
      "The transfer sends ${swapTickerAmount(transfer.token.amount, bought)}, not the swap's minimum of ${swapTickerAmount(review.minOut, bought)}.",
    );
  }
  if (transfer.sourcePort != delivery.port ||
      transfer.sourceChannel != delivery.sourceChannel) {
    problems.add(
      'The transfer leaves over ${transfer.sourceChannel}, not over ${delivery.sourceChannel}, the channel Zunia checked.',
    );
  }
  if (transfer.memo.isNotEmpty) {
    problems.add(
      'The transfer carries a memo, which a delivery to your own address never needs.',
    );
  }
  final nowNanos = BigInt.from(now.microsecondsSinceEpoch) * BigInt.from(1000);
  if (BigInt.parse(transfer.timeoutTimestamp) <= nowNanos) {
    problems.add(
      "The transfer's timeout has already passed, so it would only come back. Refresh the price.",
    );
  }
  return problems;
}

/// Everything a pool swap's transaction does that the review did not say;
/// any of it refuses the signature.
List<String> poolSwapTermsProblems(
  PoolSwapFacts? facts,
  PoolSwapReview review, {
  required String chainId,
  required String signerAddress,
  required List<TxMsg> msgs,
  required SwapFeePolicy policy,
  required SwapTokenBook book,
  required DateTime now,
  required String venueChainId,
}) {
  if (facts == null) return const [unreadableSwap];
  // The swap, then the fee when there is a bank send, then the transfer when
  // delivering. Anything left over is a message nobody reviewed.
  final rest = msgs.sublist(1);
  final feeMsg = rest.isNotEmpty && rest.first.typeUrl == bankSendTypeUrl
      ? rest.first
      : null;
  final afterFee = feeMsg != null ? rest.sublist(1) : rest;
  final delivering = review.poolPath == SwapPath.poolDeliver;
  if (afterFee.length > (delivering ? 1 : 0)) return const [extraMessages];
  final transferMsg = delivering && afterFee.isNotEmpty ? afterFee.first : null;

  final from = review.from;
  final to = review.to;
  final problems = <String>[];
  if (chainId != venueChainId || from.chainId != venueChainId) {
    problems.add(
      "A swap in Osmosis's pools signs on Osmosis, and this one would sign on $chainId.",
    );
  }
  if (facts.sender != signerAddress) {
    problems.add(
      'The swap would spend from ${_short(facts.sender)}, not from the account signing it.',
    );
  }
  if (facts.sold.denom != from.denom) {
    problems.add(
      'The message spends ${_shortDenom(facts.sold.denom)}, not the ${from.ticker} on ${from.chainName} you reviewed.',
    );
  } else if (facts.sold.amount != review.fee.net.toString()) {
    problems.add(
      'The message spends ${swapTickerAmount(facts.sold.amount, from.identity)}, not the ${swapTickerAmount(review.fee.net, from.identity)} you reviewed.',
    );
  }
  final expected = to.chainId == venueChainId
      ? to.denom
      : to.identity.osmosisDenom;
  if (facts.outputDenom != review.venueOutputDenom ||
      (expected != null && expected != facts.outputDenom)) {
    problems.add(
      'The swap would buy ${book.identityOf(venueChainId, facts.outputDenom).ticker}, not the ${to.ticker} you picked.',
    );
  }
  final bought = book.identityOf(venueChainId, facts.outputDenom);
  if (facts.minOut != review.minOut) {
    problems.add(
      "The swap's minimum is ${swapTickerAmount(facts.minOut, bought)}, not the ${swapTickerAmount(review.minOut, bought)} you reviewed.",
    );
  }
  if (!sameRoutes(facts.routes, review.routes)) {
    problems.add(
      'The swap would go through other pools, or other amounts, than the route you reviewed.',
    );
  }
  if (!delivering) {
    if (review.recipient != signerAddress) {
      problems.add(
        'Osmosis pays a swap to the account that signs it, not to ${_short(review.recipient)}, where this review delivers.',
      );
    }
  } else {
    problems.addAll(
      poolDeliveryProblems(
        readDeliveryTransfer(transferMsg),
        review,
        signerAddress: signerAddress,
        now: now,
        book: book,
        venueChainId: venueChainId,
      ),
    );
  }
  problems.addAll(
    _feeProblems(
      review: review,
      feeMsg: feeMsg,
      chainId: chainId,
      signer: signerAddress,
      policy: policy,
      book: book,
    ),
  );
  return problems;
}

/// Every problem with [msgs] as the transaction [review] signs, re-read from
/// the messages; empty when they are exactly what the review shows.
List<String> reviewProblems(
  SwapReview review, {
  required List<TxMsg> msgs,
  required String chainId,
  required SwapFeePolicy policy,
  required SwapTokenBook book,
  required DateTime now,
  required String venueChainId,
}) {
  if (msgs.isEmpty) return const [unreadableSwap];
  return switch (review) {
    ContractSwapReview() => swapTermsProblems(
      readSwapMessage(msgs.first),
      review,
      chainId: chainId,
      signerAddress: review.signer,
      msgs: msgs,
      policy: policy,
      book: book,
      venueChainId: venueChainId,
    ),
    PoolSwapReview() => poolSwapTermsProblems(
      readPoolSwapMsg(msgs.first),
      review,
      chainId: chainId,
      signerAddress: review.signer,
      msgs: msgs,
      policy: policy,
      book: book,
      now: now,
      venueChainId: venueChainId,
    ),
  };
}

/* -------------------------------------------------------------------------- *
 * Whether the review still stands
 * -------------------------------------------------------------------------- */

/// What the form would sign right now, to check a review against.
@immutable
class LiveSwap {
  const LiveSwap({
    required this.from,
    required this.to,
    required this.path,
    required this.amountUnits,
    required this.fee,
    required this.planKey,
    required this.planning,
    required this.planFingerprint,
    required this.delivery,
    required this.blockedReason,
  });

  final SwapAsset? from;
  final SwapAsset? to;
  final SwapPath? path;
  final BigInt? amountUnits;
  final SwapFee? fee;

  /// `''` when the form cannot plan.
  final String planKey;
  final bool planning;

  /// The contract plan's fingerprint ([routePlanFingerprint]); null when none.
  final String? planFingerprint;

  /// The pool path's checked transfer leg.
  final PoolDelivery? delivery;
  final String? blockedReason;
}

/// What a plan would have signed, without the per-build packet timeout.
String routePlanFingerprint(RoutePlan plan, String receiver) => jsonEncode([
  plan.sourceChainId,
  plan.destChainId,
  plan.inputDenom,
  plan.outputDenom,
  plan.memo,
  receiver,
  [
    for (final hop in plan.hops)
      [
        hop.chainId,
        hop.channelId,
        hop.port,
        hop.counterpartyChainId,
        hop.kind.name,
      ],
  ],
]);

/// Why a review no longer stands, or null while it does: in what moved, so
/// the user knows what to check. A new price does not move it.
String? reviewDrift(SwapReview review, LiveSwap live) {
  if (live.from?.key != review.from.key) {
    return 'The swap form no longer sells ${review.from.ticker} on ${review.from.chainName}.';
  }
  if (live.to?.key != review.to.key) {
    return 'The swap form no longer buys ${review.to.ticker} on ${review.to.chainName}.';
  }
  if (live.amountUnits != review.amountUnits) {
    return 'The amount on the swap form is no longer ${swapTickerAmount(review.amountUnits, review.from.identity)}.';
  }
  if (live.fee == null || live.fee != review.fee) {
    return 'The Zunia fee on the swap form is no longer the one you reviewed.';
  }
  if (live.path != review.path) {
    return 'Zunia now swaps this pair another way. Review it again.';
  }
  if (live.planKey != review.planKey) {
    return (live.planKey.isEmpty ? live.blockedReason : null) ??
        "The swap's settings changed after this review.";
  }
  switch (review) {
    case ContractSwapReview():
      if (live.planning) return 'Zunia is checking the route again.';
      final fingerprint = live.planFingerprint;
      if (fingerprint == null) {
        return live.blockedReason ??
            'The route you reviewed is no longer offered.';
      }
      if (fingerprint != routePlanFingerprint(review.plan, review.receiver)) {
        return 'Zunia planned the route again, and it is not the one you reviewed.';
      }
      return null;
    case PoolSwapReview(:final delivery):
      if (delivery == null) return null;
      if (live.planning) return 'Zunia is checking the transfer again.';
      final current = live.delivery;
      if (current == null) {
        return live.blockedReason ??
            'The transfer you reviewed is no longer offered.';
      }
      if (current != delivery) {
        return 'Zunia planned the transfer again, and it is not the one you reviewed.';
      }
      return null;
  }
}

/// Said when a price is too old to sign against.
String priceExpiredText(Duration ttl) =>
    'This price is more than ${ttl.inSeconds} seconds old. Refresh it, check it, then sign.';

/// Why the reviewed swap cannot be signed right now: the button's short label
/// and the sentence behind it, or null when it can. Checked again at the
/// moment of signing, not only when the button is drawn.
({String label, String reason})? swapSignBlock({
  required String? problem,
  required String? drift,
  required SwapPrice price,
  required bool refreshing,
  required DateTime now,
  required Duration ttl,
  required bool feeShort,
}) {
  if (problem != null) return (label: 'Cannot sign', reason: problem);
  if (drift != null) {
    return (
      label: 'Out of date',
      reason: '$drift Go back and review the swap again.',
    );
  }
  if (refreshing) {
    return (label: 'Updating…', reason: 'The price is being updated.');
  }
  if (price.quote == null) {
    return (
      label: 'No price',
      reason:
          price.error ??
          'There is no price for this swap. Refresh it, check it, then sign.',
    );
  }
  if (priceExpired(price, now, ttl)) {
    return (label: 'Price expired', reason: priceExpiredText(ttl));
  }
  if (feeShort) {
    return (
      label: 'Need fee room',
      reason:
          'Not enough is left for the network fee. Lower the amount or the fee speed.',
    );
  }
  return null;
}

/* -------------------------------------------------------------------------- *
 * Copy
 * -------------------------------------------------------------------------- */

/// What becomes of the fee if the swap fails, by how the swap reaches the
/// contract or the pools.
String swapFeeOutcome(SwapReview review) {
  switch (review) {
    case ContractSwapReview():
      if (review.venueOrigin) {
        return 'The swap and the fee are one transaction: if the swap fails, no fee is taken.';
      }
      final rate = review.fee.bps > 0 ? ' ${feeRateText(review.fee.bps)}' : '';
      return 'If the swap fails on Osmosis, the amount swapped comes back to you, but the$rate Zunia fee does not.';
    case PoolSwapReview(:final poolPath):
      return poolPath == SwapPath.pool
          ? 'The swap and the fee are one transaction: if the swap fails, no fee is taken.'
          : 'The swap, the fee and the transfer are one transaction: if the swap would pay less than the minimum, none of them happens.';
  }
}

/// The form's fee line: `Zunia fee` and `0.5% · 0.05 OSMO`. Null when no fee
/// applies, and then no line is drawn.
({String label, String value})? swapFeeLine(
  SwapFee? fee,
  SwapTokenIdentity from,
) {
  if (fee == null || fee.fee <= BigInt.zero) return null;
  return (
    label: 'Zunia fee',
    value: '${feeRateText(fee.bps)} · ${swapTickerAmount(fee.fee, from)}',
  );
}

/// The default `tx.body.memo` for a swap, as the extension writes it when the
/// user leaves the memo empty: the transaction is named by its first message,
/// never by the fee beside it. A contract call or a pool swap names both
/// tokens as the signing chain names them (`Swap OSMO to ATOM`); a transfer
/// names the token sold (`Swap ATOM`); a token nothing proves is left out.
String swapTxMemo(List<TxMsg> msgs, String chainId, SwapTokenBook book) {
  String? named(String? denom) {
    if (denom == null || denom.isEmpty) return null;
    final identity = book.identityOf(chainId, denom);
    return identity.proven ? identity.ticker : null;
  }

  var phrase = 'Swap';
  final first = msgs.isEmpty ? null : msgs.first;
  if (first != null) {
    if (first.typeUrl == transferTypeUrl) {
      final token = first.value['token'];
      final sold = named(token is Map ? token['denom'] as String? : null);
      phrase = sold == null ? 'Swap' : 'Swap $sold';
    } else if (first.typeUrl == executeContractTypeUrl) {
      final read = readSwapMessage(first);
      final sold = named(read?.sold.denom);
      final bought = named(read?.swap.outputDenom);
      phrase = sold != null && bought != null
          ? 'Swap $sold to $bought'
          : 'Contract call';
    } else {
      final read = readPoolSwapMsg(first);
      final sold = named(read?.sold.denom);
      final bought = named(read?.outputDenom);
      phrase = sold != null && bought != null
          ? 'Swap $sold to $bought'
          : 'Swap';
    }
  }
  const tag = ' · $zuniaWalletTag';
  const maxChars = 256;
  if (phrase.length + tag.length <= maxChars) return '$phrase$tag';
  return '${phrase.substring(0, maxChars - tag.length - 1)}…$tag';
}
