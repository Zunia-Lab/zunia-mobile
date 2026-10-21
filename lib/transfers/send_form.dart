/// The Send form's rules, kept pure so every branch is tested without a
/// screen: which recipient is acceptable, which amount, and the one sentence
/// the disabled Review button shows.
///
/// Mirrors the validation in `zunia-extension/entrypoints/popup/screens/
/// SendScreen.tsx` (0.1.5). A balance that was not read never produces an
/// "over balance" claim; only a number the chain gave is compared.
library;

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/util/address_payload.dart';
import 'package:zunia_mobile/util/amounts.dart';

enum RecipientTone { empty, error, valid }

@immutable
class RecipientCheck {
  const RecipientCheck(this.tone, this.hint);

  final RecipientTone tone;

  /// `Saved as Alice`, `Expected a osmo1… address`, null while empty.
  final String? hint;

  bool get valid => tone == RecipientTone.valid;
}

/// Is [value] an address this send may go to?
///
/// [expectedPrefix] is the bech32 prefix of the chain that receives: the
/// sending chain for a same-chain send, the destination for another chain.
RecipientCheck checkRecipient({
  required String value,
  required String? expectedPrefix,
  required bool cross,
  required String? ownAddress,
  String? selfOnDestination,
  List<AddressBookEntry> contacts = const [],
  String? destName,
}) {
  final text = value.trim();
  if (text.isEmpty) {
    if (cross && (selfOnDestination ?? '').isNotEmpty) {
      return RecipientCheck(
        RecipientTone.valid,
        destName == null ? 'This wallet on the destination' : 'This wallet on $destName',
      );
    }
    return const RecipientCheck(RecipientTone.empty, null);
  }
  if (!isValidBech32(text)) {
    return const RecipientCheck(RecipientTone.error, 'Not a valid address. Check it for a typo.');
  }
  if (expectedPrefix != null && bech32Prefix(text) != expectedPrefix) {
    return RecipientCheck(RecipientTone.error, 'Expected a ${expectedPrefix}1… address');
  }
  if (!cross && ownAddress != null && text == ownAddress) {
    return const RecipientCheck(RecipientTone.error, "That is this wallet's address");
  }
  for (final contact in contacts) {
    if (contact.address == text) return RecipientCheck(RecipientTone.valid, 'Saved as ${contact.label}');
  }
  return const RecipientCheck(RecipientTone.valid, 'Valid address');
}

@immutable
class AmountCheck {
  const AmountCheck({required this.units, required this.error, required this.overBalance});

  /// Base units typed, or null when the text is not an amount of this token.
  final BigInt? units;

  /// What is wrong with the text, for under the field. Null while empty.
  final String? error;

  /// More than can be sent. Only ever true against a balance that was read.
  final bool overBalance;
}

/// Reads the typed amount with the token's own exponent. A token whose
/// decimals are unknown takes only Max: its field holds raw base units.
AmountCheck checkAmount({
  required String text,
  required AmountScale scale,
  required BigInt? spendable,
}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const AmountCheck(units: null, error: null, overBalance: false);
  final parsed = parseAmount(trimmed, decimals: scale.decimalsKnown ? scale.decimals : 0);
  switch (parsed.issue) {
    case AmountIssue.empty:
      return const AmountCheck(units: null, error: null, overBalance: false);
    case AmountIssue.notANumber:
      return const AmountCheck(units: null, error: 'Use digits with , or . before the decimals', overBalance: false);
    case AmountIssue.negative:
      return const AmountCheck(units: null, error: 'Enter a positive amount', overBalance: false);
    case AmountIssue.tooManyDecimals:
      return AmountCheck(
        units: null,
        error: scale.decimalsKnown
            ? '${scale.ticker} carries ${scale.decimals} decimals'
            : maxOnlyNote,
        overBalance: false,
      );
    case AmountIssue.notPositive:
      return const AmountCheck(units: null, error: 'Enter an amount above 0', overBalance: false);
    case null:
      final units = BigInt.parse(parsed.baseUnits);
      final over = spendable != null && units > spendable;
      return AmountCheck(
        units: units,
        error: over ? 'More than the ${scale.ticker} available' : null,
        overBalance: over,
      );
  }
}

/// The text Max (or a percentage) writes: exact digits for any size.
String percentText(BigInt spendable, int percent, AmountScale scale) {
  final units = spendable * BigInt.from(percent) ~/ BigInt.from(100);
  return amountFieldText(units, scale.decimalsKnown ? scale.decimals : 0);
}

/// Why the Review button is off, or null when it may be pressed. A disabled
/// control always says what is missing.
String? sendBlockedReason({
  required bool hasChain,
  required bool cross,
  required bool liveReads,
  required bool hasDestination,
  required bool hasRecipient,
  required RecipientCheck recipient,
  required AmountCheck amount,
  required String amountText,
  required bool maxOnly,
  required bool planning,
  String? planError,
  String? planBlocked,
  bool hasPlan = false,
  String? destName,
  String? sourceName,
}) {
  if (!hasChain) return 'Enable at least one network first.';
  if (cross && !liveReads) {
    return 'Sending to another chain plans the route from public endpoints. Turn on live reads in Settings.';
  }
  if (cross && !hasDestination) return 'Pick a destination network.';
  if (cross && !hasRecipient) return 'This wallet has no address on the destination. Add one to continue.';
  if (recipient.tone == RecipientTone.empty) return 'Enter a recipient.';
  if (recipient.tone != RecipientTone.valid) return recipient.hint;
  if (amountText.trim().isEmpty) {
    return maxOnly ? "Use Max to set the amount: this token's decimals are unknown." : 'Enter an amount.';
  }
  if (amount.units == null) return amount.error ?? 'That amount is not a number this chain can hold.';
  if (amount.units! <= BigInt.zero) return 'Enter an amount above zero.';
  if (amount.overBalance) return amount.error;
  if (!cross) return null;
  if (planning) return 'Planning the route…';
  if (planError != null) return planError;
  if (!hasPlan) {
    return 'No channel path from ${sourceName ?? 'this network'} to ${destName ?? 'there'}. '
        'Use Edit route to enter one.';
  }
  return planBlocked;
}
