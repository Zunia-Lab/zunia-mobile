/// One amount policy for every token surface.
///
/// Port of `zunia-extension/lib/token-amount.ts`. The precision follows the
/// kind of surface, and a token whose decimals are not known is shown as raw
/// base units, never scaled and never compacted: 12340000 base units of a
/// voucher nobody can scale must not read "12.34M".
///
/// Digits come from integer arithmetic on the base units, never from a
/// double: 18-decimal balances routinely exceed what a double holds exactly.
library;

import 'package:zunia_mobile/tokens/token_identity.dart';

/// Where an amount is shown.
/// - `list`: balance rows. Two decimals, k/M/Bn allowed, padded.
/// - `picker`: a picker row. Exact, up to six decimals.
/// - `confirm`: review and confirm screens. Exact, up to six decimals.
/// - `history`: activity rows and notices. Up to three decimals, k/M/Bn.
enum TokenAmountVariant { list, picker, confirm, history }

/// What an amount needs from an identity; a full [TokenIdentity] converts.
class AmountScale {
  const AmountScale({
    required this.decimals,
    required this.decimalsKnown,
    required this.ticker,
    required this.denom,
    this.unknown = false,
  });

  factory AmountScale.of(TokenIdentity identity) => AmountScale(
        decimals: identity.decimals,
        decimalsKnown: identity.decimalsKnown,
        ticker: identity.ticker,
        denom: identity.denom,
        unknown: identity.provenance == TokenProvenance.unknown,
      );

  /// A chain's own coin at the catalog's exponent.
  factory AmountScale.known(int decimals, String ticker, {String denom = ''}) =>
      AmountScale(decimals: decimals, decimalsKnown: true, ticker: ticker, denom: denom);

  final int decimals;
  final bool decimalsKnown;
  final String ticker;
  final String denom;

  /// The identity is unknown: the unit after an amount is the short denom.
  final bool unknown;
}

class _Precision {
  const _Precision(this.digits, this.compact, this.pad);
  final int digits;
  final bool compact;
  final bool pad;
}

const Map<TokenAmountVariant, _Precision> _precision = {
  TokenAmountVariant.list: _Precision(2, true, true),
  TokenAmountVariant.picker: _Precision(6, false, false),
  TokenAmountVariant.confirm: _Precision(6, false, false),
  TokenAmountVariant.history: _Precision(3, true, false),
};

const List<(String, int)> _compactUnits = [('Bn', 9), ('M', 6), ('k', 3)];

/// The words after a raw amount whose decimals are unknown.
const String baseUnitsWords = 'base units';

/// Beside an amount field that cannot take typed input.
const String maxOnlyNote = "This token's decimals are unknown, so only Max can be used.";

/// Shown wherever a balance is hidden.
const String maskedAmount = '••••';

final RegExp _integer = RegExp(r'^-?\d+$');

/// A signed integer in canonical form, or null when [amount] is not one.
String? integerText(Object amount) {
  if (amount is BigInt) return amount.toString();
  final text = amount.toString().trim();
  return _integer.hasMatch(text) ? BigInt.parse(text).toString() : null;
}

int _exponentOf(int decimals) => decimals > 0 ? decimals : 0;

({BigInt whole, String fraction}) _cutDecimal(BigInt units, int exponent, int digits) {
  final scale = BigInt.from(10).pow(exponent);
  final whole = units ~/ scale;
  final raw = exponent > 0 ? (units % scale).toString().padLeft(exponent, '0') : '';
  final cut = raw.length > digits ? raw.substring(0, digits) : raw;
  return (whole: whole, fraction: cut.padRight(digits, '0'));
}

final RegExp _nonZeroDigit = RegExp('[1-9]');
final RegExp _trailingZeros = RegExp(r'0+$');

