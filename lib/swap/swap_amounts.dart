/// Swap amounts as text, one policy for the form, the confirm card and the
/// result: exact up to six decimals and cut, never rounded up, so Max never
/// reads more than it signs; base units when the decimals are unknown.
library;

import 'package:zunia_mobile/swap/swap_tokens.dart';
import 'package:zunia_mobile/util/amounts.dart';

/// `1.234567`, or `1234567 base units` when nothing proves the exponent.
String swapAmountText(
  Object units,
  SwapTokenIdentity identity, {
  int maxFractionDigits = 6,
}) {
  final raw = '$units';
  if (!identity.decimalsKnown) {
    return '$raw ${raw == '1' ? 'base unit' : 'base units'}';
  }
  return formatBaseUnitsExact(
    raw,
    decimals: identity.decimals,
    maxFractionDigits: maxFractionDigits,
  );
}

/// `1.234567 OSMO`.
String swapTickerAmount(Object units, SwapTokenIdentity identity) =>
    '${swapAmountText(units, identity)} ${identity.ticker}';

/// Every digit of the token's exponent, what Max writes into the field:
/// converted back with the same exponent it gives [units] exactly.
String swapFieldText(BigInt units, SwapTokenIdentity identity) =>
    formatBaseUnitsExact(
      units.toString(),
      decimals: identity.decimalsKnown ? identity.decimals : 0,
    );

/// The base units a field's text stands for, read with the row's own
/// exponent (0 when unknown, so only Max's raw integer converts). Null when
/// the text is empty or does not convert.
BigInt? swapUnitsOf(String text, SwapTokenIdentity identity) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final base = toBaseUnits(
    trimmed,
    identity.decimalsKnown ? identity.decimals : 0,
  );
  return base == null ? null : BigInt.tryParse(base);
}

/// `1 OSMO ≈ 0.0354 USDC.inj`, from base units and both exponents. Null when
/// either side's decimals are unknown or an amount is zero.
String? swapRateLine(
  String inputBase,
  SwapTokenIdentity input,
  String outputBase,
  SwapTokenIdentity output,
) {
  if (!input.decimalsKnown || !output.decimalsKnown) return null;
  final a = BigInt.tryParse(inputBase);
  final b = BigInt.tryParse(outputBase);
  if (a == null || b == null || a <= BigInt.zero || b <= BigInt.zero) {
    return null;
  }
  // Scaled integer division, then one conversion: base units routinely exceed
  // what a double holds exactly.
  final scale = BigInt.from(10).pow(18);
  final exponent = input.decimals - output.decimals;
  var numerator = b * scale;
  var denominator = a;
  if (exponent > 0) numerator *= BigInt.from(10).pow(exponent);
  if (exponent < 0) denominator *= BigInt.from(10).pow(-exponent);
  final rate = (numerator ~/ denominator).toDouble() / 1e18;
  if (!rate.isFinite || rate <= 0) return null;
  final digits = rate >= 100
      ? 2
      : rate >= 1
      ? 4
      : 6;
  return '1 ${input.ticker} ≈ ${rate.toStringAsFixed(digits)} ${output.ticker}';
}
