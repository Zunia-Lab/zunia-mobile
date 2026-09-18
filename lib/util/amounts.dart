/// Base-unit to display-unit conversion, shared by every screen that shows a
/// balance so rounding and grouping never drift between them.
library;

/// Compact magnitude: 2 decimals + k / M / Bn.
/// Examples: `20.34k`, `1.50M`, `2.10Bn`, `12.50`.
String formatCompact(num value, {int fractionDigits = 2}) {
  if (value.isNaN || value.isInfinite) return '0.00';
  final sign = value < 0 ? '-' : '';
  final abs = value.abs().toDouble();
  if (abs >= 1000000000) {
    return '$sign${(abs / 1000000000).toStringAsFixed(fractionDigits)}Bn';
  }
  if (abs >= 1000000) {
    return '$sign${(abs / 1000000).toStringAsFixed(fractionDigits)}M';
  }
  if (abs >= 1000) {
    return '$sign${(abs / 1000).toStringAsFixed(fractionDigits)}k';
  }
  return '$sign${abs.toStringAsFixed(fractionDigits)}';
}

num _baseUnitsToNumber(String base, int decimals) {
  final negative = base.startsWith('-');
  final digits = (negative ? base.substring(1) : base).split('.').first;
  if (digits.isEmpty || !RegExp(r'^\d+$').hasMatch(digits)) return 0;

  final padded = digits.padLeft(decimals + 1, '0');
  final whole = padded.substring(0, padded.length - decimals);
  final fraction =
      decimals == 0 ? '0' : padded.substring(padded.length - decimals);
  final value = num.parse('$whole.$fraction');
  return negative ? -value : value;
}

/// Full-precision display for amount inputs (Send %, etc.).
String formatBaseUnitsExact(
  String base, {
  required int decimals,
  int? maxFractionDigits,
}) {
  final digitsLimit = maxFractionDigits ?? decimals;
  final negative = base.startsWith('-');
  final digits = (negative ? base.substring(1) : base).split('.').first;
  if (digits.isEmpty || !RegExp(r'^\d+$').hasMatch(digits)) return '0';

  final padded = digits.padLeft(decimals + 1, '0');
  final whole = padded.substring(0, padded.length - decimals);
  var fraction =
      decimals == 0 ? '' : padded.substring(padded.length - decimals);
  if (fraction.length > digitsLimit) {
    fraction = fraction.substring(0, digitsLimit);
  }
  fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  final body = fraction.isEmpty
      ? whole.replaceFirst(RegExp(r'^0+(?=\d)'), '')
      : '${whole.replaceFirst(RegExp(r'^0+(?=\d)'), '')}.$fraction';
  final normalized = body.isEmpty || body == '.' ? '0' : body;
  return negative ? '-$normalized' : normalized;
}

/// Turns base units into a compact display string (`20.34k`, `1.50M`, …).
String formatBaseUnits(
  String base, {
  required int decimals,
  int maxFractionDigits = 2,
}) {
  return formatCompact(
    _baseUnitsToNumber(base, decimals),
    fractionDigits: maxFractionDigits,
  );
}

/// Optional fiat compact helper (`$20.34k`).
String formatFiatCompact(num value, {String symbol = r'$'}) {
  final sign = value < 0 ? '-' : '';
  return '$sign$symbol${formatCompact(value.abs())}';
}

/// Why a typed amount cannot be used as entered.
enum AmountIssue {
  /// Nothing typed yet. Not a mistake, so the UI stays quiet.
  empty,

  /// Contains something that is not a number.
  notANumber,

  /// A minus sign; there is no such thing as a negative transfer.
  negative,

  /// Parsed to zero, which no send or delegate can use.
  notPositive,

  /// More fraction digits than the denom can represent. Truncating here would
  /// silently send a different amount than the one on screen.
  tooManyDecimals,
}

/// A user-typed amount after normalisation.
class AmountInput {
  const AmountInput._({
    required this.issue,
    required this.normalized,
    required this.baseUnits,
  });

  /// Null when the amount can be used as typed.
  final AmountIssue? issue;

