/// Zunia's swap commission: what it comes to, the bank send that pays it, and
/// the check that a transaction pays exactly that and nothing else.
///
/// Port of zunia-extension 0.1.5 `lib/swap-fee.ts`. The rate and the treasury
/// addresses come from `assets/data/swap-fee.json` ([SwapFeeConfig]), never
/// from code. The crosschain-swaps contract's `osmosis_swap` has no fee field,
/// so the fee is a `MsgSend` of its own, signed in the same transaction right
/// after the swap message, in the token sold. It comes out of the amount the
/// user typed (or Max): that amount is what they spend in all, and the swap
/// sells what is left ([SwapFee.net]).
///
/// Pure: no network, no storage, no clock.
library;

import 'package:bech32/bech32.dart';
import 'package:flutter/foundation.dart';

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/swap/swap_config.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

/// The proto type of the bank send that pays the fee.
const String bankSendTypeUrl = '/cosmos.bank.v1beta1.MsgSend';

/// Basis points in a whole.
const int _bpsPerWhole = 10000;

/// The bech32 prefix the bundled catalog gives a chain, or null when the chain
/// is not bundled. A chain the user added states its own prefix, and the
/// release does not take that on its word.
typedef BundledPrefixOf = String? Function(String chainId);

/// [BundledPrefixOf] over the bundled catalog (custom chains excluded).
String? bundledCatalogPrefix(String chainId) {
  if (!ChainCatalog.isLoaded) return null;
  for (final entry in ChainCatalog.instance.registryOnly) {
    if (entry.chainId == chainId) return entry.bech32Prefix;
  }
  return null;
}

/// The Zunia fee on one swap.
@immutable
class SwapFee {
  const SwapFee({
    required this.bps,
    required this.fee,
    required this.net,
    required this.recipient,
  });

  /// No fee: the whole [amount] is swapped.
  SwapFee.none(BigInt amount)
    : bps = 0,
      fee = BigInt.zero,
      net = amount,
      recipient = null;

  /// The rate charged, in basis points; 0 when no fee is taken.
  final int bps;

  /// Base units of the token sold paid to [recipient]; zero when none.
  final BigInt fee;

  /// Base units the swap itself sells: the amount less [fee].
  final BigInt net;

  /// The treasury on the signing chain; null exactly when no fee is taken.
  final String? recipient;

  bool get charged => fee > BigInt.zero && recipient != null;

  @override
  bool operator ==(Object other) =>
      other is SwapFee &&
      other.bps == bps &&
      other.fee == fee &&
      other.net == net &&
      other.recipient == recipient;

  @override
  int get hashCode => Object.hash(bps, fee, net, recipient);

  @override
  String toString() =>
      'SwapFee(bps: $bps, fee: $fee, net: $net, to: $recipient)';
}

/// A coin's bank send, as [readSwapFeeMsg] reads it out of a message.
@immutable
class SwapFeeMessage {
  const SwapFeeMessage({
    required this.from,
    required this.to,
    required this.denom,
    required this.amount,
  });

  final String from;
  final String to;
  final String denom;

  /// Base units, digits only, above zero.
  final String amount;

  @override
  bool operator ==(Object other) =>
      other is SwapFeeMessage &&
      other.from == from &&
      other.to == to &&
      other.denom == denom &&
      other.amount == amount;

  @override
  int get hashCode => Object.hash(from, to, denom, amount);
}

/// `bech32.fromWords`, strict: 5-bit groups to bytes, refusing a padding that
/// carries bits or is a whole group long, as scure does.
Uint8List? _fromWords(List<int> words) {
  var acc = 0;
  var bits = 0;
  final out = <int>[];
  for (final value in words) {
    if (value < 0 || value >> 5 != 0) return null;
    acc = (acc << 5) | value;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      out.add((acc >> bits) & 0xff);
    }
    acc &= (1 << bits) - 1;
  }
  if (bits >= 5) return null;
  if (acc != 0) return null;
  return Uint8List.fromList(out);
}

/// Prefix and payload of a bech32 address, checksum checked; null when it
/// does not decode.
({String prefix, Uint8List bytes})? decodeBech32Address(String address) {
  try {
    final decoded = const Bech32Codec().decode(address, 1023);
    final bytes = _fromWords(decoded.data);
    if (bytes == null) return null;
    return (prefix: decoded.hrp, bytes: bytes);
  } on Object {
    return null;
  }
}

