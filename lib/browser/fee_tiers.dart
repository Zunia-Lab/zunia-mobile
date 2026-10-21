/// Fee tiers a signing prompt may offer in place of the fee a site chose
/// (zunia-extension/lib/fee-tiers.ts).
///
/// Offered only when the site allows it (Keplr's `preferNoSetFee` is not set),
/// the fee is one coin in the chain's fee denom, and the catalog lists gas
/// prices for the chain. The site's own fee stays the default choice. The
/// site reads the fee back from `signed`, as CosmJS does, so a tier the user
/// picks is what gets broadcast.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/proto_writer.dart';

enum FeeTier {
  low('Low', 'Cheapest. A busy network can refuse it.'),
  average('Medium', "The network's usual price."),
  high('High', 'Pays extra to get through a busy network.');

  const FeeTier(this.label, this.hint);

  final String label;
  final String hint;

  static FeeTier? parse(Object? value) => switch (value) {
        'low' => FeeTier.low,
        'average' => FeeTier.average,
        'high' => FeeTier.high,
        _ => null,
      };
}

/// The hint under the picker while the site's own fee is selected.
const kSiteFeeHint = 'The fee this site set.';

class FeeCoin {
  const FeeCoin(this.denom, this.amount);

  final String denom;
  final String amount;

  Map<String, String> toJson() => {'denom': denom, 'amount': amount};

  @override
  bool operator ==(Object other) =>
      other is FeeCoin && other.denom == denom && other.amount == amount;

  @override
  int get hashCode => Object.hash(denom, amount);
}

class TxFee {
  const TxFee(this.amount, this.gas);

  final List<FeeCoin> amount;
  final String gas;
}

class FeeChoice {
  const FeeChoice({
    required this.denom,
    required this.symbol,
    required this.decimals,
    required this.gas,
    required this.site,
    required this.tiers,
  });

  final String denom;
  final String symbol;
  final int decimals;
  final String gas;

  /// Base units the site asked for.
  final String site;
  final Map<FeeTier, String> tiers;

  /// Base units for [tier], or the site's fee for null.
  String amountFor(FeeTier? tier) => tier == null ? site : tiers[tier]!;
}

/// Catalog gas prices are doubles; twelve decimals is finer than any of them.
const _priceScale = 12;

/// `gas × price`, rounded up, in exact integer arithmetic.
String _priced(BigInt gas, double price) {
  if (!price.isFinite || price <= 0) return '0';
  final parts = price.toStringAsFixed(_priceScale).split('.');
  final scaled = BigInt.parse(parts[0] + (parts.length > 1 ? parts[1] : '').padRight(_priceScale, '0'));
  final unit = BigInt.from(10).pow(_priceScale);
  return ((gas * scaled + unit - BigInt.one) ~/ unit).toString();
}

final _digits = RegExp(r'^\d+$');

/// The chain's fee denom as the kernel reads it: the fee currency, or the
/// native coin when the catalog names none.
String chainFeeDenom(ChainEntry chain) =>
    chain.feeMinimalDenom.isEmpty ? chain.coinMinimalDenom : chain.feeMinimalDenom;

/// The tiers to offer for [fee], or null when it cannot or may not change.
FeeChoice? feeChoiceFor(
  ChainEntry? chain,
  TxFee? fee, {
  required bool preferNoSetFee,
}) {
  if (preferNoSetFee || fee == null || chain == null) return null;
  final step = chain.gasPriceStep;
  if (step == null) return null;
  if (fee.amount.length != 1) return null;
  final coin = fee.amount.single;
  if (coin.denom != chainFeeDenom(chain)) return null;
  if (!_digits.hasMatch(coin.amount) || !_digits.hasMatch(fee.gas)) return null;
  final gas = BigInt.parse(fee.gas);
  if (gas == BigInt.zero) return null;
  final usesFeeCurrency = chain.feeMinimalDenom.isNotEmpty;
  return FeeChoice(
    denom: coin.denom,
    symbol: usesFeeCurrency && chain.feeDenom.isNotEmpty ? chain.feeDenom : chain.coinDenom,
    decimals: usesFeeCurrency ? chain.feeDecimals : chain.coinDecimals,
    gas: fee.gas,
    site: coin.amount,
    tiers: {
      FeeTier.low: _priced(gas, step['low'] ?? 0),
      FeeTier.average: _priced(gas, step['average'] ?? 0),
      FeeTier.high: _priced(gas, step['high'] ?? 0),
    },
  );
}

/// Keplr's sign options, as far as Zunia reads them.
bool preferNoSetFeeFrom(Object? raw) => raw is Map && raw['preferNoSetFee'] == true;

/* -------------------------------------------------------------------------- *
 * Amino
 * -------------------------------------------------------------------------- */

TxFee? aminoFeeOf(Object? signDoc) {
  if (signDoc is! Map) return null;
  final fee = signDoc['fee'];
  if (fee is! Map || fee['amount'] is! List) return null;
  final coins = <FeeCoin>[];
  for (final item in fee['amount'] as List) {
    if (item is! Map || item['denom'] is! String || item['amount'] is! String) return null;
    coins.add(FeeCoin(item['denom'] as String, item['amount'] as String));
  }
  final gas = fee['gas'];
  return TxFee(coins, gas is String ? gas : (gas is num ? '${gas.toInt()}' : ''));
}

