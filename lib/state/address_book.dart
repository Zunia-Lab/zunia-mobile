/// The address book: saved recipients, their favourite flag and how often they
/// are sent to. Addresses are public data, so plain SharedPreferences is the
/// right store.
///
/// Every rule lives in pure functions over the list (a mirror of
/// zunia-extension/lib/address-book.ts), so validation, migration and the
/// usage counters are tested without storage; [AddressBookController] only
/// reads, applies one of them, and writes.
///
/// Stable API for other workstreams:
///
/// ```dart
/// ref.watch(addressBookProvider)                    // List<AddressBookEntry>, by name
/// ref.watch(contactForAddressProvider(address))     // AddressBookEntry? (signing review)
/// contactsFor(rows, prefix: 'osmo', chainId: id)    // what Send may offer on a chain
/// suggestedContacts(rows)                           // favourites, then recent
/// final book = ref.read(addressBookProvider.notifier);
/// await book.add(ContactDraft(label: 'Desk', address: a, chainId: id));
/// await book.touch(address);   // after a send went through: use count + last used
/// await book.update(id, ContactPatch(note: 'memo required'));
/// await book.toggleFavorite(id);
/// await book.remove(id);
/// ```
///
/// `add` and `update` throw [AddressBookError] with a sentence fit to show.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/util/bech32_address.dart';

const maxContactLabelLength = 40;
const maxContactNoteLength = 140;
const maxContacts = 500;
const recentContactsLimit = 5;