/// Why [address] cannot receive the fee on [chainId], or null when it can: a
/// bech32 address (checksum included) in its canonical lowercase spelling, of
/// an account (20 bytes) or a contract (32 bytes), carrying the prefix the
/// bundled catalog gives that chain.
String? swapFeeRecipientProblem(
  String chainId,
  String address, {
  BundledPrefixOf prefixOf = bundledCatalogPrefix,
}) {
  final expected = prefixOf(chainId);
  if (expected == null) return '$chainId is not a chain this release bundles.';
  final decoded = decodeBech32Address(address);
  if (decoded == null) return '$address is not a valid bech32 address.';
  if (address != address.toLowerCase()) return '$address is not in lowercase.';
  if (decoded.prefix != expected) {
    return "$address carries the prefix ${decoded.prefix}, not $chainId's $expected.";
  }
  final length = decoded.bytes.length;
  if (length != 20 && length != 32) {
    return "$address holds $length bytes, not an account's 20 or a contract's 32.";
  }
  return null;
}

/// The fee rules of one release: its rate, its treasuries, and the catalog
/// that says which prefix each chain's treasury must carry.
@immutable
class SwapFeePolicy {
  const SwapFeePolicy({
    required this.bps,
    required this.recipients,
    this.prefixOf = bundledCatalogPrefix,
  });

  factory SwapFeePolicy.fromConfig(SwapFeeConfig config) =>
      SwapFeePolicy(bps: config.bps, recipients: config.recipients);

  final int bps;
  final Map<String, String> recipients;
  final BundledPrefixOf prefixOf;

  /// The treasury configured for [chainId], or null when there is none. An
  /// entry that fails [swapFeeRecipientProblem] counts as none, so a bad
  /// address can only ever mean no fee, never a fee sent somewhere else.
  String? recipientFor(String chainId) {
    final address = recipients[chainId];
    if (address == null) return null;
    return swapFeeRecipientProblem(chainId, address, prefixOf: prefixOf) == null
        ? address
        : null;
  }

  /// The Zunia fee on [amount] base units sold on [chainId]:
  /// `floor(amount × bps / 10000)`, so rounding only ever favours the user,
  /// and what is left for the swap. No fee at all when the chain has no
  /// treasury, the amount is not above zero, the rate is not a whole number of
  /// basis points below 100%, or the amount is too small to carry one base
  /// unit of fee.
  SwapFee feeFor(String chainId, BigInt amount) {
    final none = SwapFee.none(amount);
    if (amount <= BigInt.zero || bps <= 0 || bps >= _bpsPerWhole) return none;
    final recipient = recipientFor(chainId);
    if (recipient == null) return none;
    final fee = amount * BigInt.from(bps) ~/ BigInt.from(_bpsPerWhole);
    if (fee <= BigInt.zero) return none;
    return SwapFee(bps: bps, fee: fee, net: amount - fee, recipient: recipient);
  }

  /// Every way [msg], the message a swap transaction signs after the swap
  /// (null when it signs none), differs from the fee the swap owes; empty when
  /// it is exactly that fee. The fee owed is worked out again here from the
  /// configuration, never taken from the caller.
  List<SwapFeeIssue> issues(TxMsg? msg, SwapFeeExpectation expected) {
    final due = feeFor(expected.chainId, expected.amountUnits);
    if (msg == null) {
      return due.fee > BigInt.zero ? [SwapFeeMissing(due)] : const [];
    }
    final paid = readSwapFeeMsg(msg);
    if (paid == null) return const [SwapFeeUnreadable()];
    if (due.fee == BigInt.zero || due.recipient == null) {
      return [SwapFeeNotDue(paid)];
    }
    final out = <SwapFeeIssue>[];
    if (paid.from != expected.signer) out.add(SwapFeeWrongSender(paid));
    if (paid.to != due.recipient) out.add(SwapFeeWrongRecipient(paid, due));
    if (paid.denom != expected.denom) {
      out.add(SwapFeeWrongDenom(paid));
    } else if (paid.amount != due.fee.toString()) {
      out.add(SwapFeeWrongAmount(paid, due));
    }
    return out;
  }
}