  /// Canonical form with '.' as the decimal point, empty when unreadable.
  /// Screens pass this on rather than the raw text so every later step sees
  /// one separator regardless of the keyboard that produced it.
  final String normalized;

  /// Integer base units for the denom, '0' when unreadable.
  final String baseUnits;

  bool get isValid => issue == null;
}

const _amountSpaces = ['\u00A0', '\u202F', '\u2009', ' '];

/// Reads an amount the way a person types it.
///
/// Both ',' and '.' are accepted as the decimal separator because a French or
/// German keyboard offers only ','. When a string carries both, the last one
/// is the decimal separator and the other is grouping, so '1,234.56' and
/// '1.234,56' are the same number. A lone separator is always read as the
/// decimal point: reading '1,5' as 15 would overspend by 10x, while reading
/// '1,234' as 1.234 only underspends and is visible on the review step.
AmountInput parseAmount(String input, {required int decimals}) {
  var text = input.trim();
  for (final space in _amountSpaces) {
    text = text.replaceAll(space, '');
  }
  if (text.isEmpty) return _issue(AmountIssue.empty);
  if (text.startsWith('-')) return _issue(AmountIssue.negative);
  if (text.startsWith('+')) text = text.substring(1);

  final lastComma = text.lastIndexOf(',');
  final lastDot = text.lastIndexOf('.');
  final String? body;
  if (lastComma >= 0 && lastDot >= 0) {
    final decimalAt = lastComma > lastDot ? lastComma : lastDot;
    final grouping = lastComma > lastDot ? '.' : ',';
    final whole = _ungroup(text.substring(0, decimalAt), grouping);
    body = whole == null ? null : '$whole.${text.substring(decimalAt + 1)}';
  } else if (lastComma >= 0) {
    // Repeats can only be grouping ('1,234,567'); a single one is decimal.
    body = text.indexOf(',') == lastComma
        ? text.replaceFirst(',', '.')
        : _ungroup(text, ',');
  } else if (lastDot >= 0 && text.indexOf('.') != lastDot) {
    body = _ungroup(text, '.');
  } else {
    body = text;
  }
  if (body == null) return _issue(AmountIssue.notANumber);

  final match = RegExp(r'^(\d*)(?:\.(\d*))?$').firstMatch(body);
  if (match == null) return _issue(AmountIssue.notANumber);
  final whole = match.group(1) ?? '';
  final fraction = match.group(2) ?? '';
  if (whole.isEmpty && fraction.isEmpty) return _issue(AmountIssue.notANumber);
  if (fraction.length > decimals) return _issue(AmountIssue.tooManyDecimals);

  final digits = '${whole.isEmpty ? '0' : whole}'
      '${fraction.padRight(decimals, '0')}';
  final trimmed = digits.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final baseUnits = trimmed.isEmpty ? '0' : trimmed;
  final normalized = fraction.isEmpty
      ? (whole.isEmpty ? '0' : whole)
      : '${whole.isEmpty ? '0' : whole}.$fraction';
  return AmountInput._(
    issue: baseUnits == '0' ? AmountIssue.notPositive : null,
    normalized: normalized,
    baseUnits: baseUnits,
  );
}

/// Removes a thousands separator, or returns null when the groups are not
/// shaped like grouping ('1..2', '12,3,4') so the caller can refuse the input
/// instead of inventing a number from it.
String? _ungroup(String text, String separator) {
  final parts = text.split(separator);
  if (parts.length < 2) return text;
  if (parts.first.isEmpty || parts.first.length > 3) return null;
  for (final part in parts.skip(1)) {
    if (part.length != 3) return null;
  }
  return parts.join();
}

AmountInput _issue(AmountIssue issue) =>
    AmountInput._(issue: issue, normalized: '', baseUnits: '0');

/// Display units back to base units for building a transaction amount.
///
/// Returns null when the text is not a number this denom can carry, including
/// when it has more fraction digits than [decimals]: rounding a transfer down
/// without telling the user is not an option.
String? toBaseUnits(String display, int decimals) {
  final parsed = parseAmount(display, decimals: decimals);
  final issue = parsed.issue;
  if (issue == null || issue == AmountIssue.notPositive) {
    return parsed.baseUnits;
  }
  return null;
}
