import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/transfers/send_form.dart';

/// The Send form's rules, without a screen.
const me = 'osmo1pyysjzgfpyysjzgfpyysjzgfpyysjzgf4q8lct';
const friend = 'osmo1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5helwsw';
const hub = 'cosmos1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7xu';

final osmo = AmountScale.known(6, 'OSMO', denom: 'uosmo');
const unknown = AmountScale(decimals: 0, decimalsKnown: false, ticker: 'IBC·0123', denom: 'ibc/0123', unknown: true);

void main() {
  group('recipient', () {
    test('wants a valid address on the receiving chain', () {
      expect(checkRecipient(value: '', expectedPrefix: 'osmo', cross: false, ownAddress: me).tone,
          RecipientTone.empty);
      expect(checkRecipient(value: 'osmo1nope', expectedPrefix: 'osmo', cross: false, ownAddress: me).hint,
          'Not a valid address. Check it for a typo.');
      expect(checkRecipient(value: hub, expectedPrefix: 'osmo', cross: false, ownAddress: me).hint,
          'Expected a osmo1… address');
      expect(checkRecipient(value: friend, expectedPrefix: 'osmo', cross: false, ownAddress: me).valid, isTrue);
    });

    test("refuses the wallet's own address on the same chain only", () {
      // An address that checksums: the all-zero one.
      const self = 'osmo1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqmcn030';
      expect(checkRecipient(value: self, expectedPrefix: 'osmo', cross: false, ownAddress: self).hint,
          "That is this wallet's address");
    });

    test('names a saved contact', () {
      final check = checkRecipient(
        value: friend,
        expectedPrefix: 'osmo',
        cross: false,
        ownAddress: me,
        contacts: const [
          AddressBookEntry(id: 'c1', label: 'Ada', address: friend, createdAt: 0, updatedAt: 0),
        ],
      );
      expect(check.hint, 'Saved as Ada');
    });

    test('to another chain, an empty field means this wallet there', () {
      final check = checkRecipient(
        value: '',
        expectedPrefix: 'cosmos',
        cross: true,
        ownAddress: me,
        selfOnDestination: hub,
        destName: 'Cosmos Hub',
      );
      expect(check.valid, isTrue);
      expect(check.hint, 'This wallet on Cosmos Hub');
    });
  });

  group('amount', () {
    test('converts with the token exponent and compares to what can be sent', () {
      final ok = checkAmount(text: '1,5', scale: osmo, spendable: BigInt.from(2000000));
      expect(ok.units, BigInt.from(1500000));
      expect(ok.error, isNull);
      final over = checkAmount(text: '3', scale: osmo, spendable: BigInt.from(2000000));
      expect(over.overBalance, isTrue);
      expect(over.error, 'More than the OSMO available');
    });

    test('never claims over-balance against a balance that was not read', () {
      final check = checkAmount(text: '600', scale: osmo, spendable: null);
      expect(check.overBalance, isFalse);
      expect(check.units, BigInt.from(600000000));
    });

    test('refuses more decimals than the token carries', () {
      expect(checkAmount(text: '1.1234567', scale: osmo, spendable: null).error, 'OSMO carries 6 decimals');
      expect(checkAmount(text: '0', scale: osmo, spendable: null).error, 'Enter an amount above 0');
      expect(checkAmount(text: 'abc', scale: osmo, spendable: null).error, isNotNull);
    });

    test('takes raw base units for a token whose decimals are unknown', () {
      expect(checkAmount(text: '12340000', scale: unknown, spendable: BigInt.from(12340000)).units,
          BigInt.from(12340000));
      expect(checkAmount(text: '1.5', scale: unknown, spendable: null).error, maxOnlyNote);
    });

    test('writes exact percentages of what can be sent', () {
      final spendable = BigInt.parse('1234567890123456789');
      expect(percentText(spendable, 100, AmountScale.known(18, 'INJ')), '1.234567890123456789');
      expect(percentText(BigInt.from(1000001), 50, osmo), '0.5');
      expect(percentText(BigInt.from(12340000), 100, unknown), '12340000');
    });
  });

  group('the Review button', () {
    final valid = checkRecipient(value: friend, expectedPrefix: 'osmo', cross: false, ownAddress: me);
    final amount = checkAmount(text: '1', scale: osmo, spendable: BigInt.from(5000000));

    String? reason({
      bool cross = false,
      bool liveReads = true,
      RecipientCheck? recipient,
      AmountCheck? check,
      String text = '1',
      bool maxOnly = false,
      bool planning = false,
      bool hasPlan = true,
      String? planBlocked,
    }) =>
        sendBlockedReason(
          hasChain: true,
          cross: cross,
          liveReads: liveReads,
          hasDestination: true,
          hasRecipient: true,
          recipient: recipient ?? valid,
          amount: check ?? amount,
          amountText: text,
          maxOnly: maxOnly,
          planning: planning,
          hasPlan: hasPlan,
          planBlocked: planBlocked,
          destName: 'Cosmos Hub',
          sourceName: 'Osmosis',
        );

    test('is on for a valid same-chain send', () {
      expect(reason(), isNull);
    });

    test('always says what is missing', () {
      expect(
        reason(recipient: checkRecipient(value: '', expectedPrefix: 'osmo', cross: false, ownAddress: me)),
        'Enter a recipient.',
      );
      expect(reason(text: '', check: checkAmount(text: '', scale: osmo, spendable: null)), 'Enter an amount.');
      expect(
        reason(text: '', check: checkAmount(text: '', scale: unknown, spendable: null), maxOnly: true),
        "Use Max to set the amount: this token's decimals are unknown.",
      );
      expect(
        reason(check: checkAmount(text: '9', scale: osmo, spendable: BigInt.from(5000000)), text: '9'),
        'More than the OSMO available',
      );
    });

    test('waits for the route on another chain, and repeats why it is blocked', () {
      expect(reason(cross: true, liveReads: false), contains('Turn on live reads'));
      expect(reason(cross: true, planning: true), 'Planning the route…');
      expect(reason(cross: true, hasPlan: false), contains('No channel path from Osmosis to Cosmos Hub'));
      expect(reason(cross: true, planBlocked: 'A channel expired.'), 'A channel expired.');
      expect(reason(cross: true), isNull);
    });
  });
}
