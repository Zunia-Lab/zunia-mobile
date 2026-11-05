/// The address book rules (ported from zunia-extension's address-book tests)
/// and the controller's storage: migration of the first mobile shape, and
/// writes that cannot drop each other.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/util/bech32_address.dart';

const hub = 'cosmos1qyyq79says4nyw2qga892hrrdfchsluxcqtzp4';
const hub2 = 'cosmos1qgy3q9c7y5krxwjpfp84vhtydde8nqy8x5y8qg';
const osmo = 'osmo1qyyq79says4nyw2qga892hrrdfchsluxsmcjh8';
const safro = 'addr_safro1qyyq79says4nyw2qga892hrrdfchsluxqv2429';

/// [hub] with its last character changed: right shape, wrong checksum.
const hubTypo = 'cosmos1qyyq79says4nyw2qga892hrrdfchsluxcqtzp5';

const prefixes = {
  'cosmoshub-4': 'cosmos',
  'osmosis-1': 'osmo',
  'safrochain-1': 'addr_safro',
};
String? prefixFor(String chainId) => prefixes[chainId];

List<AddressBookEntry> book() {
  var rows = <AddressBookEntry>[];
  rows = addContact(
    rows,
    const ContactDraft(label: 'Treasury', address: hub),
    now: 1,
    id: 'a',
    prefixFor: prefixFor,
  );
  rows = addContact(
    rows,
    const ContactDraft(label: 'Exchange', address: osmo, chainId: 'osmosis-1'),
    now: 2,
    id: 'b',
    prefixFor: prefixFor,
  );
  return rows;
}