/// The sign doc with its fee replaced by [coin]; gas, payer and granter kept.
Map<String, dynamic> withAminoFee(Map<String, dynamic> signDoc, FeeCoin coin) {
  final fee = signDoc['fee'] is Map
      ? Map<String, dynamic>.from(signDoc['fee'] as Map)
      : <String, dynamic>{};
  fee['amount'] = [coin.toJson()];
  return {...signDoc, 'fee': fee};
}

/* -------------------------------------------------------------------------- *
 * Direct: `cosmos.tx.v1beta1.AuthInfo` holds `Fee` at field 2, which holds
 * its coins at field 1 and the gas limit at field 2.
 * -------------------------------------------------------------------------- */

/// One field of a protobuf message, with its exact bytes.
class ProtoField {
  const ProtoField({
    required this.field,
    required this.wire,
    required this.raw,
    this.bytes,
    this.varint,
  });

  final int field;
  final int wire;

  /// Tag and value, as they appear in the message.
  final Uint8List raw;

  /// The value of a length-delimited field.
  final Uint8List? bytes;

  /// The value of a varint field.
  final BigInt? varint;
}

/// Every top-level field of [message], in order. Throws on malformed input.
List<ProtoField> readProtoFields(Uint8List message) {
  final out = <ProtoField>[];
  var at = 0;
  BigInt readVarint() {
    var result = BigInt.zero;
    var shift = 0;
    while (true) {
      if (at >= message.length || shift > 63) {
        throw const FormatException('Bad varint');
      }
      final byte = message[at++];
      result |= BigInt.from(byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }

  while (at < message.length) {
    final start = at;
    final key = readVarint().toInt();
    final field = key >> 3;
    final wire = key & 7;
    if (field == 0) throw const FormatException('Field 0');
    Uint8List? bytes;
    BigInt? varint;
    switch (wire) {
      case 0:
        varint = readVarint();
      case 1:
        at += 8;
      case 2:
        final length = readVarint().toInt();
        if (length < 0 || at + length > message.length) {
          throw const FormatException('Bad length');
        }
        bytes = Uint8List.sublistView(message, at, at + length);
        at += length;
      case 5:
        at += 4;
      default:
        throw const FormatException('Unsupported wire type');
    }
    if (at > message.length) throw const FormatException('Truncated');
    out.add(
      ProtoField(
        field: field,
        wire: wire,
        raw: Uint8List.sublistView(message, start, at),
        bytes: bytes,
        varint: varint,
      ),
    );
  }
  return out;
}

FeeCoin? _coinFrom(Uint8List? bytes) {
  if (bytes == null) return null;
  var denom = '';
  var amount = '';
  for (final field in readProtoFields(bytes)) {
    if (field.field == 1 && field.bytes != null) {
      denom = utf8.decode(field.bytes!);
    } else if (field.field == 2 && field.bytes != null) {
      amount = utf8.decode(field.bytes!);
    }
  }
  return denom.isEmpty ? null : FeeCoin(denom, amount.isEmpty ? '0' : amount);
}

({List<ProtoField> fields, ProtoField fee, List<ProtoField> feeFields})? _feeField(
  Uint8List authInfo,
) {
  final fields = readProtoFields(authInfo);
  final fees = fields.where((f) => f.field == 2).toList();
  if (fees.length != 1 || fees.single.bytes == null) return null;
  return (fields: fields, fee: fees.single, feeFields: readProtoFields(fees.single.bytes!));
}

/// The fee inside `AuthInfo` bytes, or null when there is no single readable one.
TxFee? authInfoFee(Uint8List authInfo) {
  try {
    final found = _feeField(authInfo);
    if (found == null) return null;
    final amount = <FeeCoin>[];
    var gas = BigInt.zero;
    for (final field in found.feeFields) {
      if (field.field == 1) {
        final coin = _coinFrom(field.bytes);
        if (coin == null) return null;
        amount.add(coin);
      } else if (field.field == 2) {
        if (field.varint == null) return null;
        gas = field.varint!;
      }
    }
    return TxFee(amount, gas.toString());
  } catch (_) {
    return null;
  }
}

Uint8List _lengthDelimited(int field, Uint8List bytes) {
  final writer = ProtoWriter()..messageAlways(field, bytes);
  return writer.intoBytes();
}

/// `AuthInfo` bytes with the fee coins replaced by [coin]. Every other field,
/// signer infos, gas limit, payer, granter and tip, is kept byte for byte.
Uint8List withAuthInfoFee(Uint8List authInfo, FeeCoin coin) {
  final found = _feeField(authInfo);
  if (found == null) throw StateError('The transaction has no single fee to change');
  final coinBytes = ProtoWriter().string(1, coin.denom).string(2, coin.amount).intoBytes();
  final fee = BytesBuilder(copy: false)..add(_lengthDelimited(1, coinBytes));
  for (final field in found.feeFields) {
    if (field.field != 1) fee.add(field.raw);
  }
  final out = BytesBuilder(copy: false);
  for (final field in found.fields) {
    out.add(identical(field, found.fee) ? _lengthDelimited(2, fee.toBytes()) : field.raw);
  }
  return out.toBytes();
}
