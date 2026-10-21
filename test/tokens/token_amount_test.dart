import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/util/amounts.dart';

import '../support/catalog.dart';

/// The amount policy (extension lib/__tests__/token-amount.test.ts): exact
/// integer arithmetic on base units, a precision per surface, and raw base
/// units for a token whose decimals nobody knows.
const usdcNOnOsmosis = 'ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4';
const unlisted = 'ibc/0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF';
const variants = TokenAmountVariant.values;

void main() {
  setUpAll(loadBundledData);

  AmountScale usdcN() => AmountScale.of(identityOf('osmosis-1', usdcNOnOsmosis));
  AmountScale unknown() => AmountScale.of(identityOf('osmosis-1', unlisted));
  AmountScale inj() => AmountScale.of(identityOf('injective-1', 'inj'));

  group('unknown decimals', () {
    test('show raw base units where a 0-decimal compact reads millions', () {
      expect(unknown().decimalsKnown, isFalse);
      for (final variant in variants) {
        expect(formatTokenAmount('12340000', unknown(), variant), '12340000 base units');
      }
    });

    test('never add a k, M or Bn suffix, at any size', () {
      for (final amount in ['999', '12340', '12340000', '123456789012345678901234567890']) {
        for (final variant in variants) {
          expect(formatTokenAmount(amount, unknown(), variant), '$amount $baseUnitsWords');
        }
      }
    });

    test('keep the sign and read text that is not an integer as 0', () {
      expect(formatTokenAmount('-12340000', unknown(), TokenAmountVariant.history), '-12340000 base units');
      expect(formatTokenAmount(' 0012340000 ', unknown(), TokenAmountVariant.list), '12340000 base units');
      expect(formatTokenAmount('12.5', unknown(), TokenAmountVariant.list), '0 base units');
      expect(formatTokenAmount('1', unknown(), TokenAmountVariant.picker), '1 base unit');
    });
  });

  group('known decimals', () {
    test('use each surface precision', () {
      expect(formatTokenAmount('12340000', usdcN(), TokenAmountVariant.list), '12.34');
      expect(formatTokenAmount('20340000000', usdcN(), TokenAmountVariant.list), '20.34k');
      expect(formatTokenAmount('20345600000', usdcN(), TokenAmountVariant.history), '20.345k');
      expect(formatTokenAmount('1000000000000', usdcN(), TokenAmountVariant.history), '1M');
      expect(formatTokenAmount('1500000000000', usdcN(), TokenAmountVariant.list), '1.50M');
      expect(formatTokenAmount('12500000', usdcN(), TokenAmountVariant.list), '12.50');
      expect(formatTokenAmount('20340000000', usdcN(), TokenAmountVariant.picker), '20340');
      expect(formatTokenAmount('1234567891', usdcN(), TokenAmountVariant.confirm), '1234.567891');
    });

    test('cut an 18-decimal amount, never rounding up', () {
      expect(formatTokenAmount('1234567890123456789', inj(), TokenAmountVariant.picker), '1.234567');
      expect(formatTokenAmount('1234567890123456789', inj(), TokenAmountVariant.list), '1.23');
      expect(formatTokenAmount('1234567890123456789', inj(), TokenAmountVariant.history), '1.234');
      expect(formatTokenAmount('999999', usdcN(), TokenAmountVariant.list), '0.99');
      expect(formatTokenAmount('999999999', usdcN(), TokenAmountVariant.list), '999.99');
      expect(formatTokenAmount('999999999999', usdcN(), TokenAmountVariant.list), '999.99k');
    });

    test('stay exact past what a double holds, with no exponent', () {
      expect(formatTokenAmount('9007199254740995123456', usdcN(), TokenAmountVariant.confirm),
          '9007199254740995.123456');
      const huge = '123456789012345678901234567890';
      expect(formatTokenAmount(huge, usdcN(), TokenAmountVariant.confirm), '123456789012345678901234.56789');
      expect(formatTokenAmount(huge, usdcN(), TokenAmountVariant.list), '123456789012345.67Bn');
      for (final variant in variants) {
        expect(formatTokenAmount(huge, usdcN(), variant), isNot(contains('e+')));
      }
    });

    test('never show a non-zero amount as zero', () {
      expect(formatTokenAmount('123', inj(), TokenAmountVariant.confirm), '<0.000001');
      expect(formatTokenAmount('80000000000000', inj(), TokenAmountVariant.history, unit: true), '<0.001 INJ');
      expect(formatTokenAmount('-80000000000000', inj(), TokenAmountVariant.history), '-<0.001');
      expect(formatTokenAmount('4', usdcN(), TokenAmountVariant.list), '<0.01');
      expect(formatTokenAmount('0', usdcN(), TokenAmountVariant.list), '0.00');
      expect(formatTokenAmount('0', usdcN(), TokenAmountVariant.history), '0');
    });

    test('append the unit, or the short denom of a token nothing names', () {
      expect(formatTokenAmount('12340000', usdcN(), TokenAmountVariant.history, unit: true), '12.34 USDC.n');
      expect(formatTokenAmount('12340000', unknown(), TokenAmountVariant.history, unit: true),
          '12340000 base units ibc/0123…ABCDEF');
      expect(amountUnit(usdcN()), 'USDC.n');
      expect(amountUnit(unknown()), 'ibc/0123…ABCDEF');
    });

    test('mask the whole text in hidden mode', () {
      for (final variant in variants) {
        expect(formatTokenAmount('12340000', usdcN(), variant, hidden: true, unit: true), maskedAmount);
      }
    });
  });

  group('amountFieldText', () {
    BigInt? fieldUnits(String text, int decimals) {
      final parsed = parseAmount(text, decimals: decimals);
      return parsed.issue == null || parsed.issue == AmountIssue.notPositive ? BigInt.parse(parsed.baseUnits) : null;
    }

    test('gives Max a text that converts back to the exact balance', () {
      for (final raw in ['0', '1', '123', '1234567890123456789', '9007199254740993', '123456789012345678901234567890']) {
        for (final decimals in [18, 6, 0]) {
          final text = amountFieldText(raw, decimals);
          expect(RegExp(r'^\d+(\.\d+)?$').hasMatch(text), isTrue, reason: '$raw at $decimals');
          expect(fieldUnits(text, decimals), BigInt.parse(raw), reason: '$raw at $decimals');
        }
      }
      expect(amountFieldText('1234567890123456789', 18), '1.234567890123456789');
      expect(amountFieldText(BigInt.from(12340000), 6), '12.34');
    });

    test('gives 0 for text that is not a balance', () {
      expect(amountFieldText('-5', 6), '0');
      expect(amountFieldText('12.5', 6), '0');
      expect(amountFieldText('', 6), '0');
    });
  });

  group('formatBaseUnits (shared list format)', () {
    test('uses integer arithmetic: no float rounding, no exponent', () {
      expect(formatBaseUnits('12340000', decimals: 6), '12.34');
      expect(formatBaseUnits('20340000000', decimals: 6), '20.34k');
      expect(formatBaseUnits('1500000000000', decimals: 6), '1.50M');
      expect(formatBaseUnits('999999', decimals: 6), '0.99');
      expect(formatBaseUnits('4', decimals: 6), '<0.01');
      expect(formatBaseUnits('0', decimals: 6), '0.00');
      expect(formatBaseUnits('1234567890123456789012345', decimals: 18), '1.23M');
      expect(formatBaseUnits('-1500000', decimals: 6), '-1.50');
      expect(formatBaseUnits('1234567', decimals: 6, maxFractionDigits: 4), '1.2345');
      expect(formatBaseUnits('garbage', decimals: 6), '0.00');
    });
  });

  group('toWholeCoins', () {
    test('is for fiat display only, from exact digits', () {
      expect(toWholeCoins('1500000', 6), 1.5);
      expect(toWholeCoins('0', 6), 0);
      expect(toWholeCoins('-2500000', 6), -2.5);
      expect(toWholeCoins('nope', 6), 0);
    });
  });
}
