import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/util/amounts.dart';

/// Amount entry is the one place where a parsing slip moves money. The comma
/// cases are not cosmetic: a French keyboard has no '.' key, and reading '1,5'
/// as 15 would send ten times what the screen shows.
void main() {
  group('parseAmount', () {
    test('comma is a decimal separator, not a thousands separator', () {
      final parsed = parseAmount('1,5', decimals: 6);
      expect(parsed.isValid, isTrue);
      expect(parsed.normalized, '1.5');
      expect(parsed.baseUnits, '1500000');
      // The 10x overspend the old replaceAll(',', '') produced.
      expect(parsed.baseUnits, isNot('15000000'));
    });

    test('dot is a decimal separator', () {
      final parsed = parseAmount('1.5', decimals: 6);
      expect(parsed.isValid, isTrue);
      expect(parsed.normalized, '1.5');
      expect(parsed.baseUnits, '1500000');
    });

    test('anglo grouping: the last separator wins', () {
      final parsed = parseAmount('1,234.56', decimals: 6);
      expect(parsed.isValid, isTrue);
      expect(parsed.normalized, '1234.56');
      expect(parsed.baseUnits, '1234560000');
    });

    test('continental grouping: the last separator wins', () {
      final parsed = parseAmount('1.234,56', decimals: 6);
      expect(parsed.isValid, isTrue);
      expect(parsed.normalized, '1234.56');
      expect(parsed.baseUnits, '1234560000');
    });

    test('repeated separators are grouping', () {
      expect(parseAmount('1.234.567', decimals: 6).normalized, '1234567');
      expect(parseAmount('1,234,567', decimals: 6).normalized, '1234567');
    });

    test('non-breaking space grouping is accepted', () {
      final parsed = parseAmount('1 234,5', decimals: 6);
      expect(parsed.isValid, isTrue);
      expect(parsed.normalized, '1234.5');
    });

    test('empty input reports empty, not a mistake', () {
      expect(parseAmount('', decimals: 6).issue, AmountIssue.empty);
      expect(parseAmount('   ', decimals: 6).issue, AmountIssue.empty);
    });

    test('negative input is refused', () {
      expect(parseAmount('-1', decimals: 6).issue, AmountIssue.negative);
    });

    test('zero is readable but not sendable', () {
      final parsed = parseAmount('0,00', decimals: 6);
      expect(parsed.issue, AmountIssue.notPositive);
      expect(parsed.baseUnits, '0');
    });

    test('letters and stray symbols are refused', () {
      expect(parseAmount('1a', decimals: 6).issue, AmountIssue.notANumber);
      expect(parseAmount('.', decimals: 6).issue, AmountIssue.notANumber);
      expect(parseAmount('1..2', decimals: 6).issue, AmountIssue.notANumber);
    });

    test('more fraction digits than the denom carries is refused', () {
      expect(
        parseAmount('1.2345678', decimals: 6).issue,
        AmountIssue.tooManyDecimals,
      );
      expect(
        parseAmount('1,2345678', decimals: 6).issue,
        AmountIssue.tooManyDecimals,
      );
      expect(parseAmount('1.5', decimals: 0).issue, AmountIssue.tooManyDecimals);
      // Exactly the denom's precision still passes.
      expect(parseAmount('1.234567', decimals: 6).isValid, isTrue);
    });

    test('18-decimal denoms keep full precision', () {
      final parsed = parseAmount('1,000000000000000001', decimals: 18);
      expect(parsed.isValid, isTrue);
      expect(parsed.baseUnits, '1000000000000000001');
    });
  });

  group('toBaseUnits', () {
    test('agrees with parseAmount on both separators', () {
      expect(toBaseUnits('1,5', 6), '1500000');
      expect(toBaseUnits('1.5', 6), '1500000');
      expect(toBaseUnits('1,234.56', 6), '1234560000');
      expect(toBaseUnits('1.234,56', 6), '1234560000');
    });

    test('zero converts, unreadable input does not', () {
      expect(toBaseUnits('0', 6), '0');
      expect(toBaseUnits('', 6), isNull);
      expect(toBaseUnits('-1', 6), isNull);
      expect(toBaseUnits('abc', 6), isNull);
    });

    test('over-precise input is refused rather than truncated', () {
      expect(toBaseUnits('1.2345678', 6), isNull);
    });
  });
}
