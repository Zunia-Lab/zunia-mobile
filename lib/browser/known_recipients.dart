/// Addresses the user has paid through a dApp prompt before, so paying one
/// again is not flagged "First-time recipient". Addresses only: text a site put
/// where a recipient goes, which the chain would refuse, must not silence the
/// warning for whatever it resembles. Kept apart from the address book, which
/// is the user's own list; the prompt reads both.
library;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';

const _kKnownRecipients = 'zunia.signing.knownRecipients';

/// More than anyone pays by hand; the oldest go first past it.
const _maxRemembered = 2000;

class KnownRecipients {
  KnownRecipients._();

  static final instance = KnownRecipients._();

  Future<Set<String>> load() async {
    final store = await SharedPreferences.getInstance();
    return (store.getStringList(_kKnownRecipients) ?? const []).toSet();
  }

  Future<void> rememberAll(Iterable<String> addresses) async {
    final fresh = addresses.where((a) => shownAddressPrefix(a) != null).toList();
    if (fresh.isEmpty) return;
    final store = await SharedPreferences.getInstance();
    final list = store.getStringList(_kKnownRecipients) ?? <String>[];
    for (final address in fresh) {
      list
        ..remove(address)
        ..add(address);
    }
    final kept = list.length > _maxRemembered ? list.sublist(list.length - _maxRemembered) : list;
    await store.setStringList(_kKnownRecipients, kept);
  }
}
