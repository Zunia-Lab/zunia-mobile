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

/// Display units back to base units for building a transaction amount.
String toBaseUnits(String display, int decimals) {
  final cleaned = display.replaceAll(',', '').trim();
  if (cleaned.isEmpty) return '0';
  final parts = cleaned.split('.');
  final whole = parts.first.isEmpty ? '0' : parts.first;
  final fraction = (parts.length > 1 ? parts[1] : '')
      .padRight(decimals, '0')
      .substring(0, decimals);
  final joined = '$whole$fraction'.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  return joined.isEmpty ? '0' : joined;
}
