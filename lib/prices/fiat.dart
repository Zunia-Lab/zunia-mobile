/// Fiat amounts, the way the wallet writes them.
///
/// A fiat value is a display product of a price (a double by nature) and a
/// token amount (exact, BigInt); it is never fed back into anything signed.
library;

const Map<String, String> _symbols = {
  'usd': r'$',
  'eur': '€',
  'gbp': '£',
  'jpy': '¥',
  'chf': 'CHF ',
};

String currencySymbol(String currency) => _symbols[currency.toLowerCase()] ?? r'$';

/// JPY has no minor unit in everyday prices.
int _fractionDigits(String currency) => currency.toLowerCase() == 'jpy' ? 0 : 2;

String _grouped(int whole) {
  final digits = whole.abs().toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// `$12.41k`, `€1.50M`, `£12.50`: two decimals and k / M / Bn, as list rows
/// and the extension show it. Cut, not rounded up.
String formatFiatCompact(double value, String currency) {
  if (!value.isFinite) value = 0;
  final sign = value < 0 ? '-' : '';
  final abs = value.abs();
  final symbol = currencySymbol(currency);
  String scaled(double v, String suffix) => '${_cut(v, 2)}$suffix';
  if (abs >= 1e9) return '$sign$symbol${scaled(abs / 1e9, 'Bn')}';
  if (abs >= 1e6) return '$sign$symbol${scaled(abs / 1e6, 'M')}';
  if (abs >= 1e3) return '$sign$symbol${scaled(abs / 1e3, 'k')}';
  return '$sign$symbol${_cut(abs, _fractionDigits(currency))}';
}

/// `$12,408.20`: every digit up to a million, grouped, for the headline.
/// Above a million it reads compact, which a phone's hero line can hold.
String formatFiatFull(double value, String currency) {
  if (!value.isFinite) value = 0;
  if (value.abs() >= 1e6) return formatFiatCompact(value, currency);
  final sign = value < 0 ? '-' : '';
  final digits = _fractionDigits(currency);
  final text = _cut(value.abs(), digits);
  final parts = text.split('.');
  final whole = _grouped(int.parse(parts.first));
  return '$sign${currencySymbol(currency)}$whole${parts.length > 1 ? '.${parts[1]}' : ''}';
}

/// One coin's price, with the digits a small price needs: two decimals from 1
/// up, else four significant digits, so SAF reads `$0.0002010`, not `$0.00`.
String formatFiatPrice(double value, String currency) {
  if (!value.isFinite || value <= 0) return formatFiatFull(0, currency);
  if (value >= 1) return formatFiatFull(value, currency);
  final exponent = (value.toStringAsExponential(3).split('e').last);
  final magnitude = int.tryParse(exponent) ?? -1;
  final decimals = (-magnitude + 3).clamp(2, 12);
  var text = value.toStringAsFixed(decimals);
  if (text.contains('.')) text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return '${currencySymbol(currency)}$text';
}

/// `+1.2%` / `-0.4%`.
String formatChange(double change, {int digits = 1}) =>
    '${change >= 0 ? '+' : ''}${change.toStringAsFixed(digits)}%';

/// [value] with at most [digits] fraction digits, cut toward zero.
String _cut(double value, int digits) {
  final factor = _pow10(digits);
  // A tiny epsilon keeps 0.29 * 100 from reading 28.999999…
  final scaled = (value * factor + 1e-9).floorToDouble();
  final whole = (scaled / factor).floor();
  final fraction = (scaled - whole * factor).round();
  if (digits == 0) return '$whole';
  return '$whole.${fraction.toString().padLeft(digits, '0')}';
}

double _pow10(int digits) {
  var out = 1.0;
  for (var i = 0; i < digits; i++) {
    out *= 10;
  }
  return out;
}