@immutable
class AddressBookEntry {
  const AddressBookEntry({
    required this.id,
    required this.label,
    required this.address,
    this.chainId,
    this.note,
    this.favorite = false,
    this.lastUsedAt,
    this.useCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String label;
  final String address;

  /// Set when the address belongs to one network, e.g. an exchange deposit
  /// address. Null means any network whose prefix matches.
  final String? chainId;
  final String? note;
  final bool favorite;

  /// Milliseconds since the epoch of the last send that went through.
  final int? lastUsedAt;

  /// Sends that went through to this address.
  final int useCount;
  final int createdAt;
  final int updatedAt;

  /// The prefix the address carries, or null when it fails its checksum.
  String? get prefix => bech32PrefixOf(address);

  /// False for a row an older build saved without a checksum check. Kept, so
  /// the user sees it and fixes or deletes it rather than losing it silently.
  bool get isValid => prefix != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'address': address,
        if (chainId != null) 'chainId': chainId,
        if (note != null) 'note': note,
        'favorite': favorite,
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt,
        'useCount': useCount,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  AddressBookEntry _with({
    String? label,
    String? address,
    String? Function()? chainId,
    String? Function()? note,
    bool? favorite,
    int? lastUsedAt,
    int? useCount,
    int? updatedAt,
  }) =>
      AddressBookEntry(
        id: id,
        label: label ?? this.label,
        address: address ?? this.address,
        chainId: chainId == null ? this.chainId : chainId(),
        note: note == null ? this.note : note(),
        favorite: favorite ?? this.favorite,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        useCount: useCount ?? this.useCount,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is AddressBookEntry &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// A new contact, before it has an id and counters.
@immutable
class ContactDraft {
  const ContactDraft({
    required this.label,
    required this.address,
    this.chainId,
    this.note,
    this.favorite = false,
  });

  final String label;
  final String address;
  final String? chainId;
  final String? note;
  final bool favorite;
}

/// Fields an edit may change. Null leaves a field as it is; [clearChainId] and
/// [clearNote] remove the optional ones.
@immutable
class ContactPatch {
  const ContactPatch({
    this.label,
    this.address,
    this.chainId,
    this.note,
    this.clearChainId = false,
    this.clearNote = false,
  });

  final String? label;
  final String? address;
  final String? chainId;
  final String? note;
  final bool clearChainId;
  final bool clearNote;
}

class AddressBookError implements Exception {
  const AddressBookError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The bech32 prefix a chain's addresses carry, when the chain is known.
typedef PrefixLookup = String? Function(String chainId);

String? catalogPrefix(String chainId) => ChainCatalog.isLoaded
    ? ChainCatalog.instance.find(chainId)?.bech32Prefix
    : null;

/// Why [address] cannot be saved, or null when it can.
///
/// Checks the checksum, not only the shape, and when a network is chosen,
/// that the prefix is the one that network uses. `startsWith` would let
/// `cosmosvaloper1…` pass for the Hub, and a transfer to an operator address
/// is lost.
String? contactAddressProblem(
  String address,
  String? chainId,
  PrefixLookup prefixFor,
) {
  final value = address.trim();
  if (value.isEmpty) return 'Enter an address';
  final prefix = bech32PrefixOf(value);
  if (prefix == null) return 'Not a valid address. Check it for a typo.';
  if (chainId == null || chainId.isEmpty) return null;
  final expected = prefixFor(chainId);
  if (expected == null) return null;
  if (prefix != expected) return 'That network uses ${expected}1… addresses';
  return null;
}

String _cleanLabel(String label) {
  final value = label.trim();
  return value.length > maxContactLabelLength
      ? value.substring(0, maxContactLabelLength)
      : value;
}

String? _cleanNote(String? note) {
  var value = (note ?? '').trim();
  if (value.length > maxContactNoteLength) {
    value = value.substring(0, maxContactNoteLength);
  }
  return value.isEmpty ? null : value;
}

String? _cleanChainId(String? chainId) {
  final value = (chainId ?? '').trim();
  return value.isEmpty ? null : value;
}

int _byLabel(AddressBookEntry a, AddressBookEntry b) {
  final byName = a.label.toLowerCase().compareTo(b.label.toLowerCase());
  return byName != 0 ? byName : a.createdAt.compareTo(b.createdAt);
}

final _random = Random.secure();

/// A random v4-shaped id. Ids only need to be unique within one book.
String newContactId() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/* -------------------------------------------------------------------------- *
 * Migration
 * -------------------------------------------------------------------------- */

int? _finite(Object? value) {
  if (value is int && value >= 0) return value;
  if (value is double && value.isFinite && value >= 0) return value.floor();
  return null;
}

/// Stored rows in the current shape, whatever build wrote them.
///
/// The first mobile build kept `{label, address, chainId?}` with no id. Its
/// rows gain the new fields with neutral values. A row without a string
/// address is dropped, since nothing can be sent to it; an address that fails
/// the checksum is kept (see [AddressBookEntry.isValid]).
List<AddressBookEntry> migrateAddressBook(
  Object? raw, {
  int? now,
  String Function()? newId,
}) {
  if (raw is! List) return const [];
  final at = now ?? DateTime.now().millisecondsSinceEpoch;
  final makeId = newId ?? newContactId;
  final out = <AddressBookEntry>[];
  final ids = <String>{};
  final addresses = <String>{};
  for (final value in raw) {
    if (value is! Map) continue;
    final address = value['address'] is String
        ? (value['address'] as String).trim()
        : '';
    if (address.isEmpty || !addresses.add(address)) continue;
    var id = value['id'] is String ? value['id'] as String : '';
    if (id.isEmpty || ids.contains(id)) id = makeId();
    ids.add(id);
    final createdAt = _finite(value['createdAt']) ?? at;
    final label =
        value['label'] is String ? _cleanLabel(value['label'] as String) : '';
    out.add(
      AddressBookEntry(
        id: id,
        label: label.isEmpty
            ? (address.length > maxContactLabelLength
                ? address.substring(0, maxContactLabelLength)
                : address)
            : label,
        address: address,
        chainId: value['chainId'] is String
            ? _cleanChainId(value['chainId'] as String)
            : null,
        note: value['note'] is String ? _cleanNote(value['note'] as String) : null,
        favorite: value['favorite'] == true,
        lastUsedAt: _finite(value['lastUsedAt']),
        useCount: _finite(value['useCount']) ?? 0,
        createdAt: createdAt,
        updatedAt: _finite(value['updatedAt']) ?? createdAt,
      ),
    );
    if (out.length >= maxContacts) break;
  }
  return out;
}

/* -------------------------------------------------------------------------- *
 * Operations on the list
 * -------------------------------------------------------------------------- */

AddressBookEntry _require(List<AddressBookEntry> rows, String id) {
  for (final row in rows) {
    if (row.id == id) return row;
  }
  throw const AddressBookError('That contact no longer exists');
}

List<AddressBookEntry> addContact(
  List<AddressBookEntry> rows,
  ContactDraft draft, {
  int? now,
  String? id,
  PrefixLookup prefixFor = catalogPrefix,
}) {
  final label = _cleanLabel(draft.label);
  final address = draft.address.trim();
  final chainId = _cleanChainId(draft.chainId);
  if (label.isEmpty) throw const AddressBookError('Give this address a name');
  final problem = contactAddressProblem(address, chainId, prefixFor);
  if (problem != null) throw AddressBookError(problem);
  for (final row in rows) {
    if (row.address == address) {
      throw AddressBookError('That address is already saved as ${row.label}');
    }
  }
  if (rows.length >= maxContacts) {
    throw const AddressBookError('The address book is full');
  }
  final at = now ?? DateTime.now().millisecondsSinceEpoch;
  return [
    ...rows,
    AddressBookEntry(
      id: id ?? newContactId(),
      label: label,
      address: address,
      chainId: chainId,
      note: _cleanNote(draft.note),
      favorite: draft.favorite,
      createdAt: at,
      updatedAt: at,
    ),
  ];
}

List<AddressBookEntry> updateContact(
  List<AddressBookEntry> rows,
  String id,
  ContactPatch patch, {
  int? now,
  PrefixLookup prefixFor = catalogPrefix,
}) {
  final current = _require(rows, id);
  final label = patch.label == null ? current.label : _cleanLabel(patch.label!);
  final address = patch.address == null ? current.address : patch.address!.trim();
  final chainId = patch.clearChainId
      ? null
      : patch.chainId == null
          ? current.chainId
          : _cleanChainId(patch.chainId);
  final note = patch.clearNote
      ? null
      : patch.note == null
          ? current.note
          : _cleanNote(patch.note);
  if (label.isEmpty) throw const AddressBookError('Give this address a name');
  final problem = contactAddressProblem(address, chainId, prefixFor);
  if (problem != null) throw AddressBookError(problem);
  for (final row in rows) {
    if (row.id != id && row.address == address) {
      throw AddressBookError('That address is already saved as ${row.label}');
    }
  }
  final next = current._with(
    label: label,
    address: address,
    chainId: () => chainId,
    note: () => note,
    updatedAt: now ?? DateTime.now().millisecondsSinceEpoch,
  );
  return [for (final row in rows) row.id == id ? next : row];
}

List<AddressBookEntry> removeContact(List<AddressBookEntry> rows, String id) =>
    rows.where((row) => row.id != id).toList();

List<AddressBookEntry> toggleContactFavorite(
  List<AddressBookEntry> rows,
  String id, {
  int? now,
}) {
  final current = _require(rows, id);
  final next = current._with(
    favorite: !current.favorite,
    updatedAt: now ?? DateTime.now().millisecondsSinceEpoch,
  );
  return [for (final row in rows) row.id == id ? next : row];
}

/// Count a send that went through to [address]. An address that is not saved
/// is left alone: the book only holds what the user chose to save.
List<AddressBookEntry> touchContact(
  List<AddressBookEntry> rows,
  String address, {
  int? now,
}) {
  final value = address.trim();
  final at = now ?? DateTime.now().millisecondsSinceEpoch;
  return [
    for (final row in rows)
      row.address == value
          ? row._with(lastUsedAt: at, useCount: row.useCount + 1)
          : row,
  ];
}

/* -------------------------------------------------------------------------- *
 * Views
 * -------------------------------------------------------------------------- */

/// Sorted by name, the order the book screen lists them in.
List<AddressBookEntry> sortContacts(List<AddressBookEntry> rows) =>
    [...rows]..sort(_byLabel);

/// Contacts a transfer to this network can use: the exact prefix, and when the
/// contact is pinned to a network, that same network. A contact saved for
/// another chain is never offered.
List<AddressBookEntry> contactsFor(
  List<AddressBookEntry> rows, {
  String? prefix,
  String? chainId,
}) =>
    rows
        .where(
          (row) =>
              (prefix == null || row.prefix == prefix) &&
              (row.chainId == null || chainId == null || row.chainId == chainId),
        )
        .toList();

/// Most recently used first.
List<AddressBookEntry> recentContacts(
  List<AddressBookEntry> rows, {
  int limit = recentContactsLimit,
}) {
  final used = rows.where((row) => row.lastUsedAt != null).toList()
    ..sort((a, b) => b.lastUsedAt!.compareTo(a.lastUsedAt!));
  return used.take(limit).toList();
}

/// The few contacts worth a one-tap chip: favourites, then recent ones.
List<AddressBookEntry> suggestedContacts(
  List<AddressBookEntry> rows, {
  int limit = 4,
}) {
  final favorites = sortContacts(rows.where((row) => row.favorite).toList());
  final recent = recentContacts(rows, limit: rows.length)
      .where((row) => !row.favorite);
  return [...favorites, ...recent].take(limit).toList();
}

/// The saved contact for [address], if any.
AddressBookEntry? contactByAddress(List<AddressBookEntry> rows, String address) {
  final value = address.trim();
  for (final row in rows) {
    if (row.address == value) return row;
  }
  return null;
}

/// Contacts whose name, address, note or network matches [query].
List<AddressBookEntry> searchContacts(
  List<AddressBookEntry> rows,
  String query, {
  String? Function(String chainId)? chainName,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return rows;
  return rows.where((row) {
    final network = row.chainId;
    return row.label.toLowerCase().contains(q) ||
        row.address.toLowerCase().contains(q) ||
        (row.note ?? '').toLowerCase().contains(q) ||
        (network != null &&
            (network.toLowerCase().contains(q) ||
                (chainName?.call(network) ?? '').toLowerCase().contains(q)));
  }).toList();
}

/* -------------------------------------------------------------------------- *
 * Storage
 * -------------------------------------------------------------------------- */

const _kAddressBook = 'zunia.addressBook';

class AddressBookController extends StateNotifier<List<AddressBookEntry>> {
  AddressBookController() : super(const []) {
    _ready = _restore();
  }

  late final Future<void> _ready;
  Future<void> _queue = Future<void>.value();

  /// Completes once the stored rows are loaded.
  Future<void> get ready => _ready;

  Future<void> _restore() async {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(_kAddressBook);
    if (raw == null) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    final rows = migrateAddressBook(decoded);
    if (mounted) state = sortContacts(rows);
    // Written back once, so older rows are upgraded in place rather than on
    // every read.
    final upgraded = jsonEncode([for (final row in rows) row.toJson()]);
    if (upgraded != raw) await store.setString(_kAddressBook, upgraded);
  }

  /// One change at a time: each reads the list the previous one wrote, so two
  /// taps in quick succession cannot drop each other's edit.
  Future<T> _serial<T>(Future<T> Function() task) {
    final next = _queue.then((_) => _ready).then((_) => task());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _write(List<AddressBookEntry> rows) async {
    if (mounted) state = sortContacts(rows);
    final store = await SharedPreferences.getInstance();
    await store.setString(
      _kAddressBook,
      jsonEncode([for (final row in rows) row.toJson()]),
    );
  }

  /// Save a new contact. Returns the saved row.
  Future<AddressBookEntry> add(ContactDraft draft) => _serial(() async {
        final next = addContact(state, draft);
        await _write(next);
        return next.last;
      });

  Future<void> update(String id, ContactPatch patch) =>
      _serial(() => _write(updateContact(state, id, patch)));

  Future<void> remove(String id) =>
      _serial(() => _write(removeContact(state, id)));

  Future<void> toggleFavorite(String id) =>
      _serial(() => _write(toggleContactFavorite(state, id)));

  /// Record a send that went through to [address]. Unsaved addresses are
  /// ignored. Call it after the chain accepted the transaction, not before.
  Future<void> touch(String address) => _serial(() async {
        if (contactByAddress(state, address) == null) return;
        await _write(touchContact(state, address));
      });
}

final addressBookProvider =
    StateNotifierProvider<AddressBookController, List<AddressBookEntry>>(
  (ref) => AddressBookController(),
);

/// The saved contact for an address, or null. For the signing review ("Sending
/// to Treasury") and the send form.
final contactForAddressProvider =
    Provider.family<AddressBookEntry?, String>((ref, address) {
  return contactByAddress(ref.watch(addressBookProvider), address);
});