String _scaledText(BigInt units, int decimals, _Precision precision) {
  final exponent = _exponentOf(decimals);
  var suffix = '';
  var shift = 0;
  if (precision.compact) {
    final whole = units ~/ BigInt.from(10).pow(exponent);
    for (final (unit, unitExponent) in _compactUnits) {
      if (whole >= BigInt.from(10).pow(unitExponent)) {
        suffix = unit;
        shift = unitExponent;
        break;
      }
    }
  }
  final cut = _cutDecimal(units, exponent + shift, precision.digits);
  if (units > BigInt.zero && cut.whole == BigInt.zero && !_nonZeroDigit.hasMatch(cut.fraction)) {
    return precision.digits > 0 ? '<0.${'0' * (precision.digits - 1)}1' : '<1';
  }
  final shown = precision.pad ? cut.fraction : cut.fraction.replaceFirst(_trailingZeros, '');
  return '${cut.whole}${shown.isEmpty ? '' : '.$shown'}$suffix';
}

/// The unit after an amount: the ticker, or the short denom for a token
/// nothing names.
String amountUnit(AmountScale scale) =>
    scale.unknown && scale.denom.isNotEmpty ? shortDenom(scale.denom) : scale.ticker;

/// [amount] (base units, optionally signed) as the surface shows it: `12.34`,
/// `20.34k`, `1234.567891`, `-12.34`, `<0.001`, or `12340000 base units` when
/// the decimals are unknown. Text that is not an integer reads as 0.
String formatTokenAmount(
  Object amount,
  AmountScale scale,
  TokenAmountVariant variant, {
  bool hidden = false,
  bool unit = false,
}) {
  if (hidden) return maskedAmount;
  final raw = integerText(amount) ?? '0';
  String value;
  if (!scale.decimalsKnown) {
    value = '$raw ${raw == '1' || raw == '-1' ? 'base unit' : baseUnitsWords}';
  } else {
    final negative = raw.startsWith('-');
    final units = BigInt.parse(negative ? raw.substring(1) : raw);
    value = '${negative ? '-' : ''}${_scaledText(units, scale.decimals, _precision[variant]!)}';
  }
  return unit ? '$value ${amountUnit(scale)}' : value;
}

/// The text an amount field holds for [amount] base units, which is what Max
/// writes: every digit of the exponent, no grouping, no k/M. Converted back
/// with the same decimals it gives [amount] exactly. Not an integer: "0".
String amountFieldText(Object amount, int decimals) {
  final raw = integerText(amount);
  if (raw == null || raw.startsWith('-')) return '0';
  final exponent = _exponentOf(decimals);
  final cut = _cutDecimal(BigInt.parse(raw), exponent, exponent);
  final trimmed = cut.fraction.replaceFirst(_trailingZeros, '');
  return trimmed.isEmpty ? '${cut.whole}' : '${cut.whole}.$trimmed';
}

/// Whether the user may type an amount of this token.
bool canTypeAmount(AmountScale scale) => scale.decimalsKnown;

/// The amount a review or receipt states: every digit that is signed, or
/// `12340000 base units` when the decimals are unknown.
String exactAmountText(Object units, AmountScale scale) => scale.decimalsKnown
    ? amountFieldText(units, scale.decimals)
    : formatTokenAmount(units, scale, TokenAmountVariant.confirm);

/// `12340000 base units` split into figure and words for layout.
({String figure, String? words}) splitBaseUnits(String text) {
  final match = RegExp(r' (base units?)$').firstMatch(text);
  return match == null
      ? (figure: text, words: null)
      : (figure: text.substring(0, match.start), words: match.group(1));
}

/// Base units to a double, for fiat display maths only. Never for signing.
double toWholeCoins(String base, int decimals) {
  final raw = integerText(base);
  if (raw == null || raw == '0') return 0;
  final negative = raw.startsWith('-');
  final digits = (negative ? raw.substring(1) : raw).padLeft(decimals + 1, '0');
  final whole = digits.substring(0, digits.length - decimals);
  final fraction = decimals > 0 ? digits.substring(digits.length - decimals) : '0';
  final value = double.tryParse('$whole.$fraction') ?? 0;
  return negative ? -value : value;
}
