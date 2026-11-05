/// Account sequences: reading a refusal, and not reusing a spent sequence
/// while a public node still answers from an earlier block.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';

void main() {
  group('a refusal', () {
    test('is a sequence mismatch by its code or its words', () {
      expect(isSequenceMismatch('anything', code: 32), isTrue);
      expect(
        isSequenceMismatch('account sequence mismatch, expected 12, got 11: incorrect account sequence'),
        isTrue,
      );
      expect(isSequenceMismatch('insufficient funds', code: 5), isFalse);
    });

    test('names the sequence the chain expects', () {
      expect(
        expectedSequenceOf('account sequence mismatch, expected 12, got 11: incorrect account sequence'),
        12,
      );
      expect(
        expectedSequenceOf(
          'Another transaction from this account went through first. Try again. '
          '(account sequence mismatch, expected 40, got 39: incorrect account sequence)',
        ),
        40,
      );
      expect(expectedSequenceOf('Rejected (code 32)'), isNull);
    });
  });

  group('SequenceFloor', () {
    test('raises a stale read to the next sequence for a while, then trusts the chain', () {
      var now = DateTime(2026, 11, 5, 12);
      final floor = SequenceFloor(ttl: const Duration(minutes: 2), now: () => now);
      floor.remember('safrochain-1', 'addr_safro1me', 8);
      // The node still answers 7 (the block before the last send).
      expect(floor.atLeast('safrochain-1', 'addr_safro1me', 7), 8);
      // A newer answer wins.
      expect(floor.atLeast('safrochain-1', 'addr_safro1me', 9), 9);
      // Another chain or address is untouched.
      expect(floor.atLeast('osmosis-1', 'addr_safro1me', 3), 3);
      now = now.add(const Duration(minutes: 3));
      expect(floor.atLeast('safrochain-1', 'addr_safro1me', 7), 7);
    });

    test('keeps the higher of two remembered sequences while fresh', () {
      final now = DateTime(2026, 11, 5, 12);
      final floor = SequenceFloor(now: () => now);
      floor.remember('osmosis-1', 'osmo1me', 5);
      floor.remember('osmosis-1', 'osmo1me', 4);
      expect(floor.atLeast('osmosis-1', 'osmo1me', 0), 5);
    });
  });
}