/// A rate in basis points as a percentage, from whole numbers: 50 is `0.5%`,
/// 25 is `0.25%`, 100 is `1%`.
String feeRateText(int bps) {
  final whole = bps ~/ 100;
  if (bps % 100 == 0) return '$whole%';
  final hundredths = (bps % 100)
      .toString()
      .padLeft(2, '0')
      .replaceFirst(RegExp(r'0$'), '');
  return '$whole.$hundredths%';
}

/// The bank send that pays the fee, in the shape the kernel signs a `MsgSend`
/// in: from the signer, to the treasury, one coin of the denom sold. Throws
/// when a field is empty or the amount is not above zero.
TxMsg buildSwapFeeMsg({
  required String sender,
  required String recipient,
  required String denom,
  required BigInt amount,
}) {
  if (sender.isEmpty ||
      recipient.isEmpty ||
      denom.isEmpty ||
      amount <= BigInt.zero) {
    throw ArgumentError(
      'A swap fee needs a sender, a recipient, a denom and an amount above zero.',
    );
  }
  return TxMsg.send(
    from: sender,
    to: recipient,
    amount: [TxCoin(denom, amount.toString())],
  );
}

final RegExp _positive = RegExp(r'^[1-9]\d*$');

bool _hasExactly(Map<dynamic, dynamic> value, List<String> keys) =>
    value.length == keys.length && keys.every(value.containsKey);

/// What a message pays, read as a plain bank send of one coin: null for any
/// other message, and for a bank send carrying anything this does not show.
/// What cannot be read whole is never called a fee.
SwapFeeMessage? readSwapFeeMsg(TxMsg? msg) {
  if (msg == null || msg.typeUrl != bankSendTypeUrl) return null;
  final value = msg.value;
  if (!_hasExactly(value, const ['from_address', 'to_address', 'amount'])) {
    return null;
  }
  final from = value['from_address'];
  final to = value['to_address'];
  final coins = value['amount'];
  if (from is! String || from.isEmpty || to is! String || to.isEmpty) {
    return null;
  }
  if (coins is! List || coins.length != 1) return null;
  final coin = coins.first;
  if (coin is! Map || !_hasExactly(coin, const ['denom', 'amount'])) {
    return null;
  }
  final denom = coin['denom'];
  final amount = coin['amount'];
  if (denom is! String || denom.isEmpty) return null;
  if (amount is! String || !_positive.hasMatch(amount)) return null;
  return SwapFeeMessage(from: from, to: to, denom: denom, amount: amount);
}

/// What a swap transaction must pay as its Zunia fee.
@immutable
class SwapFeeExpectation {
  const SwapFeeExpectation({
    required this.chainId,
    required this.signer,
    required this.denom,
    required this.amountUnits,
  });

  final String chainId;
  final String signer;

  /// The exact bank denom sold.
  final String denom;

  /// Base units spent in all, the fee included.
  final BigInt amountUnits;
}

/// One way a transaction's fee message is not the fee the swap owes.
sealed class SwapFeeIssue {
  const SwapFeeIssue();
}

/// A second message that is not a plain bank send of one coin.
final class SwapFeeUnreadable extends SwapFeeIssue {
  const SwapFeeUnreadable();
}

/// A fee paid when none is owed.
final class SwapFeeNotDue extends SwapFeeIssue {
  const SwapFeeNotDue(this.paid);
  final SwapFeeMessage paid;
}

/// No fee message, when a fee is owed.
final class SwapFeeMissing extends SwapFeeIssue {
  const SwapFeeMissing(this.due);
  final SwapFee due;
}

final class SwapFeeWrongSender extends SwapFeeIssue {
  const SwapFeeWrongSender(this.paid);
  final SwapFeeMessage paid;
}

final class SwapFeeWrongRecipient extends SwapFeeIssue {
  const SwapFeeWrongRecipient(this.paid, this.due);
  final SwapFeeMessage paid;
  final SwapFee due;
}

final class SwapFeeWrongDenom extends SwapFeeIssue {
  const SwapFeeWrongDenom(this.paid);
  final SwapFeeMessage paid;
}

final class SwapFeeWrongAmount extends SwapFeeIssue {
  const SwapFeeWrongAmount(this.paid, this.due);
  final SwapFeeMessage paid;
  final SwapFee due;
}