void main() {
  group('address validation', () {
    test('checks the checksum, not only the shape', () {
      expect(isValidBech32Address(hub), isTrue);
      expect(isValidBech32Address(hubTypo), isFalse);
      expect(contactAddressProblem(hubTypo, null, prefixFor), contains('typo'));
    });

    test('reads prefixes with an underscore', () {
      expect(bech32PrefixOf(safro), 'addr_safro');
    });

    test('refuses upper case', () {
      expect(isValidBech32Address(hub.toUpperCase()), isFalse);
    });

    test('requires the chosen network\'s exact prefix', () {
      expect(
        contactAddressProblem(hub, 'osmosis-1', prefixFor),
        'That network uses osmo1… addresses',
      );
      expect(contactAddressProblem(osmo, 'osmosis-1', prefixFor), isNull);
      expect(contactAddressProblem(hub, 'unknown-1', prefixFor), isNull);
      expect(contactAddressProblem('  ', null, prefixFor), 'Enter an address');
      // An operator address is not an account on the Hub.
      expect(
        contactAddressProblem(
          'cosmosvaloper1sjllsnramtg3ewxqwwrwjxfgc4n4ef9u2lcnj0',
          'cosmoshub-4',
          prefixFor,
        ),
        isNotNull,
      );
    });
  });

  group('operations', () {
    test('add trims and starts the counters at zero', () {
      final row = addContact(
        const [],
        const ContactDraft(label: '  Treasury  ', address: ' $hub ', note: '  cold  '),
        now: 10,
        id: 'x',
        prefixFor: prefixFor,
      ).single;
      expect(row.toJson(), {
        'id': 'x',
        'label': 'Treasury',
        'address': hub,
        'note': 'cold',
        'favorite': false,
        'useCount': 0,
        'createdAt': 10,
        'updatedAt': 10,
      });
    });

    test('add refuses a missing name, a bad address and a duplicate', () {
      expect(
        () => addContact(const [], const ContactDraft(label: ' ', address: hub), prefixFor: prefixFor),
        throwsA(isA<AddressBookError>().having((e) => e.message, 'message', contains('name'))),
      );
      expect(
        () => addContact(const [], const ContactDraft(label: 'A', address: hubTypo), prefixFor: prefixFor),
        throwsA(isA<AddressBookError>()),
      );
      expect(
        () => addContact(book(), const ContactDraft(label: 'Again', address: hub), prefixFor: prefixFor),
        throwsA(
          isA<AddressBookError>().having(
            (e) => e.message,
            'message',
            'That address is already saved as Treasury',
          ),
        ),
      );
    });

    test('update edits fields, keeps the counters and stamps the time', () {
      final touched = touchContact(book(), hub, now: 50);
      final next = updateContact(
        touched,
        'a',
        const ContactPatch(label: 'Ops', note: 'multisig', chainId: 'cosmoshub-4'),
        now: 99,
        prefixFor: prefixFor,
      );
      final row = next.firstWhere((e) => e.id == 'a');
      expect(row.label, 'Ops');
      expect(row.note, 'multisig');
      expect(row.chainId, 'cosmoshub-4');
      expect(row.useCount, 1);
      expect(row.lastUsedAt, 50);
      expect(row.createdAt, 1);
      expect(row.updatedAt, 99);
    });

    test('update clears optional fields and validates against the new network', () {
      final cleared = updateContact(
        book(),
        'b',
        const ContactPatch(clearChainId: true, clearNote: true),
        prefixFor: prefixFor,
      );
      expect(cleared.firstWhere((e) => e.id == 'b').chainId, isNull);
      expect(
        () => updateContact(book(), 'b', const ContactPatch(address: hub2), prefixFor: prefixFor),
        throwsA(isA<AddressBookError>()),
      );
      expect(
        () => updateContact(book(), 'missing', const ContactPatch(label: 'X'), prefixFor: prefixFor),
        throwsA(isA<AddressBookError>().having((e) => e.message, 'm', contains('no longer exists'))),
      );
    });

    test('touch counts sends to saved addresses only', () {
      final rows = touchContact(touchContact(book(), osmo, now: 5), osmo, now: 7);
      final row = rows.firstWhere((e) => e.id == 'b');
      expect(row.useCount, 2);
      expect(row.lastUsedAt, 7);
      expect(touchContact(book(), hub2, now: 9).map((e) => e.useCount), [0, 0]);
    });

    test('favourite toggles and remove deletes by id', () {
      final fav = toggleContactFavorite(book(), 'a', now: 3);
      expect(fav.firstWhere((e) => e.id == 'a').favorite, isTrue);
      expect(removeContact(fav, 'a').map((e) => e.id), ['b']);
    });
  });

  group('views', () {
    test('contactsFor offers the exact prefix and the pinned network only', () {
      final rows = book();
      expect(contactsFor(rows, prefix: 'osmo', chainId: 'osmosis-1').map((e) => e.id), ['b']);
      expect(contactsFor(rows, prefix: 'cosmos', chainId: 'cosmoshub-4').map((e) => e.id), ['a']);
      // Same prefix, another network: a contact pinned to osmosis-1 is not offered.
      expect(contactsFor(rows, prefix: 'osmo', chainId: 'osmo-test-5'), isEmpty);
    });

    test('suggested: favourites first, then most recent', () {
      var rows = toggleContactFavorite(book(), 'b', now: 1);
      rows = addContact(
        rows,
        const ContactDraft(label: 'Desk', address: hub2),
        now: 3,
        id: 'c',
        prefixFor: prefixFor,
      );
      rows = touchContact(rows, hub, now: 10);
      rows = touchContact(rows, hub2, now: 20);
      expect(suggestedContacts(rows).map((e) => e.id), ['b', 'c', 'a']);
      expect(recentContacts(rows).map((e) => e.id), ['c', 'a']);
    });

    test('search covers name, address, note and network name', () {
      final rows = book();
      String? name(String id) => id == 'osmosis-1' ? 'Osmosis' : null;
      expect(searchContacts(rows, 'treas', chainName: name).map((e) => e.id), ['a']);
      expect(searchContacts(rows, 'osmosis', chainName: name).map((e) => e.id), ['b']);
      expect(searchContacts(rows, 'qyyq79', chainName: name).length, 2);
    });
  });

  group('storage', () {
    test('migrates the first mobile shape and drops unusable rows', () {
      final rows = migrateAddressBook(
        [
          {'label': 'Old', 'address': hub, 'chainId': 'cosmoshub-4'},
          {'label': 'No address'},
          {'address': osmo},
          {'label': 'Dup', 'address': hub},
          'junk',
        ],
        now: 100,
        newId: () => 'generated',
      );
      expect(rows.length, 2);
      expect(rows.first.id, 'generated');
      expect(rows.first.chainId, 'cosmoshub-4');
      expect(rows.first.createdAt, 100);
      // A nameless row is named after its address.
      expect(rows.last.label, osmo.substring(0, maxContactLabelLength));
    });

    test('the controller upgrades stored rows and serialises writes', () async {
      SharedPreferences.setMockInitialValues({
        'zunia.addressBook': jsonEncode([
          {'label': 'Old', 'address': hub},
        ]),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final book = container.read(addressBookProvider.notifier);
      // Two writes fired together, before the restore has even finished.
      await Future.wait([
        book.add(const ContactDraft(label: 'Exchange', address: osmo)),
        book.add(const ContactDraft(label: 'Desk', address: hub2)),
      ]);
      expect(
        container.read(addressBookProvider).map((e) => e.label),
        ['Desk', 'Exchange', 'Old'],
      );
      final stored = jsonDecode(
        (await SharedPreferences.getInstance()).getString('zunia.addressBook')!,
      ) as List;
      expect(stored.length, 3);
      expect((stored.first as Map)['id'], isNotEmpty);
      expect(
        container.read(contactForAddressProvider(osmo))?.label,
        'Exchange',
      );
      await book.touch(osmo);
      expect(container.read(contactForAddressProvider(osmo))?.useCount, 1);
    });
  });
}
