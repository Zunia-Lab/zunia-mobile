/// `ceil(gas × price)`, in exact integer arithmetic.
///
/// Catalog gas prices are doubles, and an 18-decimal chain prices gas in
/// hundreds of millions of base units: Injective's "high" is 1.5e9 inj per gas.
/// Scaling such a price into an `int` before multiplying overflows 64 bits, and
/// Dart clamps an out-of-range `double.round()` to 2^63-1 rather than failing.
/// That is how a 400000-gas Injective send was quoted 3689348814742 inj
/// (`(2^63-1) × 400000 / 10^12`) when the chain wanted at least 6.4e13.
///
/// The price is read as the decimal it prints as (`0.0025`, `1500000000.0`,
/// `8e-7`), so a catalog's `0.025` is 25/1000 exactly rather than its nearest
/// binary fraction. Zero, negative and non-finite prices cost nothing.
BigInt gasFee(BigInt gas, double price) {
  if (gas <= BigInt.zero || !price.isFinite || price <= 0) return BigInt.zero;
  final (numerator, denominator) = decimalFraction(price);
  final product = gas * numerator;
  final whole = product ~/ denominator;
  return product % denominator == BigInt.zero ? whole : whole + BigInt.one;
}

/// [value] as `numerator / denominator`, with the denominator a power of ten.
///
/// Reads Dart's shortest round-trip spelling, which is a plain decimal or
/// `<mantissa>e<exponent>` for very small and very large values.
(BigInt, BigInt) decimalFraction(double value) {
  final text = value.abs().toString().toLowerCase();
  final parts = text.split('e');
  var mantissa = parts[0];
  var exponent = parts.length > 1 ? int.parse(parts[1]) : 0;
  final dot = mantissa.indexOf('.');
  if (dot >= 0) {
    // `1500000000.0` is a whole number: drop the fraction's trailing zeros so
    // the denominator is the smallest power of ten that holds the value.
    final fraction = mantissa.substring(dot + 1).replaceFirst(RegExp(r'0+$'), '');
    exponent -= fraction.length;
    mantissa = mantissa.substring(0, dot) + fraction;
  }
  final digits = BigInt.parse(mantissa);
  final ten = BigInt.from(10);
  final numerator = exponent >= 0 ? digits * ten.pow(exponent) : digits;
  final denominator = exponent >= 0 ? BigInt.one : ten.pow(-exponent);
  return (value < 0 ? -numerator : numerator, denominator);
}
