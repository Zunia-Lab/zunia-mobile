import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/screens/wallet_setup_flow.dart';

/// Restoring a phrase: what is accepted, and what the user is told when it
/// is not.
void main() {
  const valid =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon about';

  test('pasted lists lose their numbering, case and separators', () {
    expect(
      normalizeImportedPhrase(
        '1. Abandon\n2) abandon, 3 abandon;4.abandon\t5-abandon abandon abandon '
        'abandon abandon abandon abandon ABOUT ',
      ),
      valid,
    );
  });

  test('a valid 12-word phrase passes', () {
    expect(importedPhraseProblem(valid), isNull);
  });

  test('an unknown word is named with its position', () {
    final typo = valid.replaceFirst('about', 'abuot');
    expect(importedPhraseProblem(typo), contains('Word 12 ("abuot")'));
    final two = 'abandn ${valid.split(' ').skip(1).join(' ').replaceFirst('about', 'abuot')}';
    expect(importedPhraseProblem(two), startsWith('Words 1, 12'));
  });

  test('the word count must be 12 or 24', () {
    final eleven = valid.split(' ').take(11).join(' ');
    expect(importedPhraseProblem(eleven), contains('This one has 11'));
  });

  test('valid words in the wrong order fail the checksum', () {
    final swapped = valid.replaceFirst('about', 'abandon');
    expect(importedPhraseProblem(swapped), contains('checksum'));
  });

  test('empty input asks for the phrase', () {
    expect(importedPhraseProblem(''), 'Paste or type your recovery phrase.');
  });
}
